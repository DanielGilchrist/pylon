require "../../wire/delta"
require "../fault"

module Pylon::Session
  class LocalEndpoint
    class SettledSignatures
      def initialize(@found : Wire::Delta::Signatures)
        @settled = false
      end

      def settle_into(signatures : Wire::Delta::Signatures) : Fault?
        return if @settled

        @settled = true
        signatures.merge!(@found)

        nil
      end
    end
  end
end
