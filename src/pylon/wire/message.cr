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

module Pylon::Wire
  PROTOCOL = 1_u32
  IDENTITY = "PYLON"

  record Compatible
  record Incompatible, version : UInt32
  record Foreign

  alias Greeting = Compatible | Incompatible | Foreign

  def self.write_greeting(io : IO) : Nil
    io.write(IDENTITY.to_slice)
    io.write_bytes(PROTOCOL, FORMAT)
  end

  def self.read_greeting(io : IO) : Greeting
    identity = Bytes.new(IDENTITY.bytesize)
    io.read_fully(identity)
    return Foreign.new unless identity == IDENTITY.to_slice

    version = io.read_bytes(UInt32, FORMAT)
    version == PROTOCOL ? Compatible.new : Incompatible.new(version)
  rescue IO::Error
    Foreign.new
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

  record Closed

  def self.read_message(io : IO) : Message | Closed | Invalid
    byte = first_byte(io)
    return Closed.new if byte.nil?

    Truncated.contain do
      tag = Tag.from_value?(byte)
      next Invalid.new("unknown message tag #{byte}, both sides must run the same pylon version") if tag.nil?

      decode(tag, io)
    end
  end

  private def self.first_byte(io : IO) : UInt8?
    io.read_byte
  rescue IO::Error
    nil
  end

  private def self.decode(tag : Tag, io : IO) : Message
    case tag
    in .failure?           then Failure.new(Binary.read_required_string(io))
    in .scan_request?      then ScanRequest.new(io.read_bytes(Int64, FORMAT))
    in .scan_response?     then ScanResponse.new(Chunks.read_entry(io))
    in .contents_request?  then read_contents_request(io)
    in .contents_response? then ContentsResponse.new(read_contents(io))
    in .write_request?     then WriteRequest.new(Binary.read_changes(io), read_contents(io))
    in .write_response?    then WriteResponse.new(Binary.read_outcomes(io))
    in .tree_update?       then TreeUpdate.new(io.read_bytes(UInt32, FORMAT), Chunks.read_entry(io))
    in .tree_delta?        then TreeDelta.new(io.read_bytes(UInt32, FORMAT), Binary.read_changes(io))
    end
  end

  def self.read_contents_request(io : IO) : ContentsRequest
    budget = io.read_bytes(UInt64, FORMAT)
    ContentsRequest.new(read_digests(io), budget)
  end

  def self.read_digests(io : IO) : Array(Bytes)
    count = io.read_bytes(UInt32, FORMAT)
    Array(Bytes).new(count) { Binary.read_required_bytes(io) }
  end

  def self.read_contents(io : IO) : Contents
    count = io.read_bytes(UInt32, FORMAT)
    contents = Contents.new(initial_capacity: count)
    codec = Compress::Zstd.new
    scratch = Chunks.scratch

    count.times do
      digest = Binary.read_required_bytes(io)
      content = Chunks.read_all(io, codec, scratch)
      contents[digest] = content if content
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
