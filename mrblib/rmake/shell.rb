module RMake
  class Shell
    attr_reader :last_error

    def initialize(dry_run = false, silent = false, ignore_errors = false)
      @dry_run = dry_run
      @silent = silent
      @ignore_errors = ignore_errors
      @last_error = nil
    end

    def dry_run?
      @dry_run
    end

    def self.supports_spawn?
      Object.const_defined?(:Process) && Process.respond_to?(:spawn)
    end

    def run(cmd, vars, env_vars = nil)
      @last_error = nil
      env_vars ||= {}
      loc_file, loc_line, raw_cmd = Util.extract_location(cmd.to_s)
      expand_ctx = env_vars.dup
      if loc_file && !loc_file.empty?
        expand_ctx["__file"] = loc_file
        expand_ctx["__line"] = loc_line
      end
      base_silent, base_ignore, base_force, body = Util.strip_cmd_prefixes(raw_cmd.to_s)
      expanded = Util.expand(body, vars, expand_ctx)
      return [true, false] if expanded.nil? || expanded.strip.empty?
      ran = false
      expanded.split("\n", -1).each do |line|
        silent, ignore_fail, force, line_cmd = Util.strip_cmd_prefixes(line.to_s)
        silent ||= base_silent
        ignore_fail ||= base_ignore
        ignore_fail ||= @ignore_errors
        force ||= base_force
        next if line_cmd.nil? || line_cmd.strip.empty?
        recursive = force || recursive_make_cmd?(line_cmd, vars)
        force = true if recursive
        exec_cmd = with_makelevel(line_cmd, vars, recursive)
        exec_cmd = apply_recipe_exports(exec_cmd, vars, recursive)
        if @dry_run && !force
          puts line_cmd
          ran = true
          next
        end
        if @dry_run && force
          puts line_cmd unless @silent
        else
          puts line_cmd unless silent || @silent
        end
        print_dirs = recursive && print_directory_for_recursive?(vars)
        if print_dirs
          puts "#{recursive_make_prefix(vars)}: Entering directory '#{Dir.pwd}'"
        end
        ok, status = run_command(exec_cmd)
        if print_dirs
          puts "#{recursive_make_prefix(vars)}: Leaving directory '#{Dir.pwd}'"
        end
        unless ok
          @last_error = {
            status: status || 1,
            line_cmd: line_cmd,
            file: expand_ctx["__file"],
            line: expand_ctx["__line"],
          }
          if ignore_fail
            emit_ignored_error(expand_ctx, status, vars)
            ran = true
            next
          end
          return [false, true]
        end
        ran = true
      end
      [true, ran]
    end

    def run_recipe(recipe, vars, env_vars = nil)
      @last_error = nil
      env_vars ||= {}
      prepared = []
      recipe.each do |raw|
        loc_file, loc_line, recipe_line = Util.extract_location(raw.to_s)
        expand_ctx = env_vars.dup
        if loc_file && !loc_file.empty?
          expand_ctx["__file"] = loc_file
          expand_ctx["__line"] = loc_line
        end
        base_silent, base_ignore, base_force, body = Util.strip_cmd_prefixes(recipe_line.to_s)
        expanded = Util.expand(body, vars, expand_ctx)
        next if expanded.nil? || expanded.strip.empty?
        expanded.split("\n", -1).each do |line|
          silent, ignore_fail, force, line_cmd = Util.strip_cmd_prefixes(line.to_s)
          silent ||= base_silent
          ignore_fail ||= base_ignore
          ignore_fail ||= @ignore_errors
          force ||= base_force
          next if line_cmd.nil? || line_cmd.strip.empty?
          recursive = force || recursive_make_cmd?(line_cmd, vars)
          force = true if recursive
          exec_cmd = with_makelevel(line_cmd, vars, recursive)
          exec_cmd = apply_recipe_exports(exec_cmd, vars, recursive)
          prepared << [line_cmd, exec_cmd, silent, ignore_fail, force, expand_ctx]
        end
      end

      ran = false
      prepared.each do |line_cmd, exec_cmd, silent, ignore_fail, force, expand_ctx|
        if @dry_run && !force
          puts line_cmd
          ran = true
          next
        end
        if @dry_run && force
          puts line_cmd unless @silent
        else
          puts line_cmd unless silent || @silent
        end
        print_dirs = recursive_make_cmd?(line_cmd, vars) && print_directory_for_recursive?(vars)
        if print_dirs
          puts "#{recursive_make_prefix(vars)}: Entering directory '#{Dir.pwd}'"
        end
        ok, status = run_command(exec_cmd)
        if print_dirs
          puts "#{recursive_make_prefix(vars)}: Leaving directory '#{Dir.pwd}'"
        end
        unless ok
          @last_error = {
            status: status || 1,
            line_cmd: line_cmd,
            file: expand_ctx["__file"],
            line: expand_ctx["__line"],
          }
          if ignore_fail
            emit_ignored_error(expand_ctx, status, vars)
            ran = true
            next
          end
          return [false, true]
        end
        ran = true
      end
      [true, ran]
    end

    def spawn_recipe(node, vars, env_vars = nil)
      env_vars ||= {}
      script = +"set -e\n"
      node.recipe.each do |raw|
        loc_file, loc_line, recipe = Util.extract_location(raw.to_s)
        expand_ctx = env_vars.dup
        if loc_file && !loc_file.empty?
          expand_ctx["__file"] = loc_file
          expand_ctx["__line"] = loc_line
        end
        expanded = Util.expand(recipe, vars, expand_ctx)
        silent, ignore_fail, force, expanded = Util.strip_cmd_prefixes(expanded)
        next if expanded.nil? || expanded.strip.empty?
        recursive = force || recursive_make_cmd?(expanded, vars)
        force = true if recursive
        exec_cmd = with_makelevel(expanded, vars, recursive)
        exec_cmd = apply_recipe_exports(exec_cmd, vars, recursive)
        if @dry_run && !force
          puts expanded
          next
        end
        script << "echo #{escape_sh(expanded)}\n" unless silent || @silent
        if ignore_fail
          prefix = ignored_error_prefix(expand_ctx, vars).gsub("\"", "\\\"")
          script << "if /bin/sh -c #{escape_sh(exec_cmd)}; then :; else __rmake_status=$?; "
          script << "echo \"#{prefix}$__rmake_status (ignored)\"; "
          script << "fi\n"
        else
          script << "#{exec_cmd}\n"
        end
      end
      return 0 if @dry_run && script == "set -e\n"
      Process.spawn("/bin/sh", "-c", script)
    end


    def wait_any
      pid, status = Process.waitpid2(-1)
      [pid, status.exitstatus]
    end

    private

    def run_command(cmd)
      if Kernel.respond_to?(:system)
        ok = system(cmd)
        code = $?.respond_to?(:exitstatus) ? $?.exitstatus : ($?.to_i)
        return [ok, code || 1]
      end
      if Object.const_defined?(:Process) && Process.respond_to?(:spawn)
        pid = Process.spawn("/bin/sh", "-c", cmd)
        _, status = Process.waitpid2(pid)
        code = status.exitstatus
        return [code == 0, code]
      end
      if IO.respond_to?(:popen)
        IO.popen("/bin/sh -c #{escape_sh(cmd)}") do |io|
          if Object.const_defined?(:STDOUT) && STDOUT.respond_to?(:write)
            loop do
              chunk = io.read(4096)
              break if chunk.nil? || chunk.empty?
              STDOUT.write(chunk)
            end
          else
            io.read
          end
        end
        code = $?.to_i
        return [code == 0, code]
      end
      [false, 1]
    end

    def with_makelevel(cmd, vars, recursive)
      return cmd unless recursive

      make_cmd = nil
      if Object.const_defined?(:ENV)
        make_cmd = ENV["MAKE"]
      end
      make_cmd = var_value(vars, "MAKE") if (make_cmd.nil? || make_cmd.empty?) && vars
      return cmd if make_cmd.nil? || make_cmd.empty?
      assign = recursive_make_assignments(vars, cmd)
      return cmd if assign.empty?
      inject = "env #{assign} #{make_cmd}"
      extra_args = recursive_make_extra_args(vars, cmd)
      inject += " #{extra_args}" unless extra_args.empty?
      stripped = cmd.lstrip
      if stripped.start_with?(make_cmd)
        lead = cmd[0...(cmd.length - stripped.length)]
        rest = stripped[make_cmd.length..-1].to_s
        return lead + inject + rest
      end
      idx = cmd.index(make_cmd)
      return cmd unless idx
      before = cmd[0...idx]
      return cmd unless idx == 0 || before.end_with?(" ", "\t", ";", "&", "|", "(")
      after = cmd[(idx + make_cmd.length)..-1].to_s
      before + inject + after
    end

    def recursive_make_assignments(vars, cmd = nil)
      current = nil
      if Object.const_defined?(:ENV)
        current = ENV["MAKELEVEL"]
      end
      current = var_value(vars, "MAKELEVEL") if (current.nil? || current.empty?) && vars
      level = current ? current.to_i + 1 : 1
      parts = ["MAKELEVEL=#{level}"]
      cmd_s = cmd.to_s
      override_makeflags = cmd_s.include?("MAKEFLAGS=")
      flags = nil
      mflags = nil
      if Object.const_defined?(:ENV)
        flags = ENV["MAKEFLAGS"]
        mflags = ENV["MFLAGS"]
      end
      unless override_makeflags
        flags = var_value(vars, "MAKEFLAGS") if (flags.nil? || flags.empty?) && vars
        parts << "MAKEFLAGS=#{Util.shell_escape(flags)}" if flags && !flags.empty?
        mflags = var_value(vars, "MFLAGS") if (mflags.nil? || mflags.empty?) && vars
        parts << "MFLAGS=#{Util.shell_escape(mflags)}" if mflags && !mflags.empty?
      end
      parts.join(" ")
    end

    def recursive_make_extra_args(vars, cmd = nil)
      parts = []
      env_override = var_value(vars, "__RMAKE_ENV_OVERRIDE__")
      if (env_override.nil? || env_override.empty?) && Object.const_defined?(:ENV)
        env_override = ENV["__RMAKE_ENV_OVERRIDE__"]
      end
      if env_override == "1"
        cmd_s = cmd.to_s
        parts << "-e" unless cmd_s.include?("MAKEFLAGS=")
      end

      cli_assigns = var_value(vars, "__RMAKE_CLI_ASSIGNS_ESC")
      if (cli_assigns.nil? || cli_assigns.empty?) && vars
        cli_assigns = var_value(vars, "__RMAKE_CLI_ASSIGNS_ESC__")
      end
      if (cli_assigns.nil? || cli_assigns.empty?) && Object.const_defined?(:ENV)
        cli_assigns = ENV["__RMAKE_CLI_ASSIGNS_ESC"]
      end
      parts << cli_assigns if cli_assigns && !cli_assigns.empty?
      parts.join(" ")
    end

    def recursive_make_prefix(vars)
      base = "make"
      mk = nil
      if Object.const_defined?(:ENV)
        mk = ENV["MAKE"]
      end
      mk = var_value(vars, "MAKE") if (mk.nil? || mk.empty?) && vars
      if mk && !mk.empty?
        token = Util.split_ws(mk).first
        base = File.basename(token) if token && !token.empty?
      end
      level = 0
      if Object.const_defined?(:ENV)
        lv = ENV["MAKELEVEL"]
        level = lv.to_i if lv && !lv.empty?
      end
      if level == 0
        lv = var_value(vars, "MAKELEVEL")
        level = lv.to_i if lv && !lv.empty?
      end
      level += 1
      "#{base}[#{level}]"
    end

    def print_directory_for_recursive?(vars)
      flags = nil
      if Object.const_defined?(:ENV)
        flags = ENV["MAKEFLAGS"]
      end
      flags = var_value(vars, "MAKEFLAGS") if (flags.nil? || flags.empty?) && vars
      flags = var_value(vars, "MFLAGS") if (flags.nil? || flags.empty?) && vars
      return false if flags_include_silent?(flags)
      return false if flags && flags.include?("--no-print-directory")
      return true if flags && (flags.include?("-w") || flags.include?("--print-directory"))
      true
    end

    def flags_include_silent?(flags)
      return false if flags.nil? || flags.empty?
      parts = Util.split_ws(flags)
      parts.each do |p|
        token = p.to_s
        return true if token == "s" || token == "-s" || token == "--silent" || token == "--quiet"
        if token.start_with?("-") && !token.start_with?("--")
          chars = token[1..-1].to_s
          return true if chars.index("s")
          next
        end
        next unless alpha_token?(token)
        return true if token.index("s")
      end
      false
    end

    def alpha_token?(token)
      return false if token.nil? || token.empty?
      i = 0
      while i < token.length
        ch = token[i]
        code = ch.ord
        upper = code >= 65 && code <= 90
        lower = code >= 97 && code <= 122
        return false unless upper || lower
        i += 1
      end
      true
    end

    def var_value(vars, name)
      var = vars[name]
      return nil unless var
      var.simple ? var.value.to_s : Util.expand(var.value.to_s, vars, {})
    end

    def apply_recipe_exports(cmd, vars, recursive = false)
      return cmd if vars.nil?
      suppress_makeflags = recursive && cmd.to_s.include?("MAKEFLAGS=")
      exports = var_value(vars, "__RMAKE_EXPORTS__")
      names = []
      names.concat(Util.split_ws(exports)) if exports && !exports.empty?
      env_keys = var_value(vars, "__RMAKE_ENV_KEYS__")
      if env_keys && !env_keys.empty?
        Util.split_ws(env_keys).each do |name|
          next if name.nil? || name.empty?
          next if suppress_makeflags && (name == "MAKEFLAGS" || name == "MFLAGS")
          names << name if vars[name]
        end
      end
      %w[MAKE MAKEFLAGS MFLAGS MAKELEVEL MAKECMDGOALS].each do |name|
        next if suppress_makeflags && (name == "MAKEFLAGS" || name == "MFLAGS")
        names << name if vars[name]
      end
      seen = {}
      names = names.reject do |name|
        next true if name.nil? || name.empty?
        if seen[name]
          true
        else
          seen[name] = true
          false
        end
      end
      return cmd if names.empty?
      assigns = []
      names.each do |name|
        next if name.nil? || name.empty?
        val = var_value(vars, name)
        if val.nil? && Object.const_defined?(:ENV)
          val = ENV[name]
        end
        val = "" if val.nil?
        assigns << "#{name}=#{Util.shell_escape(val.to_s)}"
      end
      return cmd if assigns.empty?
      "env #{assigns.join(' ')} /bin/sh -c #{Util.shell_escape(cmd)}"
    end

    def recursive_make_cmd?(cmd, vars)
      make_cmd = nil
      if Object.const_defined?(:ENV)
        make_cmd = ENV["MAKE"]
      end
      if make_cmd.nil? || make_cmd.empty?
        make_cmd = var_value(vars, "MAKE") if vars
      end
      return false if make_cmd.nil? || make_cmd.empty?
      stripped = cmd.lstrip
      return true if stripped.start_with?(make_cmd)
      idx = cmd.index(make_cmd)
      return false unless idx
      before = cmd[0...idx]
      idx == 0 || before.end_with?(" ", "\t", ";", "&", "|", "(")
    end

    def escape_sh(str)
      "'" + str.gsub("'", "'\"'\"'") + "'"
    end

    def emit_ignored_error(env_vars, status, vars = nil)
      line = ignored_error_line(env_vars, status, vars)
      return if line.empty?
      if Kernel.respond_to?(:warn)
        warn line
      else
        puts line
      end
    end

    def ignored_error_line(env_vars, status, vars = nil)
      prefix = ignored_error_prefix(env_vars, vars)
      return "" if prefix.empty?
      status_i = status.nil? ? 1 : status.to_i
      "#{prefix}#{status_i} (ignored)"
    end

    def ignored_error_prefix(env_vars, vars = nil)
      target = nil
      if env_vars && env_vars["@"] && !env_vars["@"].to_s.empty?
        target = env_vars["@"].to_s
      end
      label = target ? "[#{target}]" : ""
      prefix = "make"
      mk = nil
      if Object.const_defined?(:ENV)
        mk = ENV["MAKE"]
      end
      if mk && !mk.empty?
        token = Util.split_ws(mk).first
        prefix = File.basename(token) if token && !token.empty?
      end
      level = nil
      if Object.const_defined?(:ENV) && ENV["MAKELEVEL"]
        level = ENV["MAKELEVEL"].to_i
      end
      if (level.nil? || level == 0) && vars && vars["MAKELEVEL"]
        val = vars["MAKELEVEL"]
        level = val.simple ? val.value.to_i : Util.expand(val.value.to_s, vars, {}).to_i
      end
      prefix = "#{prefix}[#{level}]" if level && level > 0
      if label.empty?
        "#{prefix}: Error "
      else
        "#{prefix}: #{label} Error "
      end
    end

  end
end
