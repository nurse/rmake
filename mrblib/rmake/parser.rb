module RMake
  class ParseError < StandardError; end

  class Parser
    Line = Struct.new(:raw, :stripped, :recipe, :lineno, :filename)

    def initialize(io, filename = "Makefile")
      @io = io
      @filename = filename
    end

    def parse
      lines = []
      buf = ""
      continuing = false
      continuation_recipe = false
      posix_mode = false
      recipe_prefix = "\t"
      in_define = false
      define_name = nil
      define_op = "="
      define_body = []
      define_line = nil
      define_depth = 0
      @io.each_line.with_index(1) do |line, idx|
        line = line.chomp
        if in_define
          if parse_define_header(line, idx)
            define_body << line
            define_depth += 1
            next
          end
          head = Util.strip_comments(line.lstrip).strip
          if endef_directive?(head)
            if define_depth > 0
              define_body << line
              define_depth -= 1
              next
            end
            extra = endef_extra(head)
            warn_directive(idx, "extraneous text after 'endef' directive") unless extra.empty?
            value = define_body.join("\n")
            raw = "#{define_name} #{define_op} #{value}"
            lines << Line.new(raw, raw, false, define_line, @filename)
            in_define = false
            define_name = nil
            define_op = "="
            define_body = []
            define_line = nil
            define_depth = 0
          else
            define_body << line
          end
          next
        end
        if continuing && !continuation_recipe
          line = Util.strip_leading_ws(line)
        end
        if !continuing
          if (defn = parse_define_header(line, idx))
            define_name, define_op = defn
            in_define = true
            define_line = idx
            define_depth = 0
            next
          end
        end
        is_recipe = continuing ? continuation_recipe : (!recipe_prefix.empty? && line.start_with?(recipe_prefix))
        if is_recipe && !continuing
          line = line[recipe_prefix.length..-1].to_s
        end
        if line.end_with?("\\")
          chunk = line[0...-1]
          if !is_recipe && !posix_mode && chunk.end_with?("$")
            j = chunk.length - 2
            while j >= 0 && (chunk[j] == " " || chunk[j] == "\t")
              j -= 1
            end
            chunk = chunk[0..j].to_s + "$"
          end
          buf << chunk
          buf << " " unless is_recipe
          continuing = true
          continuation_recipe = is_recipe
          next
        else
          buf << line
        end
        stripped = is_recipe ? buf : Util.strip_comments(buf)
        lines << Line.new(buf, stripped, is_recipe, idx, @filename)
        if !is_recipe
          new_prefix = recipe_prefix_from_assignment(stripped)
          recipe_prefix = new_prefix unless new_prefix.nil?
        end
        if !is_recipe && stripped.to_s.strip.start_with?(".POSIX:")
          posix_mode = true
        end
        buf = ""
        continuing = false
        continuation_recipe = false
      end
      if in_define
        raise ParseError, "#{@filename}:#{define_line}: *** missing 'endef', unterminated 'define'.  Stop."
      end
      lines
    end

    private

    def parse_define_header(line, idx)
      stripped = line.strip
      return nil unless stripped.start_with?("define")
      return nil unless stripped == "define" || stripped[6] == " " || stripped[6] == "\t"

      head = Util.strip_comments(stripped).strip
      return ["", "="] if head == "define"
      rest = Util.strip_leading_ws(head[6..-1].to_s)
      return nil if starts_with_assign_op?(rest)

      name, tail = split_define_name(rest)
      tail = Util.strip_leading_ws(tail.to_s)
      op = "="
      if tail.start_with?(":::=")
        op = ":::="
        tail = tail[4..-1].to_s
      elsif tail.start_with?("::=")
        op = "::="
        tail = tail[3..-1].to_s
      elsif tail.start_with?(":=")
        op = ":="
        tail = tail[2..-1].to_s
      elsif tail.start_with?("+=")
        op = "+="
        tail = tail[2..-1].to_s
      elsif tail.start_with?("?=")
        op = "?="
        tail = tail[2..-1].to_s
      elsif tail.start_with?("=")
        op = "="
        tail = tail[1..-1].to_s
      end
      extra = Util.strip_leading_ws(tail.to_s)
      warn_directive(idx, "extraneous text after 'define' directive") unless extra.empty?
      [name, op.strip]
    end

    def split_define_name(str)
      i = 0
      depth = 0
      closer = nil
      out = ""
      while i < str.length
        c = str[i]
        if c == "$" && (str[i + 1] == "(" || str[i + 1] == "{")
          depth += 1
          closer = str[i + 1] == "(" ? ")" : "}"
          out << c
          i += 1
          out << str[i]
          i += 1
          next
        end
        if depth > 0 && c == closer
          depth -= 1
          out << c
          i += 1
          next
        end
        if depth == 0 && (c == " " || c == "\t" || c == ":" || c == "+" || c == "?" || c == "=")
          break
        end
        out << c
        i += 1
      end
      [out, str[i..-1].to_s]
    end

    def starts_with_assign_op?(str)
      str.start_with?("=") || str.start_with?(":=") || str.start_with?("::=") ||
        str.start_with?(":::=") || str.start_with?("+=") || str.start_with?("?=")
    end

    def endef_directive?(head)
      head == "endef" || head.start_with?("endef ") || head.start_with?("endef\t")
    end

    def endef_extra(head)
      return "" if head == "endef"
      Util.strip_leading_ws(head[5..-1].to_s)
    end

    def warn_directive(line, msg)
      text = "#{@filename}:#{line}: #{msg}"
      if Kernel.respond_to?(:warn)
        warn text
      else
        puts text
      end
    end

    def recipe_prefix_from_assignment(stripped)
      s = stripped.to_s.strip
      return nil unless s.start_with?(".RECIPEPREFIX")
      eq = s.index("=")
      return nil if eq.nil?
      rhs = Util.strip_leading_ws(s[(eq + 1)..-1].to_s)
      return "\t" if rhs.empty?
      rhs[0]
    end

  end
end
