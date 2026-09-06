module Pylon::Session
  # Scans run on their own thread so the blocking file reads never stall the request.
  class ScanThread
    include Fibers::Blocking

    record Request, endpoint : LocalEndpoint, now_ns : Int64, result : Channel(Core::Entry?)

    @@shared : ScanThread?

    def self.scan(endpoint : LocalEndpoint, now_ns : Int64) : Channel(Core::Entry?)
      shared.scan(endpoint, now_ns)
    end

    private def self.shared : ScanThread
      @@shared ||= new.tap { |thread| Fibers.isolated(:server_scan, thread) }
    end

    def initialize : Nil
      @requests = Channel(Request).new
    end

    def scan(endpoint : LocalEndpoint, now_ns : Int64) : Channel(Core::Entry?)
      result = Channel(Core::Entry?).new(1)
      @requests.send(Request.new(endpoint, now_ns, result))
      result
    end

    def run_blocking : Nil
      while (request = @requests.receive?)
        request.result.send(request.endpoint.scan(request.now_ns))
      end
    end
  end
end
