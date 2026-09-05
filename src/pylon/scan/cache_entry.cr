require "./metadata"

module Pylon::Scan
  struct CacheEntry
    def initialize(@metadata : Metadata, @digest : Bytes, @freshly_written : Bool) : Nil
    end

    getter metadata : Metadata
    getter digest : Bytes
    getter? freshly_written : Bool

    def reuse(observed : Metadata, now_ns : Int64, granularity_ns : Int64) : Bytes?
      return if @freshly_written
      return if observed.freshly_modified?(now_ns, granularity_ns)
      return unless metadata.same_content?(observed)

      digest
    end
  end
end
