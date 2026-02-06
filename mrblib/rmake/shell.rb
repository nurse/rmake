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

      ok = run_command(exec_cmd)
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
          script << "#{exec_cmd} || true\n"
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
        return system(cmd)
      end
      if Object.const_defined?(:Process) && Process.respond_to?(:spawn)
        pid = Process.spawn("/bin/sh", "-c", cmd)
        _, status = Process.waitpid2(pid)
        return status.exitstatus == 0
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
        return $?.to_i == 0
      end
      false
    end

    def with_makelevel(cmd, vars, recursive)
      return cmd unless recursive

      make_cmd = nil
      if Object.const_defined?(:ENV)
        make_cmd = ENV["MAKE"]
      end
      make_cmd = var_value(vars, "MAKE") if (make_cmd.nil? || make_cmd.empty?) && vars
      return cmd if make_cmd.nil? || make_cmd.empty?
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
      prefix = parts.join(" ") + " "
      stripped = cmd.lstrip
      return prefix + cmd if stripped.start_with?(make_cmd)
      idx = cmd.index(make_cmd)
      return cmd unless idx
      before = cmd[0...idx]
      after = cmd[idx..-1]
      before_strip = before.rstrip
      if before_strip.end_with?("exec")
        exec_idx = before_strip.rindex("exec")
        if exec_idx && (exec_idx == 0 || " \t;&|(".include?(before_strip[exec_idx - 1]))
          return before[0...exec_idx] + prefix + before[exec_idx..-1] + after
        end
      end
      return cmd unless idx == 0 || before.end_with?(" ", "\t", ";", "&", "|", "(")
      before + prefix + after
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

  end
end
