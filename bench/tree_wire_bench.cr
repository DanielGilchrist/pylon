require "../src/pylon/core"
require "../src/pylon/core/digests"
require "../src/pylon/core/reconciler"
require "../src/pylon/discard"
require "../src/pylon/scan/scanner"
require "../src/pylon/disk"
require "../src/pylon/wire/chunks"
require "../src/pylon/wire/message"

include Pylon

root = ARGV[0]? || abort("usage: tree_wire_bench <root>")
ignores = Scan::Ignores.new((ENV["BULK_IGNORE"]? || ".git").split(','))
now = Time.utc.to_unix_ns.to_i64

snapshot = Scan::Scanner.new(
  Disk.new(root),
  Scan::Cache.new,
  now,
  ignores,
  baseline: nil,
  recheck: Set(String).new,
  tally: Scan::Tally.new,
  keeper: Pylon::Discard.new,
).scan
puts "files:         #{snapshot.cache.size}"

raw = IO::Memory.new
Wire::Binary.write_entry(raw, snapshot.root)
puts "tree raw:      #{(raw.size / 1024.0).round(1)} KiB"

started = Time.instant
packed = IO::Memory.new
Wire::Message.write(packed, Wire::Message::ScanResponse.new(snapshot.root))
encode = Time.instant - started
puts "tree on wire:  #{(packed.size / 1024.0).round(1)} KiB (encode+compress " \
     "#{encode.total_milliseconds.round(1)} ms)"

packed.rewind
started = Time.instant
decoded = Wire::Message.read(packed)
decode = Time.instant - started
puts "decode:        #{decode.total_milliseconds.round(1)} ms (#{decoded.class})"

started = Time.instant
digests = Core::Digests.all(snapshot.root)
puts "Digests.all:   #{(Time.instant - started).total_milliseconds.round(2)} ms (#{digests.size} " \
     "digests)"

preferences = Core::Preferences.build(Array(String).new, Array(String).new)
raise "expected empty preferences to build" if preferences.is_a?(Core::Preferences::Invalid)
base = snapshot.root.try(&.syncable)
started = Time.instant
reconciliation = Core::Reconciler.reconcile(base, snapshot.root, snapshot.root, preferences)
puts "reconcile same: #{(Time.instant - started).total_milliseconds.round(2)} ms " \
     "(#{reconciliation.local_changes.size} changes)"

if snapshot.root.is_a?(Core::Directory)
  copy = Wire::Message.read(packed.rewind)
  if copy.is_a?(Wire::Message::ScanResponse)
    started = Time.instant
    reconciliation = Core::Reconciler.reconcile(base, snapshot.root, copy.root, preferences)
    puts "reconcile copy: #{(Time.instant - started).total_milliseconds.round(2)} ms " \
         "(structurally equal decoded tree, #{reconciliation.local_changes.size} changes)"
  end
end
