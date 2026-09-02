require "../core/digests"
require "../wire/message"
require "../wire/delta"
require "./staging/unrecoverable"

module Pylon::Session
  struct Staging(R)
    def initialize(@contents : Wire::Contents, @resolver : R = Unrecoverable.new)
    end

    def content(digest : Bytes) : Bytes?
      case staged = @contents[digest]?
      in Nil
        @resolver.recovered_content(digest)
      in Bytes
        staged
      in Wire::Patch
        reconstruct(digest, staged)
      end
    end

    private def reconstruct(digest : Bytes, patch : Wire::Patch) : Bytes?
      base = @resolver.recovered_content(patch.base)
      return if base.nil?

      rebuilt = Wire::Delta.apply(base, patch.ops)
      return if rebuilt.nil?
      return unless Core::Digests.matches?(rebuilt, digest)

      rebuilt
    end
  end
end
