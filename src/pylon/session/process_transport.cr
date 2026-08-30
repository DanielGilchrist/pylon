module Pylon::Session
  class ProcessTransport
    getter reader : IO
    getter writer : IO

    def self.open(command : String, arguments : Array(String)) : ProcessTransport
      new(start(command, arguments, Process::Redirect::Inherit))
    end

    def self.open(command : String, arguments : Array(String), &relay : String ->) : ProcessTransport
      process = start(command, arguments, Process::Redirect::Pipe)
      errors = process.error

      spawn do
        while (line = errors.gets)
          relay.call(line)
        end
      end

      new(process)
    end

    private def self.start(command : String, arguments : Array(String), error : Process::Redirect) : Process
      Process.new(
        command,
        arguments,
        input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe,
        error: error,
      )
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
  end
end
