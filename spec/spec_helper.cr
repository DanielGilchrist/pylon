require "spec"
require "./support/allocations"
require "./support/entries"

include Pylon::Core

record ReconcileCase,
  description : String,
  modes : Array(SyncMode),
  base : Entry?,
  local : Entry?,
  remote : Entry?,
  base_changes : Array(Change) = [] of Change,
  local_changes : Array(Change) = [] of Change,
  remote_changes : Array(Change) = [] of Change,
  conflicts : Array(Conflict) = [] of Conflict

def assert_changes(actual : Array(Change), expected : Array(Change), label : String) : Nil
  actual.size.should eq(expected.size), "#{label}: expected #{expected.size} change(s), got #{actual.size}"

  by_path = expected.to_h { |change| {change.path, change} }

  actual.each do |change|
    matching = by_path[change.path]?
    matching.should_not be_nil, "#{label}: unexpected change at #{change.path.inspect}"
    next if matching.nil?

    Entry.equal?(change.old, matching.old).should be_true,
      "#{label}: old mismatch at #{change.path.inspect}"
    Entry.equal?(change.new, matching.new).should be_true,
      "#{label}: new mismatch at #{change.path.inspect}"
  end
end

def assert_reconciliation(reconciliation : Reconciliation, expected : ReconcileCase) : Nil
  assert_changes(reconciliation.base_changes, expected.base_changes, "base")
  assert_changes(reconciliation.local_changes, expected.local_changes, "local")
  assert_changes(reconciliation.remote_changes, expected.remote_changes, "remote")

  reconciliation.conflicts.map(&.root).sort!.should eq(expected.conflicts.map(&.root).sort!)
end
