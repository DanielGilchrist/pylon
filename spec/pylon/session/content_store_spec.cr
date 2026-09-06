require "../../spec_helper"

require "digest/sha256"
require "file_utils"

private alias ContentStore = Pylon::Session::ContentStore
private alias Locations = Pylon::Session::Locations
private ORPHAN_LIMIT = Pylon::Session::ContentStore::ORPHAN_LIMIT
private alias Problem = Pylon::Problem

private def in_store(& : String, ContentStore, String ->) : Nil
  base = File.join(Dir.tempdir, "pylon-store-#{Random::Secure.hex(8)}")
  tree = File.join(base, "tree")
  directory = File.join(base, "store")
  Dir.mkdir_p(tree)

  opened = ContentStore.open(directory, tree)
  raise "the store could not be opened: #{opened.reason}" if opened.is_a?(Problem)

  begin
    yield tree, opened, directory
  ensure
    FileUtils.rm_rf(base)
  end
end

private def place(tree : String, name : String, content : String) : Bytes
  File.write(File.join(tree, name), content)
  Digest::SHA256.digest(content).to_slice
end

describe ContentStore do
  it "recovers a kept file after it was deleted" do
    in_store do |tree, store, _|
      digest = place(tree, "a.rb", "version one")
      store.keep("a.rb", digest)
      File.delete(File.join(tree, "a.rb"))

      store.holds?(digest).should be_true
      store.held([digest, Bytes.new(32, 9_u8)]).should eq([digest])
      String.new(store.content(digest) || Bytes.empty).should eq("version one")
    end
  end

  it "recovers a kept file after it was replaced by rename" do
    in_store do |tree, store, _|
      digest = place(tree, "a.rb", "version one")
      store.keep("a.rb", digest)
      File.write(File.join(tree, "a.rb.tmp"), "version two")
      File.rename(File.join(tree, "a.rb.tmp"), File.join(tree, "a.rb"))

      String.new(store.content(digest) || Bytes.empty).should eq("version one")
    end
  end

  it "forgets content that no longer matches its digest" do
    in_store do |tree, store, directory|
      digest = place(tree, "a.rb", "original")
      File.write(File.join(tree, "a.rb"), "changed before the snapshot")
      store.keep("a.rb", digest)

      store.content(digest).should be_nil
      store.holds?(digest).should be_false
      Dir.children(directory).should be_empty
    end
  end

  it "ignores a path that no longer exists" do
    in_store do |_, store, directory|
      store.keep("vanished.rb", Bytes.new(32, 1_u8))

      store.holds?(Bytes.new(32, 1_u8)).should be_false
      Dir.children(directory).should be_empty
    end
  end

  it "prunes orphans past the bound and keeps what the tree still holds" do
    in_store do |tree, _, directory|
      kept = Array.new(3) { |index| place(tree, "kept#{index}", "kept #{index}") }
      kept.each { |digest| File.write(File.join(directory, digest.hexstring), "") }
      (ORPHAN_LIMIT + 5).times do |index|
        File.write(File.join(directory, Digest::SHA256.hexdigest(index.to_s)), "")
      end

      reopened = ContentStore.open(directory, tree)
      raise "the store could not be reopened" if reopened.is_a?(Problem)
      live = Locations.new
      kept.each_with_index { |digest, index| live.remember(digest, "kept#{index}", 0_u64) }

      reopened.prune(live)

      reopened.held(kept).should eq(kept)
      Dir.children(directory).size.should eq(ORPHAN_LIMIT + kept.size)
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
      Dir.children(directory).size.should eq(4)
    end
  end

  it "reopens with what an earlier run kept" do
    in_store do |tree, store, directory|
      digest = place(tree, "a.rb", "persisted")
      store.keep("a.rb", digest)

      reopened = ContentStore.open(directory, tree)
      raise "the store could not be reopened" if reopened.is_a?(Problem)

      reopened.holds?(digest).should be_true
    end
  end
end
