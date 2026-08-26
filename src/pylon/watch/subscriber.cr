require "./client"

module Pylon::Watch
  class Subscriber
    getter signals : Channel(Nil)

    def self.open(
      root : String,
      ignores : Array(String),
      signals : Channel(Nil) = Channel(Nil).new(1),
      name : String = "pylon",
    ) : Subscriber?
      socket = Client(UNIXSocket).socket_path
      return nil if socket.nil?

      client = Client(UNIXSocket).connect(socket)
      return nil unless client.is_a?(Client(UNIXSocket))
      return nil unless client.watch_project(root).is_a?(PDU::Response)
      return nil unless client.subscribe(root, name, ignores).is_a?(PDU::Response)

      new(client, signals)
    end

    def initialize(@client : Client(UNIXSocket), @signals : Channel(Nil) = Channel(Nil).new(1))
      @stopping = false
      @first = true

      spawn { listen }
    end

    def close : Nil
      @stopping = true
      @client.close
    rescue IO::Error
      nil
    end

    private def listen : Nil
      until @stopping
        pdu = @client.read

        case pdu
        in PDU::Snapshot
          signal unless first_snapshot?
        in PDU::Delta
          signal
        in PDU::Failure
          break
        in PDU::Response
          next
        end
      end
    rescue IO::Error
      nil
    end

    private def first_snapshot? : Bool
      return false unless @first

      @first = false
      true
    end

    private def signal : Nil
      select
      when @signals.send(nil)
      else
      end
    end
  end
end
