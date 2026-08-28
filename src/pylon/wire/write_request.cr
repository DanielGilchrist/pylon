require "./content_source"
require "./binary"
require "./writable"

module Pylon::Wire
  struct WriteRequest
    include Writable

    getter changes : Array(Core::Change)
    getter source : ContentSource

    def self.new(changes : Array(Core::Change), contents : Contents)
      new(changes, ContentSource::Materialised.new(contents))
    end

    def initialize(@changes : Array(Core::Change), @source : ContentSource)
    end

    def contents : Contents
      source.contents
    end

    def tag : Tag
      Tag::WriteRequest
    end

    def write_payload(io : IO) : Nil
      Binary.write_changes(io, changes)
      source.write(io)
    end
  end
end
