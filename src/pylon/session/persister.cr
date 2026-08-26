require "./store"

module Pylon::Session
  class Persister
    DEFAULT_INTERVAL = 5.seconds

    def initialize(@path : String, @build : Proc(State), @interval : Time::Span = DEFAULT_INTERVAL)
      @last = Time.instant - @interval
    end

    def maybe : Nil
      return if Time.instant - @last < @interval

      flush
    end

    def flush : Nil
      Store.save(@path, @build.call)
      @last = Time.instant
    end
  end
end
