require "./metadata"

module Pylon::Scan
  struct CacheEntry
    getter metadata : Metadata
    getter digest : Bytes

    def initialize(@metadata : Metadata, @digest : Bytes)
    end

    def reuse(observed : Metadata, now_ns : Int64, granularity_ns : Int64) : Bytes?
      return if observed.racy?(now_ns, granularity_ns)
      return unless metadata.same_content?(observed)

      digest
    end
  end
end
