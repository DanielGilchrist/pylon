require "./contents"
require "./content_source"
require "./binary"
require "./writable"

module Pylon::Wire
  struct ContentsResponse
    include Writable

    getter source : ContentSource

    def initialize(@source : ContentSource)
    end

    def initialize(contents : Contents)
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
