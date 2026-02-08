module RMake
  module Util
    def self.strip_comments(line)
      return line if line.nil?
      return line if line.index("#").nil?
      out = +""
      closers = []
      i = 0
      while i < line.length
        ch = line[i]
        if ch == "$" && (line[i + 1] == "(" || line[i + 1] == "{")
          closers << (line[i + 1] == "(" ? ")" : "}")
          out << ch
          i += 1
          out << line[i]
          i += 1
          next
        end
        if !closers.empty? && ch == closers[-1]
          closers.pop
          out << ch
          i += 1
          next
        end
        if ch == "#" && closers.empty?
          bs = 0
          j = i - 1
          while j >= 0 && line[j] == "\\"
            bs += 1
            j -= 1
          end
          break if (bs % 2) == 0
        end
        out << ch
        i += 1
      end
      out
    end

    def self.expand(str, vars, ctx = {})
      return "" if str.nil?
      return str if str.index("$").nil?
      out = ""
      i = 0
      while i < str.length
        ch = str[i]
        if ch == "$"
          nxt = str[i + 1]
          if nxt == "$"
            out << "$"
            i += 2
            next
          elsif nxt == "(" || nxt == "{"
            close = (nxt == "(") ? ")" : "}"
            i += 2
            depth = 1
            token = ""
            while i < str.length && depth > 0
              c = str[i]
              if c == nxt
                depth += 1
              elsif c == close
                depth -= 1
                if depth == 0
                  i += 1
                  break
                end
              end
              token << c if depth > 0
              i += 1
            end
            out << eval_token(token, vars, ctx)
            next
          else
            # Automatic variables ($@ $< $?) or single-letter vars ($n)
            auto = nxt
            if auto
              if ctx.key?(auto)
                out << (ctx[auto] || "")
              else
                var = vars[auto]
                out << (var ? expand_var(var, vars, ctx) : "")
              end
              i += 2
              next
            end
          end
        end
        out << ch
        i += 1
      end
      out
    end

    def self.eval_token(token, vars, ctx)
      func, func_args = split_func_name(token)
      if func
        res = eval_func(func, func_args, vars, ctx)
        return res unless res.nil?
      end

      name = token
      subst = nil
      if (idx = token.index(":"))
        name = token[0...idx]
        subst = token[(idx + 1)..-1]
      end

      name = expand(name, vars, ctx)
      value = ctx[name]
      if value.nil?
        var = vars[name]
        value = var ? expand_var(var, vars, ctx) : ""
        if var.nil?
          envv = env_value(name)
          value = envv unless envv.nil?
        end
      end


      if subst
        from, to = subst.split("=", 2)
        from = expand(from.to_s, vars, ctx)
        to = expand(to.to_s, vars, ctx)
        value = apply_subst(value, from, to)
      end

      value
    end

    def self.env_value(name)
      return nil if name.nil? || name.empty?
      if Object.const_defined?(:ENV)
        return ENV[name]
      end
      return nil unless respond_to?(:shell_capture)
      out = shell_capture("printenv #{shell_escape(name)}")
      return nil if out.nil? || out.empty?
      out
    end

    def self.split_ws(str)
      return [] if str.nil?
      return [] if str.empty?
      return [str] if str.index(" ").nil? && str.index("\t").nil? && str.index("\n").nil? && str.index("\r").nil?
      out = []
      cur = ""
      i = 0
      while i < str.length
        ch = str[i]
        if ch == " " || ch == "\t" || ch == "\n" || ch == "\r"
          if !cur.empty?
            out << cur
            cur = ""
          end
        else
          cur << ch
        end
        i += 1
      end
      out << cur unless cur.empty?
      out
    end

    def self.split_func_args(str)
      return ["", ""] if str.nil?
      left, right, _had_sep = split_func_args_with_flag(str)
      [left, right]
    end

    def self.split_func_args_with_flag(str)
      return ["", "", false] if str.nil?
      i = 0
      closers = []
      while i < str.length
        c = str[i]
        if c == "$" && (str[i + 1] == "(" || str[i + 1] == "{")
          closers << (str[i + 1] == "(" ? ")" : "}")
          i += 2
          next
        end
        if !closers.empty? && c == closers[-1]
          closers.pop
          i += 1
          next
        end
        if closers.empty? && c == ","
          return [str[0...i].to_s, str[(i + 1)..-1].to_s, true]
        end
        i += 1
      end
      [str.to_s, "", false]
    end

    def self.split_func_args_all(str)
      return [] if str.nil?
      out = []
      cur = ""
      i = 0
      closers = []
      while i < str.length
        c = str[i]
        if c == "$" && (str[i + 1] == "(" || str[i + 1] == "{")
          closers << (str[i + 1] == "(" ? ")" : "}")
          cur << c
          i += 1
          cur << str[i]
          i += 1
          next
        end
        if !closers.empty? && c == closers[-1]
          closers.pop
          cur << c
          i += 1
          next
        end
        if closers.empty? && c == ","
          out << cur
          cur = ""
          i += 1
          next
        end
        cur << c
        i += 1
      end
      out << cur
      out
    end

    def self.split_func_name(token)
      return nil unless token
      t = token.lstrip
      idx_space = t.index(" ")
      idx_comma = t.index(",")
      idx = [idx_space, idx_comma].compact.min
      return nil unless idx
      func = t[0...idx]
      args = t[(idx + 1)..-1].to_s
      return nil if func.empty?
      [func, args]
    end

    def self.eval_func(func, args, vars, ctx)
      case func
      when "info"
        msg = expand(args.to_s, vars, ctx)
        puts msg
        return ""
      when "strip"
        arg = expand(args.to_s, vars, ctx)
        return strip_ws(arg)
      when "findstring"
        a, b = split_func_args(args)
        a = expand(a.to_s, vars, ctx)
        b = expand(b.to_s, vars, ctx)
        return b.include?(a) ? a : ""
      when "shell"
        cmd = expand(args.to_s, vars, ctx)
        if ctx.nil? || !ctx["__skip_exported_env"]
          cmd = with_exported_env(cmd, vars, ctx)
        end
        out, status = shell_capture_with_status(cmd, vars, ctx)
        set_shellstatus(vars, ctx, status)
        return out
      when "file"
        lhs, rhs, has_sep = split_func_args_with_flag(args)
        spec = expand(lhs.to_s, vars, ctx).to_s
        spec = strip_leading_ws(spec)
        mode = nil
        path = nil
        if spec.start_with?(">>")
          mode = :append
          path = spec[2..-1].to_s
        elsif spec.start_with?(">")
          mode = :write
          path = spec[1..-1].to_s
        elsif spec.start_with?("<")
          mode = :read
          path = spec[1..-1].to_s
        else
          op = split_ws(spec).first.to_s
          op = spec.to_s if op.empty?
          raise_make_error("file: invalid file operation: #{op}", ctx)
        end
        path = path.to_s.strip
        raise_make_error("file: missing filename", ctx) if path.empty?
        if mode == :read
          raise_make_error("file: too many arguments", ctx) if has_sep
          return "" unless File.exist?(path)
          begin
            data = File.read(path).to_s
          rescue SystemCallError => e
            raise_make_error("open: #{path}: #{sys_message(e)}", ctx)
          rescue StandardError => e
            raise_make_error("open: #{path}: #{e.message}", ctx)
          end
          data = data[0...-1] if data.end_with?("\n")
          return data
        end
        text = nil
        if has_sep
          text = expand(rhs.to_s, vars, ctx).to_s
          text += "\n" unless text.end_with?("\n")
        end
        open_mode = (mode == :append ? "a" : "w")
        begin
          File.open(path, open_mode) do |f|
            f.write(text) unless text.nil?
          end
        rescue SystemCallError => e
          raise_make_error("open: #{path}: #{sys_message(e)}", ctx)
        rescue StandardError => e
          raise_make_error("open: #{path}: #{e.message}", ctx)
        end
        return ""
      when "if"
        a, rest = split_func_args(args)
        b, c = split_func_args(rest)
        cond = expand(a.to_s, vars, ctx)
        return strip_ws(cond.to_s).empty? ? expand(c.to_s, vars, ctx) : expand(b.to_s, vars, ctx)
      when "and"
        parts = split_func_args_all(args)
        out = ""
        parts.each do |p|
          out = expand(p.to_s, vars, ctx)
          return "" unless truthy_value?(out)
        end
        return out
      when "or"
        parts = split_func_args_all(args)
        parts.each do |p|
          out = expand(p.to_s, vars, ctx)
          return out if truthy_value?(out)
        end
        return ""
      when "filter"
        a, b = split_func_args(args)
        patterns = split_ws(expand(a.to_s, vars, ctx))
        words = split_ws(expand(b.to_s, vars, ctx))
        matched = words.select { |w| patterns.any? { |p| match_pattern(w, p) } }
        return matched.join(" ")
      when "filter-out"
        a, b = split_func_args(args)
        patterns = split_ws(expand(a.to_s, vars, ctx))
        words = split_ws(expand(b.to_s, vars, ctx))
        matched = words.reject { |w| patterns.any? { |p| match_pattern(w, p) } }
        return matched.join(" ")
      when "subst"
        a, b = split_func_args(args)
        from = expand(a.to_s, vars, ctx)
        to, text = split_func_args(b)
        to = expand(to.to_s, vars, ctx)
        text = expand(text.to_s, vars, ctx)
        return text.to_s.gsub(from.to_s, to.to_s)
      when "patsubst"
        a, b = split_func_args(args)
        from = expand(a.to_s, vars, ctx)
        to, text = split_func_args(b)
        to = expand(to.to_s, vars, ctx)
        text = expand(text.to_s, vars, ctx)
        words = split_ws(text)
        words = words.map do |w|
          repl = apply_percent_subst(w, from, to)
          repl ? repl : w
        end
        return words.join(" ")
      when "addprefix"
        a, b = split_func_args(args)
        prefix = expand(a.to_s, vars, ctx)
        words = split_ws(expand(b.to_s, vars, ctx))
        return words.map { |w| prefix + w }.join(" ")
      when "addsuffix"
        a, b = split_func_args(args)
        suffix = expand(a.to_s, vars, ctx)
        words = split_ws(expand(b.to_s, vars, ctx))
        return words.map { |w| w + suffix }.join(" ")
      when "firstword"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words[0] || ""
      when "lastword"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words[-1] || ""
      when "word"
        a, b = split_func_args(args)
        idx_raw = expand(a.to_s, vars, ctx)
        idx = parse_index_arg(idx_raw, "word", "first", true, false, ctx)
        words = split_ws(expand(b.to_s, vars, ctx))
        return words[idx - 1] || ""
      when "words"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words.length.to_s
      when "wordlist"
        a, b = split_func_args(args)
        c, d = split_func_args(b)
        start_raw = expand(a.to_s, vars, ctx)
        end_raw = expand(c.to_s, vars, ctx)
        start_idx = parse_index_arg(start_raw, "wordlist", "first", false, false, ctx)
        end_idx = parse_index_arg(end_raw, "wordlist", "second", false, true, ctx)
        words = split_ws(expand(d.to_s, vars, ctx))
        return "" if end_idx < start_idx
        seg = words[(start_idx - 1)..(end_idx - 1)]
        return seg ? seg.join(" ") : ""
      when "intcmp"
        parts = split_func_args_all(args)
        return "" if parts.length < 2
        left_raw = expand(parts[0].to_s, vars, ctx)
        right_raw = expand(parts[1].to_s, vars, ctx)
        left_num = parse_intcmp_arg(left_raw, "first", ctx)
        right_num = parse_intcmp_arg(right_raw, "second", ctx)
        cmp = compare_bigints(left_num, right_num)
        case parts.length
        when 2
          return cmp == 0 ? bigint_to_s(left_num) : ""
        when 3
          return cmp < 0 ? expand(parts[2].to_s, vars, ctx) : ""
        when 4
          return cmp < 0 ? expand(parts[2].to_s, vars, ctx) : expand(parts[3].to_s, vars, ctx)
        else
          return expand(parts[2].to_s, vars, ctx) if cmp < 0
          return expand(parts[3].to_s, vars, ctx) if cmp == 0
          return expand(parts[4].to_s, vars, ctx)
        end
      when "wildcard"
        patterns = split_ws(expand(args.to_s, vars, ctx))
        matches = []
        if Object.const_defined?(:Dir) && Dir.respond_to?(:glob)
          patterns.each { |pat| matches.concat(Dir.glob(pat)) }
          return matches.join(" ")
        end
        # Fallback to shell expansion when Dir.glob is unavailable (mruby).
        patterns.each do |pat|
          if pat.include?("*") || pat.include?("?") || pat.include?("[")
            out = shell_capture("for p in #{pat}; do [ -e \"$p\" ] && printf '%s\\t' \"$p\"; done 2>/dev/null")
            out.to_s.split("\t").each do |m|
              next if m.nil? || m.empty?
              matches << m
            end
          elsif File.exist?(pat)
            matches << pat
          end
        end
        return matches.join(" ")
      when "abspath"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words.map { |w| abs_word(w) }.join(" ")
      when "realpath"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words.map { |w| real_word(w) }.reject { |w| w.nil? || w.empty? }.join(" ")
      when "notdir"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words.map { |w| File.basename(w) }.join(" ")
      when "dir"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words.map { |w| normalize_dir(w) }.join(" ")
      when "basename"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words.map { |w| basename_word(w) }.join(" ")
      when "suffix"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words.map { |w| suffix_word(w) }.join(" ")
      when "join"
        a, b = split_func_args(args)
        wa = split_ws(expand(a.to_s, vars, ctx))
        wb = split_ws(expand(b.to_s, vars, ctx))
        max = wa.length > wb.length ? wa.length : wb.length
        out = []
        i = 0
        while i < max
          left = wa[i] || ""
          right = wb[i] || ""
          out << (left + right)
          i += 1
        end
        return out.join(" ")
      when "sort"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words.uniq.sort.join(" ")
      when "value"
        name = expand(args.to_s, vars, ctx)
        if ctx && ctx.key?(name)
          return (ctx[name] || "").to_s
        end
        var = vars[name]
        return var ? var.value.to_s : ""
      when "flavor"
        name = expand(args.to_s, vars, ctx).to_s.strip
        var = vars[name]
        return "undefined" if var.nil?
        return var.simple ? "simple" : "recursive"
      when "origin"
        name = expand(args.to_s, vars, ctx).to_s.strip
        return "automatic" if automatic_var_name?(name)
        if ctx && ctx.key?(name)
          return "automatic"
        end
        evaluator = ctx["__evaluator"]
        if evaluator
          begin
            return evaluator.__send__(:origin_of, name)
          rescue StandardError
          end
        end
        return vars[name] ? "file" : "undefined"
      when "call"
        parts = split_func_args_all(args)
        name = expand(parts.shift.to_s, vars, ctx)
        var = vars[name]
        ctx2 = ctx.dup
        ctx2.keys.each do |k|
          next unless digits_only?(k.to_s) || k.to_s == "0"
          ctx2.delete(k)
        end
        ctx2["0"] = name
        parts.each_with_index do |arg, i|
          ctx2[(i + 1).to_s] = expand(arg.to_s, vars, ctx)
        end
        if var.nil?
          call_args = parts.map { |arg| expand(arg.to_s, vars, ctx) }
          res = eval_func(name.to_s, call_args.join(","), vars, ctx2)
          return res.nil? ? "" : res
        end
        body = var.value.to_s
        return expand(body, vars, ctx2)
      when "foreach"
        parts = split_func_args_all(args)
        if parts.length < 3
          raise_make_error("insufficient number of arguments (#{parts.length}) to function 'foreach'", ctx, true)
        end
        var_name = expand(parts[0].to_s, vars, ctx).to_s.strip
        list = parts[1]
        text = parts[2..-1].join(",")
        words = split_ws(expand(list.to_s, vars, ctx))
        out = []
        words.each do |w|
          ctx2 = ctx.dup
          ctx2[var_name] = w
          out << expand(text.to_s, vars, ctx2)
        end
        return out.join(" ")
      when "let"
        parts = split_func_args_all(args)
        if parts.length < 3
          raise_make_error("insufficient number of arguments (#{parts.length}) to function 'let'", ctx, true)
        end
        names = split_ws(expand(parts[0].to_s, vars, ctx))
        list_text = expand(parts[1].to_s, vars, ctx).to_s
        text = parts[2..-1].join(",")
        ctx2 = ctx ? ctx.dup : {}
        scan = 0
        names.each_with_index do |name, i|
          next if name.nil? || name.empty?
          if i == names.length - 1
            scan += 1 while scan < list_text.length && whitespace_char?(list_text[scan])
            ctx2[name] = list_text[scan..-1].to_s
            next
          end
          scan += 1 while scan < list_text.length && whitespace_char?(list_text[scan])
          if scan >= list_text.length
            ctx2[name] = ""
            next
          end
          start = scan
          scan += 1 while scan < list_text.length && !whitespace_char?(list_text[scan])
          ctx2[name] = list_text[start...scan].to_s
        end
        return expand(text.to_s, vars, ctx2)
      when "eval"
        eval_body = expand(args.to_s, vars, ctx)
        if ctx && ctx["@"]
          if contains_prereq_rule?(eval_body)
            raise_make_error("prerequisites cannot be defined in recipes", ctx)
          end
        end
        evaluator = ctx["__evaluator"]
        if evaluator && evaluator.respond_to?(:eval_text, true)
          evaluator.send(:eval_text, eval_body.to_s, ctx)
        end
        return ""
      when "warning"
        msg = expand(args.to_s, vars, ctx)
        msg = with_location_prefix(msg, ctx)
        if Kernel.respond_to?(:warn)
          warn msg
        else
          puts msg
        end
        return ""
      when "error"
        msg = expand(args.to_s, vars, ctx)
        raise_make_error("#{msg}", ctx)
      end
      nil
    end

    def self.truthy_value?(value)
      return false if value.nil?
      !strip_ws(value.to_s).empty?
    end

    def self.contains_prereq_rule?(text)
      lines = text.to_s.split("\n", -1)
      lines.each do |line|
        s = line.to_s.strip
        next if s.empty?
        next if s[0] == "#"
        idx = s.index(":")
        next if idx.nil?
        op = s[idx, 4].to_s
        next if op.start_with?(":=", "::=", ":::=")
        next if idx > 0 && (s[idx - 1] == "?" || s[idx - 1] == "+")
        rhs = s[(idx + 1)..-1].to_s.strip
        next if rhs.empty?
        rhs = rhs.split(";", 2)[0].to_s.strip
        return true unless rhs.empty?
      end
      false
    end

    def self.parse_intcmp_arg(raw, which, ctx)
      text = raw.to_s
      stripped = text.strip
      if stripped.empty?
        raise_make_error("non-numeric #{which} argument to 'intcmp' function: empty value", ctx)
      end
      sign = 1
      if stripped[0] == "+"
        stripped = stripped[1..-1].to_s
      elsif stripped[0] == "-"
        sign = -1
        stripped = stripped[1..-1].to_s
      end
      if stripped.empty? || !digits_only?(stripped)
        raise_make_error("non-numeric #{which} argument to 'intcmp' function: '#{text}'", ctx)
      end
      i = 0
      while i < stripped.length - 1 && stripped[i] == "0"
        i += 1
      end
      digits = stripped[i..-1].to_s
      sign = 1 if digits == "0"
      [sign, digits]
    end

    def self.compare_bigints(a, b)
      as, ad = a
      bs, bd = b
      return -1 if as < bs
      return 1 if as > bs
      if ad.length != bd.length
        cmp = ad.length < bd.length ? -1 : 1
        return as > 0 ? cmp : -cmp
      end
      if ad == bd
        return 0
      end
      cmp = ad < bd ? -1 : 1
      as > 0 ? cmp : -cmp
    end

    def self.bigint_to_s(num)
      sign, digits = num
      return digits if digits == "0" || sign >= 0
      "-#{digits}"
    end

    def self.whitespace_char?(c)
      c == " " || c == "\t" || c == "\n" || c == "\r"
    end

    def self.expand_var(var, vars, ctx)
      return "" if var.nil?
      return var.value if var.simple
      ctx2 = ctx ? ctx.dup : {}
      if var.respond_to?(:file) && var.file && !var.file.to_s.empty?
        ctx2["__def_file"] = var.file
      end
      if var.respond_to?(:line) && var.line && !var.line.to_s.empty?
        ctx2["__def_line"] = var.line
      end
      expand(var.value, vars, ctx2)
    end

    def self.with_location_prefix(msg, ctx, prefer_definition = false)
      file = nil
      line = nil
      if prefer_definition && ctx
        file = ctx["__def_file"]
        line = ctx["__def_line"]
      end
      if file.nil? || file.to_s.empty? || line.nil? || line.to_s.empty?
        file = ctx ? ctx["__file"] : nil
        line = ctx ? ctx["__line"] : nil
      end
      return msg.to_s if file.nil? || file.to_s.empty? || line.nil? || line.to_s.empty?
      "#{file}:#{line}: #{msg}"
    end

    def self.raise_make_error(msg, ctx, prefer_definition = false)
      loc = with_location_prefix("", ctx, prefer_definition)
      if loc.empty?
        raise RMake::Evaluator::MakeError, "*** #{msg}.  Stop."
      else
        raise RMake::Evaluator::MakeError, "#{loc}*** #{msg}.  Stop."
      end
    end

    LONG_MAX_STR = "9223372036854775807"

    def self.parse_index_arg(raw, func_name, arg_name, special_word_zero, allow_zero, ctx)
      text = raw.to_s
      stripped = text.strip
      if stripped.empty?
        raise_make_error("invalid #{arg_name} argument to '#{func_name}' function: empty value", ctx, true)
      end
      unless digits_only?(stripped)
        raise_make_error("invalid #{arg_name} argument to '#{func_name}' function: '#{text}'", ctx, true)
      end
      if out_of_range_int?(stripped)
        raise_make_error("invalid #{arg_name} argument to '#{func_name}' function: '#{text}' out of range", ctx, true)
      end
      n = stripped.to_i
      if n <= 0
        return n if allow_zero && n == 0
        if special_word_zero
          raise_make_error("first argument to 'word' function must be greater than 0", ctx, true)
        else
          raise_make_error("invalid #{arg_name} argument to '#{func_name}' function: '#{text}'", ctx, true)
        end
      end
      n
    end

    def self.out_of_range_int?(digits)
      d = digits.to_s
      return true if d.length > LONG_MAX_STR.length
      return false if d.length < LONG_MAX_STR.length
      d > LONG_MAX_STR
    end

    def self.digits_only?(str)
      return false if str.nil? || str.empty?
      i = 0
      while i < str.length
        c = str[i]
        return false if c < "0" || c > "9"
        i += 1
      end
      true
    end

    def self.match_pattern(word, pattern)
      return false if pattern.nil?
      tokens = parse_pattern_tokens(pattern.to_s)
      match_pattern_tokens(word.to_s, tokens, 0, 0)
    end

    def self.sys_message(error)
      errnum = if error.class.const_defined?(:Errno)
        error.class.const_get(:Errno)
      else
        nil
      end
      return error.message.to_s if errnum.nil?
      SystemCallError.new(nil, errnum).message
    rescue StandardError
      error.message.to_s
    end

    def self.parse_pattern_tokens(pattern)
      out = []
      lit = ""
      i = 0
      while i < pattern.length
        c = pattern[i]
        if c == "\\"
          n = pattern[i + 1]
          if n == "%" || n == "\\"
            lit << n
            i += 2
            next
          end
          lit << "\\"
          i += 1
          next
        end
        if c == "%"
          out << lit
          out << :wild
          lit = ""
          i += 1
          next
        end
        lit << c
        i += 1
      end
      out << lit
      out
    end

    def self.match_pattern_tokens(word, tokens, wi, ti)
      return wi == word.length if ti >= tokens.length
      tok = tokens[ti]
      if tok == :wild
        j = wi
        while j <= word.length
          return true if match_pattern_tokens(word, tokens, j, ti + 1)
          j += 1
        end
        return false
      end
      lit = tok.to_s
      return false if wi + lit.length > word.length
      return false unless word[wi, lit.length] == lit
      match_pattern_tokens(word, tokens, wi + lit.length, ti + 1)
    end

    def self.normalize_dir(word)
      return "./" if word.nil? || word.empty?
      d = File.dirname(word)
      d = "." if d.nil? || d.empty?
      d = "./" if d == "."
      d = "#{d}/" unless d.end_with?("/")
      d
    end

    def self.abs_word(word)
      return "" if word.nil? || word.empty?
      File.expand_path(word.to_s)
    rescue StandardError
      ""
    end

    def self.real_word(word)
      return "" if word.nil? || word.empty?
      path = abs_word(word.to_s)
      return "" if path.nil? || path.empty?
      if File.respond_to?(:realpath)
        return File.realpath(path)
      end
      return "" unless File.exist?(path)
      path
    rescue StandardError
      ""
    end

    def self.basename_word(word)
      return "" if word.nil? || word.empty?
      s = word.to_s
      slash = s.rindex("/")
      dot = s.rindex(".")
      return s if dot.nil?
      return s if slash && dot <= slash + 1
      s[0...dot]
    end

    def self.suffix_word(word)
      return "" if word.nil? || word.empty?
      s = word.to_s
      slash = s.rindex("/")
      dot = s.rindex(".")
      return "" if dot.nil?
      return "" if slash && dot <= slash + 1
      s[dot..-1].to_s
    end

    def self.automatic_var_name?(name)
      return false if name.nil? || name.empty?
      return true if %w[@ % < ? ^ + *].include?(name)
      return true if %w[@D @F <D <F ?D ?F ^D ^F +D +F *D *F].include?(name)
      false
    end

    def self.strip_ws(str)
      return "" if str.nil?
      split_ws(str).join(" ")
    end

    LOCATION_MARK = "__RMAKE_LOC__\t"

    def self.attach_location(cmd, file, line)
      return cmd.to_s if file.nil? || file.to_s.empty? || line.nil?
      "#{LOCATION_MARK}#{file}\t#{line}\t#{cmd}"
    end

    def self.extract_location(cmd)
      s = cmd.to_s
      return [nil, nil, s] unless s.start_with?(LOCATION_MARK)
      rest = s[LOCATION_MARK.length..-1].to_s
      i = rest.index("\t")
      return [nil, nil, s] if i.nil?
      j = rest.index("\t", i + 1)
      return [nil, nil, s] if j.nil?
      file = rest[0...i]
      line = rest[(i + 1)...j]
      body = rest[(j + 1)..-1].to_s
      [file, line, body]
    end

    def self.shell_capture(cmd, vars = nil, ctx = nil)
      out, _status = shell_capture_with_status(cmd, vars, ctx)
      out
    end

    def self.shell_capture_with_status(cmd, vars = nil, ctx = nil)
      return ["", 0] if cmd.nil?
      return ["", 0] if cmd.strip.empty?
      if Process.respond_to?(:spawn) && Process.respond_to?(:waitpid2)
        out = ""
        err = ""
        status = 0
        t = Time.now
        usec = t.respond_to?(:usec) ? t.usec : 0
        @shell_capture_seq ||= 0
        @shell_capture_seq += 1
        pid_part = (Process.respond_to?(:pid) ? Process.pid : 0)
        tmp_out = "/tmp/rmake.shell.out.#{pid_part}.#{t.to_i}.#{usec}.#{@shell_capture_seq}"
        tmp_err = "/tmp/rmake.shell.err.#{pid_part}.#{t.to_i}.#{usec}.#{@shell_capture_seq}"
        begin
          sh_cmd = "#{cmd} > #{shell_escape(tmp_out)} 2> #{shell_escape(tmp_err)}"
          pid = Process.spawn("/bin/sh", "-c", sh_cmd)
          _, st = Process.waitpid2(pid)
          status = shell_status_code(st)
          out = File.exist?(tmp_out) ? File.read(tmp_out).to_s : ""
          err = File.exist?(tmp_err) ? File.read(tmp_err).to_s : ""
          emit_shell_stderr(err, cmd, status, vars, ctx)
        rescue
          return ["", 127]
        ensure
          File.delete(tmp_out) rescue nil
          File.delete(tmp_err) rescue nil
        end
        out = out.to_s
        return [normalize_shell_output(out), status]
      end
      if IO.respond_to?(:popen)
        out = ""
        err = ""
        status = 0
        t = Time.now
        usec = t.respond_to?(:usec) ? t.usec : 0
        @shell_capture_seq ||= 0
        @shell_capture_seq += 1
        pid_part = (Process.respond_to?(:pid) ? Process.pid : 0)
        tmp_out = "/tmp/rmake.shell.out.#{pid_part}.#{t.to_i}.#{usec}.#{@shell_capture_seq}"
        tmp_err = "/tmp/rmake.shell.err.#{pid_part}.#{t.to_i}.#{usec}.#{@shell_capture_seq}"
        begin
          Kernel.system("/bin/sh -c #{shell_escape("#{cmd} > #{shell_escape(tmp_out)} 2> #{shell_escape(tmp_err)}")}")
          st = $?
          status = shell_status_code(st)
          out = File.exist?(tmp_out) ? File.read(tmp_out).to_s : ""
          err = File.exist?(tmp_err) ? File.read(tmp_err).to_s : ""
          emit_shell_stderr(err, cmd, status, vars, ctx)
          out = out.to_s
          return [normalize_shell_output(out), status]
        rescue
          return ["", 127]
        ensure
          File.delete(tmp_out) rescue nil
          File.delete(tmp_err) rescue nil
        end
      end
      ["", 127]
    end

    def self.with_exported_env(cmd, vars, ctx = {})
      return cmd if cmd.nil? || cmd.empty?
      return cmd if vars.nil?
      ctx2 = ctx ? ctx.dup : {}
      ctx2["__skip_exported_env"] = true
      exports_var = vars["__RMAKE_EXPORTS__"]
      names = []
      if exports_var
        exports = if exports_var.simple
          exports_var.value.to_s
        else
          expand(exports_var.value.to_s, vars, ctx2)
        end
        names.concat(split_ws(exports))
      end
      if Object.const_defined?(:ENV)
        ENV.each_key do |name|
          next if name.nil? || name.empty?
          names << name if vars[name]
        end
      end
      env_keys_var = vars["__RMAKE_ENV_KEYS__"]
      if env_keys_var
        env_keys = env_keys_var.simple ? env_keys_var.value.to_s : expand(env_keys_var.value.to_s, vars, ctx2)
        split_ws(env_keys).each do |name|
          next if name.nil? || name.empty?
          names << name if vars[name]
        end
      end
      names = uniq_words(names)
      return cmd if names.empty?
      assigns = []
      names.each do |name|
        next if name.nil? || name.empty?
        val = nil
        if (var = vars[name])
          val = var.simple ? var.value.to_s : expand(var.value.to_s, vars, ctx2)
        else
          val = env_value(name)
        end
        next if val.nil?
        assigns << "#{name}=#{shell_escape(val.to_s)}"
      end
      return cmd if assigns.empty?
      "env #{assigns.join(' ')} /bin/sh -c #{shell_escape(cmd)}"
    end

    def self.normalize_shell_output(out)
      return "" if out.nil?
      s = out.to_s
      if s.end_with?("\r\n")
        s = s[0...-2]
      elsif s.end_with?("\n")
        s = s[0...-1]
      end
      s.tr("\n", " ")
    end

    def self.uniq_words(words)
      out = []
      seen = {}
      words.each do |w|
        next if w.nil? || w.empty?
        next if seen[w]
        seen[w] = true
        out << w
      end
      out
    end

    def self.shell_status_code(status_obj)
      return 127 if status_obj.nil?
      if status_obj.respond_to?(:signaled?) && status_obj.signaled?
        sig = status_obj.respond_to?(:termsig) ? status_obj.termsig.to_i : 0
        return 128 + sig
      end
      if status_obj.respond_to?(:exitstatus)
        st = status_obj.exitstatus
        return st.nil? ? 0 : st.to_i
      end
      raw = status_obj.to_i
      return raw if raw <= 255
      (raw >> 8)
    end

    def self.make_invocation_name(vars = nil, ctx = nil)
      if vars && vars["MAKE"]
        var = vars["MAKE"]
        raw = var.simple ? var.value.to_s : expand(var.value.to_s, vars, ctx || {})
        first = split_ws(raw).first
        return File.basename(first) if first && !first.empty?
      end
      if ctx && ctx["__evaluator"] && ctx["__evaluator"].respond_to?(:vars)
        evars = ctx["__evaluator"].vars
        if evars && evars["MAKE"]
          var = evars["MAKE"]
          raw = var.simple ? var.value.to_s : expand(var.value.to_s, evars, ctx || {})
          first = split_ws(raw).first
          return File.basename(first) if first && !first.empty?
        end
      end
      if Object.const_defined?(:ENV)
        mk = ENV["MAKE"]
        if mk && !mk.empty?
          first = split_ws(mk).first
          return File.basename(first) if first && !first.empty?
        end
      end
      "make"
    end

    def self.rewrite_shell_stderr(err, status, vars = nil, ctx = nil)
      s = err.to_s
      return s if status != 127
      prefix = make_invocation_name(vars, ctx)
      lines = s.split("\n", -1)
      out = []
      lines.each do |line|
        if line.start_with?("/bin/sh: ")
          body = line[9..-1].to_s
          body = body[8..-1].to_s if body.start_with?("line ")
          out << "#{prefix}: #{body}"
        else
          out << line
        end
      end
      out.join("\n")
    end

    def self.emit_shell_stderr(err, _cmd, status, vars = nil, ctx = nil)
      return if err.nil? || err.empty?
      text = rewrite_shell_stderr(err, status, vars, ctx)
      if Object.const_defined?(:STDERR) && STDERR.respond_to?(:write)
        STDERR.write(text)
        STDERR.write("\n") unless text.end_with?("\n")
      else
        puts text
      end
    end

    def self.set_shellstatus(vars, ctx, status)
      st = status.to_i.to_s
      evaluator = ctx ? ctx["__evaluator"] : nil
      if evaluator && evaluator.respond_to?(:set_special_var)
        evaluator.set_special_var(".SHELLSTATUS", st, "automatic")
        return
      end
      return if vars.nil?
      if Object.const_defined?(:RMake) && RMake.const_defined?(:Evaluator) &&
         RMake::Evaluator.const_defined?(:Var)
        vars[".SHELLSTATUS"] = RMake::Evaluator::Var.simple(st)
      end
    end

    def self.strip_leading_ws(str)
      i = 0
      while i < str.length && str[i].ord <= 32
        i += 1
      end
      str[i..-1] || ""
    end

    def self.strip_cmd_prefix(str, ch)
      i = 0
      while i < str.length && str[i].ord <= 32
        i += 1
      end
      return [false, str] if i >= str.length
      if str[i] == ch
        j = i + 1
        while j < str.length && str[j].ord <= 32
          j += 1
        end
        return [true, (str[j..-1] || "")]
      end
      [false, str]
    end

    def self.strip_cmd_prefixes(str)
      silent = false
      ignore = false
      force = false
      cmd = str
      loop do
        changed = false
        flag, cmd2 = strip_cmd_prefix(cmd, "@")
        if flag
          silent = true
          cmd = cmd2
          changed = true
        end
        flag, cmd2 = strip_cmd_prefix(cmd, "-")
        if flag
          ignore = true
          cmd = cmd2
          changed = true
        end
        flag, cmd2 = strip_cmd_prefix(cmd, "+")
        if flag
          force = true
          cmd = cmd2
          changed = true
        end
        break unless changed
      end
      [silent, ignore, force, cmd]
    end

    def self.strip_prefix(str, ch)
      i = 0
      while i < str.length && str[i] == ch
        i += 1
      end
      str[i..-1] || ""
    end

    def self.strip_suffix(name)
      idx = name.rindex(".")
      return name if idx.nil?
      name[0...idx]
    end

    def self.filter_prereq_words(words)
      out = []
      words.each do |w|
        next if w == "export" || w == "override"
        next if w.include?("=")
        out << w
      end
      out
    end

    def self.normalize_brace_path(token)
      return token unless token.start_with?("{")
      idx = token.index("}")
      return token if idx.nil?
      inner = token[1...idx]
      rest = token[(idx + 1)..-1].to_s
      dirs = split_ws(inner.tr(":", " "))
      if rest.empty?
        dirs.each do |d|
          next if d.empty?
          return d if File.exist?(d)
        end
        return dirs.first || token
      end
      dirs.each do |d|
        next if d.empty?
        candidate = File.join(d, rest)
        return candidate if File.exist?(candidate)
      end
      rest
    end

    def self.normalize_path(token)
      return token unless token.start_with?("./")
      rest = token[2..-1].to_s
      rest.empty? ? "." : rest
    end

    def self.apply_percent_subst(word, from, to)
      return nil unless from.include?("%")
      parts = from.split("%", 2)
      pre = parts[0]
      post = parts[1] || ""
      return nil unless word.start_with?(pre) && word.end_with?(post)
      mid = word[pre.length...(word.length - post.length)]
      to.gsub("%", mid)
    end

    def self.shell_escape(str)
      "'" + str.gsub("'", "'\"'\"'") + "'"
    end


    def self.apply_subst(value, from, to)
      return value if from.empty?
      words = split_ws(value)
      if from.include?("%")
        words = words.map do |w|
          repl = apply_percent_subst(w, from, to)
          repl ? repl : w
        end
      else
        words = words.map do |w|
          if w.end_with?(from)
            w[0...-from.length] + to
          else
            w
          end
        end
      end
      words.join(" ")
    end
  end
end
