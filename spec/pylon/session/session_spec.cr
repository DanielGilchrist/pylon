require "../../spec_helper"

private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias Session = Pylon::Session::Session

private NOW = Time.utc.to_unix_ns.to_i64

private def in_pair(
  & : Sandbox, Sandbox, Session(LocalEndpoint, LocalEndpoint, Pylon::Discard) ->
) : Nil
  Sandbox.open do |sandbox|
    local_root = sandbox.directory("local")
    remote_root = sandbox.directory("remote")

    session = build_session(local_endpoint(local_root), local_endpoint(remote_root))
    yield local_root, remote_root, session
  end
end

private def tick : Int64
  NOW + Random.rand(1_000_000_i64)
end

private def tree(root : Sandbox) : Hash(String, String)
  files = Hash(String, String).new

  Dir.glob(root.path("**/*")).each do |path|
    next unless File.file?(path)

    files[path.lchop("#{root.root}/")] = File.read(path)
  end

  files
end

describe Session do
  it "copies a new file from local to remote" do
    in_pair do |local, remote, session|
      local.write("hello.rb", "puts 1")

      cycle!(session, tick)

      remote.read("hello.rb").should eq("puts 1")
    end
  end

  it "copies a new file from remote to local" do
    in_pair do |local, remote, session|
      remote.write("there.rb", "puts 2")

      cycle!(session, tick)

      local.read("there.rb").should eq("puts 2")
    end
  end

  it "settles after one cycle and does nothing on the next" do
    in_pair do |local, _, session|
      local.directory("app/models")
      local.write("app/models/user.rb", "class User; end")

      cycle!(session, tick)
      second = cycle!(session, tick)

      second.quiet?.should be_true
    end
  end

  it "converges both trees" do
    in_pair do |local, remote, session|
      local.directory("a")
      local.write("a/one.rb", "one")
      remote.write("two.rb", "two")

      cycle!(session, tick)

      tree(local).should eq(tree(remote))
      tree(local).keys.sort!.should eq(["a/one.rb", "two.rb"])
    end
  end

  it "propagates a deletion" do
    in_pair do |local, remote, session|
      local.write("temp.rb", "x")
      cycle!(session, tick)
      remote.exists?("temp.rb").should be_true

      local.remove("temp.rb")
      cycle!(session, tick)

      remote.exists?("temp.rb").should be_false
    end
  end

  it "propagates a modification back the other way" do
    in_pair do |local, remote, session|
      local.write("notes.md", "first")
      cycle!(session, tick)

      remote.write("notes.md", "second")
      cycle!(session, tick)

      local.read("notes.md").should eq("second")
    end
  end

  it "propagates the executable bit" do
    in_pair do |local, remote, session|
      local.write("run.sh", "#!/bin/sh\n")
      local.chmod("run.sh", 0o755)

      cycle!(session, tick)

      remote.info("run.sh").permissions.value.should eq(0o755)
    end
  end

  it "reports a conflict and touches neither side when both changed" do
    in_pair do |local, remote, session|
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

  it "keeps a deleted file when the other side modified it" do
    in_pair do |local, remote, session|
      local.write("kept.rb", "original")
      cycle!(session, tick)

      local.remove("kept.rb")
      remote.write("kept.rb", "edited")
      cycle!(session, tick)

      local.read("kept.rb").should eq("edited")
    end
  end
end

