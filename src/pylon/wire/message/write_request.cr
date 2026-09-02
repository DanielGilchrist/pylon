require "../content_source"
require "../binary"
require "../chunks"
require "./writable"

module Pylon::Wire::Message
  struct WriteRequest
    include Writable

    getter changes : Core::Changes
    getter source : ContentSource

    def self.new(changes : Core::Changes, contents : Contents)
      new(changes, ContentSource::Materialised.new(contents))
    end

    def initialize(@changes : Core::Changes, @source : ContentSource)
    end

    def contents : Contents
      source.contents
    end

    def tag : Tag
      Tag::WriteRequest
    end

    def write_payload(io : IO) : Nil
      Chunks.write_changes(io, changes)
      source.write(io)
    end
  end
end
