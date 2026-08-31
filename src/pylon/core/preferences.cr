require "../filesystem/pattern"

module Pylon::Core
  struct Preferences
    enum Side
      Local
      Remote
    end

    record GlobRule, side : Side, pattern : Filesystem::Pattern
    record FallbackRule, side : Side

    alias Rule = GlobRule | FallbackRule

    record Invalid, message : String

    FALLBACK = "."

    def self.none : Preferences
      new([] of Rule)
    end

    def self.build(local : Array(String), remote : Array(String)) : Preferences | Invalid
      rules = [] of Rule

      collect(rules, :local, local) || collect(rules, :remote, remote) || new(rules)
    end

    private def self.collect(rules : Array(Rule), side : Side, texts : Array(String)) : Invalid?
      texts.each do |text|
        if text == FALLBACK
          rules << FallbackRule.new(side)
          next
        end

        pattern = Filesystem::Pattern.parse(text)
        return Invalid.new("#{text.inspect} is not a valid glob: #{pattern.reason}") if pattern.is_a?(Problem)

        rules << GlobRule.new(side, pattern)
      end

      nil
    end

    @explicit : Array(GlobRule)
    @fallback : Side?

    def initialize(rules : Array(Rule))
      @explicit = [] of GlobRule
      fallbacks = [] of FallbackRule

      rules.each do |rule|
        case rule
        in GlobRule     then @explicit << rule
        in FallbackRule then fallbacks << rule
        end
      end

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
        next unless rule.pattern.matches?(path)
        return Side::Local if rule.side.local?

        preferred = Side::Remote
      end

      preferred || @fallback
    end
  end
end
