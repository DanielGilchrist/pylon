require "../../spec_helper"

require "socket"
require "../../support/remote_end"

private alias RemoteEndpoint = Pylon::Session::RemoteEndpoint
private alias Session = Pylon::Session::Session
private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias Discard = Pylon::Discard

private def in_remote_pair(
  & : Sandbox, Sandbox, Session(LocalEndpoint, RemoteEndpoint, Discard), RemoteEndpoint ->
) : Nil
  Sandbox.open do |sandbox|
    local_root = sandbox.directory("local")
    remote_root = sandbox.directory("remote")

    client, socket = UNIXSocket.pair
    serve_remote_end(socket)

    begin
      remote = RemoteEndpoint.new(client, client, remote_configuration(remote_root), resume: nil)
      session = build_session(local_endpoint(local_root), remote)
      yield local_root, remote_root, session, remote
    ensure
      client.close
      socket.close
    end
  end
end

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

describe "a session over the wire protocol" do
  it "copies a file to the remote side" do
    in_remote_pair do |local, remote, session|
      local.write("hello.rb", "puts 1")

      cycle!(session, tick)

      remote.read("hello.rb").should eq("puts 1")
    end
  end

  it "copies a file back from the remote side" do
    in_remote_pair do |local, remote, session|
      remote.directory("lib")
      remote.write("lib/thing.rb", "puts 2")

      cycle!(session, tick)

      local.read("lib/thing.rb").should eq("puts 2")
    end
  end

  it "pulls content that does not fit one transfer budget in several batches" do
    in_remote_pair do |local, remote, session, endpoint|
      third = (Pylon::Session::Session::TRANSFER_BUDGET // 3 + 1).to_i32
      3.times do |index|
        remote.write("blob#{index}.bin", Bytes.new(third, (index + 1).to_u8))
      end

      cycle!(session, tick)

      3.times { |index| File.size(local.path("blob#{index}.bin")).should eq(third) }
      endpoint.exchanges.should eq(2)
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "patches many files that shared one base in a single parallel batch" do
    in_remote_pair do |local, remote, session|
      shared = Random.new(61).random_bytes(64 * 1024)
      count = Pylon::Write::Writer::PARALLEL_THRESHOLD + 4
      count.times { |index| local.write("shared_#{index}.bin", shared) }
      cycle!(session, tick)

      count.times do |index|
        edited = shared.dup
        edited[index] ^= 0xFF_u8
        local.write("shared_#{index}.bin", edited)
      end

      report = cycle!(session, tick)

      report.remote_outcomes.reject(&.applied?).map(&.path).should be_empty
      count.times do |index|
        remote.read("shared_#{index}.bin").to_slice[index].should eq(
          shared[index] ^ 0xFF_u8,
        )
      end
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "settles after one cycle" do
    in_remote_pair do |local, _, session|
      local.write("a.rb", "a")
      local.write("b.rb", "b")

      cycle!(session, tick)
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "moves many files in a single cycle" do
    in_remote_pair do |local, remote, session|
      200.times { |index| local.write("file_#{index}.rb", "body #{index}") }

      cycle!(session, tick)

      remote.children.size.should eq(200)
      remote.read("file_199.rb").should eq("body 199")
    end
  end

  it "propagates a deletion across the wire" do
    in_remote_pair do |local, remote, session|
      local.write("temp.rb", "x")
      cycle!(session, tick)

      local.remove("temp.rb")
      cycle!(session, tick)

      remote.exists?("temp.rb").should be_false
    end
  end

  it "propagates the executable bit across the wire" do
    in_remote_pair do |local, remote, session|
      local.write("run.sh", "#!/bin/sh\n")
      local.chmod("run.sh", 0o755)

      cycle!(session, tick)

      remote.info("run.sh").permissions.value.should eq(0o755)
    end
  end

  it "reports a conflict without touching either side" do
    in_remote_pair do |local, remote, session|
      local.write("shared.rb", "original")
      cycle!(session, tick)

      local.write("shared.rb", "from local")
      remote.write("shared.rb", "from remote")
      report = cycle!(session, tick)

      report.conflicts.should eq(["shared.rb"])
      local.read("shared.rb").should eq("from local")
      remote.read("shared.rb").should eq("from remote")
    end
  end
end

describe "a session whose remote pushes tree updates" do
  it "still sees remote changes when no pusher exists, at the cost of a round trip" do
    in_remote_pair do |local, remote, session|
      remote.write("pushed.rb", "from the box")

      cycle!(session, tick)

      local.read("pushed.rb").should eq("from the box")
    end
  end

  it "keeps its cached remote tree correct after its own write" do
    in_remote_pair do |local, remote, session|
      local.write("one.rb", "1")
      cycle!(session, tick)
      cycle!(session, tick).quiet?.should be_true

      local.write("two.rb", "2")
      cycle!(session, tick)

      remote.read("two.rb").should eq("2")
      cycle!(session, tick).quiet?.should be_true
    end
  end
end

describe "a large push followed by more cycles" do
  it "does not delete what it just sent" do
    in_remote_pair do |local, remote, session|
      local.directory("app/models")
      local.directory("db")
      400.times do |index|
        local.write("app/models/f#{index}.rb", "class F#{index}; end")
      end
      local.write("db/structure.sql", "-- schema")

      cycle!(session, tick)
      remote.exists?("db/structure.sql").should be_true

      3.times do
        report = cycle!(session, tick)
        report.halted?.should be_false
      end

      local.directory?("app/models").should be_true
      local.directory?("db").should be_true
      local.children("app/models").size.should eq(400)
      remote.children("app/models").size.should eq(400)
    end
  end

  it "keeps both sides settled after a burst in each direction" do
    in_remote_pair do |local, remote, session|
      300.times { |index| local.write("up_#{index}.rb", "up #{index}") }
      cycle!(session, tick)

      300.times { |index| remote.write("down_#{index}.rb", "down #{index}") }
      cycle!(session, tick)

      cycle!(session, tick).quiet?.should be_true
      local.children.size.should eq(600)
      remote.children.size.should eq(600)
    end
  end
end
