require "../src/pylon/session/local_endpoint"
require "../src/pylon/session/remote_endpoint"
require "../src/pylon/session/process_transport"
require "../src/pylon/session/session"

include Pylon

SEED = 42_u64

files = (ARGV[0]? || "10000").to_i
binary = ARGV[1]? || File.expand_path("../bin/pylon", __DIR__)

unless File.exists?(binary)
  STDERR.puts("build first: crystal build --release -o bin/pylon src/pylon.cr")
  exit(1)
end

work = File.tempname("pylon-bulk")
local_root = File.join(work, "local")
remote_root = File.join(work, "remote")
Dir.mkdir_p(remote_root)

random = Random.new(SEED)
words = %w[def end class module require include return case when nil true false property getter struct record alias]
total_bytes = 0_i64

generated = Time.instant

files.times do |index|
  directory = File.join(local_root, "src", "part#{index % 40}", "group#{(index // 40) % 25}")
  Dir.mkdir_p(directory)

  weight = random.rand(100)
  lines = weight < 80 ? random.rand(10..80) : weight < 95 ? random.rand(80..1200) : random.rand(1200..20_000)

  File.open(File.join(directory, "file#{index}.cr"), "w") do |file|
    lines.times do |line|
      file << words[random.rand(words.size)] << " item" << line << " " << words[random.rand(words.size)] << "\n"
    end
  end

  total_bytes += File.size(File.join(directory, "file#{index}.cr"))
end

puts "tree:      #{files} files, #{(total_bytes / (1024.0 * 1024.0)).round(1)} MiB (generated in #{(Time.instant - generated).total_seconds.round(1)}s)"

level = (ENV["BULK_COMPRESSION"]? || "1").to_i

opened =
  if (latency = ENV["BULK_LATENCY_MS"]?) || ENV["BULK_RATE_BYTES"]?
    proxy = File.expand_path("../bin/latency_proxy", __DIR__)

    unless File.exists?(proxy)
      STDERR.puts("build first: crystal build --release -o bin/latency_proxy bench/latency_proxy.cr")
      exit(1)
    end

    rate = ENV["BULK_RATE_BYTES"]? || "0"
    Session::ProcessTransport.open(proxy, [latency || "0", rate, binary, "remote"]) { |line| STDERR.puts(line) }
  else
    Session::ProcessTransport.open(binary, ["remote"]) { |line| STDERR.puts(line) }
  end

transport =
  case opened
  in Pylon::Problem            then abort("the server could not be started: #{opened.reason}")
  in Session::ProcessTransport then opened
  end

left = Session::LocalEndpoint.new(local_root, Scan::Ignores::NONE, compression: level)
right = Session::RemoteEndpoint.new(transport.reader, transport.writer, Pylon::Wire::Message::Configure.new(root: remote_root, ignores: Array(String).new, compression: level, brand: Pylon::Brand::DEFAULT, state: nil, watch: false))
preferences = Core::Preferences.build(Array(String).new, Array(String).new)
raise "expected empty preferences to build" if preferences.is_a?(Core::Preferences::Invalid)
session = Session::Session.new(left, right, preferences: preferences, base: nil, dry_run: false, push_first: true, on_progress: nil)

started = Time.instant
report = session.cycle(Time.utc.to_unix_ns.to_i64)
abort("the session faulted: #{report.explain}") if report.is_a?(Session::Fault)
elapsed = Time.instant - started

applied = report.remote_outcomes.count(&.applied?)
skipped = report.remote_outcomes.count { |outcome| !outcome.applied? }

puts "bulk push: #{elapsed.total_seconds.round(2)}s (#{(total_bytes / (1024.0 * 1024.0) / elapsed.total_seconds).round(1)} MiB/s)"
puts "outcomes:  #{applied} applied, #{skipped} skipped, #{report.conflicts.size} conflicts, halted=#{report.halted?}"
puts "roundtrip: #{right.exchanges} exchanges"

verify_started = Time.instant
second = session.cycle(Time.utc.to_unix_ns.to_i64)
abort("the session faulted: #{second.explain}") if second.is_a?(Session::Fault)
puts "verify:    converged=#{second.quiet?} (no-op cycle #{(Time.instant - verify_started).total_seconds.round(2)}s)"

synced = Dir.glob(File.join(remote_root, "**", "*")).count { |path| File.file?(path) }
puts "remote:    #{synced} files on disk"

memory = GC.stats
puts "client GC: #{(memory.total_bytes / (1024.0 * 1024.0)).round(0)} MiB allocated over the run"

transport.close
FileUtils.rm_rf(work)
