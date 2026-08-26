require "../watch/client"
require "./session"

module Pylon::Session
  class Runner(A, B)
    DEFAULT_DEBOUNCE = 20.milliseconds
    DEFAULT_POLL     = 250.milliseconds

    def initialize(
      @session : Session(A, B),
      @signals : Channel(Nil),
      @debounce : Time::Span = DEFAULT_DEBOUNCE,
      @poll : Time::Span = DEFAULT_POLL,
      @remote_poll : Proc(Bool)? = nil,
    )
      @stopping = false
    end

    def stop : Nil
      @stopping = true
    end

    def run(&block : Report ->) : Nil
      block.call(cycle)

      until @stopping
        next unless wait_for_work

        settle
        block.call(cycle)
      end
    end

    private def wait_for_work : Bool
      select
      when @signals.receive?
        true
      when timeout(@poll)
        remote_changed?
      end
    end

    private def settle : Nil
      sleep(@debounce)

      loop do
        select
        when @signals.receive?
          # another change landed inside the debounce window
        else
          break
        end
      end
    end

    private def remote_changed? : Bool
      poll = @remote_poll
      return false if poll.nil?

      poll.call
    end

    private def cycle : Report
      @session.cycle(Time.utc.to_unix_ns.to_i64)
    end
  end
end
