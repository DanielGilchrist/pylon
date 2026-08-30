require "wait_group"

module Pylon
  module Fibers
    def self.future(&block : -> T) : Channel(T | Exception) forall T
      results = Channel(T | Exception).new(1)

      spawn do
        outcome = begin
          block.call
        rescue error
          error
        end

        results.send(outcome)
      end

      results
    end

    def self.await(results : Channel(T | Exception)) : T forall T
      outcome = results.receive
      raise outcome if outcome.is_a?(Exception)

      outcome
    end

    def self.parallel(name : String, workers : Int32, &block : Int32 ->) : Nil
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

    private def self.launch(
      context : Fiber::ExecutionContext::Parallel,
      waiting : WaitGroup,
      worker : Int32,
      failures : Channel(Exception),
      block : Int32 ->,
    ) : Nil
      context.spawn do
        begin
          block.call(worker)
        rescue error
          failures.send(error)
        ensure
          waiting.done
        end
      end
    end
  end
end
