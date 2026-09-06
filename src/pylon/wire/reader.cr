module Pylon::Wire
  # Reads the stream until complete or first failure. When a failure occurs reading essentially
  # becomes a no-op and doesn't touch the stream again.
  class Reader
    record Oversized, claimed : UInt32

    def initialize(@io : IO) : Nil
    end

    getter? failed = false
    getter reason = ""

    def fail(reason : String) : Nil
      return if @failed

      @failed = true
      @reason = reason
    end

    def result(value : T) : T | Problem forall T
      @failed ? Problem.new(@reason) : value
    end

    def repeat(count : UInt32, & : ->) : Nil
      count.times do
        break if @failed

        yield
      end
    end

    def byte : UInt8
      value = read(&.read_byte)
      return 0_u8 if @failed
      return value if value

      fail("the stream ended mid-message")
      0_u8
    end

    def u32 : UInt32
      number(UInt32)
    end

    def u64 : UInt64
      number(UInt64)
    end

    def i32 : Int32
      number(Int32)
    end

    def i64 : Int64
      number(Int64)
    end

    def count : UInt32
      u32
    end

    def bool : Bool
      case byte
      when 1_u8 then true
      when 0_u8 then false
      else
        fail("a bool was neither 0 nor 1")
        false
      end
    end

    def framed_size(limit : Int32) : Int32 | Oversized | Nil
      size = u32

      # Frame sizes are stored off by one so that 0 can mean absent (or the end of a stream).
      return if @failed || size == 0

      claimed = size - 1
      return Oversized.new(claimed) if claimed > limit

      claimed.to_i32
    end

    def bytes? : Bytes?
      case (size = framed_size(MAX_FIELD_BYTES))
      in Nil
        return
      in Oversized
        fail("a field claims #{size.claimed} bytes, over the #{MAX_FIELD_BYTES} limit")
        return
      in Int32
      end

      buffer = Bytes.new(size)
      fill(buffer)
      buffer unless @failed
    end

    def digest : Bytes
      take(DIGEST_BYTES)
    end

    def string? : String?
      case (size = framed_size(MAX_FIELD_BYTES))
      in Nil
        return
      in Oversized
        fail("a field claims #{size.claimed} bytes, over the #{MAX_FIELD_BYTES} limit")
        return
      in Int32
      end

      value = read do |io|
        String.new(size) do |buffer|
          io.read_fully(Slice.new(buffer, size))
          {size, 0}
        end
      end

      return if value.nil?

      if value.includes?('\0')
        fail("a string in the message contains a NUL byte")
        return
      end

      value
    end

    def required_string : String
      value = string?
      return "" if @failed
      return value if value

      fail("missing string in message")
      ""
    end

    def path : String
      raw = required_string
      return "" if @failed

      case (parsed = Core::RelativePath.parse(raw))
      in Core::RelativePath then parsed.value
      in Problem
        fail("the path #{raw.inspect} #{parsed.reason}")
        ""
      end
    end

    def name : String
      raw = required_string
      return "" if @failed

      case (parsed = Core::Name.parse(raw))
      in Core::Name then parsed.value
      in Problem
        fail("the name #{raw.inspect} #{parsed.reason}")
        ""
      end
    end

    def fill(buffer : Bytes) : Nil
      read(&.read_fully(buffer))
    end

    def take(size : Int32) : Bytes
      buffer = Bytes.new(size)
      fill(buffer)
      buffer
    end

    private def number(type : T.class) : T forall T
      value = read(&.read_bytes(type, FORMAT))
      value.nil? ? T.zero : value
    end

    private def read(& : IO -> T) : T? forall T
      return if @failed

      yield @io
    rescue error : IO::Error
      fail(error.message || "the stream failed mid-message")
      nil
    end
  end
end
