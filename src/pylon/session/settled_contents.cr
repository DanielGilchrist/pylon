require "../wire/content_source"

module Pylon::Session
  struct SettledContents
    def initialize(@source : Wire::ContentSource) : Nil
    end

    def await : Wire::ContentSource
      @source
    end
  end
end
