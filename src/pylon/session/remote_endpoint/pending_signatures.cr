require "../../wire/delta"
require "../fault"

module Pylon::Session
  class RemoteEndpoint
    class PendingSignatures
      def initialize(@endpoint : RemoteEndpoint, @fault : Fault?)
        @settled = false
      end

      def settle_into(signatures : Wire::Delta::Signatures) : Fault?
        return if @settled

        @settled = true

        if (fault = @fault)
          return fault
        end

        case received = @endpoint.receive_signatures
        in Fault
          received
        in Wire::Delta::Signatures
          signatures.merge!(received)
          nil
        end
      end
    end
  end
end
