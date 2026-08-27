require "../checkpoint"

module Pylon::Session
  class Checkpoint::Schedule
    DEFAULT_INTERVAL = 5.seconds

    def initialize(@path : String, @build : Proc(Checkpoint), @interval : Time::Span = DEFAULT_INTERVAL)
      @last = Time.instant - @interval
    end

    def save_if_due : Nil
      return if Time.instant - @last < @interval

      save
    end

    def save : Nil
      @build.call.save(@path)
      @last = Time.instant
    end
  end
end
