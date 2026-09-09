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
                ChecksumsRequest |
                ChecksumsResponse |
                WriteRequest |
                WriteResponse |
                TreeUpdate |
                TreeChanges |
                Configure |
                ScanProgress |
                TreeAnnounce |
                ReusableRequest |
                ReusableResponse |
                HeartbeatRequest |
                HeartbeatResponse

    def write(io : IO, message : Any) : Problem?
      message.write(io)
      nil
    rescue error : IO::Error
      Problem.new(error.message || "the stream failed mid-message")
    end

    def read(io : IO) : Any | Closed | Problem
      case (byte = first_byte(io))
      in Closed, Problem
        byte
      in UInt8
        tag = Tag.from_value?(byte)
        if tag.nil?
          return Problem.new("unknown message tag #{byte}, both sides must run the same version")
        end

        reader = Reader.new(io)
        reader.result(decode(tag, reader))
      end
    end

    private def first_byte(io : IO) : UInt8 | Closed | Problem
      io.read_byte || Closed.new
    rescue error : IO::Error
      io.closed? ? Closed.new : Problem.new(error.message || "the stream failed between messages")
    end

    private def decode(tag : Tag, reader : Reader) : Any
      case tag
      in .failure?            then Failure.new(reader.required_string)
      in .scan_request?       then ScanRequest.new(reader.i64)
      in .scan_response?      then ScanResponse.new(Chunks.read_entry(reader))
      in .contents_request?   then read_contents_request(reader)
      in .contents_response?  then ContentsResponse.new(Chunks.read_contents(reader))
      in .checksums_request?  then ChecksumsRequest.new(Binary.read_bases(reader))
      in .checksums_response? then ChecksumsResponse.new(Binary.read_checksums_map(reader))
      in .write_request?      then read_write_request(reader)
      in .write_response?     then WriteResponse.new(Chunks.read_outcomes(reader))
      in .tree_update?        then read_tree_update(reader)
      in .tree_changes?       then read_tree_changes(reader)
      in .configure?          then read_configure(reader)
      in .scan_progress?      then ScanProgress.new(reader.i64, reader.i64)
      in .tree_announce?      then TreeAnnounce.new(reader.u32)
      in .reusable_request?   then ReusableRequest.new(Binary.read_digests(reader))
      in .reusable_response?  then ReusableResponse.new(Binary.read_digests(reader))
      in .heartbeat_request?  then HeartbeatRequest.new
      in .heartbeat_response? then HeartbeatResponse.new
      end
    end

    private def read_contents_request(reader : Reader) : ContentsRequest
      budget = reader.u64
      digests = Binary.read_digests(reader)

      ContentsRequest.new(digests, budget, Binary.read_checksums_map(reader))
    end

    private def read_write_request(reader : Reader) : WriteRequest
      WriteRequest.new(
        Chunks.read_changes(reader),
        Chunks.read_relocations(reader),
        Chunks.read_contents(reader),
      )
    end

    private def read_tree_update(reader : Reader) : TreeUpdate
      sequence = reader.u32
      live = reader.bool

      TreeUpdate.new(sequence, Chunks.read_entry(reader), live: live)
    end

    private def read_tree_changes(reader : Reader) : TreeChanges
      sequence = reader.u32
      live = reader.bool

      TreeChanges.new(sequence, Chunks.read_changes(reader), live: live)
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
      tree_fingerprint = reader.bytes?
      if tree_fingerprint && tree_fingerprint.size != DIGEST_BYTES
        reader.fail("the tree fingerprint has the wrong length")
      end

      Configure.new(
        root: root,
        ignores: ignores,
        compression: compression,
        brand: Brand.new(brand),
        state: state,
        watch: watch,
        tree_fingerprint: tree_fingerprint,
      )
    end
  end
end
