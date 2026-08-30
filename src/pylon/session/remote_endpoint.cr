require "../core/applier"
require "../wire/message"
require "./fault"

module Pylon::Session
  class RemoteEndpoint
    # the reader fiber must never block, or it stops draining the socket
    # while the server is mid-push, which deadlocks both ends
    RESPONSE_BUFFER = 8

    getter exchanges = 0

    @fault : Fault? = nil
    @tree : Core::Entry? = nil

    def initialize(@input : IO, @output : IO, @signals : Channel(Nil)? = nil)
      @responses = Channel(Wire::Message).new(RESPONSE_BUFFER)
      @greeting = Channel(Nil).new
      @known = false
      @sequence = 0_u32

      spawn { listen }
    end

    def scan(now_ns : Int64) : Scan::Snapshot | Fault
      return Scan::Snapshot.new(@tree, Scan::Cache.new) if @known

      reply = exchange(Wire::ScanRequest.new(now_ns))
      return reply if reply.is_a?(Fault)
      return unexpected("a scan response", reply) unless reply.is_a?(Wire::ScanResponse)

      @tree = reply.root

      Scan::Snapshot.new(reply.root, Scan::Cache.new)
    end

    def content_source(digests : Array(Bytes), budget : UInt64) : Wire::ContentSource | Fault
      return Wire::ContentSource::Materialised.new(Wire::Contents.new) if digests.empty?

      reply = exchange(Wire::ContentsRequest.new(digests, budget))
      return reply if reply.is_a?(Fault)
      return unexpected("a contents response", reply) unless reply.is_a?(Wire::ContentsResponse)

      Wire::ContentSource::Materialised.new(reply.contents)
    end

    def payload_size(changes : Array(Core::Change)) : UInt64?
      nil
    end

    def write_begin(changes : Array(Core::Change), source : Wire::ContentSource) : Nil
      transmit(Wire::WriteRequest.new(changes, source))
    end

    def write_await : Array(Write::Outcome) | Fault
      reply = await
      return reply if reply.is_a?(Fault)
      return unexpected("a write response", reply) unless reply.is_a?(Wire::WriteResponse)

      @tree = Core::Applier.apply(@tree, Write::Outcome.changes(reply.outcomes))
      reply.outcomes
    end

    private def unexpected(wanted : String, reply : Wire::Message) : Misbehaved
      Misbehaved.new("expected #{wanted}, got #{reply.class.name}")
    end

    private def listen : Nil
      case greeting = Wire.read_greeting(@input)
      in Wire::Compatible
        @greeting.close
      in Wire::Incompatible
        stop_with(Incompatible.new(
          "the remote pylon uses wire protocol version #{greeting.version} but this one uses #{Wire::PROTOCOL}. Update the remote binary",
        ))
        return
      in Wire::Foreign
        stop_with(Incompatible.new(
          "the remote did not identify itself as a pylon server. It may be an outdated pylon binary or the wrong command",
        ))
        return
      end

      loop do
        case message = Wire.read_message(@input)
        in Wire::Closed
          @fault ||= Stopped.new
          @responses.close
          return
        in Wire::Invalid
          @fault ||= Stopped.new(message.reason)
          @responses.close
          return
        in Wire::TreeUpdate
          @tree = message.root
          @sequence = message.sequence
          @known = true
          signal
        in Wire::TreeDelta
          if message.sequence == @sequence + 1
            @tree = Core::Applier.apply(@tree, message.changes)
            @sequence = message.sequence
          else
            @known = false
          end

          signal
        in Wire::Failure, Wire::ScanResponse, Wire::ContentsResponse, Wire::WriteResponse
          @responses.send(message)
        in Wire::ScanRequest, Wire::ContentsRequest, Wire::WriteRequest
          @fault ||= Misbehaved.new("the server sent a #{message.class.name}, which only clients send")
          @responses.close
          return
        end
      end
    end

    private def stop_with(fault : Fault) : Nil
      @fault = fault
      @responses.close
      @greeting.close
    end

    private def signal : Nil
      signals = @signals
      return if signals.nil?

      select
      when signals.send(nil)
      else
      end
    end

    private def exchange(request : Wire::Message) : Wire::Message | Fault
      if (fault = transmit(request))
        return fault
      end

      await
    end

    private def transmit(request : Wire::Message) : Fault?
      @greeting.receive?

      if (fault = @fault)
        return fault
      end

      @exchanges += 1
      request.write(@output)
      nil
    rescue error : IO::Error
      @fault ||= Stopped.new(error.message)
      @fault
    end

    private def await : Wire::Message | Fault
      reply = @responses.receive?
      return (@fault || Stopped.new) if reply.nil?
      return Misbehaved.new(reply.message) if reply.is_a?(Wire::Failure)

      reply
    end
  end
end
