require "./session"

module Pylon::Session
  class Runner(A, B)
    DEFAULT_DEBOUNCE     = 20.milliseconds
    DEFAULT_POLL         = 250.milliseconds
    DEFAULT_BURST_QUIET  = 300.milliseconds
    DEFAULT_SETTLE_LIMIT = 10.seconds
    BURST_PATHS          = 8

    def initialize(
      @session : Session(A, B),
      @signals : Channel(Nil),
      @debounce : Time::Span = DEFAULT_DEBOUNCE,
      @poll : Time::Span = DEFAULT_POLL,
      @burst_quiet : Time::Span = DEFAULT_BURST_QUIET,
      @settle_limit : Time::Span = DEFAULT_SETTLE_LIMIT,
      @before : Proc(Nil)? = nil,
      @gauge : Proc(Int32)? = nil,
    )
      @stopping = false
    end

    def stop : Nil
      @stopping = true
    end

    def run(&block : Report, Time::Span ->) : Fault?
      started = Time.instant
      report = cycle
      return report if report.is_a?(Fault)

      block.call(report, Time.instant - started)

      until @stopping
        next unless wait_for_work

        {% if flag?(:timing) %}
          woke = Time.instant
        {% end %}

        settle

        {% if flag?(:timing) %}
          settled = Time.instant
        {% end %}

        started = Time.instant
        report = cycle
        return report if report.is_a?(Fault)

        {% if flag?(:timing) %}
          STDERR.puts("settle=%.1fms cycle=%.1fms" % [
            (settled - woke).total_milliseconds,
            (Time.instant - settled).total_milliseconds,
          ])
        {% end %}

        block.call(report, Time.instant - started)
      end

      nil
    end

    private def wait_for_work : Bool
      select
      when @signals.receive?
        true
      when timeout(@poll)
        false
      end
    end

    private def settle : Nil
      sleep(@debounce)
      drain

      wait_out_burst if dirtied >= BURST_PATHS
    end

    private def wait_out_burst : Nil
      deadline = Time.instant + @settle_limit

      until @stopping || Time.instant >= deadline
        select
        when @signals.receive?
          drain
          dirtied
        when timeout(@burst_quiet)
          return
        end
      end
    end

    private def dirtied : Int32
      gauge = @gauge
      return 0 if gauge.nil?

      gauge.call
    end

    private def drain : Nil
      loop do
        select
        when @signals.receive?
        else
          return
        end
      end
    end

    private def cycle : Report | Fault
      @before.try(&.call)
      @session.cycle(Time.utc.to_unix_ns.to_i64)
    end
  end
end
