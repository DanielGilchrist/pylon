require "../checkpoint"

module Pylon::Session
  class Checkpoint::Schedule
    DEFAULT_INTERVAL = 5.seconds

    def initialize(
      @path : String,
      @build : Proc(Checkpoint),
      @on_problem : Proc(String, Nil)?,
      @interval : Time::Span = DEFAULT_INTERVAL,
    ) : Nil
      @last = Time.instant - @interval
      @complained = false
    end

    def save_if_due : Nil
      return if Time.instant - @last < @interval

      save
    end

    def save : Nil
      damaged = @build.call.save(@path)
      @last = Time.instant

      if damaged.nil?
        @complained = false
        return
      end

      return if @complained

      @complained = true
      @on_problem.try(&.call("the sync state at #{@path} was not saved (#{damaged.reason})"))
    end
  end
end
