require "wait_group"

module Pylon
  # Crystal swallows an exception left unhandled in a fiber: the fiber prints to stderr and
  # dies, the program keeps running, and any waiter proceeds as if the work completed, with
  # partial and potentially corrupt data. Every raise in this codebase is an assertion (a bug),
  # so it must halt the whole program, not one fiber. Here we effectively wrap fiber spawning
  # to explicitly capture the exception as it happens and convert it into a value inside the
  # worker, then the waiters (`await`, `parallel`) re-raise it on their own fiber to restore
  # the crash. Those re-raises are never rescued; they end the process. Always spawn worker
  # fibers through this module, never hand-roll the capture.
  module Fibers
    extend self

    def future(&block : -> T) : Channel(T | Exception) forall T
      results = Channel(T | Exception).new(1)

      spawn do
        results.send(contain { block.call })
      end

      results
    end

    def await(results : Channel(T | Exception)) : T forall T
      outcome = results.receive
      raise outcome if outcome.is_a?(Exception)

      outcome
    end

    def parallel(name : String, workers : Int32, &block : Int32 ->) : Nil
      context = Fiber::ExecutionContext::Parallel.new(name, workers)
      waiting = WaitGroup.new(workers)
      failures = Channel(Exception).new(workers)

      workers.times do |worker|
        launch(context, waiting, worker, failures, block)
      end

      waiting.wait

      select
      when error = failures.receive
        raise error
      else
      end
    end

    private def launch(
      context : Fiber::ExecutionContext::Parallel,
      waiting : WaitGroup,
      worker : Int32,
      failures : Channel(Exception),
      block : Int32 ->,
    ) : Nil
      context.spawn do
        begin
          outcome = contain { block.call(worker) }
          failures.send(outcome) if outcome.is_a?(Exception)
        ensure
          waiting.done
        end
      end
    end

    private def contain(& : -> T) : T | Exception forall T
      yield
    rescue error
      error
    end
  end
end
