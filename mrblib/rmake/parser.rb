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
      @io.each_line.with_index(1) do |line, idx|
        line = line.chomp
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
