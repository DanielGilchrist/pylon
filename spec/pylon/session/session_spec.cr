require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/local_endpoint"
require "../../../src/pylon/session/session"

include Pylon::Session

private NOW = Time.utc.to_unix_ns.to_i64

private def in_pair(& : String, String, Session(LocalEndpoint, LocalEndpoint) ->)
  base = File.join(Dir.tempdir, "pylon-session-#{Random::Secure.hex(8)}")
  local_root = File.join(base, "local")
  remote_root = File.join(base, "remote")
  Dir.mkdir_p(local_root)
  Dir.mkdir_p(remote_root)

  begin
    session = Session.new(LocalEndpoint.new(local_root), LocalEndpoint.new(remote_root))
    yield local_root, remote_root, session
  ensure
    FileUtils.rm_rf(base)
  end
end

private def tick : Int64
  NOW + Random.rand(1_000_000_i64)
end

private def tree(root : String) : Hash(String, String)
  files = {} of String => String

  Dir.glob(File.join(root, "**", "*")).each do |path|
    next unless File.file?(path)

    files[path.lchop("#{root}/")] = File.read(path)
  end

  files
end

describe Pylon::Session::Session do
  it "copies a new file from local to remote" do
    in_pair do |local, remote, session|
      File.write(File.join(local, "hello.rb"), "puts 1")

      session.cycle(tick)

      File.read(File.join(remote, "hello.rb")).should eq("puts 1")
    end
  end

  it "copies a new file from remote to local" do
    in_pair do |local, remote, session|
      File.write(File.join(remote, "there.rb"), "puts 2")

      session.cycle(tick)

      File.read(File.join(local, "there.rb")).should eq("puts 2")
    end
  end

  it "settles after one cycle and does nothing on the next" do
    in_pair do |local, _, session|
      Dir.mkdir_p(File.join(local, "app", "models"))
      File.write(File.join(local, "app", "models", "user.rb"), "class User; end")

      session.cycle(tick)
      second = session.cycle(tick)

      second.quiet?.should be_true
    end
  end

  it "converges both trees" do
    in_pair do |local, remote, session|
      Dir.mkdir_p(File.join(local, "a"))
      File.write(File.join(local, "a", "one.rb"), "one")
      File.write(File.join(remote, "two.rb"), "two")

      session.cycle(tick)

      tree(local).should eq(tree(remote))
      tree(local).keys.sort!.should eq(["a/one.rb", "two.rb"])
    end
  end

  it "propagates a deletion" do
    in_pair do |local, remote, session|
      path = File.join(local, "temp.rb")
      File.write(path, "x")
      session.cycle(tick)
      File.exists?(File.join(remote, "temp.rb")).should be_true

      File.delete(path)
      session.cycle(tick)

      File.exists?(File.join(remote, "temp.rb")).should be_false
    end
  end

  it "propagates a modification back the other way" do
    in_pair do |local, remote, session|
      File.write(File.join(local, "notes.md"), "first")
      session.cycle(tick)

      File.write(File.join(remote, "notes.md"), "second")
      session.cycle(tick)

      File.read(File.join(local, "notes.md")).should eq("second")
    end
  end

  it "propagates the executable bit" do
    in_pair do |local, remote, session|
      path = File.join(local, "run.sh")
      File.write(path, "#!/bin/sh\n")
      File.chmod(path, 0o755)

      session.cycle(tick)

      File.info(File.join(remote, "run.sh")).permissions.value.should eq(0o755)
    end
  end

  it "reports a conflict and touches neither side when both changed" do
    in_pair do |local, remote, session|
      File.write(File.join(local, "shared.rb"), "original")
      session.cycle(tick)

      File.write(File.join(local, "shared.rb"), "from local")
      File.write(File.join(remote, "shared.rb"), "from remote")
      report = session.cycle(tick)

      report.conflicts.map(&.root).should eq(["shared.rb"])
      File.read(File.join(local, "shared.rb")).should eq("from local")
      File.read(File.join(remote, "shared.rb")).should eq("from remote")
    end
  end

  it "keeps a deleted file when the other side modified it" do
    in_pair do |local, remote, session|
      File.write(File.join(local, "kept.rb"), "original")
      session.cycle(tick)

      File.delete(File.join(local, "kept.rb"))
      File.write(File.join(remote, "kept.rb"), "edited")
      session.cycle(tick)

      File.read(File.join(local, "kept.rb")).should eq("edited")
    end
  end
end
