require "digest/sha256"
require "../../src/pylon/core"
require "../../src/pylon/scan/metadata"

module Fixtures
  include Pylon::Core

  D1 = Digest::SHA256.digest("d1")
  D2 = Digest::SHA256.digest("d2")

  NONE        = built
  LOCAL_WINS  = built(local: ["."])
  REMOTE_WINS = built(remote: ["."])

  ALL_PREFERENCES   = [NONE, LOCAL_WINS, REMOTE_WINS]
  NO_PREFERENCES    = [NONE]
  PREFERRING_LOCAL  = [LOCAL_WINS]
  PREFERRING_REMOTE = [REMOTE_WINS]

  def self.built(
    local : Array(String) = Array(String).new,
    remote : Array(String) = Array(String).new,
  ) : Preferences
    case (preferences = Preferences.build(local, remote))
    in Preferences then preferences
    in Pylon::Problem
      raise "the fixture preferences are not a valid glob: #{preferences.reason}"
    end
  end

  def self.f1 : Entry
    Pylon::Core::File.new(D1, executable: false)
  end

  def self.f2 : Entry
    Pylon::Core::File.new(D2, executable: false)
  end

  def self.f1x : Entry
    Pylon::Core::File.new(D1, executable: true)
  end

  def self.symlink_relative : Entry
    Pylon::Core::SymbolicLink.new("other")
  end

  def self.symlink_absolute : Entry
    Pylon::Core::SymbolicLink.new("/other")
  end

  def self.untracked : Entry
    Pylon::Core::Untracked.new
  end

  def self.problematic : Entry
    Pylon::Core::Problematic.new("permission denied")
  end

  def self.d0 : Entry
    Pylon::Core::Directory.new
  end

  def self.d1 : Entry
    Pylon::Core::Directory.new({"file" => f1})
  end

  def self.dir(contents : Hash(String, Entry)) : Entry
    Pylon::Core::Directory.new(contents)
  end
end

module Fixtures
  def self.directory!(entry : Pylon::Core::Entry?) : Pylon::Core::Directory
    raise "expected a directory, got #{entry.inspect}" unless entry.is_a?(Pylon::Core::Directory)

    entry
  end

  def self.file!(entry : Pylon::Core::Entry?) : Pylon::Core::File
    raise "expected a file, got #{entry.inspect}" unless entry.is_a?(Pylon::Core::File)

    entry
  end

  def self.problem!(entry : Pylon::Core::Entry?) : Pylon::Core::Problematic
    unless entry.is_a?(Pylon::Core::Problematic)
      raise "expected a problematic entry, got #{entry.inspect}"
    end

    entry
  end

  def self.dig!(entry : Pylon::Core::Entry?, *names : String) : Pylon::Core::Entry
    current = entry

    names.each do |name|
      current = directory!(current).contents[name]?
      raise "missing entry #{name.inspect} under #{names.inspect}" if current.nil?
    end

    raise "missing entry at #{names.inspect}" if current.nil?

    current
  end
end

module Fixtures
  def self.metadata!(
    observed : Pylon::Scan::Metadata | Pylon::Problem | Nil,
  ) : Pylon::Scan::Metadata
    raise "expected metadata, got #{observed.inspect}" unless observed.is_a?(Pylon::Scan::Metadata)

    observed
  end
end
