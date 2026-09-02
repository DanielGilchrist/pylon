require "../core/applier"
require "../fibers"
require "../wire/message"
require "./fault"
require "./pending_write"
require "./remote_endpoint/pending_signatures"

module Pylon::Session
  class RemoteEndpoint
    # the reader fiber must never block, or it stops draining the socket
    # while the server is mid-push, which deadlocks both ends
    RESPONSE_BUFFER = 8

    getter exchanges = 0

    @fault : Fault? = nil
    @tree : Core::Entry? = nil
    @unapplied = Core::Changes.new

    def initialize(@input : IO, @output : IO, @signals : Channel(Nil)? = nil)
      @responses = Channel(Wire::Message::Any).new(RESPONSE_BUFFER)
      @greeting = Channel(Nil).new
      @known = false
      @sequence = 0_u32

      Fibers.detach(:endpoint_listen) { listen }
    end

    def scan(now_ns : Int64) : Scan::Snapshot | Fault
      return Scan::Snapshot.new(settled_tree, Scan::Cache.new) if @known

      reply = exchange(Wire::Message::ScanRequest.new(now_ns))
      return reply if reply.is_a?(Fault)
      return unexpected("a scan response", reply) unless reply.is_a?(Wire::Message::ScanResponse)

      @unapplied.clear
      @tree = reply.root

      Scan::Snapshot.new(reply.root, Scan::Cache.new)
    end

    def delta_capable? : Bool
      true
    end

    def signatures_begin(pairs : Array(Wire::Message::SignaturesRequest::Pair)) : PendingSignatures
      PendingSignatures.new(self, transmit(Wire::Message::SignaturesRequest.new(pairs)))
    end

    def content_source(digests : Array(Bytes), budget : UInt64, signatures : Wire::Delta::Signatures = Wire::Delta::Signatures.new) : Wire::ContentSource | Fault
      return Wire::ContentSource::Materialised.new(Wire::Contents.new) if digests.empty?

      reply = exchange(Wire::Message::ContentsRequest.new(digests, budget, signatures))
      return reply if reply.is_a?(Fault)
      return unexpected("a contents response", reply) unless reply.is_a?(Wire::Message::ContentsResponse)

      Wire::ContentSource::Materialised.new(reply.contents)
    end

    def known_size(path : String) : UInt64?
      nil
    end

    def payload_size(changes : Core::Changes) : UInt64?
      nil
    end

    def write_begin(changes : Core::Changes, source : Wire::ContentSource) : PendingWrite
      transmit(Wire::Message::WriteRequest.new(changes, source))
      PendingWrite.new(Proc(Array(Write::Outcome) | Fault).new { receive_written })
    end

    protected def receive_signatures : Wire::Delta::Signatures | Fault
      reply = await
      return reply if reply.is_a?(Fault)
      return unexpected("a signatures response", reply) unless reply.is_a?(Wire::Message::SignaturesResponse)

      reply.signatures
    end

    private def receive_written : Array(Write::Outcome) | Fault
      reply = await
      return reply if reply.is_a?(Fault)
      return unexpected("a write response", reply) unless reply.is_a?(Wire::Message::WriteResponse)

      reply.outcomes.each { |outcome| @unapplied << Core::Change.new(outcome.path, nil, outcome.entry) }
      reply.outcomes
    end

    private def settled_tree : Core::Entry?
      unless @unapplied.empty?
        @tree = Core::Applier.apply(@tree, @unapplied)
        @unapplied.clear
      end

      @tree
    end

    private def unexpected(wanted : String, reply : Wire::Message::Any) : Misbehaved
      Misbehaved.new("expected #{wanted}, got #{reply.class.name}")
    end

    private def listen : Nil
      case greeting = Wire::Greeting.read(@input)
      in Wire::Greeting::Compatible
        @greeting.close
      in Wire::Greeting::Incompatible
        stop_with(Incompatible.new(
          "the remote pylon uses wire protocol version #{greeting.version} but this one uses #{Wire::PROTOCOL}. Update the remote binary",
        ))
        return
      in Wire::Greeting::Foreign
        stop_with(Incompatible.new(
          "the remote did not identify itself as a pylon server. It may be an outdated pylon binary or the wrong command",
        ))
        return
      in Wire::Greeting::Unreachable
        stop_with(Stopped.new("the connection failed before the remote identified itself: #{greeting.reason}"))
        return
      end

      loop do
        case message = Wire::Message.read(@input)
        in Wire::Closed
          @fault ||= Stopped.new
          @responses.close
          return
        in Wire::Invalid
          @fault ||= Stopped.new(message.reason)
          @responses.close
          return
        in Wire::Message::TreeUpdate
          @unapplied.clear
          @tree = message.root
          @sequence = message.sequence
          @known = true
          signal
        in Wire::Message::TreeDelta
          if message.sequence == @sequence + 1
            @tree = Core::Applier.apply(settled_tree, message.changes)
            @sequence = message.sequence
          else
            @known = false
          end

          signal
        in Wire::Message::Failure, Wire::Message::ScanResponse, Wire::Message::ContentsResponse, Wire::Message::SignaturesResponse, Wire::Message::WriteResponse
          @responses.send(message)
        in Wire::Message::ScanRequest, Wire::Message::ContentsRequest, Wire::Message::SignaturesRequest, Wire::Message::WriteRequest
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

    private def exchange(request : Wire::Message::Any) : Wire::Message::Any | Fault
      if (fault = transmit(request))
        return fault
      end

      await
    end

    private def transmit(request : Wire::Message::Any) : Fault?
      @greeting.receive?

      if (fault = @fault)
        return fault
      end

      @exchanges += 1

      if (problem = Wire::Message.write(@output, request))
        return (@fault ||= Stopped.new(problem.reason))
      end

      nil
    end

    private def await : Wire::Message::Any | Fault
      reply = @responses.receive?
      return (@fault || Stopped.new) if reply.nil?
      return Misbehaved.new(reply.message) if reply.is_a?(Wire::Message::Failure)

      reply
    end
  end
end
