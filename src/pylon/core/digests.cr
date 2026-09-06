require "digest/sha256"

module Pylon::Core
  module Digests
    extend self

    def matches?(content : Bytes, digest : Bytes) : Bool
      hasher = ::Digest::SHA256.new
      return false unless digest.size == hasher.digest_size

      hasher.update(content)
      hasher.final == digest
    end

    def all(entry : Entry?) : Set(Bytes)
      digests = Set(Bytes).new
      gather(entry, digests)

      digests
    end

    def fingerprint(entry : Entry?) : Bytes
      hasher = ::Digest::SHA256.new
      feed(entry, hasher)
      hasher.final
    end

    private def feed(entry : Entry?, hasher : ::Digest::SHA256) : Nil
      case entry
      in Nil
        hasher.update(Bytes[0_u8])
      in Directory
        hasher.update(Bytes[1_u8])
        feed(entry.contents.size, hasher)

        entry.contents.keys.sort!.each do |name|
          feed(name, hasher)
          feed(entry.contents[name], hasher)
        end
      in File
        hasher.update(Bytes[2_u8, entry.executable? ? 1_u8 : 0_u8])
        hasher.update(entry.digest)
      in SymbolicLink
        hasher.update(Bytes[3_u8])
        feed(entry.target, hasher)
      in Untracked
        hasher.update(Bytes[4_u8])
      in Problematic
        hasher.update(Bytes[5_u8])
        feed(entry.problem, hasher)
      end
    end

    private def feed(text : String, hasher : ::Digest::SHA256) : Nil
      feed(text.bytesize, hasher)
      hasher.update(text.to_slice)
    end

    private def feed(count : Int32, hasher : ::Digest::SHA256) : Nil
      hasher.update(Bytes[count.to_u8!, (count >> 8).to_u8!])
      hasher.update(Bytes[(count >> 16).to_u8!, (count >> 24).to_u8!])
    end

    private def gather(entry : Entry?, into : Set(Bytes)) : Nil
      case entry
      in Nil, SymbolicLink, Untracked, Problematic
        nil
      in File
        into << entry.digest
      in Directory
        entry.contents.each_value { |child| gather(child, into) }
      end
    end
  end
end
