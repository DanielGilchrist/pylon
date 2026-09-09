module Pylon::Session
  class Runner(A, B, N)
    DEFAULT_DEBOUNCE     = 10.milliseconds
    DEFAULT_POLL         = 250.milliseconds
    DEFAULT_BURST_QUIET  = 300.milliseconds
    DEFAULT_SETTLE_LIMIT = 10.seconds
    DEFAULT_HEARTBEAT    = 30.seconds
    DEFAULT_DEADLINE     = 60.seconds
    BURST_PATHS          = 8

    def initialize(
      @session : Session(A, B, N),
      @dirty_paths : Watch::DirtyPaths,
      @debounce : Time::Span = DEFAULT_DEBOUNCE,
      @poll : Time::Span = DEFAULT_POLL,
      @burst_quiet : Time::Span = DEFAULT_BURST_QUIET,
      @settle_limit : Time::Span = DEFAULT_SETTLE_LIMIT,
      @heartbeat : Time::Span = DEFAULT_HEARTBEAT,
      @deadline : Time::Span = DEFAULT_DEADLINE,
    ) : Nil
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
        unless wait_for_work
          fault = @session.heartbeat(Time.instant, after: @heartbeat, deadline: @deadline)
          return fault if fault

          next
        end

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
      when @dirty_paths.signals.receive?
        true
      when timeout(@poll)
        false
      end
    end

    private def settle : Nil
      sleep(@debounce)
      clear_signals

      wait_out_burst if dirtied >= BURST_PATHS
    end

    private def wait_out_burst : Nil
      deadline = Time.instant + @settle_limit

      until @stopping || Time.instant >= deadline
        select
        when @dirty_paths.signals.receive?
          clear_signals
          dirtied
        when timeout(@burst_quiet)
          return
        end
      end
    end

    private def dirtied : Int32
      @session.local.mark_dirty(@dirty_paths.consume)
    end

    private def clear_signals : Nil
      loop do
        select
        when @dirty_paths.signals.receive?
        else
          return
        end
      end
    end

    private def cycle : Report | Fault
      @session.local.mark_dirty(@dirty_paths.consume)
      @session.cycle(Time.utc.to_unix_ns.to_i64)
    end
  end
end
