require "../patch"
require "../chunks"
require "./writable"

module Pylon::Wire::Message
  struct ScanResponse
    include Writable

    getter root : Core::Entry?

    def initialize(@root : Core::Entry?)
    end

    def tag : Tag
      Tag::ScanResponse
    end

    def write_payload(io : IO) : Nil
      Chunks.write_entry(io, root)
    end
  end
end
