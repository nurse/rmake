module RMake
  class Parser
    Line = Struct.new(:raw, :stripped, :recipe)

    def initialize(io, filename = "Makefile")
      @io = io
      @filename = filename
    end

    def parse
      lines = []
      buf = ""
      continuing = false
      continuation_recipe = false
      in_define = false
      define_name = nil
      define_body = []
      @io.each_line.with_index(1) do |line, idx|
        line = line.chomp
        if in_define
          if line.strip.start_with?("endef")
            value = define_body.join("\n")
            raw = "#{define_name} = #{value}"
            lines << Line.new(raw, raw, false)
            in_define = false
            define_name = nil
            define_body = []
          else
            define_body << line
          end
          next
        end
        if !continuing
          stripped_line = line.strip
          if stripped_line.start_with?("define ")
            define_name = stripped_line[7..-1].to_s.strip
            in_define = true
            next
          elsif stripped_line == "define"
            define_name = ""
            in_define = true
            next
          end
        end
        is_recipe = continuing ? continuation_recipe : line.start_with?("\t")
        if line.end_with?("\\")
          buf << line[0...-1]
          continuing = true
          continuation_recipe = is_recipe
          next
        else
          buf << line
        end
        stripped = is_recipe ? buf : Util.strip_comments(buf)
        lines << Line.new(buf, stripped, is_recipe)
        buf = ""
        continuing = false
        continuation_recipe = false
      end
      lines
    end
  end
end
