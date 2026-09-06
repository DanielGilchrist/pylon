module Pylon::Session
  class Locations
    record Located, path : String, size : UInt64

    def initialize : Nil
      @by_digest = Hash(Bytes, Located).new
    end

    def size : Int32
      @by_digest.size
    end

    def has?(digest : Bytes) : Bool
      @by_digest.has_key?(digest)
    end

    def locate(digest : Bytes) : Located?
      @by_digest[digest]?
    end

    def remember(digest : Bytes, path : String, size : UInt64) : Nil
      @by_digest[digest] = Located.new(path, size)
    end

    def forget(digest : Bytes, path : String) : Nil
      located = @by_digest[digest]?
      @by_digest.delete(digest) if located && located.path == path
    end
  end
end
