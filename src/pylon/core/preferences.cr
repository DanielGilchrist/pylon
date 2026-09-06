module Pylon::Core
  struct Preferences
    FALLBACK = "."

    alias Rule = GlobRule | FallbackRule

    record GlobRule, replica : Replica, pattern : Filesystem::Pattern
    record FallbackRule, replica : Replica

    def self.build(local : Array(String), remote : Array(String)) : Preferences | Problem
      rules = Array(Rule).new

      collect(rules, :local, local) || collect(rules, :remote, remote) || new(rules)
    end

    private def self.collect(
      rules : Array(Rule),
      replica : Replica,
      texts : Array(String),
    ) : Problem?
      texts.each do |text|
        if text == FALLBACK
          rules << FallbackRule.new(replica)
          next
        end

        pattern = Filesystem::Pattern.parse(text)
        if pattern.is_a?(Problem)
          return Problem.new("#{text.inspect} is not a valid glob: #{pattern.reason}")
        end

        rules << GlobRule.new(replica, pattern)
      end

      nil
    end

    @explicit : Array(GlobRule)
    @fallback : Replica?

    def initialize(rules : Array(Rule)) : Nil
      @explicit = Array(GlobRule).new
      fallbacks = Array(FallbackRule).new

      rules.each do |rule|
        case rule
        in GlobRule     then @explicit << rule
        in FallbackRule then fallbacks << rule
        end
      end

      @fallback =
        if fallbacks.empty?
          nil
        elsif fallbacks.any?(&.replica.local?)
          Replica::Local
        else
          Replica::Remote
        end
    end

    def winner(path : String) : Replica?
      preferred : Replica? = nil

      @explicit.each do |rule|
        next unless rule.pattern.matches?(path)
        return Replica::Local if rule.replica.local?

        preferred = Replica::Remote
      end

      preferred || @fallback
    end
  end
end
