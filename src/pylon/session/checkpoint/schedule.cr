require "../checkpoint"

module Pylon::Session
  class Checkpoint::Schedule
    DEFAULT_INTERVAL = 5.seconds

    def initialize(@path : String, @interval : Time::Span = DEFAULT_INTERVAL) : Nil
      @last = Time.instant - @interval
      @complained = false
    end

    def save_if_due(checkpoint : Checkpoint) : Problem?
      return if Time.instant - @last < @interval

      save(checkpoint)
    end

    def save(checkpoint : Checkpoint) : Problem?
      failed = checkpoint.save(@path)
      @last = Time.instant

      if failed.nil?
        @complained = false
        return
      end

      return if @complained

      @complained = true
      Problem.new("the sync state at #{@path} was not saved (#{failed.reason})")
    end
  end
end
