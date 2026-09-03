require "spec"
require "./support/allocations"
require "./support/entries"

include Pylon::Core

def local_endpoint(root : String) : Pylon::Session::LocalEndpoint
  Pylon::Session::LocalEndpoint.new(root, Pylon::Scan::Ignores::NONE, compression: Pylon::Compress::Zstd::DEFAULT_LEVEL)
end

def build_session(
  local : A,
  remote : B,
  preferences : Preferences = Fixtures::NONE,
  base : Entry? = nil,
  dry_run : Bool = false,
  push_first : Bool = false,
  on_progress : Proc(Pylon::Session::Progress, Nil)? = nil,
) : Pylon::Session::Session(A, B) forall A, B
  Pylon::Session::Session.new(
    local,
    remote,
    preferences: preferences,
    base: base,
    dry_run: dry_run,
    push_first: push_first,
    on_progress: on_progress,
  )
end

def cycle!(session : Pylon::Session::Session, now_ns : Int64) : Pylon::Session::Report
  result = session.cycle(now_ns)
  return result if result.is_a?(Pylon::Session::Report)

  raise "the session faulted: #{result.explain}"
end

record ReconcileCase,
  description : String,
  preferences : Array(Preferences),
  base : Entry?,
  local : Entry?,
  remote : Entry?,
  base_changes : Changes = Changes.new,
  local_changes : Changes = Changes.new,
  remote_changes : Changes = Changes.new,
  conflicts : Array(Conflict) = Array(Conflict).new,
  troubles : Array(Trouble) = Array(Trouble).new

def assert_changes(actual : Changes, expected : Changes, label : String) : Nil
  actual.size.should eq(expected.size), "#{label}: expected #{expected.size} change(s), got #{actual.size}"

  by_path = expected.to_h { |change| {change.path, change} }

  actual.each do |change|
    matching = by_path[change.path]?
    matching.should_not be_nil, "#{label}: unexpected change at #{change.path.inspect}"
    next if matching.nil?

    (change.old == matching.old).should be_true,
      "#{label}: old mismatch at #{change.path.inspect}"
    (change.new == matching.new).should be_true,
      "#{label}: new mismatch at #{change.path.inspect}"
  end
end

def assert_reconciliation(reconciliation : Reconciliation, expected : ReconcileCase) : Nil
  assert_changes(reconciliation.base_changes, expected.base_changes, "base")
  assert_changes(reconciliation.local_changes, expected.local_changes, "local")
  assert_changes(reconciliation.remote_changes, expected.remote_changes, "remote")

  reconciliation.conflicts.map(&.root).sort!.should eq(expected.conflicts.map(&.root).sort!)
  reconciliation.troubles.sort_by! { |trouble| {trouble.path, trouble.side.value} }
    .should eq(expected.troubles.sort_by { |trouble| {trouble.path, trouble.side.value} })
end
