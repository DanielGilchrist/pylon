require "benchmark"
require "../src/pylon/core"
require "../src/pylon/scan/scanner"
require "../src/pylon/disk"

include Pylon::Core
include Pylon::Scan

IGNORES = Ignores.new(%w[
  .git .idea .code flow-typed log node_modules tmp
  vendor/bundle .ruby-lsp vc_sidecar .claude/worktrees .agents
])

root = ARGV[0]? || abort("usage: scan_bench <root>")
now = Time.utc.to_unix_ns.to_i64
parallelism = (ARGV[1]? || Scanner::DEFAULT_PARALLELISM).to_i
filesystem = Pylon::Disk.new(root)

puts "root: #{root} (parallelism #{parallelism})"

started = Time.instant
cold = Scanner.new(filesystem, Cache.new, now, IGNORES, baseline: nil, recheck: Set(String).new, tally: Tally.new, parallelism: parallelism).scan
cold_elapsed = Time.instant - started

files = cold.cache.size
bytes = 0_u64
cold.cache.each_value { |entry| bytes += entry.metadata.size }

puts "files hashed: #{files}"
puts "bytes hashed: #{bytes // 1_048_576} MiB"
puts "cold scan:    #{cold_elapsed.total_milliseconds.round(1)} ms"

started = Time.instant
warm = Scanner.new(filesystem, cold.cache, now + 60_000_000_000_i64, IGNORES, baseline: nil, recheck: Set(String).new, tally: Tally.new).scan
warm_elapsed = Time.instant - started

puts "warm scan:    #{warm_elapsed.total_milliseconds.round(1)} ms"
puts "identical:    #{cold.root == warm.root}"
puts

started = Time.instant
base = cold.root.try(&.syncable)
preferences = Pylon::Core::Preferences.build(Array(String).new, Array(String).new)
raise "expected empty preferences to build" if preferences.is_a?(Pylon::Core::Preferences::Invalid)
reconciliation = Reconciler.reconcile(base, cold.root, warm.root, preferences)
quiet = reconciliation.local_changes.empty? && reconciliation.remote_changes.empty? && reconciliation.conflicts.empty?
puts "reconcile:    #{(Time.instant - started).total_milliseconds.round(2)} ms (#{quiet ? "no changes" : "changes"})"
