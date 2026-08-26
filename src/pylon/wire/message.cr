require "./binary"

module Pylon::Wire
  alias Contents = Hash(Bytes, Bytes)

  enum Tag : UInt8
    Failure
    ScanRequest
    ScanResponse
    ContentsRequest
    ContentsResponse
    WriteRequest
    WriteResponse
  end

  module Writable
    abstract def tag : Tag
    abstract def write_payload(io : IO) : Nil

    def write(io : IO) : Nil
      io.write_byte(tag.value)
      write_payload(io)
      io.flush
    end
  end

  struct Failure
    include Writable

    getter message : String

    def initialize(@message : String)
    end

    def tag : Tag
      Tag::Failure
    end

    def write_payload(io : IO) : Nil
      Binary.write_string(io, message)
    end
  end

  struct ScanRequest
    include Writable

    getter now_ns : Int64

    def initialize(@now_ns : Int64)
    end

    def tag : Tag
      Tag::ScanRequest
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(now_ns, FORMAT)
    end
  end

  struct ScanResponse
    include Writable

    getter root : Core::Entry?

    def initialize(@root : Core::Entry?)
    end

    def tag : Tag
      Tag::ScanResponse
    end

    def write_payload(io : IO) : Nil
      Binary.write_entry(io, root)
    end
  end

  struct ContentsRequest
    include Writable

    getter digests : Array(Bytes)

    def initialize(@digests : Array(Bytes))
    end

    def tag : Tag
      Tag::ContentsRequest
    end

    def write_payload(io : IO) : Nil
      io.write_bytes(digests.size.to_u32, FORMAT)
      digests.each { |digest| Binary.write_bytes(io, digest) }
    end
  end

  struct ContentsResponse
    include Writable

    getter contents : Contents

    def initialize(@contents : Contents)
    end

    def tag : Tag
      Tag::ContentsResponse
    end

    def write_payload(io : IO) : Nil
      Wire.write_contents(io, contents)
    end
  end

  struct WriteRequest
    include Writable

    getter changes : Array(Core::Change)
    getter contents : Contents

    def initialize(@changes : Array(Core::Change), @contents : Contents)
    end

    def tag : Tag
      Tag::WriteRequest
    end

    def write_payload(io : IO) : Nil
      Binary.write_changes(io, changes)
      Wire.write_contents(io, contents)
    end
  end

  struct WriteResponse
    include Writable

    getter outcomes : Array(Write::Outcome)

    def initialize(@outcomes : Array(Write::Outcome))
    end

    def tag : Tag
      Tag::WriteResponse
    end

    def write_payload(io : IO) : Nil
      Binary.write_outcomes(io, outcomes)
    end
  end

  alias Message = Failure |
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