describe "moves" do
  it "moves a directory on the other side with one rename instead of copying its files" do
    in_pair do |local, remote, session|
      local.directory("lib/deep")
      local.write("lib/a.rb", "a")
      local.write("lib/deep/b.rb", "b")
      cycle!(session, tick)
      before = remote.info("lib/deep/b.rb")

      local.rename("lib", "moved")
      report = cycle!(session, tick)

      report.remote_relocations.map { |relocation| {relocation.from, relocation.to} }.should eq(
        [{"lib", "moved"}],
      )
      remote.read("moved/deep/b.rb").should eq("b")
      remote.directory?("lib").should be_false
      before.same_file?(remote.info("moved/deep/b.rb")).should be_true
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "moves a file renamed on the remote side back to the local side" do
    in_pair do |local, remote, session|
      local.write("one.rb", "same")
      cycle!(session, tick)

      remote.rename("one.rb", "two.rb")
      report = cycle!(session, tick)

      report.local_relocations.map { |relocation| {relocation.from, relocation.to} }.should eq(
        [{"one.rb", "two.rb"}],
      )
      local.read("two.rb").should eq("same")
      local.exists?("one.rb").should be_false
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "falls back to copying when the moved directory also changed" do
    in_pair do |local, remote, session|
      local.directory("lib")
      local.write("lib/a.rb", "a")
      cycle!(session, tick)

      local.rename("lib", "moved")
      local.write("moved/extra.rb", "extra")
      report = cycle!(session, tick)

      report.remote_relocations.should be_empty
      tree(remote).should eq(tree(local))
      cycle!(session, tick).quiet?.should be_true
    end
  end

  it "previews a move in a dry run without touching either side" do
    in_pair do |local, remote, session|
      local.directory("lib")
      local.write("lib/a.rb", "a")
      cycle!(session, tick)

      local.rename("lib", "moved")
      preview = build_session(
        local_endpoint(local),
        local_endpoint(remote),
        base: session.base,
        dry_run: true,
      )
      report = cycle!(preview, tick)

      report.remote_relocations.map { |relocation| {relocation.from, relocation.to} }.should eq(
        [{"lib", "moved"}],
      )
      report.quiet?.should be_false
      remote.directory?("lib").should be_true
      remote.directory?("moved").should be_false
    end
  end
end

describe "case-only renames" do
  it "lands a rename that changed only the letter case in a single cycle" do
    in_pair do |local, remote, session|
      local.write("Readme.md", "content")
      cycle!(session, tick)

      local.rename("Readme.md", "README.md")
      cycle!(session, tick)

      remote.children.should eq(local.children)
      remote.read(remote.children.first).should eq("content")
    end
  end
end

describe "safety halts" do
  it "mirrors one side deliberately emptying everything" do
    in_pair do |local, remote, session|
      3.times { |index| local.write("f#{index}.rb", "x") }
      cycle!(session, tick)

      local.children.each { |name| local.remove(name) }

      report = cycle!(session, tick)

      report.halted?.should be_false
      remote.children.should be_empty
    end
  end
end

describe "the first cycle of a session" do
  it "pushes local files up and removes ones only the remote had" do
    in_pair do |local, remote, _|
      local.write("mine.rb", "local")
      remote.write("stale.rb", "left over on the box")

      session = build_session(local_endpoint(local), local_endpoint(remote), push_first: true)
      cycle!(session, tick)

      remote.exists?("mine.rb").should be_true
      remote.exists?("stale.rb").should be_false
      local.exists?("stale.rb").should be_false
    end
  end

  it "lets the local copy win without reporting a conflict" do
    in_pair do |local, remote, _|
      local.write("shared.rb", "from the local side")
      remote.write("shared.rb", "from the box")

      session = build_session(local_endpoint(local), local_endpoint(remote), push_first: true)
      report = cycle!(session, tick)

      report.conflicts.should be_empty
      remote.read("shared.rb").should eq("from the local side")
    end
  end

  it "goes two way from the second cycle onwards" do
    in_pair do |local, remote, _|
      local.write("mine.rb", "local")

      session = build_session(local_endpoint(local), local_endpoint(remote), push_first: true)
      cycle!(session, tick)

      remote.write("generated.rbi", "made on the box")
      cycle!(session, tick)

      local.read("generated.rbi").should eq("made on the box")
    end
  end

  it "overwrites remote changes made while no session was running even with saved state" do
    in_pair do |local, remote, _|
      local.write("shared.rb", "as last synced")
      remote.write("shared.rb", "as last synced")

      warm_up = build_session(local_endpoint(local), local_endpoint(remote), push_first: true)
      cycle!(warm_up, tick)

      remote.write("shared.rb", "replaced on the box")
      remote.write("from_box.rb", "box")

      session = build_session(
        local_endpoint(local),
        local_endpoint(remote),
        base: warm_up.base,
        push_first: true,
      )
      report = cycle!(session, tick)

      report.conflicts.should be_empty
      remote.read("shared.rb").should eq("as last synced")
      remote.exists?("from_box.rb").should be_false
      local.exists?("from_box.rb").should be_false
    end
  end
end
