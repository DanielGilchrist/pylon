require "../core/applier"
require "../fibers"
require "../wire/message"
require "./fault"
require "./pending_write"
require "./session"
require "./settled_contents"
require "./remote_endpoint/pending_contents"
require "./remote_endpoint/pending_signatures"

module Pylon::Session
  class RemoteEndpoint
    @fault : Fault? = nil
    @tree : Core::Entry? = nil
    @unapplied = Core::Changes.new

    def initialize(@input : IO, @output : IO, @configure : Wire::Message::Configure, @signals : Channel(Nil)? = nil) : Nil
      @scanned = Channel(Wire::Message::ScanResponse).new(1)
      @contents = Channel(Wire::Message::ContentsResponse).new(1)
      @signatures = Channel(Wire::Message::SignaturesResponse).new(1)
      @written = Channel(Wire::Message::WriteResponse).new(Session::WRITE_WINDOW)
      @greeting = Channel(Nil).new
      @initial = Channel(Nil).new
      @known = false
      @sequence = 0_u32

      Fibers.detach(:endpoint_listen) { listen }
    end

    getter exchanges = 0

    def scan(now_ns : Int64) : Core::Entry? | Fault
      return settled_tree if @known
      return initial_tree if @configure.watch? && !@initial.closed?

      reply = exchange(Wire::Message::ScanRequest.new(now_ns), @scanned)
      return reply if reply.is_a?(Fault)

      @unapplied.clear
      @tree = reply.root
    end

    def delta_capable? : Bool
      true
    end

    def signatures_begin(pairs : Array(Wire::Message::SignaturesRequest::Pair)) : PendingSignatures
      PendingSignatures.new(self, transmit(Wire::Message::SignaturesRequest.new(pairs)))
    end

    def content_begin(digests : Array(Bytes), budget : UInt64, signatures : Wire::Delta::Signatures) : PendingContents | SettledContents
      return SettledContents.new(Wire::ContentSource::Materialised.new(Wire::Contents.new)) if digests.empty?

      PendingContents.new(self, transmit(Wire::Message::ContentsRequest.new(digests, budget, signatures)))
    end

    def known_size(path : String) : UInt64?
      nil
    end

    def payload_size(changes : Core::Changes) : UInt64?
      nil
    end

    def write_begin(changes : Core::Changes, source : Wire::ContentSource, relocations : Array(Core::Relocation)) : PendingWrite
      transmit(Wire::Message::WriteRequest.new(changes, relocations, source))
      PendingWrite.new(Proc(Array(Write::Outcome) | Fault).new { receive_written })
    end

    protected def receive_contents : Wire::ContentSource | Fault
      reply = receive(@contents)
      return reply if reply.is_a?(Fault)

      Wire::ContentSource::Materialised.new(reply.contents)
    end

    protected def receive_signatures : Wire::Delta::Signatures | Fault
      reply = receive(@signatures)
      return reply if reply.is_a?(Fault)

      reply.signatures
    end

    private def receive_written : Array(Write::Outcome) | Fault
      reply = receive(@written)
      return reply if reply.is_a?(Fault)

      reply.outcomes.each { |outcome| @unapplied << Core::Change.new(outcome.path, nil, outcome.entry) }
      reply.outcomes
    end

    private def initial_tree : Core::Entry? | Fault
      @initial.receive?

      if (fault = @fault)
        return fault
      end

      settled_tree
    end

    private def settled_tree : Core::Entry?
      unless @unapplied.empty?
        @tree = Core::Applier.apply(@tree, @unapplied)
        @unapplied.clear
      end

      @tree
    end

    private def listen : Nil
      case (greeting = Wire::Greeting.read(@input))
      in Wire::Greeting::Compatible
        if (problem = Wire::Message.write(@output, @configure))
          stop_with(Stopped.new("the configuration could not be sent: #{problem.reason}"))
          return
        end

        @greeting.close
      in Wire::Greeting::Incompatible
        stop_with(Incompatible.new(
          "the remote #{@configure.brand.name} uses wire protocol version #{greeting.version} but this one uses #{Wire::PROTOCOL}. Update the remote binary",
        ))
        return
      in Wire::Greeting::Foreign
        stop_with(Incompatible.new(
          "the remote did not identify itself as #{@configure.brand.name}. It may be running an outdated binary or the wrong command",
        ))
        return
      in Wire::Greeting::Unreachable
        stop_with(Stopped.new("the connection failed before the remote identified itself: #{greeting.reason}"))
        return
      end

      loop do
        case (message = Wire::Message.read(@input))
        in Wire::Closed
          stop_with(Stopped.new)
          return
        in Wire::Invalid
          stop_with(Stopped.new(message.reason))
          return
        in Wire::Message::TreeUpdate
          @unapplied.clear
          @tree = message.root
          @sequence = message.sequence
          @known = message.live?
          @initial.close
        in Wire::Message::TreeDelta
          if message.sequence == @sequence + 1
            @tree = Core::Applier.apply(settled_tree, message.changes)
            @sequence = message.sequence
          else
            @known = false
          end

          signal
        in Wire::Message::ScanResponse
          return unless deliver(@scanned, message)
        in Wire::Message::ContentsResponse
          return unless deliver(@contents, message)
        in Wire::Message::SignaturesResponse
          return unless deliver(@signatures, message)
        in Wire::Message::WriteResponse
          return unless deliver(@written, message)
        in Wire::Message::Failure
          stop_with(Misbehaved.new(message.message))
          return
        in Wire::Message::ScanRequest,
           Wire::Message::ContentsRequest,
           Wire::Message::SignaturesRequest,
           Wire::Message::WriteRequest,
           Wire::Message::Configure
          stop_with(Misbehaved.new("the server sent a #{message.class.name}, which only clients send"))
          return
        end
      end
    end

    private def deliver(channel : Channel(T), message : T) : Bool forall T
      select
      when channel.send(message)
        true
      else
        stop_with(Misbehaved.new("the server sent a #{message.class.name} that nothing was waiting for"))
        false
      end
    end

    private def stop_with(fault : Fault) : Nil
      @fault ||= fault
      @scanned.close
      @contents.close
      @signatures.close
      @written.close
      @greeting.close
      @initial.close
    end

    private def signal : Nil
      signals = @signals
      return if signals.nil?

      select
      when signals.send(nil)
      else
      end
    end

    private def exchange(request : Wire::Message::Any, replies : Channel(T)) : T | Fault forall T
      if (fault = transmit(request))
        return fault
      end

      receive(replies)
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

    private def receive(channel : Channel(T)) : T | Fault forall T
      channel.receive? || @fault || Stopped.new
    end
  end
end
