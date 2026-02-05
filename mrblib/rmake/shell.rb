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
      silent, ignore_fail, expanded = Util.strip_cmd_prefixes(expanded)
      exec_cmd = with_makelevel(expanded)
      if @dry_run
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
        silent, ignore_fail, expanded = Util.strip_cmd_prefixes(expanded)
        exec_cmd = with_makelevel(expanded)
        if @dry_run
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
      return 0 if @dry_run
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

    def with_makelevel(cmd)
      return cmd unless Object.const_defined?(:ENV)
      make = ENV["MAKE"]
      return cmd if make.nil? || make.empty?
      return cmd unless cmd.lstrip.start_with?(make)
      current = ENV["MAKELEVEL"]
      level = current ? current.to_i + 1 : 1
      "MAKELEVEL=#{level} #{cmd}"
    end

    def escape_sh(str)
      "'" + str.gsub("'", "'\"'\"'") + "'"
    end
  end
end
