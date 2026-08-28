require "json"
require "../../core/entry"

module Pylon::Watch::Watchman
  struct Observation
    def self.from(json : JSON::Any) : Observation?
      name = json["name"]?.try(&.as_s?)
      return nil if name.nil?

      new(
        name: name,
        mode: json["mode"]?.try(&.as_i64?).try(&.to_u32) || 0_u32,
        size: json["size"]?.try(&.as_i64?).try(&.to_u64) || 0_u64,
        mtime_ns: json["mtime_ns"]?.try(&.as_i64?) || 0_i64,
        exists: json["exists"]?.try(&.as_bool?) != false,
        created: json["new"]?.try(&.as_bool?) == true,
      )
    end

    getter name : String
    getter mode : UInt32
    getter size : UInt64
    getter mtime_ns : Int64

    def initialize(
      @name : String,
      @mode : UInt32,
      @size : UInt64,
      @mtime_ns : Int64,
      @exists : Bool,
      @created : Bool,
    )
    end

    def exists? : Bool
      @exists
    end

    def created? : Bool
      @created
    end

    def deleted? : Bool
      !@exists
    end

    def kind : Core::Entry::Kind
      Core::Entry::Kind.from_mode(mode)
    end

    def directory? : Bool
      kind.directory?
    end

    def executable? : Bool
      mode & 0o111_u32 != 0
    end
  end
end
