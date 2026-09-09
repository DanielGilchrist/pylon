module Pylon::Session
  class RemoteEndpoint
    @fault : Fault? = nil
    @tree : Core::Entry? = nil
    @unapplied = Core::Changes.new

    def initialize(
      input : IO,
      @output : IO,
      @configure : Wire::Message::Configure,
      @signals : Channel(Nil)? = nil,
      *,
      resume : Core::Entry?,
    ) : Nil
      @tree = resume
      @inbound = Inbound.new
      @input = MeteredReader.new(input, @inbound)
      @scanned = Channel(Wire::Message::ScanResponse).new(1)
      @contents = Channel(Wire::Message::ContentsResponse).new(1)
      @checksums = Channel(Wire::Message::ChecksumsResponse).new(1)
      @reusable = Channel(Wire::Message::ReusableResponse).new(1)
      @written = Channel(Wire::Message::WriteResponse).new(Session::WRITE_WINDOW)
      @greeting = Channel(Nil).new
      @initial = Channel(Nil).new
      @live = false
      @sequence = 0_u32
      @last_heard = Time.instant
      @probed = nil

      Fibers.detach(:endpoint_listen) { listen }
    end

    getter exchanges = 0
    getter inbound : Inbound

    def scan(now_ns : Int64) : Core::Entry? | Fault
      return tree if @live
      return initial_tree unless @initial.closed?

      reply = exchange(Wire::Message::ScanRequest.new(now_ns), @scanned)
      return reply if reply.is_a?(Fault)

      @unapplied.clear
      @tree = reply.root
    end

    def remote? : Bool
      true
    end

    def request_checksums(bases : Wire::Bases) : Session::PendingChecksums
      fault = transmit(Wire::Message::ChecksumsRequest.new(bases))
      Awaiting(Wire::Message::ChecksumsResponse, Wire::Checksums::Map).new(self, @checksums, fault)
    end

    def holds?(digest : Bytes) : Bool
      false
    end

    def request_reusable(digests : Array(Bytes)) : Session::PendingReusable
      return Settled.new(Array(Bytes).new) if digests.empty?

      fault = transmit(Wire::Message::ReusableRequest.new(digests))
      Awaiting(Wire::Message::ReusableResponse, Array(Bytes)).new(self, @reusable, fault)
    end

    def request_content(
      digests : Array(Bytes),
      budget : UInt64,
      checksums : Wire::Checksums::Map,
      bases : Wire::Bases,
    ) : Session::PendingContents
      if digests.empty?
        return Settled(Wire::ContentSource).new(
          Wire::ContentSource::Materialised.new(Wire::Contents.new),
        )
      end

      fault = transmit(Wire::Message::ContentsRequest.new(digests, budget, checksums))
      Awaiting(Wire::Message::ContentsResponse, Wire::ContentSource).new(self, @contents, fault)
    end

    def size_of(path : String) : UInt64?
      nil
    end

    def total_size(changes : Core::Changes) : UInt64?
      nil
    end

    def request_write(
      changes : Core::Changes,
      source : Wire::ContentSource,
      relocations : Array(Core::Relocation),
    ) : Session::PendingOutcomes
      fault = transmit(Wire::Message::WriteRequest.new(changes, relocations, source))
      Awaiting(Wire::Message::WriteResponse, Array(Write::Outcome)).new(self, @written, fault)
    end

    def tree : Core::Entry?
      unless @unapplied.empty?
        @tree = Core::Applier.apply(@tree, @unapplied)
        @unapplied.clear
      end

      @tree
    end

    def heartbeat(now : Time::Instant, *, after : Time::Span, deadline : Time::Span) : Fault?
      if (fault = @fault)
        return fault
      end

      if (probed = @probed)
        return if now - probed < deadline

        stop_with(Disconnected.new)
        return @fault
      end

      return if now - @last_heard < after

      @probed = now
      transmit(Wire::Message::HeartbeatRequest.new)
    end

    protected def receive(channel : Channel(T)) : T | Fault forall T
      channel.receive? || @fault || Disconnected.new
    end

    private def initial_tree : Core::Entry? | Fault
      @initial.receive?

      if (fault = @fault)
        return fault
      end

      tree
    end

    private def listen : Nil
      case (greeting = Wire::Greeting.read(@input))
      in Nil
        if (problem = Wire::Message.write(@output, @configure))
          stop_with(Stopped.new("the configuration could not be sent: #{problem.reason}"))
          return
        end

        @greeting.close
      in Wire::Greeting::Incompatible
        stop_with(Incompatible.new(
          "the remote #{@configure.brand.name} uses wire protocol version #{greeting.version} " \
          "but this one uses #{Wire::PROTOCOL}. Update the remote binary",
        ))
        return
      in Wire::Greeting::Foreign
        stop_with(Incompatible.new(
          "the remote did not identify itself as #{@configure.brand.name}. It may be running an " \
          "outdated binary or the wrong command",
        ))
        return
      in Problem
        reason = "the connection failed before the remote identified itself: #{greeting.reason}"
        stop_with(Stopped.new(reason))
        return
      end

      loop do
        message = Wire::Message.read(@input)
        @last_heard = Time.instant

        case message
        in Wire::Closed
          stop_with(Disconnected.new)
          return
        in Problem
          stop_with(Disconnected.new(message.reason))
          return
        in Wire::Message::TreeUpdate
          @unapplied.clear
          @tree = message.root
          @sequence = message.sequence
          @live = message.live?
          @initial.close
        in Wire::Message::TreeChanges
          if @initial.closed?
            follow(message)
          else
            open_with(message)
          end
        in Wire::Message::ScanResponse
          return unless deliver(@scanned, message)
        in Wire::Message::ContentsResponse
          return unless deliver(@contents, message)
        in Wire::Message::ChecksumsResponse
          return unless deliver(@checksums, message)
        in Wire::Message::ReusableResponse
          return unless deliver(@reusable, message)
        in Wire::Message::WriteResponse
          message.payload.each do |outcome|
            @unapplied << Core::Change.new(outcome.path, nil, outcome.entry)
          end
          return unless deliver(@written, message)
        in Wire::Message::HeartbeatResponse
          @probed = nil
        in Wire::Message::ScanProgress
          @inbound.scanning(message.files, message.bytes)
        in Wire::Message::TreeAnnounce
          @inbound.announced(message.bytes)
        in Wire::Message::Failure
          stop_with(Misbehaved.new(message.message))
          return
        in Wire::Message::ScanRequest,
           Wire::Message::ContentsRequest,
           Wire::Message::ChecksumsRequest,
           Wire::Message::WriteRequest,
           Wire::Message::ReusableRequest,
           Wire::Message::HeartbeatRequest,
           Wire::Message::Configure
          stop_with(
            Misbehaved.new("the server sent a #{message.class.name}, which only clients send"),
          )
          return
        end
      end
    end

    private def open_with(message : Wire::Message::TreeChanges) : Nil
      @unapplied.clear
      @tree = Core::Applier.apply(@tree, message.changes)
      @sequence = message.sequence
      @live = message.live?
      @initial.close
    end

    private def follow(message : Wire::Message::TreeChanges) : Nil
      if message.sequence == @sequence + 1
        @tree = Core::Applier.apply(tree, message.changes)
        @sequence = message.sequence
      else
        @live = false
      end

      signal
    end

    private def deliver(channel : Channel(T), message : T) : Bool forall T
      select
      when channel.send(message)
        true
      else
        stop_with(
          Misbehaved.new("the server sent a #{message.class.name} that nothing was waiting for"),
        )
        false
      end
    end

    private def stop_with(fault : Fault) : Nil
      @fault ||= fault
      @scanned.close
      @contents.close
      @checksums.close
      @reusable.close
      @written.close
      @greeting.close
      @initial.close

      # The client would otherwise sit like nothing has happened until a trigger happens on its end
      signal
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
        return (@fault ||= Disconnected.new(problem.reason))
      end

      nil
    end
  end
end
