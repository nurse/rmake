module RMake
  module Util
    def self.strip_comments(line)
      # Remove comments unless escaped. This is a minimal placeholder.
      return line.rstrip if line.index("#").nil?
      in_escape = false
      out = ""
      line.each_char do |ch|
        if ch == "#" && !in_escape
          break
        end
        in_escape = (ch == "\\") && !in_escape
        out << ch
      end
      out.rstrip
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
                out << (var ? (var.simple ? var.value : expand(var.value, vars, ctx)) : "")
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
        value = var ? (var.simple ? var.value : expand(var.value, vars, ctx)) : ""
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
      i = 0
      depth = 0
      closer = nil
      while i < str.length
        c = str[i]
        if c == "$" && (str[i + 1] == "(" || str[i + 1] == "{")
          depth += 1
          closer = str[i + 1] == "(" ? ")" : "}"
          i += 2
          next
        end
        if depth > 0 && c == closer
          depth -= 1
          i += 1
          next
        end
        if depth == 0 && c == ","
          return [str[0...i].to_s, str[(i + 1)..-1].to_s]
        end
        i += 1
      end
      [str.to_s, ""]
    end

    def self.split_func_args_all(str)
      return [] if str.nil?
      out = []
      cur = ""
      i = 0
      depth = 0
      closer = nil
      while i < str.length
        c = str[i]
        if c == "$" && (str[i + 1] == "(" || str[i + 1] == "{")
          depth += 1
          closer = str[i + 1] == "(" ? ")" : "}"
          cur << c
          i += 1
          cur << str[i]
          i += 1
          next
        end
        if depth > 0 && c == closer
          depth -= 1
          cur << c
          i += 1
          next
        end
        if depth == 0 && c == ","
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
        cmd = with_exported_env(cmd, vars, ctx)
        return shell_capture(cmd)
      when "if"
        a, b, c = split_func_args_all(args)
        cond = expand(a.to_s, vars, ctx)
        return cond.to_s.empty? ? expand(c.to_s, vars, ctx) : expand(b.to_s, vars, ctx)
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
      when "word"
        a, b = split_func_args(args)
        idx = expand(a.to_s, vars, ctx).to_i
        words = split_ws(expand(b.to_s, vars, ctx))
        return idx <= 0 ? "" : (words[idx - 1] || "")
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
            out = shell_capture("ls -1 #{pat} 2>/dev/null")
            matches.concat(split_ws(out))
          elsif File.exist?(pat)
            matches << pat
          end
        end
        return matches.join(" ")
      when "notdir"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words.map { |w| File.basename(w) }.join(" ")
      when "dir"
        words = split_ws(expand(args.to_s, vars, ctx))
        return words.map { |w| normalize_dir(w) }.join(" ")
      when "value"
        name = expand(args.to_s, vars, ctx)
        var = vars[name]
        return var ? var.value.to_s : ""
      when "call"
        parts = split_func_args_all(args)
        name = expand(parts.shift.to_s, vars, ctx)
        var = vars[name]
        body = var ? var.value.to_s : ""
        ctx2 = ctx.dup
        parts.each_with_index do |arg, i|
          ctx2[(i + 1).to_s] = expand(arg.to_s, vars, ctx)
        end
        return expand(body, vars, ctx2)
      when "foreach"
        a, b = split_func_args(args)
        var_name = expand(a.to_s, vars, ctx)
        list, text = split_func_args(b)
        words = split_ws(expand(list.to_s, vars, ctx))
        out = []
        words.each do |w|
          ctx2 = ctx.dup
          ctx2[var_name] = w
          out << expand(text.to_s, vars, ctx2)
        end
        return out.join(" ")
      when "eval"
        eval_body = expand(args.to_s, vars, ctx)
        evaluator = ctx["__evaluator"]
        if evaluator && evaluator.respond_to?(:eval_text, true)
          evaluator.send(:eval_text, eval_body.to_s)
        end
        return ""
      end
      nil
    end

    def self.match_pattern(word, pattern)
      return false if pattern.nil?
      if pattern.include?("%")
        parts = pattern.split("%", 2)
        pre = parts[0]
        post = parts[1] || ""
        return word.start_with?(pre) && word.end_with?(post)
      end
      word == pattern
    end

    def self.normalize_dir(word)
      return "./" if word.nil? || word.empty?
      d = File.dirname(word)
      d = "." if d.nil? || d.empty?
      d = "./" if d == "."
      d = "#{d}/" unless d.end_with?("/")
      d
    end

    def self.strip_ws(str)
      return "" if str.nil?
      split_ws(str).join(" ")
    end

    def self.shell_capture(cmd)
      return "" if cmd.nil?
      return "" if cmd.strip.empty?
      if Process.respond_to?(:spawn) && Process.respond_to?(:waitpid2)
        out = ""
        t = Time.now
        usec = t.respond_to?(:usec) ? t.usec : 0
        @shell_capture_seq ||= 0
        @shell_capture_seq += 1
        pid_part = (Process.respond_to?(:pid) ? Process.pid : 0)
        tmp = "/tmp/rmake.shell.#{pid_part}.#{t.to_i}.#{usec}.#{@shell_capture_seq}"
        begin
          sh_cmd = "#{cmd} > #{shell_escape(tmp)}"
          pid = Process.spawn("/bin/sh", "-c", sh_cmd)
          Process.waitpid2(pid)
          if File.exist?(tmp)
            out = File.read(tmp).to_s
          end
        rescue
          return ""
        ensure
          File.delete(tmp) rescue nil
        end
        out = out.to_s
        return normalize_shell_output(out)
      end
      if IO.respond_to?(:popen)
        out = ""
        begin
          IO.popen("/bin/sh -c #{shell_escape(cmd)}") { |io| out = io.read.to_s }
          out = out.to_s
          return normalize_shell_output(out)
        rescue
          return ""
        end
      end
      ""
    end

    def self.with_exported_env(cmd, vars, ctx = {})
      return cmd if cmd.nil? || cmd.empty?
      return cmd if vars.nil?
      exports_var = vars["__RMAKE_EXPORTS__"]
      return cmd unless exports_var
      exports = if exports_var.simple
        exports_var.value.to_s
      else
        expand(exports_var.value.to_s, vars, ctx || {})
      end
      names = split_ws(exports)
      return cmd if names.empty?
      assigns = []
      names.each do |name|
        next if name.nil? || name.empty?
        val = nil
        if (var = vars[name])
          val = var.simple ? var.value.to_s : expand(var.value.to_s, vars, ctx || {})
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
