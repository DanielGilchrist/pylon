require "../../spec_helper"

require "digest/sha256"

private alias ContentStore = Pylon::Session::ContentStore
private alias Locations = Pylon::Session::Locations
private alias Problem = Pylon::Problem

private def in_store(& : Sandbox, ContentStore, Sandbox ->) : Nil
  Sandbox.open do |base|
    tree = base.directory("tree")
    directory = Sandbox.new(base.path("store"))

    opened = ContentStore.open(directory.root, tree.root)
    raise "the store could not be opened: #{opened.reason}" if opened.is_a?(Problem)

    yield tree, opened, directory
  end
end

private def place(tree : Sandbox, name : String, content : String) : Bytes
  tree.write(name, content)
  Digest::SHA256.digest(content).to_slice
end

describe ContentStore do
  it "recovers a kept file after it was deleted" do
    in_store do |tree, store, _|
      digest = place(tree, "a.rb", "version one")
      store.keep("a.rb", digest)
      tree.remove("a.rb")

      store.holds?(digest).should be_true
      store.held([digest, Bytes.new(32, 9_u8)]).should eq([digest])
      String.new(store.content(digest) || Bytes.empty).should eq("version one")
    end
  end

  it "recovers a kept file after it was replaced by rename" do
    in_store do |tree, store, _|
      digest = place(tree, "a.rb", "version one")
      store.keep("a.rb", digest)
      tree.write("a.rb.tmp", "version two")
      tree.rename("a.rb.tmp", "a.rb")

      String.new(store.content(digest) || Bytes.empty).should eq("version one")
    end
  end

  it "forgets content that no longer matches its digest" do
    in_store do |tree, store, directory|
      digest = place(tree, "a.rb", "original")
      tree.write("a.rb", "changed before the snapshot")
      store.keep("a.rb", digest)

      store.content(digest).should be_nil
      store.holds?(digest).should be_false
      directory.children.should be_empty
    end
  end

  it "ignores a path that no longer exists" do
    in_store do |_, store, directory|
      store.keep("vanished.rb", Bytes.new(32, 1_u8))

      store.holds?(Bytes.new(32, 1_u8)).should be_false
      directory.children.should be_empty
    end
  end

  it "leaves a store under the bound alone" do
    in_store do |tree, store, directory|
      digests = Array.new(4) { |index| place(tree, "f#{index}", "body #{index}") }
      digests.each_with_index { |digest, index| store.keep("f#{index}", digest) }

      live = Locations.new
      live.remember(digests[0], "f0", 0_u64)
      store.prune(live)

      store.held(digests).should eq(digests)
      directory.children.size.should eq(4)
    end
  end

  it "reopens with what an earlier run kept" do
    in_store do |tree, store, directory|
      digest = place(tree, "a.rb", "persisted")
      store.keep("a.rb", digest)

      reopened = ContentStore.open(directory.root, tree.root)
      raise "the store could not be reopened" if reopened.is_a?(Problem)

      reopened.holds?(digest).should be_true
    end
  end
end
