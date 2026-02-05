module RMake
  class CLI
    def self.run(argv)
      opts, jobs_set = parse_args(argv)

      if opts[:help]
        print_help
        return 0
      end

      make_cmd = make_command
      set_env_make_vars(make_cmd, opts)

      File.open(opts[:makefile], "r") do |io|
        lines = Parser.new(io, opts[:makefile]).parse
        evalr = Evaluator.new(lines)
        opts[:vars].each { |k, v| evalr.set_override(k, v.to_s) }
        evalr.evaluate

        set_make_vars(evalr, make_cmd, opts)
        graph = Graph.new
        evalr.rules.each do |r|
          if r.targets.length > 1
            r.targets.each do |t|
              graph.ensure_node(t)
              phony = evalr.phony?(t)
              precious = evalr.precious?(t)
              single = Evaluator::Rule.new([t], r.prereqs, r.order_only, r.recipe, r.double_colon)
              graph.add_rule(single, phony: phony, precious: precious)
            end
          else
            r.targets.each { |t| graph.ensure_node(t) }
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
        emit_nothing_to_do(target, opts) if ok && !opts[:dry_run] && !opts[:trace] && !exec.built_any?
        return ok ? 0 : 2
      end
    rescue Errno::ENOENT
      if Kernel.respond_to?(:warn)
        warn "rmake: #{opts[:makefile]} not found"
      else
        puts "rmake: #{opts[:makefile]} not found"
      end
      return 1
    end

    def self.print_help
      puts "Usage: rmake [options] [target] [VAR=VALUE]"
      puts ""
      puts "Options:"
      puts "  -f FILE       Read FILE as a makefile"
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
        elsif arg.start_with?("-j") && arg.length > 2
          opts[:jobs] = normalize_jobs(arg[2..-1].to_i)
          jobs_set = true
        else
          opts[:target] = arg
        end
        i += 1
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
      ENV["MFLAGS"] = opts[:jobs] > 1 ? "-j#{opts[:jobs]}" : ""
      ENV["MAKECMDGOALS"] = opts[:target].to_s
    end

    def self.set_make_vars(evalr, make_cmd, opts)
      evalr.vars["MAKE"] = Evaluator::Var.simple(make_cmd)
      evalr.vars["MFLAGS"] = Evaluator::Var.simple(opts[:jobs] > 1 ? "-j#{opts[:jobs]}" : "")
      evalr.vars["MAKECMDGOALS"] = Evaluator::Var.simple(opts[:target].to_s)
    end

    def self.emit_nothing_to_do(target, opts)
      return 0 if target && target.start_with?(".")
      level = 0
      if Object.const_defined?(:ENV)
        lvl = ENV["MAKELEVEL"]
        level = lvl.to_i if lvl
      end
      prefix = level > 0 ? "make[#{level}]" : "make"
      if opts[:target] && !opts[:target].to_s.empty?
        puts "#{prefix}: `#{target}' is up to date."
      else
        puts "#{prefix}: Nothing to be done for `#{target}'."
      end
      0
    end

    def self.default_jobs
      if Object.const_defined?(:ENV)
        env = ENV["RMAKE_JOBS"]
        if env && !env.empty?
          n = env.to_i
          return n if n > 0
        end
        flags = ENV["MAKEFLAGS"]
        n = jobs_from_flags(flags)
        if n
          return n if n > 0
          detected = detect_cpu_jobs
          return detected if detected && detected > 0
        end
        flags = ENV["MFLAGS"]
        n = jobs_from_flags(flags)
        if n
          return n if n > 0
          detected = detect_cpu_jobs
          return detected if detected && detected > 0
        end
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
