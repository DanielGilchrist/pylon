require "../patch"
require "../content_source"
require "../binary"
require "./writable"

module Pylon::Wire::Message
  struct ContentsResponse
    include Writable

    getter source : ContentSource

    def initialize(@source : ContentSource) : Nil
    end

    def initialize(contents : Contents) : Nil
      @source = ContentSource::Materialised.new(contents)
    end

    def contents : Contents
      source.contents
    end

    def tag : Tag
      Tag::ContentsResponse
    end

    def write_payload(io : IO) : Nil
      source.write(io)
    end
  end
end
