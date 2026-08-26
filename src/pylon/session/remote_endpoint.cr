require "../wire/message"

module Pylon::Session
  class RemoteEndpoint
    class ProtocolError < Exception
    end

    def initialize(@input : IO, @output : IO)
    end

    def scan(now_ns : Int64) : Scan::Snapshot
      reply = exchange(Wire::ScanRequest.new(now_ns))
      raise ProtocolError.new("expected a scan response") unless reply.is_a?(Wire::ScanResponse)

      Scan::Snapshot.new(reply.root, Scan::Cache.new)
    end

    def contents(digests : Array(Bytes)) : Wire::Contents
      return Wire::Contents.new if digests.empty?

      reply = exchange(Wire::ContentsRequest.new(digests))
      raise ProtocolError.new("expected a contents response") unless reply.is_a?(Wire::ContentsResponse)

      reply.contents
    end

    def write(changes : Array(Core::Change), contents : Wire::Contents) : Array(Write::Outcome)
      return [] of Write::Outcome if changes.empty?

      reply = exchange(Wire::WriteRequest.new(changes, contents))
      raise ProtocolError.new("expected a write response") unless reply.is_a?(Wire::WriteResponse)

      reply.outcomes
    end

    private def exchange(request : Wire::Message) : Wire::Message
      request.write(@output)
      reply = Wire.read_message(@input)

      raise ProtocolError.new(reply.message) if reply.is_a?(Wire::Failure)

      reply
    end
  end
end
