require "digest/sha256"
require "./change"
require "./entry"
require "./changes"
require "./digests/collector"

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
