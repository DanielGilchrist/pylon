module Pylon::Session
  class ProcessTransport
    getter reader : IO
    getter writer : IO

    def self.open(command : String, arguments : Array(String)) : ProcessTransport
      process = Process.new(
        command,
        arguments,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: Process::Redirect::Inherit,
      )

      new(process)
    end

    def initialize(@process : Process)
      @reader = @process.output
      @writer = @process.input
    end

    def close : Process::Status
      @writer.close unless @writer.closed?
      @process.wait
    rescue IO::Error
      @process.wait
    end

    def terminate : Nil
      @process.terminate unless @process.terminated?
    rescue RuntimeError
      nil
    end
  end
end
