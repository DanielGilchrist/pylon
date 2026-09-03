require "../patch"
require "../chunks"
require "./writable"

module Pylon::Wire::Message
  struct ScanResponse
    include Writable

    def initialize(@root : Core::Entry?) : Nil
    end

    getter root : Core::Entry?

    def tag : Tag
      Tag::ScanResponse
    end

    def write_payload(io : IO) : Nil
      Chunks.write_entry(io, root)
    end
  end
end
