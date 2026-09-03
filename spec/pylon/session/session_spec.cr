require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/local_endpoint"
require "../../../src/pylon/session/session"

include Pylon::Session
include Pylon::Core

private NOW = Time.utc.to_unix_ns.to_i64

private def in_pair(& : String, String, Session(LocalEndpoint, LocalEndpoint) ->) : Nil
  base = File.join(Dir.tempdir, "pylon-session-#{Random::Secure.hex(8)}")
  local_root = File.join(base, "local")
  remote_root = File.join(base, "remote")
  Dir.mkdir_p(local_root)
  Dir.mkdir_p(remote_root)

  begin
    session = build_session(local_endpoint(local_root), local_endpoint(remote_root))
    yield local_root, remote_root, session
  ensure
    FileUtils.rm_rf(base)
  end
end

private def tick : Int64
  NOW + Random.rand(1_000_000_i64)
end

private def tree(root : String) : Hash(String, String)
  files = Hash(String, String).new

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

      cycle!(session, tick)

      File.read(File.join(remote, "hello.rb")).should eq("puts 1")
    end
  end

  it "copies a new file from remote to local" do
    in_pair do |local, remote, session|
      File.write(File.join(remote, "there.rb"), "puts 2")

      cycle!(session, tick)

      File.read(File.join(local, "there.rb")).should eq("puts 2")
    end
  end

  it "settles after one cycle and does nothing on the next" do
    in_pair do |local, _, session|
      Dir.mkdir_p(File.join(local, "app", "models"))
      File.write(File.join(local, "app", "models", "user.rb"), "class User; end")

      cycle!(session, tick)
      second = cycle!(session, tick)

      second.quiet?.should be_true
    end
  end

  it "converges both trees" do
    in_pair do |local, remote, session|
      Dir.mkdir_p(File.join(local, "a"))
      File.write(File.join(local, "a", "one.rb"), "one")
      File.write(File.join(remote, "two.rb"), "two")

      cycle!(session, tick)

      tree(local).should eq(tree(remote))
      tree(local).keys.sort!.should eq(["a/one.rb", "two.rb"])
    end
  end

  it "propagates a deletion" do
    in_pair do |local, remote, session|
      path = File.join(local, "temp.rb")
      File.write(path, "x")
      cycle!(session, tick)
      File.exists?(File.join(remote, "temp.rb")).should be_true

      File.delete(path)
      cycle!(session, tick)

      File.exists?(File.join(remote, "temp.rb")).should be_false
    end
  end

  it "propagates a modification back the other way" do
    in_pair do |local, remote, session|
      File.write(File.join(local, "notes.md"), "first")
      cycle!(session, tick)

      File.write(File.join(remote, "notes.md"), "second")
      cycle!(session, tick)

      File.read(File.join(local, "notes.md")).should eq("second")
    end
  end

  it "propagates the executable bit" do
    in_pair do |local, remote, session|
      path = File.join(local, "run.sh")
      File.write(path, "#!/bin/sh\n")
      File.chmod(path, 0o755)

      cycle!(session, tick)

      File.info(File.join(remote, "run.sh")).permissions.value.should eq(0o755)
    end
  end

  it "reports a conflict and touches neither side when both changed" do
    in_pair do |local, remote, session|
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

  it "keeps a deleted file when the other side modified it" do
    in_pair do |local, remote, session|
      File.write(File.join(local, "kept.rb"), "original")
      cycle!(session, tick)

      File.delete(File.join(local, "kept.rb"))
      File.write(File.join(remote, "kept.rb"), "edited")
      cycle!(session, tick)

      File.read(File.join(local, "kept.rb")).should eq("edited")
    end
  end
end

