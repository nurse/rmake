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
      saved_env = capture_make_env
      set_env_make_vars(make_cmd, opts)

      begin
        pass = 0
        evalr = nil
        graph = nil
        remade = {}
        precompleted = {}
        loop do
          begin
            evalr, graph = load_makefile(opts, make_cmd)
          rescue Errno::ENOENT
            if opts[:makefile] == "Makefile" || opts[:makefile] == "GNUmakefile"
              first_goal = explicit_targets(opts).first
              if first_goal && !first_goal.to_s.empty?
                msg = "#{make_prefix}: *** No rule to make target '#{first_goal}'. Stop."
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
          rescue ParseError, Evaluator::MakeError => e
            if Kernel.respond_to?(:warn)
              warn e.message
            else
              puts e.message
            end
            return 2
          end
          rebuilt = remake_includes(evalr, graph, opts, remade, precompleted)
          pass += 1
          break unless rebuilt && pass < 2
        end

        missing = missing_required_includes(evalr, graph, opts)
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

        targets = explicit_targets(opts)
        if targets.empty?
          target = self.default_target(nil, evalr, graph)
          targets = [target] if target
        end
        unless targets && !targets.empty?
          if Kernel.respond_to?(:warn)
            warn "rmake: no target found"
          else
            puts "rmake: no target found"
          end
          return 1
        end

        shell = Shell.new(opts[:dry_run], opts[:silent], opts[:ignore_errors])
        exec = Executor.new(graph, shell, evalr.vars, evalr.delete_on_error?, opts[:trace], precompleted, evalr.suffixes, evalr.second_expansion?, evalr, opts[:touch], opts[:what_if])
        begin
          if opts[:question]
            q = 0
            targets.each do |t|
              st = exec.question_status(t)
              return 2 if st == 2
              q = 1 if st == 1
            end
            return q
          end
          targets.each do |t|
            ok = exec.build_parallel(t, opts[:jobs])
            return 2 unless ok
          end
        rescue Evaluator::MakeError => e
          if Kernel.respond_to?(:warn)
            warn e.message
          else
            puts e.message
          end
          return 2
        end
        emit_nothing_to_do(targets, opts, graph) if !opts[:trace] && !exec.built_any?
        0
      ensure
        restore_make_env(saved_env)
      end
    end

    def self.with_chdir(dir)
      prev = Dir.pwd
      begin
        Dir.chdir(dir)
      rescue SystemCallError => e
        prefix = "make"
        if Object.const_defined?(:ENV) && ENV["MAKELEVEL"]
          level = ENV["MAKELEVEL"].to_i
          prefix = "make[#{level}]" if level > 0
        end
        reason = chdir_error_reason(e)
        msg = "#{prefix}: *** -C #{dir}: #{reason}. Stop."
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

    def self.chdir_error_reason(error)
      errnum = if error.class.const_defined?(:Errno)
        error.class.const_get(:Errno)
      else
        nil
      end
      if errnum
        SystemCallError.new(nil, errnum).message
      else
        "No such file or directory"
      end
    rescue StandardError
      "No such file or directory"
    end

    def self.load_makefile(opts, make_cmd)
      lines = []
      if File.exist?(opts[:makefile])
        File.open(opts[:makefile], "r") do |io|
          lines = Parser.new(io, opts[:makefile]).parse
        end
      elsif opts[:evals].nil? || opts[:evals].empty?
        raise Errno::ENOENT
      end
      begin
        evalr = Evaluator.new(lines)
        evalr.set_env_override(opts[:env_override]) if evalr.respond_to?(:set_env_override)
        evalr.set_include_dirs(opts[:include_dirs]) if evalr.respond_to?(:set_include_dirs)
        apply_env_vars(evalr, opts)
        set_make_vars(evalr, make_cmd, opts)
        evalr.set_no_builtin_rules(true) if opts[:no_builtin_rules]
        evalr.set_no_builtin_variables(true) if opts[:no_builtin_variables]
        apply_cli_assignments(evalr, opts)
        evalr.evaluate
        apply_cli_evals(evalr, opts)
        graph = Graph.new
        evalr.rules.each do |r|
          if r.targets.length > 1
            r.targets.each do |t|
              node = graph.ensure_node(t)
              phony = evalr.phony?(t)
              precious = evalr.precious?(t)
              pvars = evalr.pattern_target_vars_for(t) if evalr.respond_to?(:pattern_target_vars_for)
              node.target_vars.merge!(pvars) if pvars && !pvars.empty?
              pins = evalr.pattern_target_inherit_for(t) if evalr.respond_to?(:pattern_target_inherit_for)
              node.target_inherit_append.merge!(pins) if pins && !pins.empty?
              tvars = evalr.target_vars[t]
              node.target_vars.merge!(tvars) if tvars
              tins = evalr.target_inherit_append[t] if evalr.respond_to?(:target_inherit_append)
              node.target_inherit_append.merge!(tins) if tins && !tins.empty?
              single = Evaluator::Rule.new([t], r.prereqs, r.order_only, r.recipe, r.double_colon)
              graph.add_rule(single, phony: phony, precious: precious)
            end
          else
            r.targets.each do |t|
              node = graph.ensure_node(t)
              pvars = evalr.pattern_target_vars_for(t) if evalr.respond_to?(:pattern_target_vars_for)
              node.target_vars.merge!(pvars) if pvars && !pvars.empty?
              pins = evalr.pattern_target_inherit_for(t) if evalr.respond_to?(:pattern_target_inherit_for)
              node.target_inherit_append.merge!(pins) if pins && !pins.empty?
              tvars = evalr.target_vars[t]
              node.target_vars.merge!(tvars) if tvars
              tins = evalr.target_inherit_append[t] if evalr.respond_to?(:target_inherit_append)
              node.target_inherit_append.merge!(tins) if tins && !tins.empty?
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

    def self.remake_includes(evalr, graph, opts, remade, precompleted)
      includes = evalr.includes
      return false if includes.nil? || includes.empty?

      exec = Executor.new(graph, Shell.new(opts[:dry_run], opts[:silent]), evalr.vars, evalr.delete_on_error?, opts[:trace], nil, evalr.suffixes, evalr.second_expansion?, evalr, opts[:touch], opts[:what_if])
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
        mark_precompleted(precompleted, path) if precompleted
        rebuilt = true
      end
      rebuilt
    end

    def self.mark_precompleted(precompleted, path)
      return if precompleted.nil? || path.nil? || path.empty?
      precompleted[path] = true
      if path.start_with?("./")
        precompleted[path[2..-1]] = true
      else
        precompleted["./#{path}"] = true
      end
    end

    def self.missing_required_includes(evalr, graph, opts)
      missing = []
      checker = nil
      if opts[:dry_run]
        checker = Executor.new(graph, Shell.new(true, opts[:silent]), evalr.vars, evalr.delete_on_error?, false, nil, evalr.suffixes, evalr.second_expansion?, evalr, opts[:touch], opts[:what_if])
      end
      evalr.missing_required.each do |path|
        next if path.nil? || path.empty?
        if checker && checker.can_build?(path)
          next
        end
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
      puts "  -s            Silent mode"
      puts "  -q            Question mode (exit 0/1/2 without running commands)"
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
        silent: false,
        ignore_errors: false,
        no_silent: false,
        keep_going: false,
        touch: false,
        no_builtin_rules: false,
        no_builtin_variables: false,
        always_make: false,
        no_print_directory: false,
        question: false,
        env_override: false,
        target: nil,
        targets: [],
        evals: [],
        include_dirs: [],
        what_if: [],
        vars: {},
        var_assigns: [],
        trace: false,
        help: false,
      }
      jobs_set = false
      silent_set = false
      print_dir_set = false
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
        elsif arg == "-i" || arg == "--ignore-errors"
          opts[:ignore_errors] = true
        elsif arg == "-k" || arg == "--keep-going"
          opts[:keep_going] = true
        elsif arg == "-S" || arg == "--no-keep-going"
          opts[:keep_going] = false
        elsif arg == "-r" || arg == "--no-builtin-rules"
          opts[:no_builtin_rules] = true
        elsif arg == "-R" || arg == "--no-builtin-variables"
          opts[:no_builtin_variables] = true
        elsif arg == "-B" || arg == "--always-make"
          opts[:always_make] = true
        elsif arg == "-t" || arg == "--touch"
          opts[:touch] = true
        elsif arg == "-s" || arg == "--silent" || arg == "--quiet"
          opts[:silent] = true
          opts[:no_silent] = false
          silent_set = true
        elsif arg == "--no-silent"
          opts[:silent] = false
          opts[:no_silent] = true
          silent_set = true
        elsif arg == "-w" || arg == "--print-directory"
          opts[:print_directory] = true
          opts[:no_print_directory] = false
          print_dir_set = true
        elsif arg == "--no-print-directory"
          opts[:print_directory] = false
          opts[:no_print_directory] = true
          print_dir_set = true
        elsif arg == "-e" || arg == "--environment-overrides"
          opts[:env_override] = true
        elsif arg == "-q" || arg == "--question"
          opts[:question] = true
        elsif arg == "-E" || arg == "--eval"
          i += 1
          opts[:evals] << argv[i].to_s if i < argv.length
        elsif arg.start_with?("--eval=")
          opts[:evals] << arg.split("=", 2)[1].to_s
        elsif arg == "-I"
          i += 1
          opts[:include_dirs] << argv[i].to_s if i < argv.length
        elsif arg.start_with?("--include-dir=")
          opts[:include_dirs] << arg.split("=", 2)[1].to_s
        elsif arg == "-W"
          i += 1
          opts[:what_if] << argv[i].to_s if i < argv.length
        elsif arg.start_with?("--what-if=") || arg.start_with?("--new-file=") || arg.start_with?("--assume-new=")
          opts[:what_if] << arg.split("=", 2)[1].to_s
        elsif arg == "-l" || arg == "--load-average" || arg == "--max-load"
          nxt = argv[i + 1]
          if nxt && !nxt.start_with?("-")
            i += 1
            opts[:load_average] = nxt
          end
        elsif arg.start_with?("--load-average=") || arg.start_with?("--max-load=")
          opts[:load_average] = arg.split("=", 2)[1].to_s
        elsif arg.start_with?("--warn")
          opts[:warn_spec] = arg
        elsif arg.start_with?("--shuffle")
          opts[:shuffle] = arg
        elsif arg.start_with?("--jobserver-style=")
          opts[:jobserver_style] = arg.split("=", 2)[1].to_s
        elsif arg == "-O" || arg == "--output-sync"
          opts[:output_sync] = true
        elsif arg.start_with?("--output-sync=")
          opts[:output_sync] = arg.split("=", 2)[1].to_s
        elsif arg == "-p" || arg == "--print-data-base" || arg == "-b" || arg == "-m"
          # Accepted for compatibility; behavior is currently ignored.
        elsif arg == "--"
          i += 1
          while i < argv.length
            rest = argv[i]
            if (assign = parse_cli_assignment(rest))
              name, op, val = assign
              opts[:var_assigns] << assign
              opts[:vars][name] = val if op == "="
            else
              opts[:targets] << rest
              opts[:target] = rest
            end
            i += 1
          end
          break
        elsif arg == "-d" || arg == "--trace"
          opts[:trace] = true
        elsif !arg.start_with?("-") && (assign = parse_cli_assignment(arg))
          name, op, val = assign
          opts[:var_assigns] << assign
          opts[:vars][name] = val if op == "="
        elsif arg.start_with?("-C") && arg.length > 2
          opts[:chdir] = arg[2..-1]
        elsif arg.start_with?("-j") && arg.length > 2
          opts[:jobs] = normalize_jobs(arg[2..-1].to_i)
          jobs_set = true
        elsif arg.start_with?("-f") && arg.length > 2
          opts[:makefile] = arg[2..-1]
        elsif arg.start_with?("-E") && arg.length > 2
          opts[:evals] << arg[2..-1]
        elsif arg.start_with?("-I") && arg.length > 2
          opts[:include_dirs] << arg[2..-1]
        elsif arg.start_with?("-W") && arg.length > 2
          opts[:what_if] << arg[2..-1]
        elsif arg.start_with?("-l") && arg.length > 2
          opts[:load_average] = arg[2..-1]
        elsif arg.start_with?("-") && arg.length > 2 && !arg.start_with?("--")
          handled, ni, jobs_set = parse_short_bundle(opts, argv, i, jobs_set)
          if handled
            i = ni
          else
            opts[:targets] << arg
            opts[:target] = arg
          end
        else
          opts[:targets] << arg
          opts[:target] = arg
        end
        i += 1
      end

      if !opts[:dry_run]
        flags = nil
        flags = cli_var_value(opts, "MAKEFLAGS")
        flags = cli_var_value(opts, "MFLAGS") if flags.nil? || flags.empty?
        if flags.nil? || flags.empty?
          flags = env_var("MAKEFLAGS")
          flags = env_var("MFLAGS") if (flags.nil? || flags.empty?)
        end
        if flags && !flags.empty?
          opts[:dry_run] = dry_run_from_flags(flags)
          opts[:question] = question_from_flags(flags) unless opts[:question]
        end
      end

      if !opts[:env_override]
        flags = nil
        flags = cli_var_value(opts, "MAKEFLAGS")
        flags = cli_var_value(opts, "MFLAGS") if flags.nil? || flags.empty?
        if flags.nil? || flags.empty?
          flags = env_var("MAKEFLAGS")
          flags = env_var("MFLAGS") if (flags.nil? || flags.empty?)
        end
        opts[:env_override] = env_override_from_flags(flags) if flags && !flags.empty?
      end

      if !silent_set
        flags = nil
        flags = cli_var_value(opts, "MAKEFLAGS")
        flags = cli_var_value(opts, "MFLAGS") if flags.nil? || flags.empty?
        if flags.nil? || flags.empty?
          flags = env_var("MAKEFLAGS")
          flags = env_var("MFLAGS") if (flags.nil? || flags.empty?)
        end
        s = silent_from_flags(flags)
        unless s.nil?
          opts[:silent] = s
          opts[:no_silent] = !s
        end
      end

      if !print_dir_set
        flags = nil
        flags = cli_var_value(opts, "MAKEFLAGS")
        flags = cli_var_value(opts, "MFLAGS") if flags.nil? || flags.empty?
        if flags.nil? || flags.empty?
          flags = env_var("MAKEFLAGS")
          flags = env_var("MFLAGS") if (flags.nil? || flags.empty?)
        end
        pd = print_directory_from_flags(flags)
        unless pd.nil?
          opts[:print_directory] = pd
          opts[:no_print_directory] = !pd
        end
      end

      if !jobs_set
        flags = cli_var_value(opts, "MAKEFLAGS")
        flags = cli_var_value(opts, "MFLAGS") if flags.nil? || flags.empty?
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

    def self.short_option_cluster?(flags)
      return false if flags.nil? || flags.empty?
      flags.each_char.all? { |ch| short_option_char?(ch) }
    end

    def self.short_option_char?(ch)
      ch == "n" || ch == "s" || ch == "e" || ch == "q" || ch == "d" ||
        ch == "i" || ch == "k" || ch == "S" || ch == "r" || ch == "R" ||
        ch == "t" || ch == "w" || ch == "B" || ch == "p" || ch == "b" || ch == "m"
    end

    def self.apply_short_flag(opts, ch)
      case ch
      when "n" then opts[:dry_run] = true
      when "s" then opts[:silent] = true
      when "e" then opts[:env_override] = true
      when "q" then opts[:question] = true
      when "d" then opts[:trace] = true
      when "i" then opts[:ignore_errors] = true
      when "k" then opts[:keep_going] = true
      when "S" then opts[:keep_going] = false
      when "r" then opts[:no_builtin_rules] = true
      when "R" then opts[:no_builtin_variables] = true
      when "t" then opts[:touch] = true
      when "w"
        opts[:print_directory] = true
        opts[:no_print_directory] = false
      when "B" then opts[:always_make] = true
      else
        # accepted no-op compatibility options
      end
    end

    def self.parse_short_bundle(opts, argv, i, jobs_set)
      arg = argv[i].to_s
      return [false, i, jobs_set] unless arg.start_with?("-") && arg.length > 2 && !arg.start_with?("--")
      flags = arg[1..-1]
      idx = 0
      while idx < flags.length
        ch = flags[idx]
        if short_option_char?(ch)
          apply_short_flag(opts, ch)
          idx += 1
          next
        end
        if ch == "f" || ch == "C" || ch == "I" || ch == "W" || ch == "E"
          rest = flags[(idx + 1)..-1].to_s
          if rest.empty?
            i += 1
            rest = argv[i].to_s if i < argv.length
          end
          return [false, i, jobs_set] if rest.nil? || rest.empty?
          if ch == "f"
            opts[:makefile] = rest
          elsif ch == "C"
            opts[:chdir] = rest
          elsif ch == "I"
            opts[:include_dirs] << rest
          elsif ch == "W"
            opts[:what_if] << rest
          elsif ch == "E"
            opts[:evals] << rest
          end
          return [true, i, jobs_set]
        end
        if ch == "j" || ch == "l"
          rest = flags[(idx + 1)..-1].to_s
          if rest.empty?
            nxt = argv[i + 1]
            if nxt && !nxt.start_with?("-")
              i += 1
              rest = nxt
            end
          end
          if ch == "j"
            opts[:jobs] = normalize_jobs(rest.to_i)
            jobs_set = true
          else
            opts[:load_average] = rest unless rest.nil? || rest.empty?
          end
          return [true, i, jobs_set]
        end
        return [false, i, jobs_set]
      end
      [true, i, jobs_set]
    end

    def self.normalize_jobs(n)
      return default_jobs if n.nil? || n <= 0
      n
    end

    def self.make_command
      if Object.const_defined?(:ENV)
        env_make = ENV["MAKE"]
        return env_make if env_make && !env_make.empty?
      elsif Util.respond_to?(:shell_capture)
        env_make = Util.shell_capture("printenv MAKE")
        return env_make if env_make && !env_make.empty?
      end
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
      mflags = mflags_for(opts)
      ENV["MFLAGS"] = mflags
      ENV["MAKEFLAGS"] = makeflags_for(opts, mflags)
      ENV["__RMAKE_ENV_OVERRIDE__"] = opts[:env_override] ? "1" : ""
      ENV["__RMAKE_CLI_ASSIGNS_ESC"] = cli_assigns_escaped(opts)
      ENV["MAKECMDGOALS"] = explicit_targets(opts).join(" ")
      makelevel = cli_var_value(opts, "MAKELEVEL")
      if makelevel && !makelevel.empty?
        ENV["MAKELEVEL"] = makelevel
      elsif (ENV["MAKELEVEL"].nil? || ENV["MAKELEVEL"].empty?)
        ENV["MAKELEVEL"] = "0"
      end
    end

    def self.capture_make_env
      return {} unless Object.const_defined?(:ENV)
      keys = ["MAKE", "MFLAGS", "MAKEFLAGS", "MAKECMDGOALS", "MAKELEVEL", "__RMAKE_ENV_OVERRIDE__", "__RMAKE_CLI_ASSIGNS_ESC"]
      out = {}
      keys.each do |k|
        if ENV.key?(k)
          out[k] = ENV[k]
        else
          out[k] = :__unset__
        end
      end
      out
    end

    def self.restore_make_env(saved)
      return unless Object.const_defined?(:ENV)
      return if saved.nil?
      saved.each do |k, v|
        if v == :__unset__
          ENV.delete(k)
        else
          ENV[k] = v
        end
      end
    end

    def self.set_make_vars(evalr, make_cmd, opts)
      evalr.set_special_var("MAKE", make_cmd, "default")
      mflags = mflags_for(opts)
      evalr.set_special_var("MFLAGS", mflags, "default")
      evalr.set_special_var("mflags", mflags, "default")
      evalr.set_special_var("MAKEFLAGS", makeflags_for(opts, mflags), "default")
      evalr.set_special_var("__RMAKE_ENV_OVERRIDE__", opts[:env_override] ? "1" : "", "default")
      evalr.set_special_var("__RMAKE_CLI_ASSIGNS_ESC", cli_assigns_escaped(opts), "default")
      evalr.set_special_var("MAKECMDGOALS", explicit_targets(opts).join(" "), "default")
      unless cli_var_assigned?(opts, "MAKELEVEL")
        level = 0
        env_level = env_var("MAKELEVEL")
        level = env_level.to_i if env_level && !env_level.empty?
        evalr.set_special_var("MAKELEVEL", level.to_s, "default")
      end
    end

    def self.emit_nothing_to_do(targets, opts, graph = nil)
      return 0 if opts[:silent]
      list = targets.is_a?(Array) ? targets : [targets]
      list.each do |target|
        next if special_target_name?(target)
        node = graph ? graph.node(target) : nil
        has_recipe = node && node.recipe && !node.recipe.empty?
        if (opts[:target] && !opts[:target].to_s.empty?) || has_recipe
          puts "#{make_prefix}: '#{target}' is up to date."
        else
          puts "#{make_prefix}: Nothing to be done for '#{target}'."
        end
      end
      0
    end

    def self.make_prefix
      base = "make"
      mk = env_var("MAKE")
      if mk && !mk.empty?
        token = Util.split_ws(mk).first
        if token && !token.empty?
          base = File.basename(token)
        end
      end
      level = 0
      if Object.const_defined?(:ENV)
        lvl = ENV["MAKELEVEL"]
        level = lvl.to_i if lvl
      else
        lvl = env_var("MAKELEVEL")
        level = lvl.to_i if lvl && !lvl.empty?
      end
      level > 0 ? "#{base}[#{level}]" : base
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
      parts.any? { |p| p == "-n" || p == "--just-print" || p == "--dry-run" || token_has_short_option?(p, "n") }
    end

    def self.question_from_flags(flags)
      return false unless flags && !flags.empty?
      parts = Util.split_ws(flags)
      parts.any? { |p| p == "-q" || p == "--question" || token_has_short_option?(p, "q") }
    end

    def self.env_override_from_flags(flags)
      return false unless flags && !flags.empty?
      parts = Util.split_ws(flags)
      parts.any? { |p| p == "-e" || p == "--environment-overrides" || token_has_short_option?(p, "e") }
    end

    def self.token_has_short_option?(token, flag)
      return false if token.nil? || token.empty?
      if !token.start_with?("-")
        return false if token.include?("=")
        return alpha_token?(token) && token.index(flag) != nil
      end
      return false if token.start_with?("--")
      chars = token[1..-1].to_s
      i = 0
      while i < chars.length
        ch = chars[i]
        return true if ch == flag
        break if short_option_requires_arg?(ch)
        i += 1
      end
      false
    end

    def self.short_option_requires_arg?(ch)
      ch == "C" || ch == "f" || ch == "I" || ch == "W" || ch == "E" || ch == "j" || ch == "l"
    end

    def self.alpha_token?(token)
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

    def self.silent_from_flags(flags)
      return nil unless flags && !flags.empty?
      out = nil
      Util.split_ws(flags).each do |p|
        if p == "--no-silent"
          out = false
        elsif p == "--silent" || p == "--quiet" || token_has_short_option?(p, "s")
          out = true
        end
      end
      out
    end

    def self.print_directory_from_flags(flags)
      return nil unless flags && !flags.empty?
      out = nil
      Util.split_ws(flags).each do |p|
        if p == "--no-print-directory"
          out = false
        elsif p == "-w" || p == "--print-directory" || token_has_short_option?(p, "w")
          out = true
        end
      end
      out
    end

    def self.mflags_for(opts)
      flags = []
      flags << "-j#{opts[:jobs]}" if opts[:jobs] > 1
      flags << "-s" if opts[:silent]
      flags << "-e" if opts[:env_override]
      flags << "-n" if opts[:dry_run]
      flags << "-q" if opts[:question]
      flags << "-r" if opts[:no_builtin_rules]
      flags << "-R" if opts[:no_builtin_variables]
      flags.join(" ").strip
    end

    def self.makeflags_for(opts, mflags = nil)
      short = ""
      short << "s" if opts[:silent]
      short << "e" if opts[:env_override]
      short << "n" if opts[:dry_run]
      short << "q" if opts[:question]
      short << "r" if opts[:no_builtin_rules]
      short << "R" if opts[:no_builtin_variables]
      mf = short.dup
      mflags = mflags_for(opts) if mflags.nil?
      if mflags.include?("-j")
        jpart = mflags.split(" ").find { |x| x.start_with?("-j") }
        mf = mf.empty? ? " #{jpart}" : "#{mf} #{jpart}" if jpart
      end
      mf = mf.to_s
      mf += " --no-silent" if opts[:no_silent]
      mf += " --no-print-directory" if opts[:no_print_directory]
      mf
    end

    def self.cli_assigns_escaped(opts)
      assigns = opts[:var_assigns]
      return "" if assigns.nil? || assigns.empty?
      parts = assigns.map do |name, op, value|
        Util.shell_escape("#{name}#{op}#{value}")
      end
      parts.join(" ")
    end

    def self.default_target(explicit, evalr, graph)
      if explicit && !explicit.empty?
        if explicit.is_a?(Array)
          first = explicit.first
          return first if first && !first.empty?
        else
          return explicit
        end
      end
      evalr.rules.each do |r|
        r.targets.each do |t|
          return t unless special_target_name?(t)
        end
      end
      graph.nodes.each do |node|
        name = node.name
        return name unless special_target_name?(name)
      end
      evalr.rules.first&.targets&.first || graph.nodes.first&.name
    end

    def self.apply_cli_assignments(evalr, opts)
      assigns = opts[:var_assigns]
      return if assigns.nil? || assigns.empty?
      assigns.each do |name, op, value|
        evalr.set_override_with_op(name, op, value)
      end
    end

    def self.apply_env_vars(evalr, opts)
      env_keys = []
      env_pairs.each do |k, v|
        next if k.nil? || k.empty?
        next if k == "PWD"
        env_keys << k
        if opts[:env_override]
          evalr.set_env_var(k, v.to_s, true)
        else
          evalr.set_env_var(k, v.to_s, false) unless evalr.vars.key?(k)
        end
      end
      evalr.set_special_var("__RMAKE_ENV_KEYS__", env_keys.join(" "), "default")
    end

    def self.apply_cli_evals(evalr, opts)
      evals = opts[:evals]
      return if evals.nil? || evals.empty?
      evals.each do |snippet|
        next if snippet.nil?
        evalr.send(:eval_text, snippet.to_s, {})
      end
    end

    def self.env_pairs
      out = []
      if Object.const_defined?(:ENV)
        if ENV.respond_to?(:each_pair)
          ENV.each_pair { |k, v| out << [k, v] }
          return out
        elsif ENV.respond_to?(:each)
          ENV.each { |k, v| out << [k, v] }
          return out
        end
      end
      return out unless Util.respond_to?(:shell_capture)
      raw = Util.shell_capture("printenv | tr '\\n' '\\t'")
      return out if raw.nil? || raw.empty?
      raw.split("\t").each do |line|
        next if line.nil? || line.empty?
        i = line.index("=")
        next if i.nil? || i <= 0
        out << [line[0...i], line[(i + 1)..-1].to_s]
      end
      out
    end

    def self.parse_cli_assignment(arg)
      return nil if arg.nil? || arg.empty?
      i = arg.index("=")
      return nil if i.nil? || i <= 0
      op = "="
      j = i - 1
      j -= 1 while j >= 0 && (arg[j] == " " || arg[j] == "\t")
      name_end = j + 1
      if j >= 2 && arg[(j - 2)..j] == ":::"
        op = ":::="
        name_end = j - 2
      elsif j >= 1 && arg[(j - 1)..j] == "::"
        op = "::="
        name_end = j - 1
      elsif j >= 0 && (arg[j] == ":" || arg[j] == "+" || arg[j] == "?")
        op = "#{arg[j]}="
        name_end = j
      end
      name = arg[0...name_end]
      return nil if name.nil? || name.empty?
      value = arg[(i + 1)..-1].to_s
      [name, op.strip, value]
    end

    def self.cli_var_value(opts, name)
      assigns = opts[:var_assigns]
      return nil if assigns.nil? || assigns.empty?
      out = nil
      assigns.each do |k, op, v|
        next unless k == name
        if op == "=" || op == ":=" || op == "::=" || op == ":::="
          out = v
        elsif op == "+="
          out = out ? "#{out} #{v}" : v
        elsif op == "?="
          out = v if out.nil?
        end
      end
      out
    end

    def self.cli_var_assigned?(opts, name)
      assigns = opts[:var_assigns]
      return false if assigns.nil? || assigns.empty?
      assigns.any? { |k, _op, _v| k == name }
    end

    def self.explicit_targets(opts)
      goals = opts[:targets]
      return goals if goals && !goals.empty?
      t = opts[:target]
      return [] if t.nil? || t.empty?
      [t]
    end

    def self.special_target_name?(name)
      return false if name.nil? || name.empty?
      name.start_with?(".") && !name.include?("/")
    end

  end
end
