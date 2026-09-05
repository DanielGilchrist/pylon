require "../src/pylon/session/content_store"
require "../src/pylon/session/local_endpoint"
require "../src/pylon/session/remote_endpoint"
require "../src/pylon/session/process_transport"
require "../src/pylon/session/session"

include Pylon

SEED = 42_u64

files = (ARGV[0]? || "10000").to_i
edited = (ARGV[1]? || "2000").to_i
binary = ARGV[2]? || File.expand_path("../bin/pylon", __DIR__)

unless File.exists?(binary)
  STDERR.puts("build first: crystal build --release -o bin/pylon src/pylon.cr")
  exit(1)
end

work = File.tempname("pylon-incremental")
local_root = File.join(work, "local")
remote_root = File.join(work, "remote")

random = Random.new(SEED)
words = %w[def end class module require include return case when nil true false property getter struct record alias]
total_bytes = 0_i64
paths = Array(String).new(files)

files.times do |index|
  directory = File.join(local_root, "src", "part#{index % 40}", "group#{(index // 40) % 25}")
  Dir.mkdir_p(directory)

  weight = random.rand(100)
  lines = weight < 80 ? random.rand(10..80) : weight < 95 ? random.rand(80..1200) : random.rand(1200..20_000)
  path = File.join(directory, "file#{index}.cr")

  File.open(path, "w") do |file|
    lines.times do |line|
      file << words[random.rand(words.size)] << " item" << line << " " << words[random.rand(words.size)] << "\n"
    end
  end

  total_bytes += File.size(path)
  paths << path
end

Process.run("cp", ["-R", local_root, remote_root])

puts "tree:      #{files} files, #{(total_bytes / (1024.0 * 1024.0)).round(1)} MiB, remote pre-populated"

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
if (store_directory = ENV["BULK_STORE"]?)
  case (store = Session::ContentStore.open(store_directory, local_root))
  in Session::ContentStore              then left.store = store
  in Session::ContentStore::Unavailable then abort("the content store could not be opened: #{store.reason}")
  end
end

right = Session::RemoteEndpoint.new(transport.reader, transport.writer, Pylon::Wire::Message::Configure.new(root: remote_root, ignores: Array(String).new, compression: level, brand: Pylon::Brand::DEFAULT, state: nil, watch: false, known: nil), resume: nil)
preferences = Core::Preferences.build(Array(String).new, Array(String).new)
raise "expected empty preferences to build" if preferences.is_a?(Core::Preferences::Invalid)
session = Session::Session.new(left, right, preferences: preferences, base: nil, dry_run: false, push_first: true, on_progress: nil)

started = Time.instant
report = session.cycle(Time.utc.to_unix_ns.to_i64)
abort("the session faulted: #{report.explain}") if report.is_a?(Session::Fault)
puts "converge:  #{(Time.instant - started).total_seconds.round(2)}s, quiet=#{report.quiet?}"

edited_bytes = 0_i64
appended = 0_i64

paths.sample(edited, Random.new(SEED)).each do |path|
  File.open(path, "a") { |file| file << "record edited_marker\n" }
  appended += "record edited_marker\n".bytesize
  edited_bytes += File.size(path)
end

puts "edited:    #{edited} files, #{(edited_bytes / (1024.0 * 1024.0)).round(1)} MiB of file content now dirty, #{(appended / 1024.0).round(1)} KiB actually new"

started = Time.instant
report = session.cycle(Time.utc.to_unix_ns.to_i64)
abort("the session faulted: #{report.explain}") if report.is_a?(Session::Fault)
elapsed = Time.instant - started

applied = report.remote_outcomes.count(&.applied?)
puts "edit sync: #{elapsed.total_seconds.round(2)}s, #{applied} applied"

renamed_from = File.join(local_root, "src", "part0")
renamed_to = File.join(local_root, "src", "part0_renamed")
File.rename(renamed_from, renamed_to)
renamed_bytes = 0_i64
Dir.glob(File.join(renamed_to, "**", "*")).each { |path| renamed_bytes += File.size(path) if File.file?(path) }
puts "renamed:   src/part0 -> src/part0_renamed (#{(renamed_bytes / (1024.0 * 1024.0)).round(1)} MiB of unchanged content)"

started = Time.instant
report = session.cycle(Time.utc.to_unix_ns.to_i64)
abort("the session faulted: #{report.explain}") if report.is_a?(Session::Fault)
puts "move sync: #{(Time.instant - started).total_seconds.round(2)}s, #{report.remote_outcomes.count(&.applied?)} applied"

report.remote_outcomes.reject(&.applied?).first(5).each { |outcome| puts "  skipped #{outcome.path}: #{outcome.skipped.try(&.explain)}" }
puts "  #{report.remote_outcomes.size} outcomes total"

verify = session.cycle(Time.utc.to_unix_ns.to_i64)
abort("the session faulted: #{verify.explain}") if verify.is_a?(Session::Fault)
puts "move verify: quiet=#{verify.quiet?}"
synced = Dir.glob(File.join(remote_root, "src", "part0_renamed", "**", "*")).count { |path| File.file?(path) }
puts "  remote renamed dir holds #{synced} files"

transport.close
FileUtils.rm_rf(work)
