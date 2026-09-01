require "./contents_request"
require "./contents_response"
require "./failure"
require "./scan_request"
require "./scan_response"
require "./write_request"
require "./chunks"
require "./write_response"
require "./tree_delta"
require "./tree_update"
require "../problem"
require "digest/sha256"

# stdlibs `IO` reports failures by throwing exceptions. We want to avoid exceptions as they
# can leave the application in undesirable states but also make potential failures invisible
# to the type system. Here we effectively wrap the session's stream IO to explicitly handle
# the exceptions as they happen and convert them into values. This allows us to encode the
# potential failures into the return type and force callers to handle them as needed.
module Pylon::Wire
  PROTOCOL = 2_u32
  IDENTITY = "PYLON"

  record Closed

  record Compatible
  record Incompatible, version : UInt32
  record Foreign
  record Unreachable, reason : String

  alias Greeting = Compatible | Incompatible | Foreign | Unreachable

  def self.write_greeting(io : IO) : Problem?
    transmit("the greeting could not be written") do
      io.write(IDENTITY.to_slice)
      io.write_bytes(PROTOCOL, FORMAT)
    end
  end

  def self.read_greeting(io : IO) : Greeting
    identity = Bytes.new(IDENTITY.bytesize)
    io.read_fully(identity)
    return Foreign.new unless identity == IDENTITY.to_slice

    version = io.read_bytes(UInt32, FORMAT)
    version == PROTOCOL ? Compatible.new : Incompatible.new(version)
  rescue error : IO::Error
    Unreachable.new(error.message || "the stream ended during the greeting")
  end

  alias Message = Failure |
                  ScanRequest |
                  ScanResponse |
                  ContentsRequest |
                  ContentsResponse |
                  WriteRequest |
                  WriteResponse |
                  TreeUpdate |
                  TreeDelta

  def self.write_message(io : IO, message : Message) : Problem?
    transmit("the stream failed mid-message") { message.write(io) }
  end

  private def self.transmit(fallback : String, & : ->) : Problem?
    yield
    nil
  rescue error : IO::Error
    Problem.new(error.message || fallback)
  end

  def self.read_message(io : IO) : Message | Closed | Invalid
    case byte = first_byte(io)
    in Closed, Invalid
      byte
    in UInt8
      tag = Tag.from_value?(byte)
      return Invalid.new("unknown message tag #{byte}, both sides must run the same pylon version") if tag.nil?

      reader = Reader.new(io)
      reader.result(decode(tag, reader))
    end
  end

  private def self.first_byte(io : IO) : UInt8 | Closed | Invalid
    io.read_byte || Closed.new
  rescue error : IO::Error
    io.closed? ? Closed.new : Invalid.new(error.message || "the stream failed between messages")
  end

  private def self.decode(tag : Tag, reader : Reader) : Message
    case tag
    in .failure?           then Failure.new(reader.required_string)
    in .scan_request?      then ScanRequest.new(reader.i64)
    in .scan_response?     then ScanResponse.new(Chunks.read_entry(reader))
    in .contents_request?  then read_contents_request(reader)
    in .contents_response? then ContentsResponse.new(read_contents(reader))
    in .write_request?     then WriteRequest.new(Binary.read_changes(reader), read_contents(reader))
    in .write_response?    then WriteResponse.new(Binary.read_outcomes(reader))
    in .tree_update?       then TreeUpdate.new(reader.u32, Chunks.read_entry(reader))
    in .tree_delta?        then TreeDelta.new(reader.u32, Binary.read_changes(reader))
    end
  end

  def self.read_contents_request(reader : Reader) : ContentsRequest
    budget = reader.u64
    ContentsRequest.new(read_digests(reader), budget)
  end

  def self.read_digests(reader : Reader) : Array(Bytes)
    count = reader.count
    digests = Array(Bytes).new(capacity_hint(count))
    reader.repeat(count) { digests << reader.digest }
    digests
  end

  def self.read_contents(reader : Reader) : Contents
    count = reader.count
    contents = Contents.new(initial_capacity: capacity_hint(count))
    codec = Compress::Zstd.new
    scratch = Chunks.scratch
    hasher = Digest::SHA256.new
    sum = Bytes.new(DIGEST_BYTES)

    reader.repeat(count) do
      digest = reader.digest
      content = Chunks.read_all(reader, codec, scratch)
      next if content.nil?

      hasher.reset
      hasher.update(content)
      hasher.final(sum)

      contents[digest] = content if sum == digest
    end

    contents
  end

  def self.write_contents(io : IO, contents : Contents) : Nil
    io.write_bytes(contents.size.to_u32, FORMAT)
    codec = Compress::Zstd.new
    scratch = Chunks.scratch

    contents.each do |digest, content|
      Binary.write_bytes(io, digest)
      Chunks.write_all(io, content, codec, scratch)
    end
  end
end
