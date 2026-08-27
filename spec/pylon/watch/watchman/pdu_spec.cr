require "../../../spec_helper"
require "../../../../src/pylon/watch/watchman/client"

include Pylon::Watch::Watchman

private SUBSCRIBE_REPLY = %({"clock":"c:1787606121:779:3:9","subscribe":"pylon","version":"2026.04.27.00"})

private FRESH = <<-JSON
  {"unilateral":true,"subscription":"pylon","clock":"c:1:2:3:9","is_fresh_instance":true,
   "files":[{"name":"a.txt","exists":true,"new":true,"mode":33188,"size":4,"mtime_ns":10},
            {"name":"app","exists":true,"new":true,"mode":16877,"size":64,"mtime_ns":11}]}
  JSON

private INCREMENTAL = <<-JSON
  {"unilateral":true,"subscription":"pylon","clock":"c:1:2:3:10","is_fresh_instance":false,
   "files":[{"name":"live.txt","exists":true,"new":true,"mode":33261,"size":1,"mtime_ns":12},
            {"name":"sub/b.txt","exists":false,"new":false,"mode":33188,"size":6,"mtime_ns":9}]}
  JSON

describe Pylon::Watch::Watchman::PDU do
  it "parses a command response" do
    pdu = PDU.parse(SUBSCRIBE_REPLY)
    pdu.should be_a(PDU::Response)
  end

  it "parses an error response" do
    pdu = PDU.parse(%({"error":"unable to resolve root: not a directory"}))

    pdu.should be_a(PDU::Failure)
    pdu.as(PDU::Failure).message.should eq("unable to resolve root: not a directory")
  end

  it "treats a closed connection as a failure rather than an exception" do
    PDU.parse(nil).should be_a(PDU::Failure)
  end

  it "treats malformed json as a failure rather than an exception" do
    PDU.parse("{not json").should be_a(PDU::Failure)
  end

  it "distinguishes a fresh instance from an incremental update by type" do
    PDU.parse(FRESH).should be_a(PDU::Snapshot)
    PDU.parse(INCREMENTAL).should be_a(PDU::Delta)
  end

  it "reads names, kinds and the executable bit from observations" do
    snapshot = PDU.parse(FRESH).as(PDU::Snapshot)

    snapshot.clock.should eq("c:1:2:3:9")
    snapshot.observations.map(&.name).should eq(["a.txt", "app"])
    snapshot.observations[0].kind.should eq(Entry::Kind::File)
    snapshot.observations[0].executable?.should be_false
    snapshot.observations[1].directory?.should be_true
  end

  it "reads a deletion as an observation that no longer exists" do
    delta = PDU.parse(INCREMENTAL).as(PDU::Delta)

    live, gone = delta.observations

    live.deleted?.should be_false
    live.executable?.should be_true
    gone.name.should eq("sub/b.txt")
    gone.deleted?.should be_true
  end
end

describe Pylon::Watch::Watchman::Client do
  it "sends a subscribe command carrying the ignore patterns" do
    written = IO::Memory.new
    io = IO::Stapled.new(IO::Memory.new("#{SUBSCRIBE_REPLY}\n"), written)

    Client.new(io).subscribe("/repo", "pylon", ["node_modules", ".git"])

    request = JSON.parse(written.to_s.lines.first)
    request[0].as_s.should eq("subscribe")
    request[1].as_s.should eq("/repo")
    request[2].as_s.should eq("pylon")
    request[3]["expression"].to_json.should eq(
      %(["not",["anyof",["dirname","node_modules"],["dirname",".git"]]])
    )
    request[3]["fields"].as_a.map(&.as_s).should contain("mtime_ns")
  end

  it "omits the expression when nothing is ignored" do
    io = IO::Stapled.new(IO::Memory.new("#{SUBSCRIBE_REPLY}\n"), IO::Memory.new)

    Client.new(io).subscribe("/repo", "pylon", [] of String)
  end

  it "reads a stream of updates in order" do
    io = IO::Stapled.new(IO::Memory.new("#{FRESH.gsub('\n', "")}\n#{INCREMENTAL.gsub('\n', "")}\n"), IO::Memory.new)
    client = Client.new(io)

    client.read.should be_a(PDU::Snapshot)
    client.read.should be_a(PDU::Delta)
    client.read.should be_a(PDU::Failure)
  end
end
