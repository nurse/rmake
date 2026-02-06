module RMake
  class CLI
    def self.run(argv)
      opts, jobs_set = parse_args(argv)

      if opts[:help]
        print_help
        return 0
      end

      if opts[:chdir]
        return with_chdir(opts[:chdir]) { run_with_opts(opts, jobs_set) }
      end

      run_with_opts(opts, jobs_set)
    end

    def self.run_with_opts(opts, jobs_set)

      if opts[:makefile] == "Makefile" && File.exist?("GNUmakefile")
        opts[:makefile] = "GNUmakefile"
      end

      make_cmd = make_command
      set_env_make_vars(make_cmd, opts)

      pass = 0
      evalr = nil
      graph = nil
      remade = {}
      loop do
        begin
          evalr, graph = load_makefile(opts, make_cmd)
        rescue Errno::ENOENT
          if opts[:makefile] == "Makefile" || opts[:makefile] == "GNUmakefile"
            if opts[:target] && !opts[:target].to_s.empty?
              msg = "#{make_prefix}: *** No rule to make target `#{opts[:target]}'. Stop."
            else
              msg = "#{make_prefix}: *** No targets specified and no makefile found. Stop."
            end
          else
            msg = "#{make_prefix}: #{opts[:makefile]}: No such file or directory"
          end
          if Kernel.respond_to?(:warn)
            warn msg
          else
            puts msg
          end
          return 2
        end
        rebuilt = remake_includes(evalr, graph, opts, remade)
        pass += 1
        break unless rebuilt && pass < 2
      end

      missing = missing_required_includes(evalr)
      if missing.any?
        missing.each do |path|
          if Kernel.respond_to?(:warn)
            warn "rmake: #{path}: No such file or directory"
          else
            puts "rmake: #{path}: No such file or directory"
          end
        end
        return 2
      end

      target = self.default_target(opts[:target], evalr, graph)
      unless target
        if Kernel.respond_to?(:warn)
          warn "rmake: no target found"
        else
          puts "rmake: no target found"
        end
        return 1
      end

      shell = Shell.new(opts[:dry_run])
      exec = Executor.new(graph, shell, evalr.vars, evalr.delete_on_error?, opts[:trace])
      ok = exec.build_parallel(target, opts[:jobs])
      emit_nothing_to_do(target, opts) if ok && !opts[:trace] && !exec.built_any?
      return ok ? 0 : 2
    end

    def self.with_chdir(dir)
      prev = Dir.pwd
      begin
        Dir.chdir(dir)
      rescue Errno::ENOENT, Errno::ENOTDIR
        prefix = "make"
        if Object.const_defined?(:ENV) && ENV["MAKELEVEL"]
          level = ENV["MAKELEVEL"].to_i
          prefix = "make[#{level}]" if level > 0
        end
        msg = "#{prefix}: *** -C #{dir}: No such file or directory. Stop."
        if Kernel.respond_to?(:warn)
          warn msg
        else
          puts msg
        end
        return 2
      end
      yield
    ensure
      Dir.chdir(prev) rescue nil
    end

    def self.load_makefile(opts, make_cmd)
      File.open(opts[:makefile], "r") do |io|
        lines = Parser.new(io, opts[:makefile]).parse
        evalr = Evaluator.new(lines)
        opts[:vars].each { |k, v| evalr.set_override(k, v.to_s) }
        set_make_vars(evalr, make_cmd, opts)
        evalr.evaluate
        graph = Graph.new
        evalr.rules.each do |r|
          if r.targets.length > 1
            r.targets.each do |t|
              node = graph.ensure_node(t)
              phony = evalr.phony?(t)
              precious = evalr.precious?(t)
              tvars = evalr.target_vars[t]
              node.target_vars.merge!(tvars) if tvars
              single = Evaluator::Rule.new([t], r.prereqs, r.order_only, r.recipe, r.double_colon)
              graph.add_rule(single, phony: phony, precious: precious)
            end
          else
            r.targets.each do |t|
              node = graph.ensure_node(t)
              tvars = evalr.target_vars[t]
              node.target_vars.merge!(tvars) if tvars
            end
            phony = r.targets.any? { |t| evalr.phony?(t) }
            precious = r.targets.any? { |t| evalr.precious?(t) }
            graph.add_rule(r, phony: phony, precious: precious)
          end
        end
        evalr.suffix_rules.each { |src, dst, prereqs, recipe| graph.add_suffix_rule(src, dst, prereqs, recipe) }
        evalr.phony_list.each do |t|
          node = graph.ensure_node(t)
          node.phony = true if node
        end
        return [evalr, graph]
      end
    end

    def self.remake_includes(evalr, graph, opts, remade)
      includes = evalr.includes
      return false if includes.nil? || includes.empty?

      exec = Executor.new(graph, Shell.new(false), evalr.vars, evalr.delete_on_error?, opts[:trace])
      rebuilt = false
      includes.each do |path, optional|
        next if path.nil? || path.empty?
        next if remade && remade[path]
        next unless exec.can_build?(path)
        if File.exist?(path) && !exec.needs_build?(path)
          next
        end
        ok = exec.build_parallel(path, opts[:jobs])
        return false unless ok
        remade[path] = true if remade
        rebuilt = true
      end
      rebuilt
    end

    def self.missing_required_includes(evalr)
      missing = []
      evalr.missing_required.each do |path|
        next if path.nil? || path.empty?
        missing << path unless File.exist?(path)
      end
      missing
    end

    def self.print_help
      puts "Usage: rmake [options] [target] [VAR=VALUE]"
      puts ""
      puts "Options:"
      puts "  -f FILE       Read FILE as a makefile"
      puts "  -C DIR        Change to DIR before reading makefiles"
      puts "  -j [N]        Run N jobs in parallel"
      puts "  -n            Dry-run (print commands without running)"
      puts "  -d, --trace   Trace target evaluation and skips"
      puts "  -h, --help    Show this help"
      puts ""
      puts "Notes:"
      puts "  - Command echo follows make behavior (use V=1 to show)"
      puts "  - Variables can be set as VAR=VALUE on the command line"
    end

    def self.parse_args(argv)
      opts = {
        makefile: "Makefile",
        chdir: nil,
        jobs: 1,
        dry_run: false,
        target: nil,
        vars: {},
        trace: false,
        help: false,
      }
      jobs_set = false
      i = 0
      while i < argv.length
        arg = argv[i]
        if arg == "-h" || arg == "--help"
          opts[:help] = true
        elsif arg == "-f"
          i += 1
          opts[:makefile] = argv[i]
        elsif arg == "-C"
          i += 1
          opts[:chdir] = argv[i]
        elsif arg == "-j"
          next_arg = argv[i + 1]
          if next_arg && next_arg.match?(/\A\d+\z/)
            i += 1
            opts[:jobs] = normalize_jobs(argv[i].to_i)
          else
            opts[:jobs] = normalize_jobs(nil)
          end
          jobs_set = true
        elsif arg == "-n"
          opts[:dry_run] = true
        elsif arg == "-d" || arg == "--trace"
          opts[:trace] = true
        elsif arg.index("=") && !arg.start_with?("-")
          k, v = arg.split("=", 2)
          opts[:vars][k] = v || "" if k && !k.empty?
        elsif arg.start_with?("-C") && arg.length > 2
          opts[:chdir] = arg[2..-1]
        elsif arg.start_with?("-j") && arg.length > 2
          opts[:jobs] = normalize_jobs(arg[2..-1].to_i)
          jobs_set = true
        else
          opts[:target] = arg
        end
        i += 1
      end

      if !opts[:dry_run]
        flags = nil
        flags = opts[:vars]["MAKEFLAGS"]
        flags = opts[:vars]["MFLAGS"] if flags.nil? || flags.empty?
        if flags.nil? || flags.empty?
          flags = env_var("MAKEFLAGS")
          flags = env_var("MFLAGS") if (flags.nil? || flags.empty?)
        end
        opts[:dry_run] = dry_run_from_flags(flags) if flags && !flags.empty?
      end

      if !jobs_set
        flags = opts[:vars]["MAKEFLAGS"]
        flags = opts[:vars]["MFLAGS"] if flags.nil? || flags.empty?
        n = jobs_from_flags(flags)
        if n
          opts[:jobs] = normalize_jobs(n)
          jobs_set = true
        end
      end

      if !jobs_set
        detected = default_jobs
        opts[:jobs] = detected if detected && detected > 0
      end
      [opts, jobs_set]
    end

    def self.normalize_jobs(n)
      return default_jobs if n.nil? || n <= 0
      n
    end

    def self.make_command
      make_path = File.expand_path($0)
      mruby_path = nil
      if $rmake_mruby && File.exist?($rmake_mruby)
        mruby_path = $rmake_mruby
      end
      mruby_path ? "#{mruby_path} #{make_path}" : make_path
    end

    def self.set_env_make_vars(make_cmd, opts)
      return unless Object.const_defined?(:ENV)
      ENV["MAKE"] = make_cmd
      flags = []
      flags << "-j#{opts[:jobs]}" if opts[:jobs] > 1
      flags << "-n" if opts[:dry_run]
      flags = flags.join(" ").strip
      ENV["MFLAGS"] = flags
      ENV["MAKEFLAGS"] = flags
      ENV["MAKECMDGOALS"] = opts[:target].to_s
      if opts[:vars] && opts[:vars]["MAKELEVEL"] && !opts[:vars]["MAKELEVEL"].empty?
        ENV["MAKELEVEL"] = opts[:vars]["MAKELEVEL"]
      elsif (ENV["MAKELEVEL"].nil? || ENV["MAKELEVEL"].empty?)
        ENV["MAKELEVEL"] = "0"
      end
    end

    def self.set_make_vars(evalr, make_cmd, opts)
      evalr.vars["MAKE"] = Evaluator::Var.simple(make_cmd)
      flags = []
      flags << "-j#{opts[:jobs]}" if opts[:jobs] > 1
      flags << "-n" if opts[:dry_run]
      flags = flags.join(" ").strip
      evalr.vars["MFLAGS"] = Evaluator::Var.simple(flags)
      evalr.vars["mflags"] = Evaluator::Var.simple(flags)
      evalr.vars["MAKEFLAGS"] = Evaluator::Var.simple(flags)
      evalr.vars["MAKECMDGOALS"] = Evaluator::Var.simple(opts[:target].to_s)
      unless opts[:vars].key?("MAKELEVEL")
        level = 0
        env_level = env_var("MAKELEVEL")
        level = env_level.to_i if env_level && !env_level.empty?
        evalr.vars["MAKELEVEL"] = Evaluator::Var.simple(level.to_s)
      end
    end

    def self.emit_nothing_to_do(target, opts)
      return 0 if target && target.start_with?(".")
      if opts[:target] && !opts[:target].to_s.empty?
        puts "#{make_prefix}: `#{target}' is up to date."
      else
        puts "#{make_prefix}: Nothing to be done for `#{target}'."
      end
      0
    end

    def self.make_prefix
      level = 0
      if Object.const_defined?(:ENV)
        lvl = ENV["MAKELEVEL"]
        level = lvl.to_i if lvl
      end
      level > 0 ? "make[#{level}]" : "make"
    end

    def self.default_jobs
      env = env_var("RMAKE_JOBS")
      if env && !env.empty?
        n = env.to_i
        return n if n > 0
      end
      flags = env_var("MAKEFLAGS")
      n = jobs_from_flags(flags)
      if n
        return n if n > 0
        detected = detect_cpu_jobs
        return detected if detected && detected > 0
      end
      flags = env_var("MFLAGS")
      n = jobs_from_flags(flags)
      if n
        return n if n > 0
        detected = detect_cpu_jobs
        return detected if detected && detected > 0
      end
      detect_cpu_jobs
    end

    def self.detect_cpu_jobs
      n = Util.shell_capture("getconf _NPROCESSORS_ONLN")
      n = n.to_i if n
      return n if n && n > 0
      n = Util.shell_capture("sysctl -n hw.ncpu")
      n = n.to_i if n
      return n if n && n > 0
      nil
    end

    def self.env_var(name)
      if Object.const_defined?(:ENV)
        return ENV[name]
      end
      return nil unless Util.respond_to?(:shell_capture)
      out = Util.shell_capture("printenv #{Util.shell_escape(name)}")
      out && out.empty? ? nil : out
    end

    def self.jobs_from_flags(flags)
      return nil unless flags && !flags.empty?
      parts = Util.split_ws(flags)
      i = 0
      while i < parts.length
        part = parts[i]
        if part == "-j" || part == "--jobs"
          i += 1
          return 0 if i >= parts.length
          return parts[i].to_i
        elsif part.start_with?("-j") && part.length > 2
          return part[2..-1].to_i
        elsif part.start_with?("--jobs=")
          return part.split("=", 2)[1].to_i
        end
        i += 1
      end
      nil
    end

    def self.dry_run_from_flags(flags)
      return false unless flags && !flags.empty?
      parts = Util.split_ws(flags)
      parts.any? { |p| p == "-n" || p == "--just-print" || p == "--dry-run" }
    end

    def self.default_target(explicit, evalr, graph)
      return explicit if explicit && !explicit.empty?
      evalr.rules.each do |r|
        r.targets.each do |t|
          return t unless t.start_with?(".")
        end
      end
      graph.nodes.each do |node|
        name = node.name
        return name unless name.start_with?(".")
      end
      evalr.rules.first&.targets&.first || graph.nodes.first&.name
    end

  end
end
