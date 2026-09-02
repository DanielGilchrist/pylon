require "../content_source"
require "../binary"
require "../chunks"
require "./writable"

module Pylon::Wire::Message
  struct WriteRequest
    include Writable

    def self.new(changes : Core::Changes, relocations : Array(Core::Relocation), contents : Contents) : WriteRequest
      new(changes, relocations, ContentSource::Materialised.new(contents))
    end

    def initialize(@changes : Core::Changes, @relocations : Array(Core::Relocation), @source : ContentSource) : Nil
    end

    getter changes : Core::Changes
    getter relocations : Array(Core::Relocation)
    getter source : ContentSource

    def contents : Contents
      source.contents
    end

    def tag : Tag
      Tag::WriteRequest
    end

    def write_payload(io : IO) : Nil
      Chunks.write_changes(io, changes)
      Chunks.write_relocations(io, relocations)
      source.write(io)
    end
  end
end
