require "../core/change"
require "../core/entry"
require "../write/writer"

module Pylon::Wire
  FORMAT = IO::ByteFormat::LittleEndian

  class Truncated < Exception
  end

  module Binary
    extend self

    def write_bool(io : IO, value : Bool) : Nil
      io.write_byte(value ? 1_u8 : 0_u8)
    end

    def read_bool(io : IO) : Bool
      read_byte(io) == 1_u8
    end

    def write_bytes(io : IO, value : Bytes?) : Nil
      if value.nil?
        io.write_bytes(0_u32, FORMAT)
        return
      end

      io.write_bytes(value.size.to_u32 + 1, FORMAT)
      io.write(value)
    end

    def read_bytes(io : IO) : Bytes?
      size = read_u32(io)
      return nil if size == 0

      buffer = Bytes.new(size - 1)
      read_exact(io, buffer)
      buffer
    end

    def write_string(io : IO, value : String?) : Nil
      write_bytes(io, value.try(&.to_slice))
    end

    def read_string(io : IO) : String?
      read_bytes(io).try { |bytes| String.new(bytes) }
    end

    def write_entry(io : IO, entry : Core::Entry?) : Nil
      if entry.nil?
        io.write_byte(0_u8)
        return
      end

      io.write_byte(entry.kind.value.to_u8 + 1)
      write_bytes(io, entry.digest)
      write_bool(io, entry.executable?)
      write_string(io, entry.target)
      write_string(io, entry.problem)

      io.write_bytes(entry.contents.size.to_u32, FORMAT)

      entry.contents.each do |name, child|
        write_string(io, name)
        write_entry(io, child)
      end
    end

    def read_entry(io : IO) : Core::Entry?
      tag = read_byte(io)
      return nil if tag == 0

      kind = Core::Entry::Kind.from_value(tag.to_i32 - 1)
      digest = read_bytes(io)
      executable = read_bool(io)
      target = read_string(io)
      problem = read_string(io)

      count = read_u32(io)
      contents = count.zero? ? Core::Entry::EMPTY_CONTENTS : Hash(String, Core::Entry).new(initial_capacity: count)

      count.times do
        name = read_string(io)
        child = read_entry(io)
        contents[name] = child if name && child
      end

      Core::Entry.new(
        kind: kind,
        digest: digest,
        executable: executable,
        target: target,
        problem: problem,
        contents: contents,
      )
    end

    def write_changes(io : IO, changes : Array(Core::Change)) : Nil
      io.write_bytes(changes.size.to_u32, FORMAT)

      changes.each do |change|
        write_string(io, change.path)
        write_entry(io, change.old)
        write_entry(io, change.new)
      end
    end

    def read_changes(io : IO) : Array(Core::Change)
      count = read_u32(io)
      changes = Array(Core::Change).new(count)

      count.times do
        path = read_string(io) || ""
        changes << Core::Change.new(path, read_entry(io), read_entry(io))
      end

      changes
    end

    def write_outcomes(io : IO, outcomes : Array(Write::Outcome)) : Nil
      io.write_bytes(outcomes.size.to_u32, FORMAT)

      outcomes.each do |outcome|
        write_string(io, outcome.path)
        write_entry(io, outcome.entry)
        write_string(io, outcome.problem)
      end
    end

    def read_outcomes(io : IO) : Array(Write::Outcome)
      count = read_u32(io)
      outcomes = Array(Write::Outcome).new(count)

      count.times do
        outcomes << Write::Outcome.new(read_string(io) || "", read_entry(io), read_string(io))
      end

      outcomes
    end

    private def read_byte(io : IO) : UInt8
      byte = io.read_byte
      raise Truncated.new("stream ended mid-message") if byte.nil?

      byte
    end

    private def read_u32(io : IO) : UInt32
      io.read_bytes(UInt32, FORMAT)
    rescue IO::EOFError
      raise Truncated.new("stream ended mid-message")
    end

    private def read_exact(io : IO, buffer : Bytes) : Nil
      io.read_fully(buffer)
    rescue IO::EOFError
      raise Truncated.new("stream ended mid-message")
    end
  end
end
