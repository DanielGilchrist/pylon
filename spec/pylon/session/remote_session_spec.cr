require "file_utils"
require "socket"
require "../../spec_helper"
require "../../../src/pylon/session/server"
require "../../../src/pylon/session/remote_endpoint"
require "../../../src/pylon/session/session"
require "../../support/remote_end"

include Pylon::Session

private def in_remote_pair(& : String, String, Session(LocalEndpoint, RemoteEndpoint), RemoteEndpoint ->) : Nil
  base = File.join(Dir.tempdir, "pylon-remote-#{Random::Secure.hex(8)}")
  local_root = File.join(base, "local")
  remote_root = File.join(base, "remote")
  Dir.mkdir_p(local_root)
  Dir.mkdir_p(remote_root)

  client, socket = UNIXSocket.pair
  serve_remote_end(socket)

  begin
    remote = RemoteEndpoint.new(client, client, remote_configuration(remote_root), resume: nil)
    session = build_session(local_endpoint(local_root), remote)
    yield local_root, remote_root, session, remote
  ensure
    client.close
    socket.close
    FileUtils.rm_rf(base)
  end
end

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

describe "a session over the wire protocol" do
  it "copies a file to the remote side" do
    in_remote_pair do |local, remote, session|
      File.write(File.join(local, "hello.rb"), "puts 1")

      cycle!(session, tick)

      File.read(File.join(remote, "hello.rb")).should eq("puts 1")
    end
  end

  it "copies a file back from the remote side" do
    in_remote_pair do |local, remote, session|
      Dir.mkdir_p(File.join(remote, "lib"))
      File.write(File.join(remote, "lib", "thing.rb"), "puts 2")

      cycle!(session, tick)

      File.read(File.join(local, "lib", "thing.rb")).should eq("puts 2")
    end
  end

  it "pulls content that does not fit one transfer budget in several batches" do
    in_remote_pair do |local, remote, session, endpoint|
      third = (Session::TRANSFER_BUDGET // 3 + 1).to_i32
      3.times { |index| File.write(File.join(remote, "blob#{index}.bin"), Bytes.new(third, (index + 1).to_u8)) }

      cycle!(session, tick)

      3.times { |index| File.size(File.join(local, "blob#{index}.bin")).should eq(third) }
      endpoint.exchanges.should eq(2)
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "patches many files that shared one base in a single parallel batch" do
    in_remote_pair do |local, remote, session|
      shared = Random.new(61).random_bytes(64 * 1024)
      count = Pylon::Write::Writer::PARALLEL_THRESHOLD + 4
      count.times { |index| File.write(File.join(local, "shared_#{index}.bin"), shared) }
      cycle!(session, tick)

      count.times do |index|
        edited = shared.dup
        edited[index] ^= 0xFF_u8
        File.write(File.join(local, "shared_#{index}.bin"), edited)
      end

      report = cycle!(session, tick)

      report.remote_outcomes.reject(&.applied?).map(&.path).should be_empty
      count.times do |index|
        File.read(File.join(remote, "shared_#{index}.bin")).to_slice[index].should eq(shared[index] ^ 0xFF_u8)
      end
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "settles after one cycle" do
    in_remote_pair do |local, _, session|
      File.write(File.join(local, "a.rb"), "a")
      File.write(File.join(local, "b.rb"), "b")

      cycle!(session, tick)
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "moves many files in a single cycle" do
    in_remote_pair do |local, remote, session|
      200.times { |index| File.write(File.join(local, "file_#{index}.rb"), "body #{index}") }

      cycle!(session, tick)

      Dir.children(remote).size.should eq(200)
      File.read(File.join(remote, "file_199.rb")).should eq("body 199")
    end
  end

  it "propagates a deletion across the wire" do
    in_remote_pair do |local, remote, session|
      File.write(File.join(local, "temp.rb"), "x")
      cycle!(session, tick)

      File.delete(File.join(local, "temp.rb"))
      cycle!(session, tick)

      File.exists?(File.join(remote, "temp.rb")).should be_false
    end
  end

  it "propagates the executable bit across the wire" do
    in_remote_pair do |local, remote, session|
      path = File.join(local, "run.sh")
      File.write(path, "#!/bin/sh\n")
      File.chmod(path, 0o755)

      cycle!(session, tick)

      File.info(File.join(remote, "run.sh")).permissions.value.should eq(0o755)
    end
  end

  it "reports a conflict without touching either side" do
    in_remote_pair do |local, remote, session|
      File.write(File.join(local, "shared.rb"), "original")
      cycle!(session, tick)

      File.write(File.join(local, "shared.rb"), "from local")
      File.write(File.join(remote, "shared.rb"), "from remote")
      report = cycle!(session, tick)

      report.conflicts.map(&.root).should eq(["shared.rb"])
      File.read(File.join(local, "shared.rb")).should eq("from local")
      File.read(File.join(remote, "shared.rb")).should eq("from remote")
    end
  end
end

describe "a session whose remote pushes tree updates" do
  it "still sees remote changes when no pusher exists, at the cost of a round trip" do
    in_remote_pair do |local, remote, session|
      File.write(File.join(remote, "pushed.rb"), "from the box")

      cycle!(session, tick)

      File.read(File.join(local, "pushed.rb")).should eq("from the box")
    end
  end

  it "keeps its cached remote tree correct after its own write" do
    in_remote_pair do |local, remote, session|
      File.write(File.join(local, "one.rb"), "1")
      cycle!(session, tick)
      cycle!(session, tick).quiet?.should be_true

      File.write(File.join(local, "two.rb"), "2")
      cycle!(session, tick)

      File.read(File.join(remote, "two.rb")).should eq("2")
      cycle!(session, tick).quiet?.should be_true
    end
  end
end

describe "a large push followed by more cycles" do
  it "does not delete what it just sent" do
    in_remote_pair do |local, remote, session|
      Dir.mkdir_p(File.join(local, "app", "models"))
      Dir.mkdir_p(File.join(local, "db"))
      400.times { |index| File.write(File.join(local, "app", "models", "f#{index}.rb"), "class F#{index}; end") }
      File.write(File.join(local, "db", "structure.sql"), "-- schema")

      cycle!(session, tick)
      File.exists?(File.join(remote, "db", "structure.sql")).should be_true

      3.times do
        report = cycle!(session, tick)
        report.halted?.should be_false
      end

      Dir.exists?(File.join(local, "app", "models")).should be_true
      Dir.exists?(File.join(local, "db")).should be_true
      Dir.children(File.join(local, "app", "models")).size.should eq(400)
      Dir.children(File.join(remote, "app", "models")).size.should eq(400)
    end
  end

  it "keeps both sides settled after a burst in each direction" do
    in_remote_pair do |local, remote, session|
      300.times { |index| File.write(File.join(local, "up_#{index}.rb"), "up #{index}") }
      cycle!(session, tick)

      300.times { |index| File.write(File.join(remote, "down_#{index}.rb"), "down #{index}") }
      cycle!(session, tick)

      cycle!(session, tick).quiet?.should be_true
      Dir.children(local).size.should eq(600)
      Dir.children(remote).size.should eq(600)
    end
  end
end
