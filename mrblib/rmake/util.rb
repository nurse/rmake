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
      if token.start_with?("strip ")
        arg = token[6..-1].to_s
        return strip_ws(expand(arg, vars, ctx))
      elsif token.start_with?("findstring ")
        arg = token[11..-1].to_s
        a, b = split_func_args(arg)
        a = expand(a.to_s, vars, ctx)
        b = expand(b.to_s, vars, ctx)
        return b.include?(a) ? a : ""
      elsif token.start_with?("shell ")
        cmd = expand(token[6..-1].to_s, vars, ctx)
        return shell_capture(cmd)
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
      end


      if subst
        from, to = subst.split("=", 2)
        from = expand(from.to_s, vars, ctx)
        to = expand(to.to_s, vars, ctx)
        value = apply_subst(value, from, to)
      end

      value
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
        tmp = "/tmp/rmake.shell.#{t.to_i}.#{usec}"
        begin
          sh_cmd = "#{cmd} > #{shell_escape(tmp)}"
          pid = Process.spawn("/bin/sh", "-c", sh_cmd)
          Process.waitpid2(pid)
          if File.exist?(tmp)
            out = File.read(tmp).to_s
            File.delete(tmp) rescue nil
          end
        rescue
          return ""
        end
        return out.strip
      end
      if IO.respond_to?(:popen)
        out = ""
        begin
          IO.popen("/bin/sh -c #{shell_escape(cmd)}") { |io| out = io.read.to_s }
          return out.strip
        rescue
          return ""
        end
      end
      ""
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
        break unless changed
      end
      [silent, ignore, cmd]
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
