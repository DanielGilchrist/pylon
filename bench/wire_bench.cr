require "../src/pylon/discard"
require "../src/pylon/scan/scanner"
require "../src/pylon/disk"
require "../src/pylon/wire/binary"

include Pylon

IGNORES = Scan::Ignores.new(%w[.git node_modules tmp log vendor/bundle .ruby-lsp flow-typed .idea])

root = ARGV[0]
snapshot = Scan::Scanner.new(Pylon::Disk.new(root), Scan::Cache.new, Time.utc.to_unix_ns.to_i64, IGNORES, baseline: nil, recheck: Set(String).new, tally: Scan::Tally.new, keeper: Pylon::Discard.new).scan

buffer = IO::Memory.new
started = Time.instant
Pylon::Wire::Binary.write_entry(buffer, snapshot.root)
encode = Time.instant - started

buffer.rewind
started = Time.instant
Pylon::Wire::Binary.read_entry(Pylon::Wire::Reader.new(buffer))
decode = Time.instant - started

puts "entries:  #{snapshot.cache.size} files"
puts "encoded:  #{buffer.size // 1024} KiB"
puts "encode:   #{encode.total_milliseconds.round(1)} ms"
puts "decode:   #{decode.total_milliseconds.round(1)} ms"
puts "per cycle (encode+decode): #{(encode + decode).total_milliseconds.round(1)} ms"
