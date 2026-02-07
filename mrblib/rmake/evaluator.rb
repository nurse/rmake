module RMake
  unless Object.const_defined?(:StringIO)
    class StringIO
      def initialize(str)
        @str = str.to_s
      end

      def each_line
        return enum_for(:each_line) unless block_given?
        @str.split("\n", -1).each do |line|
          yield line
        end
      end
    end
  end

  class Evaluator
    class MakeError < StandardError; end

    Rule = Struct.new(:targets, :prereqs, :order_only, :recipe, :double_colon, :grouped)

    attr_reader :rules, :vars, :target_vars, :target_pattern_vars
    attr_reader :target_inherit_append
    attr_reader :includes, :missing_required
    attr_reader :suffixes

    def initialize(lines)
      @lines = lines
      @rules = []
      @vars = {}
      @origins = {}
      @overrides = {}
      @make_overrides = {}
      @includes = []
      @missing_required = []
      @suffix_rules = []
      @suffixes = []
      @second_expansion = false
      @env_override = false
      @delete_on_error = false
      @precious = {}
      @phony = {}
      @target_vars = {}
      @target_override_vars = {}
      @target_inherit_append = {}
      @target_pattern_vars = {}
      @target_pattern_override_vars = {}
      @target_pattern_inherit_append = {}
      @target_pattern_order = []
      @exports = {}
      @cond_stack = []
      @current_file = nil
      @current_line = nil
      @call_ctx = nil
      @no_builtin_rules = false
      @no_builtin_variables = false
      @include_dirs = []
      seed_env
    end

    def evaluate
      current_rules = []
      @lines.each do |line|
        @current_file = line.filename
        @current_line = line.lineno
        s = line.stripped
        next if s.nil? || s.empty?

        if handle_condition(s)
          next
        end

        unless cond_active?
          next
        end

        if line.recipe
          if current_rules && !current_rules.empty?
            recipe = Util.attach_location(Util.strip_leading_ws(line.raw), line.filename, line.lineno)
            current_rules.each { |rule| rule.recipe << recipe }
          end
          next
        end

        current_rules = []

        # Variable assignment (+ export / override)
        force_override = false
        export_only = false
        if s.start_with?("override ")
          force_override = true
          s = s[9..-1].to_s.lstrip
        end
        if s.start_with?("export ")
          export_only = true
          s = s[7..-1].to_s.lstrip
        end
        if (assign = parse_assignment(s))
          name, op, value = assign
          name = expand(name.to_s).to_s.strip
          raise make_error(line, "*** empty variable name.  Stop.") if name.empty?
          assign_var(name, op, value, force_override)
          mark_export(name) if export_only
          next
        elsif export_only
          Util.split_ws(expand(s)).each { |name| mark_export(name) unless name.nil? || name.empty? }
          next
        end

        # include / -include / !include
        if (inc = parse_include(s))
          optional, arg = inc
          files = Util.split_ws(expand(arg))
          files.each do |f|
            @includes << [f, optional]
            include_file(f, optional, line)
          end
          next
        end

        # Special targets
        if s.start_with?(".PHONY:")
          list = Util.split_ws(expand(s.split(":", 2)[1]))
          list.each { |t| @phony[t] = true }
          next
        end
        if s.start_with?(".SUFFIXES:")
          list = Util.split_ws(expand(s.split(":", 2)[1].to_s))
          @suffixes = list
          next
        end
        if s.start_with?(".SECONDEXPANSION:")
          @second_expansion = true
          next
        end
        if s.start_with?(".DELETE_ON_ERROR:")
          @delete_on_error = true
          next
        end
        if s.start_with?(".PRECIOUS:")
          list = Util.split_ws(expand(s.split(":", 2)[1]))
          list.each { |t| @precious[t] = true }
          next
        end

        # Rules
        if (rule = parse_rule(s))
          targets_str, sep, prereq_part_raw = rule
          static_target_pattern = nil
          if sep == ":"
            idx2, len2 = find_top_level_colon(prereq_part_raw.to_s)
            if idx2
              candidate = expand(prereq_part_raw[0...idx2].to_s).to_s.strip
              if candidate.index("%")
                static_target_pattern = candidate
                prereq_part_raw = prereq_part_raw[(idx2 + len2)..-1].to_s
              end
            end
          end
          inline = nil
          if (sc = find_top_level_char(prereq_part_raw.to_s, ";"))
            inline = prereq_part_raw[(sc + 1)..-1].to_s
            prereq_part_raw = prereq_part_raw[0...sc].to_s
          end
          assign = parse_target_assignment(prereq_part_raw.to_s.strip)
          if assign && (inline.nil? || inline.strip.empty?)
            aname, aop, aval, aforce = assign
            aname = expand(aname.to_s).to_s.strip
            raise make_error(line, "*** empty variable name.  Stop.") if aname.empty?
            targets = Util.split_ws(expand(targets_str)).reject(&:empty?)
            targets = targets.map { |t| Util.normalize_path(Util.normalize_brace_path(t)) }
            targets.each { |t| assign_target_var(t, aname, aop, aval, aforce) }
            next
          end
          targets = Util.split_ws(expand(targets_str)).reject(&:empty?)
          targets = targets.map { |t| Util.normalize_path(Util.normalize_brace_path(t)) }
          prereq_part = expand(prereq_part_raw)
          normal, order_only = prereq_part.split("|", 2).map { |x| x ? x.strip : "" }
          prereq_words = Util.filter_prereq_words(Util.split_ws(normal.to_s).reject(&:empty?))
          order_words = Util.filter_prereq_words(Util.split_ws(order_only.to_s).reject(&:empty?))
          if static_target_pattern && !static_target_pattern.empty?
            current_rules = []
            targets.each do |t|
              stem = static_pattern_stem(t, static_target_pattern)
              next if stem.nil?
              prereqs = prereq_words.map { |w| static_replace_percent(w, stem) }.map { |x| Util.normalize_path(Util.normalize_brace_path(x)) }.reject(&:empty?)
              ord = order_words.map { |w| static_replace_percent(w, stem) }.map { |x| Util.normalize_path(Util.normalize_brace_path(x)) }.reject(&:empty?)
              rule_obj = Rule.new([t], prereqs, ord, [], sep == "::", sep == "&:")
              @rules << rule_obj
              current_rules << rule_obj
            end
          else
            prereqs = prereq_words.map { |t| Util.normalize_path(Util.normalize_brace_path(t)) }.reject(&:empty?)
            order_only = order_words.map { |t| Util.normalize_path(Util.normalize_brace_path(t)) }.reject(&:empty?)
            rule_obj = Rule.new(targets, prereqs, order_only, [], sep == "::", sep == "&:")
            current_rules = [rule_obj]

            # Suffix rules like .c.o:
            if targets.length == 1 && targets[0].start_with?(".") && !targets[0].include?("/") && targets[0].count(".") == 2 && prereq_part_raw.to_s.strip.empty?
              src, dst = targets[0].split(".", 3)[1..2].map { |suf| ".#{suf}" }
              if @suffixes.empty? || @suffixes.include?(src) || @suffixes.include?(dst)
                @suffix_rules << [src, dst, prereqs, rule_obj.recipe]
              else
                @rules << rule_obj
              end
            else
              @rules << rule_obj
            end
          end
          if !inline.nil?
            recipe = Util.attach_location(Util.strip_leading_ws(inline), line.filename, line.lineno)
            current_rules.each { |rule_obj| rule_obj.recipe << recipe }
          end
          next
        end

        # Expand standalone function calls (e.g., $(eval ...))
        if s.include?("$")
          expand(s)
          next
        end

        # Any remaining non-empty line is invalid make syntax.
        raise make_error(line, "*** missing separator.  Stop.") unless s.to_s.strip.empty?
      end

      self
    end

    def second_expansion?
      @second_expansion
    end

    def set_env_override(flag)
      @env_override = !!flag
    end

    def delete_on_error?
      @delete_on_error
    end

    def phony?(name)
      @phony[name]
    end

    def phony_list
      @phony.keys
    end

    def precious?(name)
      @precious[name]
    end

    def precious_list
      @precious.keys
    end

    def suffix_rules
      @suffix_rules
    end

    def set_override(name, value)
      set_override_with_op(name, "=", value)
    end

    def set_override_with_op(name, op, value)
      @overrides[name] = true
      assigned = false
      case op
      when ":=", "::="
        @vars[name] = Var.simple(expand(value.to_s))
        assigned = true
      when ":::="
        @vars[name] = Var.recursive(recursive_immediate(value.to_s))
        assigned = true
      when "+="
        prev = @vars[name]
        if prev
          if prev.simple
            @vars[name] = Var.simple(append_with_space(prev.value, expand(value.to_s)))
          else
            @vars[name] = Var.recursive(append_with_space(prev.value, value.to_s))
          end
        else
          @vars[name] = Var.recursive(value.to_s)
        end
        assigned = true
      when "?="
        if @vars[name].nil?
          @vars[name] = Var.recursive(value.to_s)
          assigned = true
        end
      else
        @vars[name] = Var.recursive(value.to_s)
        assigned = true
      end
      @origins[name] = "command line" if assigned
      apply_makeflags_side_effects if assigned && (name == "MAKEFLAGS" || name == "MFLAGS")
    end

    def merge!(ev)
      @rules.concat(ev.rules)
      @suffix_rules.concat(ev.suffix_rules)
      ev.phony_list.each { |t| @phony[t] = true }
      ev.precious_list.each { |t| @precious[t] = true }
      @delete_on_error ||= ev.delete_on_error?
      @includes.concat(ev.includes) if ev.respond_to?(:includes)
      @missing_required.concat(ev.missing_required) if ev.respond_to?(:missing_required)
      ev.instance_variable_get(:@overrides).each_key do |k|
        @overrides[k] = true
      end
      @vars.merge!(ev.vars)
      if ev.instance_variable_defined?(:@origins)
        @origins.merge!(ev.instance_variable_get(:@origins))
      end
      if ev.respond_to?(:target_vars)
        ev.target_vars.each do |t, vars|
          (@target_vars[t] ||= {}).merge!(vars)
        end
      end
      if ev.instance_variable_defined?(:@target_inherit_append)
        ev.instance_variable_get(:@target_inherit_append).each do |t, vars|
          (@target_inherit_append[t] ||= {}).merge!(vars)
        end
      end
      if ev.respond_to?(:target_pattern_vars)
        ev.target_pattern_vars.each do |pat, vars|
          (@target_pattern_vars[pat] ||= {}).merge!(vars)
          @target_pattern_order << pat unless @target_pattern_order.include?(pat)
        end
      end
      if ev.instance_variable_defined?(:@target_pattern_inherit_append)
        ev.instance_variable_get(:@target_pattern_inherit_append).each do |pat, vars|
          (@target_pattern_inherit_append[pat] ||= {}).merge!(vars)
          @target_pattern_order << pat unless @target_pattern_order.include?(pat)
        end
      end
      if ev.instance_variable_defined?(:@exports)
        ev.instance_variable_get(:@exports).each_key { |name| mark_export(name) }
      end
    end

    def set_env_var(name, value, override = false)
      return if name.nil? || name.empty?
      @vars[name] = Var.simple(value.to_s)
      @origins[name] = override ? "environment override" : "environment"
      @overrides[name] = true if override
    end

    def set_special_var(name, value, origin = "default")
      return if name.nil? || name.empty?
      @vars[name] = Var.simple(value.to_s)
      @origins[name] = origin
    end

    def set_no_builtin_rules(flag)
      @no_builtin_rules = !!flag
    end

    def no_builtin_rules?
      @no_builtin_rules
    end

    def set_no_builtin_variables(flag)
      on = !!flag
      return if @no_builtin_variables == on
      @no_builtin_variables = on
      clear_builtin_default_vars if on
      @no_builtin_rules = true if on
    end

    def no_builtin_variables?
      @no_builtin_variables
    end

    def set_include_dirs(dirs)
      @include_dirs = (dirs || []).map(&:to_s)
    end

    private

    def seed_env
      set_special_var("CURDIR", Dir.pwd, "file")
      set_special_var("MAKE", "make", "default")
      set_special_var("MFLAGS", "", "default")
      set_special_var("mflags", "", "default")
      set_special_var("MAKECMDGOALS", "", "default")
      shell = if Object.const_defined?(:ENV) && ENV["SHELL"] && !ENV["SHELL"].empty?
        ENV["SHELL"]
      else
        "/bin/sh"
      end
      set_special_var("SHELL", shell, "default")
      set_special_var("CC", "cc", "default")
      set_special_var("AR", "ar", "default")
      set_special_var("TEX", "tex", "default")
    end

    def assign_var(name, op, value, force_override = false)
      if @env_override && !force_override && !@overrides[name] && @vars[name].nil? && !@make_overrides[name]
        envv = env_var(name)
        if envv && !envv.empty?
          @overrides[name] = true
          @vars[name] = Var.simple(envv)
          @origins[name] = "environment override"
        end
      end
      return if @overrides[name] && !force_override
      return if @make_overrides[name] && !force_override
      assigned = false
      case op
      when "="
        @vars[name] = Var.recursive(value, @current_file, @current_line)
        assigned = true
      when ":=", "::="
        @vars[name] = Var.simple(expand(value), @current_file, @current_line)
        assigned = true
      when ":::="
        @vars[name] = Var.recursive(recursive_immediate(value), @current_file, @current_line)
        assigned = true
      when "+="
        prev = @vars[name]
        if prev.nil?
          envv = env_var(name)
          if envv && !envv.empty?
            prev = Var.simple(envv)
            @vars[name] = prev
          end
        end
        if prev
          if prev.simple
            @vars[name] = Var.simple(append_with_space(prev.value, expand(value)), @current_file, @current_line)
          else
            @vars[name] = Var.recursive(append_with_space(prev.value, value), @current_file, @current_line)
          end
        else
          @vars[name] = Var.recursive(value, @current_file, @current_line)
        end
        assigned = true
      when "?="
        if @vars[name].nil?
          @vars[name] = Var.recursive(value, @current_file, @current_line)
          assigned = true
        end
      else
        @vars[name] = Var.recursive(value, @current_file, @current_line)
        assigned = true
      end
      @make_overrides[name] = true if force_override
      if assigned
        @origins[name] = force_override ? "override" : "file"
        apply_makeflags_side_effects if name == "MAKEFLAGS" || name == "MFLAGS"
      end
    end

    def assign_target_var(target, name, op, value, force_override = false)
      if target && target.index("%")
        return assign_target_pattern_var(target, name, op, value, force_override)
      end
      tvars = (@target_vars[target] ||= {})
      tovr = (@target_override_vars[target] ||= {})
      if @env_override && !force_override && !@overrides[name] && !@make_overrides[name] &&
         tvars[name].nil? && !tovr[name] && !pattern_override_for?(target, name)
        envv = env_var(name)
        if envv && !envv.empty?
          @overrides[name] = true
          tvars[name] = Var.simple(envv)
        end
      end
      return if @overrides[name] && !force_override
      return if @make_overrides[name] && !force_override
      return if pattern_override_for?(target, name) && !force_override
      return if tovr[name] && !force_override
      case op
      when "="
        tvars[name] = Var.recursive(value)
        (@target_inherit_append[target] ||= {})[name] = false
      when ":=", "::="
        tvars[name] = Var.simple(expand(value))
        (@target_inherit_append[target] ||= {})[name] = false
      when ":::="
        tvars[name] = Var.recursive(recursive_immediate(value))
        (@target_inherit_append[target] ||= {})[name] = false
      when "+="
        inherit = false
        from_local = false
        from_pattern = false
        from_global = false
        prev = tvars[name]
        if prev
          from_local = true
          inherit = (@target_inherit_append[target] || {})[name] ? true : false
        end
        if prev.nil?
          pvars = pattern_target_vars_for(target)
          if pvars && pvars[name]
            prev = pvars[name]
            tvars[name] = prev
            from_pattern = true
            inherit = pattern_target_inherit_for(target)[name] ? true : false
          end
        end
        if prev.nil?
          prev = @vars[name]
          from_global = !prev.nil?
        end
        if prev.nil?
          envv = env_var(name)
          if envv && !envv.empty?
            prev = Var.simple(envv)
            tvars[name] = prev
            from_global = true
          end
        end
        if prev
          if prev.simple
            tvars[name] = Var.simple(append_with_space(prev.value, expand(value)))
          else
            tvars[name] = Var.recursive(append_with_space(prev.value, value))
          end
        else
          tvars[name] = Var.recursive(value)
        end
        if from_global
          (@target_inherit_append[target] ||= {})[name] = false
        elsif from_local || from_pattern
          (@target_inherit_append[target] ||= {})[name] = inherit
        else
          (@target_inherit_append[target] ||= {})[name] = true
        end
      when "?="
        tvars[name] ||= Var.recursive(value)
        (@target_inherit_append[target] ||= {})[name] = false
      else
        tvars[name] = Var.recursive(value)
        (@target_inherit_append[target] ||= {})[name] = false
      end
      tovr[name] = true if force_override
    end

    def assign_target_pattern_var(pattern, name, op, value, force_override = false)
      pvars = (@target_pattern_vars[pattern] ||= {})
      povr = (@target_pattern_override_vars[pattern] ||= {})
      @target_pattern_order << pattern unless @target_pattern_order.include?(pattern)
      if @env_override && !force_override && !@overrides[name] && !@make_overrides[name] &&
         pvars[name].nil? && !povr[name]
        envv = env_var(name)
        if envv && !envv.empty?
          @overrides[name] = true
          pvars[name] = Var.simple(envv)
        end
      end
      return if @overrides[name] && !force_override
      return if @make_overrides[name] && !force_override
      return if povr[name] && !force_override
      case op
      when "="
        pvars[name] = Var.recursive(value)
        (@target_pattern_inherit_append[pattern] ||= {})[name] = false
      when ":=", "::="
        pvars[name] = Var.simple(expand(value))
        (@target_pattern_inherit_append[pattern] ||= {})[name] = false
      when ":::="
        pvars[name] = Var.recursive(recursive_immediate(value))
        (@target_pattern_inherit_append[pattern] ||= {})[name] = false
      when "+="
        inherit = false
        from_local = false
        from_global = false
        prev = pvars[name] || @vars[name]
        if pvars[name]
          from_local = true
          inherit = (@target_pattern_inherit_append[pattern] || {})[name] ? true : false
        elsif @vars[name]
          from_global = true
        end
        if prev.nil?
          envv = env_var(name)
          if envv && !envv.empty?
            prev = Var.simple(envv)
            pvars[name] = prev
            from_global = true
          end
        end
        if prev
          if prev.simple
            pvars[name] = Var.simple(append_with_space(prev.value, expand(value)))
          else
            pvars[name] = Var.recursive(append_with_space(prev.value, value))
          end
        else
          pvars[name] = Var.recursive(value)
        end
        if from_global
          (@target_pattern_inherit_append[pattern] ||= {})[name] = false
        elsif from_local
          (@target_pattern_inherit_append[pattern] ||= {})[name] = inherit
        else
          (@target_pattern_inherit_append[pattern] ||= {})[name] = true
        end
      when "?="
        pvars[name] ||= Var.recursive(value)
        (@target_pattern_inherit_append[pattern] ||= {})[name] = false
      else
        pvars[name] = Var.recursive(value)
        (@target_pattern_inherit_append[pattern] ||= {})[name] = false
      end
      povr[name] = true if force_override
    end

    def pattern_target_vars_for(target)
      out = {}
      @target_pattern_order.each do |pat|
        next unless Util.match_pattern(target.to_s, pat.to_s)
        vars = @target_pattern_vars[pat]
        next if vars.nil?
        out.merge!(vars)
      end
      out
    end
    public :pattern_target_vars_for

    def pattern_override_for?(target, name)
      @target_pattern_order.each do |pat|
        next unless Util.match_pattern(target.to_s, pat.to_s)
        ov = @target_pattern_override_vars[pat]
        return true if ov && ov[name]
      end
      false
    end

    def pattern_target_inherit_for(target)
      out = {}
      @target_pattern_order.each do |pat|
        next unless Util.match_pattern(target.to_s, pat.to_s)
        vars = @target_pattern_inherit_append[pat]
        next if vars.nil?
        out.merge!(vars)
      end
      out
    end
    public :pattern_target_inherit_for

    def env_var(name)
      return nil if name.nil? || name.empty?
      if Object.const_defined?(:ENV)
        return ENV[name]
      end
      return nil unless Util.respond_to?(:shell_capture)
      out = Util.shell_capture("printenv #{Util.shell_escape(name)}")
      out && out.empty? ? nil : out
    end

    def mark_export(name)
      return if name.nil? || name.empty?
      @exports[name] = true
      @vars["__RMAKE_EXPORTS__"] = Var.simple(@exports.keys.join(" "))
    end

    def clear_builtin_default_vars
      %w[CC AR TEX].each do |name|
        next if @overrides[name] || @make_overrides[name]
        next unless @origins[name] == "default"
        @vars.delete(name)
        @origins.delete(name)
      end
    end

    def apply_makeflags_side_effects
      var = @vars["MAKEFLAGS"] || @vars["MFLAGS"]
      return unless var
      raw = var.simple ? var.value.to_s : expand(var.value.to_s, {})
      flags = Util.split_ws(raw)
      if flags.any? { |f| f == "-R" || f == "--no-builtin-variables" }
        set_no_builtin_variables(true)
      end
      if flags.any? { |f| f == "-r" || f == "--no-builtin-rules" }
        set_no_builtin_rules(true)
      end
    end

    def include_file(path, optional = false, line = nil)
      return if path.nil? || path.empty?
      candidate = resolve_include_path(path)
      begin
        File.open(candidate, "r") do |io|
          extra = Parser.new(io, path).parse
          Evaluator.new(extra).tap do |ev|
            ev.set_no_builtin_rules(@no_builtin_rules)
            ev.set_no_builtin_variables(@no_builtin_variables)
            ev.set_include_dirs(@include_dirs)
            ev.vars.clear
            ev.vars.merge!(@vars)
            if ev.instance_variable_defined?(:@origins)
              ev.instance_variable_get(:@origins).clear
              ev.instance_variable_get(:@origins).merge!(@origins)
            end
            ev.instance_variable_get(:@overrides).merge!(@overrides)
            ev.evaluate
            merge!(ev)
          end
        end
      rescue Errno::ENOENT
        unless optional
          if line && line.respond_to?(:filename) && line.respond_to?(:lineno)
            @missing_required << { path: path, file: line.filename.to_s, line: line.lineno.to_i }
          else
            @missing_required << { path: path }
          end
        end
        return
      end
    end

    def resolve_include_path(path)
      return path if File.exist?(path)
      return path if path.start_with?("/")
      @include_dirs.each do |dir|
        next if dir.nil? || dir.empty?
        candidate = File.join(dir, path)
        return candidate if File.exist?(candidate)
      end
      path
    end

    def eval_text(text, call_ctx = nil)
      return if text.nil? || text.empty?
      io = StringIO.new(text)
      extra = Parser.new(io, "<eval>").parse
      Evaluator.new(extra).tap do |ev|
        ev.set_no_builtin_rules(@no_builtin_rules)
        ev.set_no_builtin_variables(@no_builtin_variables)
        ev.set_include_dirs(@include_dirs)
        ev.vars.clear
        ev.vars.merge!(@vars)
        if call_ctx
          filtered = {}
          call_ctx.each do |k, v|
            next if k.nil? || k.empty?
            next if k.start_with?("__")
            filtered[k] = v.to_s
          end
          ev.instance_variable_set(:@call_ctx, filtered)
        end
        if ev.instance_variable_defined?(:@origins)
          ev.instance_variable_get(:@origins).clear
          ev.instance_variable_get(:@origins).merge!(@origins)
        end
        ev.instance_variable_get(:@overrides).merge!(@overrides)
        ev.evaluate
        merge!(ev)
      end
    end

    def origin_of(name)
      return "undefined" if name.nil? || name.empty?
      return "automatic" if Util.automatic_var_name?(name)
      origin = @origins[name]
      return origin if origin
      envv = env_var(name)
      unless envv.nil?
        return @env_override ? "environment override" : "environment"
      end
      "undefined"
    end

    def expand(str, ctx = {})
      ctx = ctx ? ctx.dup : {}
      ctx["__evaluator"] = self
      if @call_ctx
        @call_ctx.each do |k, v|
          ctx[k] = v unless ctx.key?(k)
        end
      end
      if @current_file && (ctx["__file"].nil? || ctx["__file"].to_s.empty?)
        ctx["__file"] = @current_file
      end
      if @current_line && (ctx["__line"].nil? || ctx["__line"].to_s.empty?)
        ctx["__line"] = @current_line
      end
      Util.expand(str, @vars, ctx)
    end

    def cond_active?
      @cond_stack.all? { |c| c[:active] }
    end

    def handle_condition(s)
      if s.start_with?("ifdef ") || s.start_with?("ifndef ")
        op, expr = s.split(" ", 2)
        cond = eval_defined_condition(op, expr.to_s)
        parent_active = cond_active?
        @cond_stack << {
          parent_active: parent_active,
          active: parent_active && cond,
          seen_true: cond,
          else_seen: false,
        }
        return true
      end

      if s.start_with?("ifeq ") || s.start_with?("ifneq ")
        op, expr = s.split(" ", 2)
        cond = eval_condition(op, expr.to_s)
        parent_active = cond_active?
        @cond_stack << {
          parent_active: parent_active,
          active: parent_active && cond,
          seen_true: cond,
          else_seen: false,
        }
        return true
      end

      if s.start_with?("else ifeq ") || s.start_with?("else ifneq ")
        rest = s[5..-1].to_s
        rest = Util.strip_leading_ws(rest)
        op, expr = rest.split(" ", 2)
        handle_else_if(op, expr.to_s)
        return true
      end

      if s.start_with?("else ifdef ") || s.start_with?("else ifndef ")
        rest = s[5..-1].to_s
        rest = Util.strip_leading_ws(rest)
        op, expr = rest.split(" ", 2)
        handle_else_if_defined(op, expr.to_s)
        return true
      end

      if s == "else" || s.start_with?("else ")
        handle_else
        return true
      end

      if s.start_with?("endif")
        @cond_stack.pop
        return true
      end

      false
    end

    def handle_else_if(op, expr)
      top = @cond_stack.last
      return unless top
      parent_active = top[:parent_active]
      if top[:seen_true]
        top[:active] = false
      else
        cond = eval_condition(op, expr)
        top[:active] = parent_active && cond
        top[:seen_true] = cond
      end
      top[:else_seen] = true
    end

    def handle_else_if_defined(op, expr)
      top = @cond_stack.last
      return unless top
      parent_active = top[:parent_active]
      if top[:seen_true]
        top[:active] = false
      else
        cond = eval_defined_condition(op, expr)
        top[:active] = parent_active && cond
        top[:seen_true] = cond
      end
      top[:else_seen] = true
    end

    def handle_else
      top = @cond_stack.last
      return unless top
      if top[:seen_true]
        top[:active] = false
      else
        top[:active] = top[:parent_active]
        top[:seen_true] = true
      end
      top[:else_seen] = true
    end

    def eval_condition(op, expr)
      a, b = parse_condition_args(expr)
      a = expand(a.to_s).to_s.strip
      b = expand(b.to_s).to_s.strip
      if op == "ifeq"
        a == b
      else
        a != b
      end
    end

    def eval_defined_condition(op, expr)
      name = expand(expr.to_s).to_s.strip
      val = ""
      if !name.empty? && @vars[name]
        v = @vars[name]
        val = v.simple ? v.value.to_s : expand(v.value.to_s)
      end
      cond = !val.empty?
      op == "ifdef" ? cond : !cond
    end

    def parse_condition_args(expr)
      expr = expr.to_s.strip
      if expr.start_with?("(") && expr.end_with?(")")
        inner = expr[1..-2]
        return Util.split_func_args(inner)
      end
      # Fallback: split by whitespace into two tokens
      parts = Util.split_ws(expr)
      [parts[0].to_s, parts[1].to_s]
    end

    def parse_assignment(s)
      eq = find_top_level_char(s, "=")
      return nil if eq.nil?
      i = eq - 1
      i -= 1 while i >= 0 && (s[i] == " " || s[i] == "\t")
      op = "="
      name_end = i + 1
      if i >= 2 && s[(i - 2)..i] == ":::"
        op = ":::="
        name_end = i - 2
      elsif i >= 1 && s[(i - 1)..i] == "::"
        op = "::="
        name_end = i - 1
      elsif i >= 0 && s[i] == ":"
        op = ":="
        name_end = i
      elsif i >= 0 && s[i] == "+"
        op = "+="
        name_end = i
      elsif i >= 0 && s[i] == "?"
        op = "?="
        name_end = i
      end
      name = s[0...name_end].strip
      return nil if name.empty?
      return nil unless find_top_level_char(name, ":").nil?
      value = strip_hws((s[(eq + 1)..-1] || ""))
      [name, op.strip, value]
    end

    def parse_target_assignment(s)
      t = s.to_s.strip
      force_override = false
      loop do
        changed = false
        if t.start_with?("override ")
          t = t[9..-1].to_s.lstrip
          force_override = true
          changed = true
        end
        if t.start_with?("export ")
          t = t[7..-1].to_s.lstrip
          changed = true
        end
        break unless changed
      end
      assign = parse_assignment(t)
      return nil unless assign
      [assign[0], assign[1], assign[2], force_override]
    end

    def parse_include(s)
      if s.start_with?("-include ")
        return [true, s[9..-1].to_s]
      elsif s.start_with?("include ")
        return [false, s[8..-1].to_s]
      elsif s.start_with?("!include ")
        return [true, s[9..-1].to_s]
      end
      nil
    end

    def parse_rule(s)
      idx, len = find_top_level_colon(s)
      return nil if idx.nil?
      if len == 2
        return [s[0...idx], "::", s[(idx + 2)..-1].to_s]
      end
      if idx > 0 && s[idx - 1] == "&"
        return [s[0...(idx - 1)], "&:", s[(idx + 1)..-1].to_s]
      end
      [s[0...idx], ":", s[(idx + 1)..-1].to_s]
    end

    def find_top_level_char(s, ch)
      i = 0
      depth = 0
      closer = nil
      while i < s.length
        c = s[i]
        if c == "$" && (s[i + 1] == "(" || s[i + 1] == "{")
          depth += 1
          closer = s[i + 1] == "(" ? ")" : "}"
          i += 2
          next
        end
        if depth > 0 && c == closer
          depth -= 1
          i += 1
          next
        end
        if depth == 0 && c == ch
          return i
        end
        i += 1
      end
      nil
    end

    def recursive_immediate(value)
      expand(value.to_s).to_s.gsub("$", "$$")
    end

    def strip_hws(str)
      i = 0
      while i < str.length && (str[i] == " " || str[i] == "\t")
        i += 1
      end
      str[i..-1].to_s
    end

    def append_with_space(left, right)
      l = left.to_s
      r = right.to_s
      return r if l.empty?
      return l if r.empty?
      "#{l} #{r}"
    end

    def make_error(line, msg)
      file = line && line.respond_to?(:filename) && line.filename ? line.filename : "<makefile>"
      ln = line && line.respond_to?(:lineno) && line.lineno ? line.lineno : 1
      MakeError.new("#{file}:#{ln}: #{msg}")
    end

    def find_top_level_colon(s)
      i = 0
      depth = 0
      closer = nil
      while i < s.length
        c = s[i]
        if c == "$" && (s[i + 1] == "(" || s[i + 1] == "{")
          depth += 1
          closer = s[i + 1] == "(" ? ")" : "}"
          i += 2
          next
        end
        if depth > 0 && c == closer
          depth -= 1
          i += 1
          next
        end
        if depth == 0 && c == ":"
          if s[i + 1] == ":"
            return [i, 2]
          end
          return [i, 1]
        end
        i += 1
      end
      [nil, 0]
    end

    def static_pattern_stem(target, pattern)
      idx = pattern.index("%")
      if idx.nil?
        return "" if target == pattern
        return nil
      end
      pre = pattern[0...idx]
      post = pattern[(idx + 1)..-1].to_s
      return nil unless target.start_with?(pre) && target.end_with?(post)
      target[pre.length...(target.length - post.length)]
    end

    def static_replace_percent(word, stem)
      return word unless word.index("%")
      word.gsub("%", stem.to_s)
    end

    class Var
      attr_reader :value, :simple, :file, :line

      def initialize(value, simple, file = nil, line = nil)
        @value = value
        @simple = simple
        @file = file
        @line = line
      end

      def self.simple(value, file = nil, line = nil)
        new(value, true, file, line)
      end

      def self.recursive(value, file = nil, line = nil)
        new(value, false, file, line)
      end
    end
  end
end
