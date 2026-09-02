module Pylon::Scan
  struct Ignores
    @patterns : Set(String)

    def initialize(patterns : Enumerable(String))
      @patterns = patterns.map(&.strip('/')).reject(&.empty?).to_set
    end

    NONE = new([] of String)

    def ignore?(relative_path : String) : Bool
      return false if relative_path.empty?
      return true if transient?(relative_path)
      return true if @patterns.includes?(relative_path)

      offset = 0

      while (separator = relative_path.index('/', offset))
        return true if @patterns.includes?(relative_path[0, separator])

        offset = separator + 1
      end

      false
    end

    # We hard reject syncing transient files like swap files and the like, maybe make this configurable later?
    private def transient?(relative_path : String) : Bool
      separator = relative_path.rindex('/')
      name = separator ? relative_path[(separator + 1)..] : relative_path

      return true if name == ".DS_Store"
      return true if name.size > 2 && name.starts_with?('#') && name.ends_with?('#')

      vim_swap?(name)
    end

    private def vim_swap?(name : String) : Bool
      return false unless name.size > 5 && name.starts_with?('.')
      return false unless name[-4] == '.' && name[-3] == 's' && name[-2] == 'w'

      name[-1].ascii_letter?
    end
  end
end
