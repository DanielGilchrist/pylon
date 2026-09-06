require "../../spec_helper"

private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias TransferProgress = Pylon::Session::TransferProgress

private def tick : Int64
  Time.utc.to_unix_ns.to_i64 + Random.rand(1_000_000_i64)
end

private class Recorder
  getter updates = Array(TransferProgress).new

  def progress(update : TransferProgress) : Nil
    @updates << update
  end
end

private def in_progress_pair(
  file_count : Int32,
  & : Array(TransferProgress), Pylon::Session::Session(LocalEndpoint, LocalEndpoint, Recorder) ->
) : Nil
  Sandbox.open do |sandbox|
    local_root = sandbox.directory("local")
    remote_root = sandbox.directory("remote")

    file_count.times do |index|
      local_root.write("file_#{index}.rb", "body #{index}")
    end

    recorder = Recorder.new
    session = build_session(
      local_endpoint(local_root),
      local_endpoint(remote_root),
      narrator: recorder,
    )

    yield recorder.updates, session
  end
end

describe "session progress reporting" do
  it "reports progress on a transfer large enough to be worth narrating" do
    in_progress_pair(201) do |updates, session|
      cycle!(session, tick)

      updates.should_not be_empty
      updates.each(&.into.remote?.should(be_true))
      updates.map(&.total).uniq!.should eq([201])
      updates.map(&.confirmed).each_cons_pair { |before, after| (before <= after).should be_true }
      updates.last.confirmed.should eq(201)

      expected_bytes = (0...201).sum(0_u64) { |index| "body #{index}".bytesize.to_u64 }
      updates.last.total_bytes.should eq(expected_bytes)
    end
  end

  it "stays silent up to and including the narration threshold" do
    in_progress_pair(200) do |updates, session|
      cycle!(session, tick)

      updates.should be_empty
    end
  end
end
