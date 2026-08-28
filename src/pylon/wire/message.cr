require "./contents_request"
require "./contents_response"
require "./failure"
require "./poll_request"
require "./poll_response"
require "./scan_request"
require "./scan_response"
require "./write_request"
require "./chunks"
require "./write_response"
require "./tree_delta"
require "./tree_update"

module Pylon::Wire
  alias Message = Failure |
                  PollRequest |
                  PollResponse |
                  ScanRequest |
                  ScanResponse |
                  ContentsRequest |
                  ContentsResponse |
                  WriteRequest |
                  WriteResponse |
                  TreeUpdate |
                  TreeDelta

  def self.read_message(io : IO) : Message
    byte = io.read_byte
    raise Truncated.new("stream ended before a message tag") if byte.nil?

    tag = Tag.from_value?(byte)
    raise Truncated.new("unknown message tag") if tag.nil?

    case tag
    in .failure?           then Failure.new(Binary.read_required_string(io))
    in .scan_request?      then ScanRequest.new(io.read_bytes(Int64, FORMAT))
    in .scan_response?     then ScanResponse.new(Chunks.read_entry(io))
    in .contents_request?  then read_contents_request(io)
    in .contents_response? then ContentsResponse.new(read_contents(io))
    in .write_request?     then WriteRequest.new(Binary.read_changes(io), read_contents(io))
    in .write_response?    then WriteResponse.new(Binary.read_outcomes(io))
    in .poll_request?      then PollRequest.new
    in .poll_response?     then PollResponse.new(Binary.read_bool(io))
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
      contents[digest] = Chunks.read_all(io, codec, scratch)
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
