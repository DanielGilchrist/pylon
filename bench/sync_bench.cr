require "../src/pylon/prelude"
require "file_utils"

include Pylon

USAGE = <<-TEXT
  usage: sync_bench <scenario> ...

    push [files]                  generate <files> locally, push them to an empty remote
    pull [files]                  generate <files> on the remote, pull them to an empty local
    edit [files] [edited]         populate both sides, edit <edited> files, then rename a directory
    flip <local> <remote> <cmd>   converge two real trees, run <cmd> in <local>, sync the result

  environment:
    BENCH_BINARY       server binary (default bin/pylon)
    BENCH_LATENCY_MS   one-way delay through bench/latency_proxy
    BENCH_RATE_BYTES   bandwidth cap in bytes per second through bench/latency_proxy
    BENCH_COMPRESSION  zstd level for content (default 1)
    BENCH_STORE        directory for the local content store (enables dictionary frames)
    BENCH_REMOTE_STATE state path for the remote, so it keeps content and its tree between runs
    BENCH_IGNORE       comma separated ignore list for flip (default .git)
    BENCH_WATCH        0 to run a non-watching remote that re-sends its tree every cycle
  TEXT

SEED    = 42_u64
WORDS   = %w[def end class module require include return case when nil true false property getter]
BINARY  = ENV["BENCH_BINARY"]? || File.expand_path("../bin/pylon", __DIR__)
LEVEL   = (ENV["BENCH_COMPRESSION"]? || "1").to_i
IGNORES = (ENV["BENCH_IGNORE"]? || ".git").split(',')

record Corpus, paths : Array(String), bytes : Int64

def generate(root : String, files : Int32) : Corpus
  random = Random.new(SEED)
  paths = Array(String).new(files)
  bytes = 0_i64

  files.times do |index|
    directory = File.join(root, "src", "part#{index % 40}", "group#{(index // 40) % 25}")
    Dir.mkdir_p(directory)
    weight = random.rand(100)
    lines =
      if weight < 80
        random.rand(10..80)
      elsif weight < 95
        random.rand(80..1200)
      else
        random.rand(1200..20_000)
      end
    path = File.join(directory, "file#{index}.cr")

    File.open(path, "w") do |file|
      lines.times do |line|
        file << WORDS[random.rand(WORDS.size)] << " item" << line << ' '
        file << WORDS[random.rand(WORDS.size)] << '\n'
      end
    end

    bytes += File.size(path)
    paths << path
  end

  Corpus.new(paths, bytes)
end

def mib(bytes : Int64) : String
  (bytes / (1024.0 * 1024.0)).round(1).to_s
end

def open_transport : Session::ProcessTransport
  latency = ENV["BENCH_LATENCY_MS"]?
  rate = ENV["BENCH_RATE_BYTES"]?

  opened =
    if latency || rate
      proxy = File.expand_path("../bin/latency_proxy", __DIR__)
      unless File.exists?(proxy)
        abort("build first: crystal build --release -o bin/latency_proxy bench/latency_proxy.cr")
      end

      arguments = [latency || "0", rate || "0", BINARY, "remote"]
      Session::ProcessTransport.open(proxy, arguments) { |line| STDERR.puts(line) }
    else
      Session::ProcessTransport.open(BINARY, ["remote"]) { |line| STDERR.puts(line) }
    end

  abort("the server could not be started: #{opened.reason}") if opened.is_a?(Problem)
  opened
end

record Pair,
  session : Session::Session(Session::LocalEndpoint, Session::RemoteEndpoint, Discard),
  local : Session::LocalEndpoint,
  remote : Session::RemoteEndpoint,
  transport : Session::ProcessTransport

def pair(local_root : String, remote_root : String, *, local_wins : Bool) : Pair
  unless File.exists?(BINARY)
    abort("build first: crystal build --release -o bin/pylon src/pylon.cr")
  end

  transport = open_transport
  local = Session::LocalEndpoint.new(local_root, Scan::Ignores.new(IGNORES), compression: LEVEL)

  if (directory = ENV["BENCH_STORE"]?)
    store = Session::ContentStore.open(directory, local_root)
    abort("the content store could not be opened: #{store.reason}") if store.is_a?(Problem)
    local.kept = store
  end

  configure = Wire::Message::Configure.new(
    root: remote_root,
    ignores: IGNORES,
    compression: LEVEL,
    brand: Brand::DEFAULT,
    state: ENV["BENCH_REMOTE_STATE"]?,
    watch: ENV["BENCH_WATCH"]? != "0",
    tree_fingerprint: nil,
  )
  remote = Session::RemoteEndpoint.new(transport.reader, transport.writer, configure, resume: nil)
  preferences = Core::Preferences.build(Array(String).new, Array(String).new)
  abort("empty preferences did not build") if preferences.is_a?(Problem)

  session = Session::Session.new(
    local,
    remote,
    preferences: preferences,
    base: nil,
    dry_run: false,
    push_first: local_wins,
    narrator: Discard.new,
  )

  Pair.new(session, local, remote, transport)
