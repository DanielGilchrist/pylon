require "benchmark"
require "../src/pylon/session/local_endpoint"
require "../src/pylon/session/session"

include Pylon

IGNORES = %w[.git node_modules tmp log vendor/bundle .ruby-lsp flow-typed .idea]

local_root = ARGV[0]
remote_root = ARGV[1]
probe = File.join(local_root, "app", "models", "cycle_probe.rb")

ignores = Scan::Ignores.new(IGNORES)
left = Pylon::Session::LocalEndpoint.new(
  local_root,
  ignores,
  compression: Compress::Zstd::DEFAULT_LEVEL,
)
right = Pylon::Session::LocalEndpoint.new(
  remote_root,
  ignores,
  compression: Compress::Zstd::DEFAULT_LEVEL,
)
left.accelerate!
right.accelerate!

preferences = Core::Preferences.build(Array(String).new, Array(String).new)
raise "expected empty preferences to build" if preferences.is_a?(Core::Preferences::Invalid)
session = Pylon::Session::Session.new(
  left,
  right,
  preferences: preferences,
  base: nil,
  dry_run: false,
  push_first: false,
  on_progress: nil,
)

started = Time.instant
session.cycle(Time.utc.to_unix_ns.to_i64)
puts "cold cycle:        #{(Time.instant - started).total_milliseconds.round(1)} ms"

started = Time.instant
session.cycle(Time.utc.to_unix_ns.to_i64)
puts "no-op cycle:       #{(Time.instant - started).total_milliseconds.round(1)} ms"

3.times do |round|
  File.write(probe, "# round #{round}\n")
  left.mark_dirty(["app/models/cycle_probe.rb"])
  right.mark_dirty(["app/models/cycle_probe.rb"])

  started = Time.instant
  session.cycle(Time.utc.to_unix_ns.to_i64)
  puts "one-file cycle:    #{(Time.instant - started).total_milliseconds.round(1)} ms"
end

File.delete?(probe)
