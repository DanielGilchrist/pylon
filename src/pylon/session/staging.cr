require "../compress/prefix"
require "../core/digests"
require "../wire/message"
require "../wire/delta"

module Pylon::Session
  struct Staging(R)
    def initialize(@contents : Wire::Contents, @resolver : R) : Nil
    end

    def content(digest : Bytes, path : String) : Bytes?
      case (staged = @contents[digest]?)
      in Nil
        @resolver.recovered_content(digest)
      in Bytes
        staged
      in Wire::Patch
        reconstruct(digest, staged, path)
      in Wire::Prefixed
        inflate(digest, staged, path)
      end
    end

    private def reconstruct(digest : Bytes, patch : Wire::Patch, path : String) : Bytes?
      base = @resolver.base_content(patch.base, path)
      return if base.nil?

      rebuilt = Wire::Delta.apply(base, patch.ops)
      return if rebuilt.nil?
      return unless Core::Digests.matches?(rebuilt, digest)

      rebuilt
    end

    private def inflate(digest : Bytes, prefixed : Wire::Prefixed, path : String) : Bytes?
      base = @resolver.base_content(prefixed.base, path)
      return if base.nil?

      rebuilt = Compress::Prefix.decompress(prefixed.frame, base, Wire::Delta::LARGEST_DELTA_FILE.to_i32)
      return if rebuilt.is_a?(Compress::Error)
      return unless Core::Digests.matches?(rebuilt, digest)

      rebuilt
    end
  end
end
