require "json"
require "./observation"

module Pylon::Watch
  module PDU
    extend self

    struct Failure
      getter message : String

      def initialize(@message : String)
      end
    end

    struct Response
      getter body : JSON::Any

      def initialize(@body : JSON::Any)
      end
    end

    struct Snapshot
      getter subscription : String
      getter clock : String
      getter observations : Array(Observation)
      getter warning : String?

      def initialize(
        @subscription : String,
        @clock : String,
        @observations : Array(Observation),
        @warning : String? = nil,
      )
      end
    end

    struct Delta
      getter subscription : String
      getter clock : String
      getter observations : Array(Observation)
      getter warning : String?

      def initialize(
        @subscription : String,
        @clock : String,
        @observations : Array(Observation),
        @warning : String? = nil,
      )
      end
    end

    alias Any = Failure | Response | Snapshot | Delta

    def parse(line : String?) : Any
      return Failure.new("connection closed") if line.nil?

      json =
        begin
          JSON.parse(line)
        rescue JSON::ParseException
          return Failure.new("malformed response")
        end

      if (message = json["error"]?.try(&.as_s?))
        return Failure.new(message)
      end

      subscription = json["subscription"]?.try(&.as_s?)
      return Response.new(json) if subscription.nil?

      clock = json["clock"]?.try(&.as_s?) || ""
      warning = json["warning"]?.try(&.as_s?)
      observations = observations_in(json)

      if json["is_fresh_instance"]?.try(&.as_bool?) == true
        Snapshot.new(subscription, clock, observations, warning)
      else
        Delta.new(subscription, clock, observations, warning)
      end
    end

    private def observations_in(json : JSON::Any) : Array(Observation)
      files = json["files"]?.try(&.as_a?)
      return [] of Observation if files.nil?

      files.compact_map { |file| Observation.from(file) }
    end
  end
end
