require "./message/tag"
require "./message/writable"
require "./message/failure"
require "./message/scan_request"
require "./message/scan_response"
require "./message/contents_request"
require "./message/contents_response"
require "./message/signatures_request"
require "./message/signatures_response"
require "./message/write_request"
require "./message/write_response"
require "./message/tree_update"
require "./message/tree_delta"
require "./message/configure"
require "./message/scan_progress"
require "./message/tree_announce"
require "./message/availability_request"
require "./message/availability_response"
require "../wire"
require "./closed"
require "./greeting"
require "./content_kind"
require "./delta"
require "./chunks"
require "../problem"

# stdlibs `IO` reports failures by throwing exceptions. We want to avoid exceptions as they
# can leave the application in undesirable states but also make potential failures invisible
# to the type system. Here we effectively wrap the session's stream IO to explicitly handle
# the exceptions as they happen and convert them into values. This allows us to encode the
# potential failures into the return type and force callers to handle them as needed.
module Pylon::Wire
  module Message
    extend self

    alias Any = Failure |
                ScanRequest |
                ScanResponse |
                ContentsRequest |
                ContentsResponse |
                SignaturesRequest |
                SignaturesResponse |
                WriteRequest |
                WriteResponse |
                TreeUpdate |
                TreeDelta |
                Configure |
                ScanProgress |
                TreeAnnounce |
                AvailabilityRequest |
                AvailabilityResponse

    def write(io : IO, message : Any) : Problem?
      message.write(io)
      nil
    rescue error : IO::Error
      Problem.new(error.message || "the stream failed mid-message")
    end

    def read(io : IO) : Any | Closed | Invalid
      case (byte = first_byte(io))
      in Closed, Invalid
        byte
      in UInt8
        tag = Tag.from_value?(byte)
        return Invalid.new("unknown message tag #{byte}, both sides must run the same version") if tag.nil?

        reader = Reader.new(io)
        reader.result(decode(tag, reader))
      end
    end

    private def first_byte(io : IO) : UInt8 | Closed | Invalid
      io.read_byte || Closed.new
    rescue error : IO::Error
      io.closed? ? Closed.new : Invalid.new(error.message || "the stream failed between messages")
    end

    private def decode(tag : Tag, reader : Reader) : Any
      case tag
      in .failure?               then Failure.new(reader.required_string)
      in .scan_request?          then ScanRequest.new(reader.i64)
      in .scan_response?         then ScanResponse.new(Chunks.read_entry(reader))
      in .contents_request?      then read_contents_request(reader)
      in .contents_response?     then ContentsResponse.new(Chunks.read_contents(reader))
      in .signatures_request?    then read_signatures_request(reader)
      in .signatures_response?   then SignaturesResponse.new(Binary.read_signatures(reader))
      in .write_request?         then read_write_request(reader)
      in .write_response?        then WriteResponse.new(Chunks.read_outcomes(reader))
      in .tree_update?           then read_tree_update(reader)
      in .tree_delta?            then read_tree_delta(reader)
      in .configure?             then read_configure(reader)
      in .scan_progress?         then ScanProgress.new(reader.i64, reader.i64)
      in .tree_announce?         then TreeAnnounce.new(reader.u32)
      in .availability_request?  then AvailabilityRequest.new(Binary.read_digests(reader))
      in .availability_response? then AvailabilityResponse.new(Binary.read_digests(reader))
      end
    end

    private def read_contents_request(reader : Reader) : ContentsRequest
      budget = reader.u64
      digests = Binary.read_digests(reader)

      ContentsRequest.new(digests, budget, Binary.read_signatures(reader))
    end

    private def read_signatures_request(reader : Reader) : SignaturesRequest
      count = reader.count
      pairs = Array(SignaturesRequest::Pair).new(Wire.capacity_hint(count))
      reader.repeat(count) { pairs << SignaturesRequest::Pair.new(reader.digest, reader.digest) }

      SignaturesRequest.new(pairs)
    end

    private def read_write_request(reader : Reader) : WriteRequest
      WriteRequest.new(Chunks.read_changes(reader), Chunks.read_relocations(reader), Chunks.read_contents(reader))
    end

    private def read_tree_update(reader : Reader) : TreeUpdate
      sequence = reader.u32
      live = reader.bool

      TreeUpdate.new(sequence, Chunks.read_entry(reader), live: live)
    end

    private def read_tree_delta(reader : Reader) : TreeDelta
      sequence = reader.u32
      live = reader.bool

      TreeDelta.new(sequence, Chunks.read_changes(reader), live: live)
    end

    private def read_configure(reader : Reader) : Configure
      root = reader.required_string
      reader.fail("the root path is empty") if root.empty?

      count = reader.count
      ignores = Array(String).new(Wire.capacity_hint(count))
      reader.repeat(count) { ignores << reader.required_string }

      compression = reader.i32
      brand = reader.required_string
      reader.fail("the brand is blank") if brand.blank?

      state = reader.string?
      watch = reader.bool
      known = reader.bytes?
      reader.fail("the known tree fingerprint has the wrong length") if known && known.size != DIGEST_BYTES

      Configure.new(
        root: root,
        ignores: ignores,
        compression: compression,
        brand: Brand.new(brand),
        state: state,
        watch: watch,
        known: known,
      )
    end
  end
end
