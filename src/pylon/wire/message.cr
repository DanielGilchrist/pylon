require "./contents_request"
require "./contents_response"
require "./failure"
require "./poll_request"
require "./poll_response"
require "./scan_request"
require "./scan_response"
require "./write_request"
require "./write_response"

module Pylon::Wire
  alias Message = Failure |
                  PollRequest |
                  PollResponse |
                  ScanRequest |
                  ScanResponse |
                  ContentsRequest |
                  ContentsResponse |
                  WriteRequest |
                  WriteResponse

  def self.read_message(io : IO) : Message
    byte = io.read_byte
    raise Truncated.new("stream ended before a message tag") if byte.nil?

    case Tag.from_value(byte)
    in Tag::Failure            then Failure.new(Binary.read_string(io) || "")
    in Tag::ScanRequest        then ScanRequest.new(io.read_bytes(Int64, FORMAT))
    in Tag::ScanResponse       then ScanResponse.new(Binary.read_entry(io))
    in Tag::ContentsRequest    then ContentsRequest.new(read_digests(io))
    in Tag::ContentsResponse   then ContentsResponse.new(read_contents(io))
    in Tag::WriteRequest  then WriteRequest.new(Binary.read_changes(io), read_contents(io))
    in Tag::WriteResponse then WriteResponse.new(Binary.read_outcomes(io))
    in Tag::PollRequest        then PollRequest.new
    in Tag::PollResponse       then PollResponse.new(Binary.read_bool(io))
    end
  end

  def self.read_digests(io : IO) : Array(Bytes)
    count = io.read_bytes(UInt32, FORMAT)
    Array(Bytes).new(count) { Binary.read_bytes(io) || Bytes.empty }
  end

  def self.read_contents(io : IO) : Contents
    count = io.read_bytes(UInt32, FORMAT)
    contents = Contents.new(initial_capacity: count)

    count.times do
      digest = Binary.read_bytes(io) || Bytes.empty
      contents[digest] = Binary.read_bytes(io) || Bytes.empty
    end

    contents
  end

  def self.write_contents(io : IO, contents : Contents) : Nil
    io.write_bytes(contents.size.to_u32, FORMAT)

    contents.each do |digest, content|
      Binary.write_bytes(io, digest)
      Binary.write_bytes(io, content)
    end
  end
end
