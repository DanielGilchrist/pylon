require "spec"
require "../src/pylon/prelude"
require "./support/allocations"
require "./support/privileges"
require "./support/waiting"
require "./support/sandbox"
require "./support/entries"

private alias Changes = Pylon::Core::Changes
private alias Discard = Pylon::Discard
private alias Entry = Pylon::Core::Entry
private alias LocalEndpoint = Pylon::Session::LocalEndpoint
private alias Preferences = Pylon::Core::Preferences
private alias Report = Pylon::Session::Report
private alias Session = Pylon::Session::Session
private alias Trouble = Pylon::Core::Trouble
private alias Reconciliation = Pylon::Core::Reconciliation

def local_endpoint(root : Sandbox) : LocalEndpoint
  local_endpoint(root.root)
end

def local_endpoint(root : String) : LocalEndpoint
  LocalEndpoint.new(
    root,
    Pylon::Scan::Ignores::NONE,
    compression: Pylon::Compress::Zstd::DEFAULT_LEVEL,
  )
end

def build_session(
  local : A,
  remote : B,
  preferences : Preferences = Fixtures::NONE,
  base : Entry? = nil,
  dry_run : Bool = false,
  push_first : Bool = false,
) : Session(A, B, Discard) forall A, B
  build_session(
    local,
    remote,
    narrator: Discard.new,
    preferences: preferences,
    base: base,
    dry_run: dry_run,
    push_first: push_first,
  )
end

def build_session(
  local : A,
  remote : B,
  *,
  narrator : N,
  preferences : Preferences = Fixtures::NONE,
  base : Entry? = nil,
  dry_run : Bool = false,
  push_first : Bool = false,
) : Session(A, B, N) forall A, B, N
  Session.new(
    local,
    remote,
    preferences: preferences,
    base: base,
    dry_run: dry_run,
    push_first: push_first,
    narrator: narrator,
  )
end

def cycle!(session : Session, now_ns : Int64) : Report
  result = session.cycle(now_ns)
  return result if result.is_a?(Report)

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
  conflicts : Array(String) = Array(String).new,
  troubles : Array(Trouble) = Array(Trouble).new

def assert_changes(actual : Changes, expected : Changes, label : String) : Nil
  actual.size.should eq(expected.size), "#{label}: expected #{expected.size} change(s), got " \
                                        "#{actual.size}"

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

  reconciliation.conflicts.sort!.should eq(expected.conflicts.sort!)
  reconciliation.troubles.sort_by! { |trouble| {trouble.path, trouble.replica.value} }
    .should eq(expected.troubles.sort_by { |trouble| {trouble.path, trouble.replica.value} })
end

def assert_descriptor_change(expected : Int32, & : ->) : Nil
  before = Dir.children("/dev/fd").size
  yield
  (Dir.children("/dev/fd").size - before).should eq(expected)
end

def assert_not_root : Nil
  running_as_root?.should be_false,
    "Can't run specs as root as it bypasses permissions which breaks this spec"
end
