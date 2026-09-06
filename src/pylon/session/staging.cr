module Pylon::Session
  struct Staging(R)
    def initialize(@contents : Wire::Contents, @resolver : R) : Nil
    end

    def content(digest : Bytes, path : String) : Bytes?
      case (staged = @contents[digest]?)
      in Nil
        @resolver.content(digest)
      in Bytes
        staged
      in Wire::Spliced
        reconstruct(digest, staged, path)
      in Wire::Dictionary
        inflate(digest, staged, path)
      end
    end

    private def reconstruct(digest : Bytes, spliced : Wire::Spliced, path : String) : Bytes?
      base = @resolver.content(spliced.base, prefer: path)
      return if base.nil?

      rebuilt = Wire::Splice.apply(base, spliced.ops)
      return if rebuilt.nil?
      return unless Core::Digests.matches?(rebuilt, digest)

      rebuilt
    end

    private def inflate(digest : Bytes, dictionary : Wire::Dictionary, path : String) : Bytes?
      base = @resolver.content(dictionary.base, prefer: path)
      return if base.nil?

      rebuilt = Compress::Dictionary.decompress(
        dictionary.frame,
        base,
        Wire::Splice::LARGEST_FILE.to_i32,
      )
      return if rebuilt.is_a?(Problem)
      return unless Core::Digests.matches?(rebuilt, digest)

      rebuilt
    end
  end
end
