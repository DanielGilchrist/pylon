require "../content_source"
require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct ContentsResponse
    include Writable

    def initialize(@payload : ContentSource) : Nil
    end

    def initialize(contents : Contents) : Nil
      @payload = ContentSource::Materialised.new(contents)
    end

    getter payload : ContentSource

    def tag : Tag
      Tag::ContentsResponse
    end

    def write_payload(io : IO) : Nil
      payload.write(io)
    end
  end
end
