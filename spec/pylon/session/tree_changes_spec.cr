require "../../spec_helper"

require "socket"
require "../../support/remote_end"

private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint
private alias Session = Pylon::Session::Session
private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias Discard = Pylon::Discard

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

# The server only pushes tree changes when it has a watcher, so this is the only
# topology that exercises the shared tree baseline.
private def in_watched_pair(
  & : Sandbox, Sandbox, Session(LocalEndpoint, RemoteEndpoint, Discard), ::Channel(Nil) ->
) : Nil
  Sandbox.open do |sandbox|
    local = sandbox.directory("local")
    remote = sandbox.directory("remote")

    client, socket = UNIXSocket.pair
    serve_remote_end(socket)

    pushes = ::Channel(Nil).new(16)

    begin
      session = build_session(
        local_endpoint(local),
        RemoteEndpoint.new(
          client,
          client,
          remote_configuration(remote, watch: true),
          pushes,
          resume: nil,
        ),
        push_first: true,
      )
      yield local, remote, session, pushes
    ensure
      client.close
      socket.close
    end
  end
end

private def await_push(pushes : ::Channel(Nil)) : Nil
  select
  when pushes.receive
  when timeout(5.seconds)
    fail("the server never pushed a tree update")
  end
end

describe "the shared tree baseline" do
  it "stays correct across the client's own writes" do
    in_watched_pair do |local, remote, session, pushes|
      20.times { |index| local.write("f#{index}.rb", "body #{index}") }
      cycle!(session, tick)
      await_push(pushes)

      local.write("mine.rb", "written by the client")
      cycle!(session, tick)
      await_push(pushes)

      remote.write("theirs.rb", "written on the box")

      5.times do
        await_push(pushes)
        cycle!(session, tick).halted?.should be_false
        break if local.exists?("theirs.rb")
      end

      local.read("theirs.rb").should eq("written on the box")
      remote.read("mine.rb").should eq("written by the client")
      remote.children.size.should eq(22)

      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "survives a push larger than a single batch" do
    in_watched_pair do |local, remote, session, pushes|
      local.directory("app/models")
      local.directory("db")
      400.times do |index|
        local.write("app/models/f#{index}.rb", "class F#{index}; end")
      end
      local.write("db/structure.sql", "-- schema")

      cycle!(session, tick)
      await_push(pushes)

      3.times do
        report = cycle!(session, tick)
        report.halted?.should be_false, "a cycle halted, which means a side looked emptied"
      end

      local.directory?("app/models").should be_true, "the local tree was deleted"
      local.children("app/models").size.should eq(400)
      remote.children("app/models").size.should eq(400)
      local.exists?("db/structure.sql").should be_true
    end
  end
end
