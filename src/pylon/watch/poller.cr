require "./client"

module Pylon::Watch
  class Poller
    getter clock : String

    def self.open(root : String, ignores : Array(String)) : Poller?
      socket = Client(UNIXSocket).socket_path
      return nil if socket.nil?

      client = Client(UNIXSocket).connect(socket)
      return nil unless client.is_a?(Client(UNIXSocket))

      return nil unless client.watch_project(root).is_a?(PDU::Response)

      reply = client.clock(root)
      return nil unless reply.is_a?(PDU::Response)

      clock = reply.body["clock"]?.try(&.as_s?)
      return nil if clock.nil?

      new(client, root, ignores, clock)
    end

    def initialize(@client : Client(UNIXSocket), @root : String, @ignores : Array(String), @clock : String)
    end

    def changed? : Bool
      reply = @client.since(@root, @clock, @ignores)
      return true unless reply.is_a?(PDU::Response)

      body = reply.body
      @clock = body["clock"]?.try(&.as_s?) || @clock

      return true if body["is_fresh_instance"]?.try(&.as_bool?) == true

      files = body["files"]?.try(&.as_a?)
      files.nil? || !files.empty?
    end

    def close : Nil
      @client.close
    rescue IO::Error
      nil
    end
  end
end
