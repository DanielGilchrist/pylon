require "../../brand"
require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct Configure
    include Writable

    def initialize(
      *,
      @root : String,
      @ignores : Array(String),
      @compression : Int32,
      @brand : Brand,
      @state : String?,
      @watch : Bool,
      @tree_fingerprint : Bytes?,
    ) : Nil
    end

    getter root : String
    getter ignores : Array(String)
    getter compression : Int32
    getter brand : Brand
    getter state : String?
    getter? watch : Bool
    getter tree_fingerprint : Bytes?

    def tag : Tag
      Tag::Configure
    end

    def write_payload(io : IO) : Nil
      Binary.write_string(io, root)
      io.write_bytes(ignores.size.to_u32, FORMAT)
      ignores.each { |pattern| Binary.write_string(io, pattern) }
      io.write_bytes(compression, FORMAT)
      Binary.write_string(io, brand.name)
      Binary.write_string(io, state)
      Binary.write_bool(io, watch?)
      Binary.write_bytes(io, tree_fingerprint)
    end
  end
end
