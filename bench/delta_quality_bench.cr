require "../src/pylon/compress/prefix"
require "../src/pylon/compress/zstd"
require "../src/pylon/wire/delta"

include Pylon

repo = ARGV[0]? || abort("usage: delta_quality_bench <git repo> <from rev> <to rev>")
from = ARGV[1]? || abort("a from revision is required")
to = ARGV[2]? || abort("a to revision is required")
level = (ENV["BULK_COMPRESSION"]? || "9").to_i
gate = (ENV["BULK_DELTA_GATE"]? || Wire::Delta::SMALLEST_DELTA_FILE.to_s).to_u64

record Pair, path : String, old : Bytes, new : Bytes

class Catalogue
  def initialize(repo : String) : Nil
    @process = Process.new("git", ["-C", repo, "cat-file", "--batch"], input: :pipe, output: :pipe, error: :inherit)
  end

  def blob(spec : String) : Bytes?
    @process.input << spec << '\n'
    @process.input.flush
    header = @process.output.gets
    return if header.nil? || header.ends_with?(" missing")

    size = header.split(' ')[2].to_i
    content = Bytes.new(size)
    @process.output.read_fully(content)
    @process.output.read_byte
    content
  end

  def close : Nil
    @process.input.close
    @process.wait
  end
end

def packed_size(codec : Compress::Zstd, source : Bytes) : Int64
  packed = codec.compress(source, Bytes.new(codec.bound(source.size)))
  abort("compression failed: #{packed.message}") if packed.is_a?(Compress::Error)
  packed.size.to_i64
end

def mib(bytes : Int64) : String
  (bytes / 1_048_576.0).round(2).to_s
end

def patch_from_size(old_path : String, new_path : String, level : Int32) : Int64
  output = IO::Memory.new
  Process.run("zstd", ["-#{level}", "-q", "-c", "--patch-from=#{old_path}", new_path], output: output)
  output.size.to_i64
end

listing = IO::Memory.new
Process.run("git", ["-C", repo, "diff", "--name-only", "--diff-filter=M", "-z", from, to], output: listing)
paths = listing.to_s.split('\0').reject(&.empty?)

catalogue = Catalogue.new(repo)
codec = Compress::Zstd.new(level)
prefix = Compress::Prefix.new
prefixed = 0_i64
prefixed_time = Time::Span.zero
scratch_old = File.tempname("delta-old")
scratch_new = File.tempname("delta-new")

raw = 0_i64
full = 0_i64
rsync_ops = 0_i64
rsync_signatures = 0_i64
rsync_gave_up = 0
rsync_gave_up_bytes = 0_i64
below_gate = 0
below_gate_bytes = 0_i64
patch_from = 0_i64
offenders = Array({String, Int64, Int64, Int64}).new

paths.each do |path|
  old = catalogue.blob("#{from}:#{path}")
  new = catalogue.blob("#{to}:#{path}")
  next if old.nil? || new.nil?

  raw += new.size
  full_packed = packed_size(codec, new)
  full += full_packed

  unless gate <= new.size.to_u64 <= Wire::Delta::LARGEST_DELTA_FILE && gate <= old.size.to_u64 <= Wire::Delta::LARGEST_DELTA_FILE
    below_gate += 1
    below_gate_bytes += full_packed
    rsync_ops += full_packed
    patch_from += full_packed
    next
  end

  signature = Wire::Delta.signature(old)
  rsync_signatures += 12 + signature.blocks.size * (4 + Wire::Delta::STRONG_BYTES)
  ops = Wire::Delta.compute(new, signature)

  rsync_cost =
    if ops.nil?
      rsync_gave_up += 1
      rsync_gave_up_bytes += full_packed
      full_packed
    else
      packed_size(codec, ops)
    end

  rsync_ops += rsync_cost

  File.write(scratch_old, old)
  File.write(scratch_new, new)
  patched = patch_from_size(scratch_old, scratch_new, level)
  patch_from += patched

  started = Time.instant
  frame = prefix.compress(new, old, Bytes.new(Compress::Zstd.bound(new.size)))
  prefixed_time += Time.instant - started
  abort("prefix compression failed: #{frame.message}") if frame.is_a?(Compress::Error)
  prefixed += frame.size

  offenders << {path, full_packed, rsync_cost, patched}
end

catalogue.close
File.delete?(scratch_old)
File.delete?(scratch_new)

added = IO::Memory.new
Process.run("git", ["-C", repo, "diff", "--name-only", "--diff-filter=A", "-z", from, to], output: added)
added_packed = 0_i64
added_raw = 0_i64
added_catalogue = Catalogue.new(repo)
added.to_s.split('\0').reject(&.empty?).each do |path|
  content = added_catalogue.blob("#{to}:#{path}")
  next if content.nil?

  added_raw += content.size
  added_packed += packed_size(codec, content)
end
added_catalogue.close

puts "added files:           #{mib(added_raw)} MiB raw, #{mib(added_packed)} MiB packed upstream"
puts "modified files:        #{paths.size} (#{below_gate} below the #{gate // 1024} KiB gate, #{mib(below_gate_bytes)} MiB packed, shipped full by every strategy)"
puts "raw new content:       #{mib(raw)} MiB"
puts "full zstd-#{level}:           #{mib(full)} MiB upstream"
puts "rsync delta (current): #{mib(rsync_ops)} MiB upstream (#{rsync_gave_up} gave up, #{mib(rsync_gave_up_bytes)} MiB of that is full sends) + #{mib(rsync_signatures)} MiB signatures downstream"
puts "zstd --patch-from:     #{mib(patch_from)} MiB upstream, no signatures"
puts "pylon prefix codec:    #{mib(prefixed + below_gate_bytes)} MiB upstream, #{prefixed_time.total_seconds.round(2)}s of compression"
puts
puts "largest rsync costs (path, full, rsync, patch-from in KiB):"
offenders.sort_by! { |_, _, rsync, _| -rsync }
offenders.first(12).each do |path, full_packed, rsync, patched|
  puts "  #{path[0, 70].ljust(70)} #{(full_packed // 1024).to_s.rjust(6)} #{(rsync // 1024).to_s.rjust(6)} #{(patched // 1024).to_s.rjust(6)}"
end
