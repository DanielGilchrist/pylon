{% skip_file unless flag?(:darwin) %}

require "digest/sha256"
require "file_utils"
require "../../spec_helper"
require "../../../src/pylon/session/content_store"

include Pylon::Session

private def in_store(& : String, ContentStore, String ->) : Nil
  base = File.join(Dir.tempdir, "pylon-store-#{Random::Secure.hex(8)}")
  tree = File.join(base, "tree")
  directory = File.join(base, "store")
  Dir.mkdir_p(tree)

  opened = ContentStore.open(directory)
  raise "the store could not be opened: #{opened.reason}" if opened.is_a?(ContentStore::Unavailable)

  begin
    yield tree, opened, directory
  ensure
    FileUtils.rm_rf(base)
  end
end

private def write_source(tree : String, name : String, content : String) : ContentStore::Retention
  path = File.join(tree, name)
  File.write(path, content)
  ContentStore::Retention.new(path, Digest::SHA256.digest(content))
end

describe Pylon::Session::ContentStore do
  it "keeps a copy that survives the source changing afterwards" do
    in_store do |tree, store, _|
      retention = write_source(tree, "a.rb", "version one")
      store.retain([retention])

      File.write(retention.source, "version two")

      store.retained?(retention.digest).should be_true
      String.new(store.content(retention.digest) || Bytes.empty).should eq("version one")
    end
  end

  it "refuses to file content under a digest it no longer matches" do
    in_store do |tree, store, directory|
      retention = write_source(tree, "a.rb", "original")
      File.write(retention.source, "changed before the clone")

      store.retain([retention])

      store.retained?(retention.digest).should be_false
      Dir.children(directory).should be_empty
    end
  end

  it "captures many files at once" do
    in_store do |tree, store, _|
      retentions = Array.new(50) { |index| write_source(tree, "f#{index}.rb", "body #{index}") }

      store.retain(retentions)

      retentions.each { |retention| String.new(store.content(retention.digest) || Bytes.empty).should eq(File.read(retention.source)) }
    end
  end

  it "prunes everything that is not kept" do
    in_store do |tree, store, directory|
      keep = write_source(tree, "a.rb", "keep me")
      drop = write_source(tree, "b.rb", "drop me")
      store.retain([keep, drop])

      store.prune(Set{keep.digest})

      store.retained?(keep.digest).should be_true
      store.retained?(drop.digest).should be_false
      store.content(drop.digest).should be_nil
      Dir.children(directory).size.should eq(1)
    end
  end

  it "lists what it holds when reopened" do
    in_store do |tree, store, directory|
      retention = write_source(tree, "a.rb", "kept across runs")
      store.retain([retention])

      reopened = ContentStore.open(directory)

      reopened.should be_a(ContentStore)
      reopened.retained?(retention.digest).should be_true if reopened.is_a?(ContentStore)
    end
  end

  it "discards an entry whose content no longer matches its digest" do
    in_store do |tree, store, directory|
      retention = write_source(tree, "a.rb", "trustworthy")
      store.retain([retention])
      File.write(File.join(directory, retention.digest.hexstring), "tampered")

      store.content(retention.digest).should be_nil
      store.retained?(retention.digest).should be_false
      File.exists?(File.join(directory, retention.digest.hexstring)).should be_false
    end
  end
end