describe "moves" do
  it "moves a directory on the other side with one rename instead of copying its files" do
    in_pair do |local, remote, session|
      Dir.mkdir_p(File.join(local, "lib", "deep"))
      File.write(File.join(local, "lib", "a.rb"), "a")
      File.write(File.join(local, "lib", "deep", "b.rb"), "b")
      cycle!(session, tick)
      before = File.info(File.join(remote, "lib", "deep", "b.rb"))

      File.rename(File.join(local, "lib"), File.join(local, "moved"))
      report = cycle!(session, tick)

      report.remote_relocations.map { |relocation| {relocation.from, relocation.to} }.should eq([{"lib", "moved"}])
      File.read(File.join(remote, "moved", "deep", "b.rb")).should eq("b")
      Dir.exists?(File.join(remote, "lib")).should be_false
      before.same_file?(File.info(File.join(remote, "moved", "deep", "b.rb"))).should be_true
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "moves a file renamed on the remote side back to the local side" do
    in_pair do |local, remote, session|
      File.write(File.join(local, "one.rb"), "same")
      cycle!(session, tick)

      File.rename(File.join(remote, "one.rb"), File.join(remote, "two.rb"))
      report = cycle!(session, tick)

      report.local_relocations.map { |relocation| {relocation.from, relocation.to} }.should eq([{"one.rb", "two.rb"}])
      File.read(File.join(local, "two.rb")).should eq("same")
      File.exists?(File.join(local, "one.rb")).should be_false
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "falls back to copying when the moved directory also changed" do
    in_pair do |local, remote, session|
      Dir.mkdir_p(File.join(local, "lib"))
      File.write(File.join(local, "lib", "a.rb"), "a")
      cycle!(session, tick)

      File.rename(File.join(local, "lib"), File.join(local, "moved"))
      File.write(File.join(local, "moved", "extra.rb"), "extra")
      report = cycle!(session, tick)

      report.remote_relocations.should be_empty
      tree(remote).should eq(tree(local))
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "previews a move in a dry run without touching either side" do
    in_pair do |local, remote, session|
      Dir.mkdir_p(File.join(local, "lib"))
      File.write(File.join(local, "lib", "a.rb"), "a")
      cycle!(session, tick)

      File.rename(File.join(local, "lib"), File.join(local, "moved"))
      preview = build_session(local_endpoint(local), local_endpoint(remote), base: session.base, dry_run: true)
      report = cycle!(preview, tick)

      report.remote_relocations.map { |relocation| {relocation.from, relocation.to} }.should eq([{"lib", "moved"}])
      report.quiet?.should be_false
      Dir.exists?(File.join(remote, "lib")).should be_true
      Dir.exists?(File.join(remote, "moved")).should be_false
    end
  end
end

describe "case-only renames" do
  it "lands a rename that changed only the letter case in a single cycle" do
    in_pair do |local, remote, session|
      File.write(File.join(local, "Readme.md"), "content")
      cycle!(session, tick)

      File.rename(File.join(local, "Readme.md"), File.join(local, "README.md"))
      cycle!(session, tick)

      Dir.children(remote).should eq(Dir.children(local))
      File.read(File.join(remote, Dir.children(remote).first)).should eq("content")
    end
  end
end

describe "safety halts" do
  it "mirrors one side deliberately emptying everything" do
    in_pair do |local, remote, session|
      3.times { |index| File.write(File.join(local, "f#{index}.rb"), "x") }
      cycle!(session, tick)

      Dir.children(local).each { |name| File.delete(File.join(local, name)) }

      report = cycle!(session, tick)

      report.halted?.should be_false
      Dir.children(remote).should be_empty
    end
  end
end

describe "the first cycle when there is no saved state" do
  it "pushes local files up and removes ones only the remote had" do
    in_pair do |local, remote, _|
      File.write(File.join(local, "mine.rb"), "local")
      File.write(File.join(remote, "stale.rb"), "left over on the box")

      session = build_session(local_endpoint(local), local_endpoint(remote), push_first: true)
      cycle!(session, tick)

      File.exists?(File.join(remote, "mine.rb")).should be_true
      File.exists?(File.join(remote, "stale.rb")).should be_false
      File.exists?(File.join(local, "stale.rb")).should be_false
    end
  end

  it "lets the local copy win without reporting a conflict" do
    in_pair do |local, remote, _|
      File.write(File.join(local, "shared.rb"), "from the local side")
      File.write(File.join(remote, "shared.rb"), "from the box")

      session = build_session(local_endpoint(local), local_endpoint(remote), push_first: true)
      report = cycle!(session, tick)

      report.conflicts.should be_empty
      File.read(File.join(remote, "shared.rb")).should eq("from the local side")
    end
  end

  it "goes two way from the second cycle onwards" do
    in_pair do |local, remote, _|
      File.write(File.join(local, "mine.rb"), "local")

      session = build_session(local_endpoint(local), local_endpoint(remote), push_first: true)
      cycle!(session, tick)

      File.write(File.join(remote, "generated.rbi"), "made on the box")
      cycle!(session, tick)

      File.read(File.join(local, "generated.rbi")).should eq("made on the box")
    end
  end

  it "still pulls remote files down when state already exists" do
    in_pair do |local, remote, session|
      File.write(File.join(remote, "from_box.rb"), "box")

      cycle!(session, tick)

      File.exists?(File.join(local, "from_box.rb")).should be_true
    end
  end
end
