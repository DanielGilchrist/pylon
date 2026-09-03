require "./metadata"

module Pylon::Scan
  struct CacheEntry
    def initialize(@metadata : Metadata, @digest : Bytes, @provisional : Bool) : Nil
    end

    getter metadata : Metadata
    getter digest : Bytes
    getter? provisional : Bool

    def reuse(observed : Metadata, now_ns : Int64, granularity_ns : Int64) : Bytes?
      return if @provisional
      return if observed.freshly_modified?(now_ns, granularity_ns)
      return unless metadata.same_content?(observed)

      digest
    end
  end
end
