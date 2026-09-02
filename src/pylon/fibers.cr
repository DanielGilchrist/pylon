require "wait_group"

module Pylon
  # Crystal swallows an exception left unhandled in a fiber and any waiter continues on
  # partial data. Every fiber should be spawned through here, which re-raises the exception in
  # the waiter or, with no waiter, ends the process.
  module Fibers
    extend self

    enum Name
      Spinner
      EndpointListen
      ServerRequests
      ServerAnnounce
      StderrRelay
      Write
      ScanDigest
      Inotify
      FSEvents
    end

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

    def detach(name : Name, &block : ->) : Nil
      spawn(name: name.to_s) { exit_on_exception(block) }
    end

    def isolated(name : Name, &block : ->) : Fiber::ExecutionContext::Isolated
      Fiber::ExecutionContext::Isolated.new(name.to_s) { exit_on_exception(block) }
    end

    @@parallel_contexts = Hash(Name, Fiber::ExecutionContext::Parallel).new

    def parallel(name : Name, workers : Int32, &block : Int32 ->) : Nil
      context = parallel_context(name, workers)
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

    private def parallel_context(name : Name, workers : Int32) : Fiber::ExecutionContext::Parallel
      context = @@parallel_contexts[name]?

      if context.nil?
        context = Fiber::ExecutionContext::Parallel.new(name.to_s, workers)
        @@parallel_contexts[name] = context
      elsif context.capacity < workers
        context.resize(workers)
      end

      context
    end

    private def launch(
      context : Fiber::ExecutionContext::Parallel,
      waiting : WaitGroup,
      worker : Int32,
      failures : Channel(Exception),
      block : Int32 ->,
    ) : Nil
      context.spawn do
        outcome = contain { block.call(worker) }
        failures.send(outcome) if outcome.is_a?(Exception)
      ensure
        waiting.done
      end
    end

    # If an unexpected exception occurs the fiber would print to stderr but the program
    # wouldn't stop. This catches the exception and force stops the program so we don't
    # continue running with partial state.
    private def exit_on_exception(block : ->) : Nil
      outcome = contain { block.call }

      return unless outcome.is_a?(Exception)
      outcome.inspect_with_backtrace(STDERR)
      exit 1
    end

    private def contain(& : -> T) : T | Exception forall T
      yield
    rescue error
      error
    end
  end
end
