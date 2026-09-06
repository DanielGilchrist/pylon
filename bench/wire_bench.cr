require "../src/pylon/prelude"
require "digest/sha256"

include Pylon

repo = ARGV[0]? || abort("usage: wire_bench <git repo> <from rev> <to rev>")
from = ARGV[1]? || abort("a from revision is required")
to = ARGV[2]? || abort("a to revision is required")
level = 9

class Catalogue
  def initialize(repo : String) : Nil
    @process = Process.new(
      "git",
      ["-C", repo, "cat-file", "--batch"],
      input: :pipe,
      output: :pipe,
      error: :inherit,
    )
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

def chunked_size(codec : Compress::Zstd, source : Bytes, scratch : Bytes) : Int64
  io = IO::Memory.new
  Wire::Chunks.write_all(io, source, codec, scratch)
  io.size.to_i64
end

def mib(bytes : Int64) : String
  (bytes / 1_048_576.0).round(2).to_s
end

def digest(content : Bytes) : Bytes
  Digest::SHA256.digest(content).to_slice.dup
end

listing = IO::Memory.new
Process.run(
  "git",
  ["-C", repo, "diff", "--name-status", "-z", "--no-renames", from, to],
  output: listing,
)
fields = listing.to_s.split('\0').reject(&.empty?)

catalogue = Catalogue.new(repo)
codec = Compress::Zstd.new(level)
scratch = Wire::Chunks.scratch
dictionary = Compress::Dictionary.new
changes = Core::Changes.new
outcomes = Array(Write::Outcome).new

adds = 0
adds_raw = 0_i64
adds_wire = 0_i64
small_mods = 0
small_mods_wire = 0_i64
dictionary_mods = 0
dictionary_raw = 0_i64
dictionary_wire = 0_i64
dictionary_time = Time::Span.zero
deletes = 0
deleted_raw = 0_i64

index = 0
while index + 1 < fields.size
  status = fields[index]
  path = fields[index + 1]
  index += 2

  case status[0]
  when 'A'
    content = catalogue.blob("#{to}:#{path}") || next
    adds += 1
    adds_raw += content.size
    adds_wire += chunked_size(codec, content, scratch)
    entry = Core::File.new(digest(content), executable: false)
    changes << Core::Change.new(path, nil, entry)
    outcomes << Write::Outcome.new(path, entry)
  when 'D'
    content = catalogue.blob("#{from}:#{path}") || next
    deletes += 1
    deleted_raw += content.size
    changes << Core::Change.new(path, Core::File.new(digest(content), executable: false), nil)
    outcomes << Write::Outcome.new(path, nil)
  when 'M'
    old = catalogue.blob("#{from}:#{path}") || next
    new = catalogue.blob("#{to}:#{path}") || next
    new_entry = Core::File.new(digest(new), executable: false)
    changes << Core::Change.new(path, Core::File.new(digest(old), executable: false), new_entry)
    outcomes << Write::Outcome.new(path, new_entry)

    if Wire::Dictionary.worthwhile?(new.size.to_u64)
      started = Time.instant
      frame = dictionary.compress(new, old, Bytes.new(Compress::Zstd.bound(new.size)))
      dictionary_time += Time.instant - started
      abort("prefix compression failed") if frame.is_a?(Pylon::Problem)
      dictionary_mods += 1
      dictionary_raw += new.size
      dictionary_wire += chunked_size(codec, frame, scratch)
    else
      small_mods += 1
      small_mods_wire += chunked_size(codec, new, scratch)
    end
  end
end
catalogue.close

changes_io = IO::Memory.new
Wire::Chunks.write_changes(changes_io, changes)
outcomes_io = IO::Memory.new
Wire::Chunks.write_outcomes(outcomes_io, outcomes)
per_item_overhead = changes.size.to_i64 * (Wire::DIGEST_BYTES + 1 + 4 + 4 + 5)

puts "#{from} -> #{to}: #{changes.size} file changes (#{adds} added, #{deletes} deleted, " \
     "#{small_mods + dictionary_mods} modified)"
puts "  upstream changes list (zstd):   #{mib(changes_io.size.to_i64)} MiB"
puts "  upstream content framing:       #{mib(per_item_overhead)} MiB (digest+kind+chunk headers " \
     "per item)"
puts "  upstream adds, full zstd-#{level}:    #{mib(adds_wire)} MiB (#{mib(adds_raw)} MiB raw, " \
     "#{adds} files)"
puts "  upstream small mods (<1 KiB):   #{mib(small_mods_wire)} MiB (#{small_mods} files)"
puts "  upstream dictionary frames:     #{mib(dictionary_wire)} MiB " \
     "(#{mib(dictionary_raw)} MiB raw, " \
     "#{dictionary_mods} files, #{dictionary_time.total_seconds.round(2)}s compress)"
total_estimate = changes_io.size.to_i64 + per_item_overhead + adds_wire +
                 small_mods_wire + dictionary_wire
puts "  upstream total estimate:        #{mib(total_estimate)} MiB"
puts "  downstream outcomes (zstd):     #{mib(outcomes_io.size.to_i64)} MiB"
puts "  deleted content, kept by receiver: #{mib(deleted_raw)} MiB raw (#{deletes} files)"
