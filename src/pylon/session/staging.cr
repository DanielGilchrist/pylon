require "../wire/message"

module Pylon::Session
  struct Staging
    def initialize(@contents : Wire::Contents)
    end

    def content(digest : Bytes) : Bytes?
      @contents[digest]?
    end
  end
end
