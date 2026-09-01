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
      @before : Proc(Nil)? = nil,
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

      loop do
        select
        when @signals.receive?
          # another change landed inside the debounce window
        else
          break
        end
      end
    end

    private def cycle : Report | Fault
      @before.try(&.call)
      @session.cycle(Time.utc.to_unix_ns.to_i64)
    end
  end
end
