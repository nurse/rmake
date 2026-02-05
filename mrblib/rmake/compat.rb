module RMake
  module Compat
  end
end

class File
  def self.mtime(path)
    f = File.open(path)
    begin
      f.mtime
    ensure
      f.close
    end
  end
end
