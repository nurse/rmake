module RMake
  class CLI
    def self.run(argv)
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
            n = argv[i].to_i
            if n <= 0
              detected = default_jobs
              opts[:jobs] = detected if detected && detected > 0
            else
              opts[:jobs] = n
            end
          else
            detected = default_jobs
            opts[:jobs] = detected if detected && detected > 0
          end
          jobs_set = true
        elsif arg == "-n"
          opts[:dry_run] = true
        elsif arg == "-d" || arg == "--trace"
          opts[:trace] = true
        elsif arg.index("=") && !arg.start_with?("-")
          k, v = arg.split("=", 2)
          if k && !k.empty?
            opts[:vars][k] = v || ""
          end
        elsif arg.start_with?("-j") && arg.length > 2
          n = arg[2..-1].to_i
          if n <= 0
            detected = default_jobs
            opts[:jobs] = detected if detected && detected > 0
          else
            opts[:jobs] = n
          end
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

      if opts[:help]
        print_help
        return 0
      end

      make_path = File.expand_path($0)
      mruby_path = nil
      if $rmake_mruby && File.exist?($rmake_mruby)
        mruby_path = $rmake_mruby
      end
      make_cmd = mruby_path ? "#{mruby_path} #{make_path}" : make_path
      if Object.const_defined?(:ENV)
        ENV["MAKE"] = make_cmd
        ENV["MFLAGS"] = opts[:jobs] > 1 ? "-j#{opts[:jobs]}" : ""
        ENV["MAKECMDGOALS"] = opts[:target].to_s
      end

      File.open(opts[:makefile], "r") do |io|
        lines = Parser.new(io, opts[:makefile]).parse
        evalr = Evaluator.new(lines)
        opts[:vars].each { |k, v| evalr.set_override(k, v.to_s) }
        evalr.evaluate

      jit_cargo = evalr.vars["JIT_CARGO_SUPPORT"]
      cargo = evalr.vars["CARGO"]
      if jit_cargo
        jit_cargo_val = jit_cargo.simple ? jit_cargo.value : Util.expand(jit_cargo.value, evalr.vars)
        cargo_val = cargo ? (cargo.simple ? cargo.value : Util.expand(cargo.value, evalr.vars)) : ""
        if jit_cargo_val == "no" && cargo_val.to_s.empty?
          found = Util.shell_capture("command -v cargo")
          if found && !found.empty?
            evalr.vars["CARGO"] = Evaluator::Var.simple(found)
            # Use a real cargo profile name so Cargo can build Rust artifacts.
            evalr.vars["JIT_CARGO_SUPPORT"] = Evaluator::Var.simple("release")
          end
        end
      end
        # If we enabled cargo but no build args are set, default to a profile and features.
        jit_cargo = evalr.vars["JIT_CARGO_SUPPORT"]
        rlib_dir = evalr.vars["RLIB_DIR"]
        cargo_args = evalr.vars["CARGO_BUILD_ARGS"]
        yjit_support = evalr.vars["YJIT_SUPPORT"]
        zjit_support = evalr.vars["ZJIT_SUPPORT"]
        if jit_cargo
          jit_cargo_val = jit_cargo.simple ? jit_cargo.value : Util.expand(jit_cargo.value, evalr.vars)
          cargo_args_val = cargo_args ? (cargo_args.simple ? cargo_args.value : Util.expand(cargo_args.value, evalr.vars)) : ""
          if cargo_args_val.to_s.strip.empty? && jit_cargo_val != "no"
            features = []
            yjit_val = yjit_support ? (yjit_support.simple ? yjit_support.value : Util.expand(yjit_support.value, evalr.vars)) : ""
            zjit_val = zjit_support ? (zjit_support.simple ? zjit_support.value : Util.expand(zjit_support.value, evalr.vars)) : ""
            features << "yjit" if yjit_val.to_s != "no"
            features << "zjit" if zjit_val.to_s != "no"
            profile = (jit_cargo_val == "yes" ? "release" : jit_cargo_val)
            args = "--profile #{profile}"
            args += " --features #{features.join(",")}" unless features.empty?
            evalr.vars["CARGO_BUILD_ARGS"] = Evaluator::Var.simple(args)
          end
        end
        disable_jit = false
        jit_cargo = evalr.vars["JIT_CARGO_SUPPORT"]
        rlib_dir = evalr.vars["RLIB_DIR"]
        top_build = evalr.vars["TOP_BUILD_DIR"]
        if jit_cargo && rlib_dir && top_build
          jit_cargo_val = jit_cargo.simple ? jit_cargo.value : Util.expand(jit_cargo.value, evalr.vars)
          rlib_dir_val = rlib_dir.simple ? rlib_dir.value : Util.expand(rlib_dir.value, evalr.vars)
          top_build_val = top_build.simple ? top_build.value : Util.expand(top_build.value, evalr.vars)
          if jit_cargo_val == "no" && !rlib_dir_val.to_s.empty?
            jit_rlib = File.join(top_build_val, rlib_dir_val, "libjit.rlib")
            disable_jit = true unless File.exist?(jit_rlib)
          end
        end
        if disable_jit
          evalr.vars["YJIT_SUPPORT"] = Evaluator::Var.simple("no")
          evalr.vars["ZJIT_SUPPORT"] = Evaluator::Var.simple("no")
          evalr.vars["YJIT_OBJ"] = Evaluator::Var.simple("")
          evalr.vars["ZJIT_OBJ"] = Evaluator::Var.simple("")
          evalr.vars["JIT_OBJ"] = Evaluator::Var.simple("")
          evalr.vars["RUST_LIB"] = Evaluator::Var.simple("")
          evalr.vars["RUST_LIBOBJ"] = Evaluator::Var.simple("")
        end
        if opts[:makefile] == "Makefile" && File.exist?("common.mk") && !evalr.vars.key?("RMAKE_COMMON_MK_INCLUDED")
          File.open("common.mk", "r") do |cio|
            c_lines = Parser.new(cio, "common.mk").parse
            c_eval = Evaluator.new(c_lines)
            opts[:vars].each { |k, v| c_eval.set_override(k, v.to_s) }
            c_eval.vars.merge!(evalr.vars)
            c_eval.evaluate
            evalr.merge!(c_eval)
            evalr.vars["RMAKE_COMMON_MK_INCLUDED"] = Evaluator::Var.simple("yes")
          end
        end
        if opts[:makefile] == "Makefile" && !disable_jit && File.exist?("defs/jit.mk") && !evalr.vars.key?("RMAKE_JIT_MK_INCLUDED")
          File.open("defs/jit.mk", "r") do |jio|
            j_lines = Parser.new(jio, "defs/jit.mk").parse
            j_eval = Evaluator.new(j_lines)
            opts[:vars].each { |k, v| j_eval.set_override(k, v.to_s) }
            j_eval.vars.merge!(evalr.vars)
            j_eval.evaluate
            evalr.merge!(j_eval)
            evalr.vars["RMAKE_JIT_MK_INCLUDED"] = Evaluator::Var.simple("yes")
          end
        end

        evalr.vars["MAKE"] = Evaluator::Var.simple(make_cmd)
        evalr.vars["MFLAGS"] = Evaluator::Var.simple(opts[:jobs] > 1 ? "-j#{opts[:jobs]}" : "")
        evalr.vars["MAKECMDGOALS"] = Evaluator::Var.simple(opts[:target].to_s)
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
        if ok && !opts[:dry_run] && !opts[:trace] && !exec.built_any?
          if target && target.start_with?(".")
            return 0
          end
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
        end
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
