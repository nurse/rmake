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
    Rule = Struct.new(:targets, :prereqs, :order_only, :recipe, :double_colon)

    attr_reader :rules, :vars, :target_vars
    attr_reader :includes, :missing_required

    def initialize(lines)
      @lines = lines
      @rules = []
      @vars = {}
      @overrides = {}
      @includes = []
      @missing_required = []
      @suffix_rules = []
      @suffixes = []
      @delete_on_error = false
      @precious = {}
      @phony = {}
      @target_vars = {}
      @cond_stack = []
      seed_env
    end

    def evaluate
      current_rule = nil
      @lines.each do |line|
        s = line.stripped
        next if s.nil? || s.empty?

        if handle_condition(s)
          next
        end

        unless cond_active?
          next
        end

        if line.recipe
          if current_rule
            recipe = Util.strip_leading_ws(line.raw)
            current_rule.recipe << recipe
          end
          next
        end

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
          assign_var(name, op, value, force_override)
          next
        elsif export_only
          # "export VAR" without assignment: ignore for now.
          next
        end

        # include / -include / !include
        if (inc = parse_include(s))
          optional, arg = inc
          files = Util.split_ws(expand(arg))
          files.each do |f|
            @includes << [f, optional]
            include_file(f, optional)
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
          inline = nil
          if (sc = find_top_level_char(prereq_part_raw.to_s, ";"))
            inline = prereq_part_raw[(sc + 1)..-1].to_s
            prereq_part_raw = prereq_part_raw[0...sc].to_s
          end
          assign = parse_assignment(prereq_part_raw.to_s.strip)
          if assign && (inline.nil? || inline.strip.empty?)
            targets = Util.split_ws(expand(targets_str)).reject(&:empty?)
            targets = targets.map { |t| Util.normalize_path(Util.normalize_brace_path(t)) }
            targets.each { |t| assign_target_var(t, assign[0], assign[1], assign[2]) }
            next
          end
          targets = Util.split_ws(expand(targets_str)).reject(&:empty?)
          targets = targets.map { |t| Util.normalize_path(Util.normalize_brace_path(t)) }
          prereq_part = expand(prereq_part_raw)
          normal, order_only = prereq_part.split("|", 2).map { |x| x ? x.strip : "" }
          prereqs = Util.filter_prereq_words(Util.split_ws(normal.to_s).reject(&:empty?)).map { |t| Util.normalize_path(Util.normalize_brace_path(t)) }.reject(&:empty?)
          order_only = Util.filter_prereq_words(Util.split_ws(order_only.to_s).reject(&:empty?)).map { |t| Util.normalize_path(Util.normalize_brace_path(t)) }.reject(&:empty?)
          current_rule = Rule.new(targets, prereqs, order_only, [], sep == "::")

          # Suffix rules like .c.o:
          if targets.length == 1 && targets[0].start_with?(".") && !targets[0].include?("/") && targets[0].count(".") == 2 && prereq_part_raw.to_s.strip.empty?
            src, dst = targets[0].split(".", 3)[1..2].map { |suf| ".#{suf}" }
            @suffix_rules << [src, dst, prereqs, current_rule.recipe]
          else
            @rules << current_rule
          end
          if inline && !inline.strip.empty?
            recipe = Util.strip_leading_ws(inline)
            current_rule.recipe << recipe
          end
          next
        end

        # Expand standalone function calls (e.g., $(eval ...))
        if s.include?("$")
          expand(s)
        end
      end

      self
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
      @overrides[name] = true
      @vars[name] = Var.recursive(value)
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
      if ev.respond_to?(:target_vars)
        ev.target_vars.each do |t, vars|
          (@target_vars[t] ||= {}).merge!(vars)
        end
      end
    end

    private

    def seed_env
      @vars["CURDIR"] = Var.simple(Dir.pwd)
      if Object.const_defined?(:ENV)
        @vars["MAKE"] = Var.simple(ENV["MAKE"] || "make")
        @vars["MFLAGS"] = Var.simple(ENV["MFLAGS"] || "")
        @vars["mflags"] = Var.simple(@vars["MFLAGS"].value)
        @vars["MAKECMDGOALS"] = Var.simple(ENV["MAKECMDGOALS"] || "")
      else
        @vars["MAKE"] = Var.simple("make")
        @vars["MFLAGS"] = Var.simple("")
        @vars["mflags"] = Var.simple("")
        @vars["MAKECMDGOALS"] = Var.simple("")
      end
    end

    def assign_var(name, op, value, force_override = false)
      return if @overrides[name] && !force_override
      case op
      when "="
        @vars[name] = Var.recursive(value)
      when ":="
        @vars[name] = Var.simple(expand(value))
      when "+="
        prev = @vars[name]
        if prev
          if prev.simple
            @vars[name] = Var.simple(prev.value + " " + expand(value))
          else
            @vars[name] = Var.recursive(prev.value + " " + value)
          end
        else
          @vars[name] = Var.recursive(value)
        end
      else
        @vars[name] = Var.recursive(value)
      end
    end

    def assign_target_var(target, name, op, value)
      tvars = (@target_vars[target] ||= {})
      case op
      when "="
        tvars[name] = Var.recursive(value)
      when ":="
        tvars[name] = Var.simple(expand(value))
      when "+="
        prev = tvars[name] || @vars[name]
        if prev
          if prev.simple
            tvars[name] = Var.simple(prev.value + " " + expand(value))
          else
            tvars[name] = Var.recursive(prev.value + " " + value)
          end
        else
          tvars[name] = Var.recursive(value)
        end
      else
        tvars[name] = Var.recursive(value)
      end
    end

    def include_file(path, optional = false)
      return if path.nil? || path.empty?
      begin
        File.open(path, "r") do |io|
          extra = Parser.new(io, path).parse
          Evaluator.new(extra).tap do |ev|
            ev.vars.merge!(@vars)
            ev.instance_variable_get(:@overrides).merge!(@overrides)
            ev.evaluate
            merge!(ev)
          end
        end
      rescue Errno::ENOENT
        @missing_required << path unless optional
        return
      end
    end

    def eval_text(text)
      return if text.nil? || text.empty?
      io = StringIO.new(text)
      extra = Parser.new(io, "<eval>").parse
      Evaluator.new(extra).tap do |ev|
        ev.vars.merge!(@vars)
        ev.instance_variable_get(:@overrides).merge!(@overrides)
        ev.evaluate
        merge!(ev)
      end
    end

    def expand(str, ctx = {})
      ctx = ctx ? ctx.dup : {}
      ctx["__evaluator"] = self
      Util.expand(str, @vars, ctx)
    end

    def cond_active?
      @cond_stack.all? { |c| c[:active] }
    end

    def handle_condition(s)
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
      if i >= 0 && s[i] == ":"
        op = ":="
        name_end = i
      elsif i >= 0 && s[i] == "+"
        op = "+="
        name_end = i
      end
      name = s[0...name_end].strip
      return nil if name.empty? || name.index(" ")
      value = (s[(eq + 1)..-1] || "").lstrip
      [name, op, value]
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

    class Var
      attr_reader :value, :simple

      def initialize(value, simple)
        @value = value
        @simple = simple
      end

      def self.simple(value)
        new(value, true)
      end

      def self.recursive(value)
        new(value, false)
      end
    end
  end
end