end

def cycle(pair : Pair, label : String) : Session::Report
  exchanges = pair.remote.exchanges
  started = Time.instant
  report = pair.session.cycle(Time.utc.to_unix_ns.to_i64)
  abort("the session faulted: #{report.explain}") if report.is_a?(Session::Fault)

  applied = report.remote_outcomes.count(&.applied?) + report.local_outcomes.count(&.applied?)
  skipped = report.skipped.size
  detail = skipped.zero? ? "" : ", #{skipped} skipped"
  seconds = (Time.instant - started).total_seconds.round(2)
  puts "#{label.ljust(12)} #{seconds}s, #{applied} applied#{detail}, " \
       "#{pair.remote.exchanges - exchanges} round trips"
  report.skipped.first(3).each do |outcome|
    puts "  skipped #{outcome.path}: #{outcome.explanation}"
  end
  report
end

def with_roots(& : String, String ->) : Nil
  work = File.tempname("pylon-bench")
  local_root = File.join(work, "local")
  remote_root = File.join(work, "remote")
  Dir.mkdir_p(local_root)
  Dir.mkdir_p(remote_root)

  begin
    yield local_root, remote_root
  ensure
    FileUtils.rm_rf(work)
  end
end

def push(files : Int32) : Nil
  with_roots do |local_root, remote_root|
    corpus = generate(local_root, files)
    puts "tree:        #{files} files, #{mib(corpus.bytes)} MiB"
    bench = pair(local_root, remote_root, local_wins: true)
    cycle(bench, "push")
    puts "verify:      quiet=#{cycle(bench, "no-op").quiet?}"
    bench.transport.close
  end
end

def pull(files : Int32) : Nil
  with_roots do |local_root, remote_root|
    corpus = generate(remote_root, files)
    puts "tree:        #{files} files, #{mib(corpus.bytes)} MiB on the remote"
    bench = pair(local_root, remote_root, local_wins: false)
    cycle(bench, "pull")
    puts "verify:      quiet=#{cycle(bench, "no-op").quiet?}"
    bench.transport.close
  end
end

def edit(files : Int32, edited : Int32) : Nil
  with_roots do |local_root, remote_root|
    corpus = generate(local_root, files)
    FileUtils.rm_rf(remote_root)
    Process.run("cp", ["-R", local_root, remote_root])
    puts "tree:        #{files} files, #{mib(corpus.bytes)} MiB, remote pre-populated"
    bench = pair(local_root, remote_root, local_wins: true)
    cycle(bench, "converge")

    dirty = 0_i64
    corpus.paths.sample(edited, Random.new(SEED)).each do |path|
      File.open(path, "a") { |file| file << "record edited_marker\n" }
      dirty += File.size(path)
    end
    puts "edited:      #{edited} files, #{mib(dirty)} MiB of content now dirty"
    cycle(bench, "edit sync")

    source = File.join(local_root, "src", "part0")
    File.rename(source, File.join(local_root, "src", "part0_renamed"))
    puts "renamed:     src/part0 -> src/part0_renamed"
    cycle(bench, "move sync")
    puts "verify:      quiet=#{cycle(bench, "no-op").quiet?}"
    bench.transport.close
  end
end

def flip(local_root : String, remote_root : String, command : String) : Nil
  bench = pair(local_root, remote_root, local_wins: true)
  cycle(bench, "converge")
  puts "tree:        #{bench.local.cache.size} files"

  status = Process.run("sh", ["-c", command], chdir: local_root, output: STDOUT, error: STDERR)
  abort("the flip command failed") unless status.success?
  puts "flipped:     #{command}"

  cycle(bench, "flip sync")
  puts "verify:      quiet=#{cycle(bench, "no-op").quiet?}"
  bench.transport.close
end

case ARGV[0]?
when "push" then push((ARGV[1]? || "10000").to_i)
when "pull" then pull((ARGV[1]? || "10000").to_i)
when "edit" then edit((ARGV[1]? || "10000").to_i, (ARGV[2]? || "2000").to_i)
when "flip"
  abort(USAGE) unless ARGV.size == 4
  flip(ARGV[1], ARGV[2], ARGV[3])
else
  abort(USAGE)
end
