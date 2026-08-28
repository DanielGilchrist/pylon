require "../core/applier"
require "../wire/message"

module Pylon::Session
  class RemoteEndpoint
    class ProtocolError < Exception
    end

    # the reader fiber must never block, or it stops draining the socket
    # while the server is mid-push, which deadlocks both ends
    RESPONSE_BUFFER = 8

    getter exchanges = 0

    def initialize(@input : IO, @output : IO, @signals : Channel(Nil)? = nil)
      @responses = Channel(Wire::Message).new(RESPONSE_BUFFER)
      @failure = nil.as(Exception?)
      @tree = nil.as(Core::Entry?)
      @known = false
      @sequence = 0_u32

      spawn { listen }
    end

    def scan(now_ns : Int64) : Scan::Snapshot
      return Scan::Snapshot.new(@tree, Scan::Cache.new) if @known

      reply = exchange(Wire::ScanRequest.new(now_ns))
      raise ProtocolError.new("expected a scan response") unless reply.is_a?(Wire::ScanResponse)

      @tree = reply.root

      Scan::Snapshot.new(reply.root, Scan::Cache.new)
    end

    def changed? : Bool
      reply = exchange(Wire::PollRequest.new)
      raise ProtocolError.new("expected a poll response") unless reply.is_a?(Wire::PollResponse)

      reply.changed?
    end

    def content_source(digests : Array(Bytes), budget : UInt64) : Wire::ContentSource
      return Wire::ContentSource::Materialised.new(Wire::Contents.new) if digests.empty?

      reply = exchange(Wire::ContentsRequest.new(digests, budget))
      raise ProtocolError.new("expected a contents response") unless reply.is_a?(Wire::ContentsResponse)

      Wire::ContentSource::Materialised.new(reply.contents)
    end

    def payload_size(changes : Array(Core::Change)) : UInt64?
      nil
    end

    def write_begin(changes : Array(Core::Change), source : Wire::ContentSource) : Nil
      transmit(Wire::WriteRequest.new(changes, source))
    end

    def write_await : Array(Write::Outcome)
      reply = await
      raise ProtocolError.new("expected a write response") unless reply.is_a?(Wire::WriteResponse)

      @tree = Core::Applier.apply(@tree, Write::Outcome.changes(reply.outcomes))
      reply.outcomes
    end

    private def listen : Nil
      loop do
        message = Wire.read_message(@input)

        if message.is_a?(Wire::TreeUpdate)
          @tree = message.root
          @sequence = message.sequence
          @known = true
          signal
          next
        end

        if message.is_a?(Wire::TreeDelta)
          if message.sequence == @sequence + 1
            @tree = Core::Applier.apply(@tree, message.changes)
            @sequence = message.sequence
          else
            @known = false
          end

          signal
          next
        end

        @responses.send(message)
      end
    rescue error : Wire::Truncated | IO::Error
      @failure = error
      @responses.close
    end

    private def signal : Nil
      signals = @signals
      return if signals.nil?

      select
      when signals.send(nil)
      else
      end
    end

    private def exchange(request : Wire::Message) : Wire::Message
      transmit(request)
      await
    end

    private def transmit(request : Wire::Message) : Nil
      @exchanges += 1
      request.write(@output)
    rescue error : IO::Error
      @failure ||= error
      raise Wire::Truncated.new("the remote stopped responding")
    end

    private def await : Wire::Message
      reply = @responses.receive?
      raise(@failure || Wire::Truncated.new("the remote stopped responding")) if reply.nil?
      raise ProtocolError.new(reply.message) if reply.is_a?(Wire::Failure)

      reply
    end
  end
end
