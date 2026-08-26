require "./binary"
require "./writable"

module Pylon::Wire
  struct TreeUpdate
    include Writable

    getter root : Core::Entry?

    def initialize(@root : Core::Entry?)
    end

    def tag : Tag
      Tag::TreeUpdate
    end

    def write_payload(io : IO) : Nil
      Binary.write_entry(io, root)
    end
  end
end
