require "../../spec_helper"

require "digest/sha256"
require "file_utils"

private FILES = 400

private def in_tree(& : String ->) : Nil
  root = File.join(Dir.tempdir, "pylon-hash-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(File.join(root, "nested"))

  FILES.times do |index|
    directory = index.even? ? root : File.join(root, "nested")
    File.write(File.join(directory, "file_#{index}.txt"), "content #{index}\n" * (index % 7 + 1))
  end

  begin
    yield root
  ensure
    FileUtils.rm_rf(root)
  end
end

private def digests(root : String, parallelism : Int32) : Hash(String, String)
  snapshot = Pylon::Scan::Scanner.new(
    Pylon::Disk.new(root),
    Pylon::Scan::Cache.new,
    Time.utc.to_unix_ns.to_i64,
    Pylon::Scan::Ignores::NONE,
    previous_tree: nil,
    recheck: Set(String).new,
    scanned: Pylon::Progress.new, keeper: Pylon::Discard.new,
    parallelism: parallelism,
  ).scan

  hexed = Hash(String, String).new
  snapshot.cache.each { |path, entry| hexed[path] = entry.digest.hexstring }
  hexed
end

describe "parallel hashing" do
  it "agrees with the digest of the bytes on disk" do
    in_tree do |root|
      computed = digests(root, 16)

      computed.size.should eq(FILES)

      computed.each do |path, hex|
        Digest::SHA256.digest(File.read(File.join(root, path)).to_slice).hexstring.should eq(hex)
      end
    end
  end

  it "gives the same answer however many workers run" do
    in_tree do |root|
      serial = digests(root, 1)

      {2, 8, 16}.each do |parallelism|
        digests(root, parallelism).should eq(serial)
      end
    end
  end

  it "gives the same answer twice in a row" do
    in_tree do |root|
      digests(root, 16).should eq(digests(root, 16))
    end
  end
end
