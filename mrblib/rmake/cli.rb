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
                msg = "#{make_prefix}: *** No rule to make target `#{first_goal}'. Stop."
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

        shell = Shell.new(opts[:dry_run], opts[:silent])
        exec = Executor.new(graph, shell, evalr.vars, evalr.delete_on_error?, opts[:trace], precompleted, evalr.suffixes, evalr.second_expansion?, evalr)
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
      File.open(opts[:makefile], "r") do |io|
        lines = Parser.new(io, opts[:makefile]).parse
        evalr = Evaluator.new(lines)
        evalr.set_env_override(opts[:env_override]) if evalr.respond_to?(:set_env_override)
        apply_env_vars(evalr, opts)
        set_make_vars(evalr, make_cmd, opts)
        apply_cli_assignments(evalr, opts)
        evalr.evaluate
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

      exec = Executor.new(graph, Shell.new(opts[:dry_run], opts[:silent]), evalr.vars, evalr.delete_on_error?, opts[:trace], nil, evalr.suffixes, evalr.second_expansion?, evalr)
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
        checker = Executor.new(graph, Shell.new(true, opts[:silent]), evalr.vars, evalr.delete_on_error?, false, nil, evalr.suffixes, evalr.second_expansion?, evalr)
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
        question: false,
        env_override: false,
        target: nil,
        targets: [],
        vars: {},
        var_assigns: [],
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
        elsif arg == "-s" || arg == "--silent"
          opts[:silent] = true
        elsif arg == "-e" || arg == "--environment-overrides"
          opts[:env_override] = true
        elsif arg == "-q" || arg == "--question"
          opts[:question] = true
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
      flags = []
      flags << "-j#{opts[:jobs]}" if opts[:jobs] > 1
      flags << "-s" if opts[:silent]
      flags << "-e" if opts[:env_override]
      flags << "-n" if opts[:dry_run]
      flags << "-q" if opts[:question]
      flags = flags.join(" ").strip
      ENV["MFLAGS"] = flags
      ENV["MAKEFLAGS"] = flags
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
      keys = ["MAKE", "MFLAGS", "MAKEFLAGS", "MAKECMDGOALS", "MAKELEVEL"]
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
      flags = []
      flags << "-j#{opts[:jobs]}" if opts[:jobs] > 1
      flags << "-s" if opts[:silent]
      flags << "-e" if opts[:env_override]
      flags << "-n" if opts[:dry_run]
      flags << "-q" if opts[:question]
      flags = flags.join(" ").strip
      evalr.set_special_var("MFLAGS", flags, "default")
      evalr.set_special_var("mflags", flags, "default")
      evalr.set_special_var("MAKEFLAGS", flags, "default")
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
      parts.any? { |p| p == "-n" || p == "--just-print" || p == "--dry-run" }
    end

    def self.question_from_flags(flags)
      return false unless flags && !flags.empty?
      parts = Util.split_ws(flags)
      parts.any? { |p| p == "-q" || p == "--question" }
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
      env_pairs.each do |k, v|
        next if k.nil? || k.empty?
        next if k == "PWD"
        if opts[:env_override]
          evalr.set_env_var(k, v.to_s, true)
        else
          evalr.set_env_var(k, v.to_s, false) unless evalr.vars.key?(k)
        end
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
