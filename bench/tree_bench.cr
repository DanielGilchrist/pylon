require "../src/pylon/core"
require "../src/pylon/core/digests"
require "../src/pylon/discard"
require "../src/pylon/disk"
require "../src/pylon/scan/scanner"
require "../src/pylon/session/checkpoint"
require "../src/pylon/wire/message"

include Pylon

root = ARGV[0]? || abort("usage: tree_bench <root> [comma separated ignores]")
ignores = Scan::Ignores.new((ARGV[1]? || ".git").split(','))
disk = Disk.new(root)
now = Time.utc.to_unix_ns.to_i64

def measure(label : String, & : -> T) : T forall T
  allocated = GC.stats.total_bytes
  started = Time.instant
  result = yield
  elapsed = (Time.instant - started).total_milliseconds
  mebibytes = (GC.stats.total_bytes - allocated) / 1_048_576.0
  puts "  %-26s %9.1f ms %8.1f MiB allocated" % [label, elapsed, mebibytes]
  result
end

def scan(
  disk : Disk,
  cache : Scan::Cache,
  now : Int64,
  ignores : Scan::Ignores,
  previous_tree : Core::Entry?,
  recheck : Set(String) = Set(String).new,
) : Scan::Snapshot
  Scan::Scanner.new(
    disk,
    cache,
    now,
    ignores,
    previous_tree: previous_tree,
    recheck: recheck,
    scanned: Progress.new,
    keeper: Discard.new,
  ).scan
end

puts "scan #{root}:"
cold = measure("cold, hashing all") { scan(disk, Scan::Cache.new, now, ignores, nil) }
bytes = 0_i64
cold.cache.each { |_, entry| bytes += entry.metadata.size.to_i64 }
puts "  #{cold.cache.size} files, #{(bytes / 1_048_576.0).round(1)} MiB"
later = now + 60_000_000_000_i64
warm = measure("warm, metadata only") { scan(disk, cold.cache, later, ignores, nil) }
measure("watched, nothing dirty") { scan(disk, warm.cache, later, ignores, warm.root) }
one_file = warm.cache.paths.sort!.first
measure("watched, one dirty file") do
  scan(disk, warm.cache, later, ignores, warm.root, Set{one_file})
end

puts "tree on the wire:"
packed = IO::Memory.new
response = Wire::Message::ScanResponse.new(cold.root)
measure("encode + compress") { Wire::Message.write(packed, response) }
puts "  #{(packed.size / 1024.0).round(1)} KiB"
packed.rewind
measure("decode") { Wire::Message.read(packed) }

puts "per cycle:"
measure("Digests.all") { Core::Digests.all(cold.root) }
measure("Digests.fingerprint") { Core::Digests.fingerprint(cold.root) }
preferences = Core::Preferences.build(Array(String).new, Array(String).new)
abort("empty preferences did not build") if preferences.is_a?(Problem)
base = cold.root.try(&.syncable)
measure("reconcile, no changes") do
  Core::Reconciler.reconcile(base, cold.root, warm.root, preferences)
end

puts "state file:"
path = File.tempname("pylon-tree-bench")
measure("save") { Session::Checkpoint.new(cold.root, cold.cache, cold.root).save(path) }
measure("load") { Session::Checkpoint.load(path) }
puts "  #{(File.size(path) / 1024.0).round(1)} KiB"
File.delete?(path)
