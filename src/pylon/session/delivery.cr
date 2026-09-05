require "../wire/content_source"
require "./local_endpoint"

module Pylon::Session
  struct Delivery < Wire::ContentSource
    def initialize(
      @endpoint : LocalEndpoint,
      @wanted : Array(LocalEndpoint::Wanted),
      @checksums : Wire::Checksums::Map,
      @bases : Wire::Bases,
    ) : Nil
      @digests = @wanted.map(&.digest).to_set
    end

    getter digests : Set(Bytes)

    def contents : Wire::Contents
      @endpoint.materialise(@wanted)
    end

    def write(io : IO) : Nil
      io.write_bytes(@digests.size.to_u32, Wire::FORMAT)
      @endpoint.emit(io, @wanted, @checksums, @bases)
    end
  end
end
