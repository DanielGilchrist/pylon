require "../../wire/content_source"
require "../fault"

module Pylon::Session
  class RemoteEndpoint
    struct PendingContents
      def initialize(@endpoint : RemoteEndpoint, @fault : Fault?) : Nil
      end

      def await : Wire::ContentSource | Fault
        if (fault = @fault)
          return fault
        end

        @endpoint.receive_contents
      end
    end
  end
end
