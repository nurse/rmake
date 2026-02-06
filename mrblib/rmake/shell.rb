module RMake
  class Shell
    def initialize(dry_run = false)
      @dry_run = dry_run
    end

    def self.supports_spawn?
      Object.const_defined?(:Process) && Process.respond_to?(:spawn)
    end

    def run(cmd, vars, env_vars = nil)
      env_vars ||= {}
      expanded = Util.expand(cmd, vars, env_vars)
      silent, ignore_fail, force, expanded = Util.strip_cmd_prefixes(expanded)
      recursive = force || recursive_make_cmd?(expanded, vars)
      force = true if recursive
      exec_cmd = with_makelevel(expanded, vars, recursive)
      if @dry_run && !force
        puts expanded
        return true
      end
      puts expanded unless silent

      ok, status = run_command(exec_cmd)
      if ignore_fail && !ok
        emit_ignored_error(env_vars, status, vars)
      end
      ok || ignore_fail
    end

    def spawn_recipe(node, vars, env_vars = nil)
      env_vars ||= {}
      script = +"set -e\n"
      node.recipe.each do |raw|
        expanded = Util.expand(raw, vars, env_vars)
        silent, ignore_fail, force, expanded = Util.strip_cmd_prefixes(expanded)
        recursive = force || recursive_make_cmd?(expanded, vars)
        force = true if recursive
        exec_cmd = with_makelevel(expanded, vars, recursive)
        if @dry_run && !force
          puts expanded
          next
        end
        script << "echo #{escape_sh(expanded)}\n" unless silent
        if ignore_fail
          prefix = ignored_error_prefix(env_vars, vars).gsub("\"", "\\\"")
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
      assign = recursive_make_assignments(vars)
      return cmd if assign.empty?
      inject = "env #{assign} #{make_cmd}"
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

    def recursive_make_assignments(vars)
      current = nil
      if Object.const_defined?(:ENV)
        current = ENV["MAKELEVEL"]
      end
      current = var_value(vars, "MAKELEVEL") if (current.nil? || current.empty?) && vars
      level = current ? current.to_i + 1 : 1
      parts = ["MAKELEVEL=#{level}"]
      flags = nil
      mflags = nil
      if Object.const_defined?(:ENV)
        flags = ENV["MAKEFLAGS"]
        mflags = ENV["MFLAGS"]
      end
      flags = var_value(vars, "MAKEFLAGS") if (flags.nil? || flags.empty?) && vars
      parts << "MAKEFLAGS=#{Util.shell_escape(flags)}" if flags && !flags.empty?
      mflags = var_value(vars, "MFLAGS") if (mflags.nil? || mflags.empty?) && vars
      parts << "MFLAGS=#{Util.shell_escape(mflags)}" if mflags && !mflags.empty?
      parts.join(" ")
    end

    def var_value(vars, name)
      var = vars[name]
      return nil unless var
      var.simple ? var.value.to_s : Util.expand(var.value.to_s, vars, {})
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
      level = nil
      if Object.const_defined?(:ENV) && ENV["MAKELEVEL"]
        level = ENV["MAKELEVEL"].to_i
      end
      if (level.nil? || level == 0) && vars && vars["MAKELEVEL"]
        val = vars["MAKELEVEL"]
        level = val.simple ? val.value.to_i : Util.expand(val.value.to_s, vars, {}).to_i
      end
      prefix = "make[#{level}]" if level && level > 0
      if label.empty?
        "#{prefix}: Error "
      else
        "#{prefix}: #{label} Error "
      end
    end

  end
end
