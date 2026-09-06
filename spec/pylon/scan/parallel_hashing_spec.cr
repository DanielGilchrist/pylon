require "../../spec_helper"

require "digest/sha256"

private FILES = 400

private def in_tree(& : Sandbox ->) : Nil
  Sandbox.open do |root|
    nested = root.directory("nested")

    FILES.times do |index|
      directory = index.even? ? root : nested
      directory.write("file_#{index}.txt", "content #{index}\n" * (index % 7 + 1))
    end

    yield root
  end
end

private def digests(root : Sandbox, parallelism : Int32) : Hash(String, String)
  snapshot = Pylon::Scan::Scanner.new(
    Pylon::Disk.new(root.root),
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
        Digest::SHA256.digest(root.read(path).to_slice).hexstring.should eq(hex)
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
end
