require "../src/pylon/scan/scanner"
require "../src/pylon/scan/disk"
require "../src/pylon/session/store"

include Pylon

IGNORES = Scan::Ignores.new(%w[.git node_modules tmp log vendor/bundle .ruby-lsp flow-typed .idea])

def allocated(label, &)
  before = GC.stats.total_bytes
  result = yield
  puts "  %-28s %8.1f MiB" % [label, (GC.stats.total_bytes - before) / 1048576.0]
  result
end

root = ARGV[0]
filesystem = Scan::Disk.new(root)
now = Time.utc.to_unix_ns.to_i64

puts "cold scan of #{root}:"
cold = allocated("full scan + hashing") { Scan::Scanner.new(filesystem, Scan::Cache.new, now, IGNORES).scan }
puts "  files: #{cold.cache.size}"

puts "warm scan (cache hit, no hashing):"
allocated("stat only") { Scan::Scanner.new(filesystem, cold.cache, now, IGNORES).scan }

puts "accelerated scan (nothing dirty):"
allocated("baseline reuse") { Scan::Scanner.new(filesystem, cold.cache, now, IGNORES, baseline: cold.root).scan }

puts "reading every file's bytes:"
allocated("contents of 500 files") do
  cold.cache.keys.first(500).each { |path| filesystem.read(path) }
end

puts "state file:"
state = Pylon::Session::State.new(cold.root, cold.cache)
path = File.join(Dir.tempdir, "alloc-state-#{Random::Secure.hex(4)}")
allocated("save") { Pylon::Session::Store.save(path, state) }
allocated("load") { Pylon::Session::Store.load(path) }
File.delete?(path)
