require "../../spec_helper"

require "socket"
require "../../support/remote_end"

private alias Message = Pylon::Wire::Message
private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint

private def configured_endpoint(root : String, client : IO, server : IO) : RemoteEndpoint
  Pylon::Wire::Greeting.write(server)
  endpoint = RemoteEndpoint.new(client, client, remote_configuration(root), resume: nil)
  Message.read(server).should be_a(Message::Configure)
  endpoint
end

describe "heartbeats" do
  it "sends one when the link has been quiet for longer than the interval" do
    Sandbox.open do |root|
      client, server = UNIXSocket.pair
      endpoint = configured_endpoint(root.root, client, server)

      begin
        endpoint.heartbeat(Time.instant, after: 0.seconds, deadline: 1.hour).should be_nil

        Message.read(server).should be_a(Message::HeartbeatRequest)
      ensure
        client.close
        server.close
      end
    end
  end

  it "stays quiet while the link is busy" do
    Sandbox.open do |root|
      client, server = UNIXSocket.pair
      endpoint = configured_endpoint(root.root, client, server)

      begin
        exchanges = endpoint.exchanges

        endpoint.heartbeat(Time.instant, after: 1.hour, deadline: 2.hours).should be_nil

        endpoint.exchanges.should eq(exchanges)
      ensure
        client.close
        server.close
      end
    end
  end

  it "gives up on a remote that never answers" do
    Sandbox.open do |root|
      client, server = UNIXSocket.pair
      endpoint = configured_endpoint(root.root, client, server)

      begin
        sent = Time.instant
        endpoint.heartbeat(sent, after: 0.seconds, deadline: 30.seconds).should be_nil
        Message.read(server).should be_a(Message::HeartbeatRequest)

        fault = endpoint.heartbeat(sent + 31.seconds, after: 0.seconds, deadline: 30.seconds)

        fault.should be_a(Pylon::Session::Disconnected)

        if fault.is_a?(Pylon::Session::Fault)
          fault.explain.should eq("the remote server disconnected")
        end
      ensure
        client.close
        server.close
      end
    end
  end

  it "carries on once the remote answers" do
    Sandbox.open do |root|
      client, server = UNIXSocket.pair
      endpoint = configured_endpoint(root.root, client, server)

      begin
        sent = Time.instant
        endpoint.heartbeat(sent, after: 0.seconds, deadline: 30.seconds).should be_nil
        Message.read(server).should be_a(Message::HeartbeatRequest)

        Message.write(server, Message::HeartbeatResponse.new)
        Message.write(server, Message::TreeUpdate.new(0_u32, nil, live: false))

        # The tree only lands after the answer ahead of it in the stream has been read.
        endpoint.scan(Time.utc.to_unix_ns.to_i64)

        endpoint.heartbeat(sent + 1.hour, after: 0.seconds, deadline: 30.seconds).should be_nil
      ensure
        client.close
        server.close
      end
    end
  end

  it "is answered by the server" do
    Sandbox.open do |root|
      client, socket = UNIXSocket.pair
      serve_remote_end(socket)

      begin
        Pylon::Wire::Greeting.read(client).should be_nil
        Message.write(client, remote_configuration(root.root))

        seen = Array(Message::Any).new
        arrivals = Channel(Nil).new(8)

        spawn do
          loop do
            message = Message.read(client)
            break unless message.is_a?(Message::Any)

            seen << message
            arrivals.send(nil)
          end
        end

        Message.write(client, Message::HeartbeatRequest.new)

        await(arrivals, for: "the server to answer the heartbeat") do
          seen.any?(Message::HeartbeatResponse)
        end
      ensure
        client.close
        socket.close
      end
    end
  end
end
