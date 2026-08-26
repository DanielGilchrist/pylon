require "../../src/pylon/core"

module Fixtures
  include Pylon::Core

  D1 = "d1".to_slice
  D2 = "d2".to_slice

  ALL_MODES      = [SyncMode::TwoWaySafe, SyncMode::TwoWayResolved]
  SAFE_MODES     = [SyncMode::TwoWaySafe]
  RESOLVED_MODES = [SyncMode::TwoWayResolved]

  def self.f1 : Entry
    Entry.file(D1)
  end

  def self.f2 : Entry
    Entry.file(D2)
  end

  def self.f1x : Entry
    Entry.file(D1, executable: true)
  end

  def self.symlink_relative : Entry
    Entry.symlink("other")
  end

  def self.symlink_absolute : Entry
    Entry.symlink("/other")
  end

  def self.untracked : Entry
    Entry.untracked
  end

  def self.problematic : Entry
    Entry.problematic("permission denied")
  end

  def self.d0 : Entry
    Entry.directory
  end

  def self.d1 : Entry
    Entry.directory({"file" => f1})
  end

  def self.d2 : Entry
    Entry.directory({"file" => f2})
  end

  def self.du : Entry
    Entry.directory({"file" => untracked})
  end

  def self.dir(contents : Hash(String, Entry)) : Entry
    Entry.directory(contents)
  end
end
