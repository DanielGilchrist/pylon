module Pylon::Scan
  struct Ignores
    @patterns : Set(String)

    def initialize(patterns : Enumerable(String))
      @patterns = patterns.map(&.strip('/')).reject(&.empty?).to_set
    end

    NONE = new([] of String)

    def ignore?(relative_path : String) : Bool
      return false if relative_path.empty?
      return true if @patterns.includes?(relative_path)

      offset = 0

      while (separator = relative_path.index('/', offset))
        return true if @patterns.includes?(relative_path[0, separator])

        offset = separator + 1
      end

      false
    end
  end
end
