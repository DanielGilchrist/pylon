module Pylon::Core
  struct Preferences
    enum Side
      Local
      Remote
    end

    record Rule, side : Side, pattern : String

    record Invalid, message : String

    FALLBACK = "."

    def self.none : Preferences
      new([] of Rule)
    end

    def self.build(local : Array(String), remote : Array(String)) : Preferences | Invalid
      rules = [] of Rule
      local.each { |pattern| rules << Rule.new(:local, pattern) }
      remote.each { |pattern| rules << Rule.new(:remote, pattern) }

      rules.each do |rule|
        if (problem = malformed(rule.pattern))
          return Invalid.new("#{rule.pattern.inspect} is not a valid glob: #{problem}")
        end
      end

      new(rules)
    end

    private def self.malformed(pattern : String) : String?
      File.match?(pattern, "probe")
      File.match?("#{pattern}/**", "probe")
      nil
    rescue error : File::BadPatternError
      error.message || "bad pattern"
    end

    @explicit : Array(Rule)
    @fallback : Side?

    def initialize(rules : Array(Rule))
      @explicit = rules.reject { |rule| rule.pattern == FALLBACK }
      fallbacks = rules.select { |rule| rule.pattern == FALLBACK }

      @fallback =
        if fallbacks.empty?
          nil
        elsif fallbacks.any? { |rule| rule.side.local? }
          Side::Local
        else
          Side::Remote
        end
    end

    def winner(path : String) : Side?
      preferred : Side? = nil

      @explicit.each do |rule|
        next unless matches?(rule.pattern, path)
        return Side::Local if rule.side.local?

        preferred = Side::Remote
      end

      preferred || @fallback
    end

    private def matches?(pattern : String, path : String) : Bool
      File.match?(pattern, path) || File.match?("#{pattern}/**", path)
    end
  end
end
