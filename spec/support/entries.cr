require "../../src/pylon/core"
require "../../src/pylon/scan/metadata"

module Fixtures
  include Pylon::Core

  D1 = "d1".to_slice
  D2 = "d2".to_slice

  LOCAL_WINS  = Preferences.new([Preferences::Rule.new(:local, ".")])
  REMOTE_WINS = Preferences.new([Preferences::Rule.new(:remote, ".")])

  ALL_PREFERENCES  = [Preferences.none, LOCAL_WINS, REMOTE_WINS]
  NO_PREFERENCES   = [Preferences.none]
  PREFERRING_LOCAL  = [LOCAL_WINS]
  PREFERRING_REMOTE = [REMOTE_WINS]

  def self.f1 : Entry
    Pylon::Core::File.new(D1)
  end

  def self.f2 : Entry
    Pylon::Core::File.new(D2)
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

  def self.d2 : Entry
    Pylon::Core::Directory.new({"file" => f2})
  end

  def self.du : Entry
    Pylon::Core::Directory.new({"file" => untracked})
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

  def self.link!(entry : Pylon::Core::Entry?) : Pylon::Core::SymbolicLink
    raise "expected a symlink, got #{entry.inspect}" unless entry.is_a?(Pylon::Core::SymbolicLink)

    entry
  end

  def self.problem!(entry : Pylon::Core::Entry?) : Pylon::Core::Problematic
    raise "expected a problematic entry, got #{entry.inspect}" unless entry.is_a?(Pylon::Core::Problematic)

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
  def self.metadata!(observed : Pylon::Scan::Metadata | Pylon::Problem | Nil) : Pylon::Scan::Metadata
    raise "expected metadata, got #{observed.inspect}" unless observed.is_a?(Pylon::Scan::Metadata)

    observed
  end
end
