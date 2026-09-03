require "../fibers"
require "../problem"

module Pylon::Session
  # stdlibs `Process` and its APIs report failures by throwing exceptions. We want to
  # avoid exceptions as they can leave the application in undeseriable states but also
  # make potential failures invisible to the type system. Here we effectively wrap `Process`
  # to explicitly handle the exceptions as they happen and convert them into values. This allows
  # us to encode the potential failures into the return type and force callers to handle them as
  # needed.
  class ProcessTransport
    def self.open(command : String, arguments : Array(String)) : ProcessTransport | Problem
      case (process = start(command, arguments, Process::Redirect::Inherit))
      in Problem then process
      in Process then new(process)
      end
    end

    def self.open(command : String, arguments : Array(String), &relay : String ->) : ProcessTransport | Problem
      case (process = start(command, arguments, Process::Redirect::Pipe))
      in Problem
        process
      in Process
        errors = process.error

        Fibers.detach(:stderr_relay) do
          while (line = errors.gets)
            relay.call(line)
          end
        end

        new(process)
      end
    end

    private def self.start(command : String, arguments : Array(String), error : Process::Redirect) : Process | Problem
      Process.new(
        command,
        arguments,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: error,
      )
    rescue error : IO::Error
      Problem.new("#{command} could not be started: #{error.message || error.class.name}")
    end

    private def initialize(@process : Process) : Nil
      @reader = @process.output
      @writer = @process.input
    end

    getter reader : IO
    getter writer : IO

    def close : Process::Status
      release_writer
      @process.wait
    end

    private def release_writer : Nil
      @writer.close unless @writer.closed?
    rescue IO::Error
    end
  end
end
