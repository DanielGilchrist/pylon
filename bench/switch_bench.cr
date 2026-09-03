require "../src/pylon/session/local_endpoint"
require "../src/pylon/session/remote_endpoint"
require "../src/pylon/session/process_transport"
require "../src/pylon/session/session"

include Pylon

local_root = ARGV[0]? || abort("usage: switch_bench <local_root> <remote_root> <switch_command> [binary]")
remote_root = ARGV[1]? || abort("a remote root is required")
switch_command = ARGV[2]? || abort("a switch command is required")
binary = ARGV[3]? || File.expand_path("../bin/pylon", __DIR__)

unless File.exists?(binary)
  STDERR.puts("build first: crystal build --release -o bin/pylon src/pylon.cr")
  exit(1)
end

level = (ENV["BULK_COMPRESSION"]? || "1").to_i
ignore = ENV["BULK_IGNORE"]? || ".git"

remote_arguments = ["remote"]

opened =
  if (latency = ENV["BULK_LATENCY_MS"]?) || ENV["BULK_RATE_BYTES"]?
    proxy = File.expand_path("../bin/latency_proxy", __DIR__)

    unless File.exists?(proxy)
      STDERR.puts("build first: crystal build --release -o bin/latency_proxy bench/latency_proxy.cr")
      exit(1)
    end

    rate = ENV["BULK_RATE_BYTES"]? || "0"
    Session::ProcessTransport.open(proxy, [latency || "0", rate, binary] + remote_arguments) { |line| STDERR.puts(line) }
  else
    Session::ProcessTransport.open(binary, remote_arguments) { |line| STDERR.puts(line) }
  end

transport =
  case opened
  in Pylon::Problem            then abort("the server could not be started: #{opened.reason}")
  in Session::ProcessTransport then opened
  end

left = Session::LocalEndpoint.new(local_root, Scan::Ignores.new([ignore]), compression: level)
right = Session::RemoteEndpoint.new(transport.reader, transport.writer, Pylon::Wire::Message::Configure.new(root: remote_root, ignores: [ignore], compression: level, brand: Pylon::Brand::DEFAULT, state: nil, watch: false))
preferences = Core::Preferences.build(Array(String).new, Array(String).new)
raise "expected empty preferences to build" if preferences.is_a?(Core::Preferences::Invalid)
session = Session::Session.new(left, right, preferences: preferences, base: nil, dry_run: false, push_first: true, on_progress: nil)

started = Time.instant
report = session.cycle(Time.utc.to_unix_ns.to_i64)
abort("the session faulted: #{report.explain}") if report.is_a?(Session::Fault)
puts "converge:  #{(Time.instant - started).total_seconds.round(2)}s, quiet=#{report.quiet?}, #{left.cache.size} files"

status = Process.run("sh", ["-c", switch_command], output: STDOUT, error: STDERR)
abort("the switch command failed") unless status.success?
puts "switched:  #{switch_command}"

started = Time.instant
report = session.cycle(Time.utc.to_unix_ns.to_i64)
abort("the session faulted: #{report.explain}") if report.is_a?(Session::Fault)
elapsed = Time.instant - started

applied = report.remote_outcomes.count(&.applied?)
skipped = report.remote_outcomes.count { |outcome| !outcome.applied? }
puts "switch sync: #{elapsed.total_seconds.round(2)}s, #{applied} applied, #{skipped} skipped"

report.remote_outcomes.reject(&.applied?).first(5).each { |outcome| puts "  skipped #{outcome.path}: #{outcome.skipped.try(&.explain)}" }

started = Time.instant
verify = session.cycle(Time.utc.to_unix_ns.to_i64)
abort("the session faulted: #{verify.explain}") if verify.is_a?(Session::Fault)
puts "verify:    converged=#{verify.quiet?} (no-op cycle #{(Time.instant - started).total_seconds.round(2)}s)"

transport.close
