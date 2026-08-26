require "../../spec_helper"

private F1 = Fixtures.f1
private F2 = Fixtures.f2
private FX = Fixtures.f1x
private UN = Fixtures.untracked
private PR = Fixtures.problematic
private D0 = Fixtures.d0
private D1 = Fixtures.d1

private CASES = {
  ReconcileCase.new(
    description: "empty everywhere",
    modes: Fixtures::ALL_MODES,
    base: nil, local: nil, remote: nil,
  ),
  ReconcileCase.new(
    description: "both sides already hold the same file",
    modes: Fixtures::ALL_MODES,
    base: nil, local: F1, remote: F1,
    base_changes: [Change.new("", nil, F1)],
  ),
  ReconcileCase.new(
    description: "local created a file",
    modes: Fixtures::ALL_MODES,
    base: nil, local: F1, remote: nil,
    base_changes: [Change.new("", nil, F1)],
    remote_changes: [Change.new("", nil, F1)],
  ),
  ReconcileCase.new(
    description: "remote created a file",
    modes: Fixtures::ALL_MODES,
    base: nil, local: nil, remote: F1,
    base_changes: [Change.new("", nil, F1)],
    local_changes: [Change.new("", nil, F1)],
  ),
  ReconcileCase.new(
    description: "local modified a file",
    modes: Fixtures::ALL_MODES,
    base: F1, local: F2, remote: F1,
    base_changes: [Change.new("", F1, F2)],
    remote_changes: [Change.new("", F1, F2)],
  ),
  ReconcileCase.new(
    description: "remote modified a file",
    modes: Fixtures::ALL_MODES,
    base: F1, local: F1, remote: F2,
    base_changes: [Change.new("", F1, F2)],
    local_changes: [Change.new("", F1, F2)],
  ),
  ReconcileCase.new(
    description: "only the executable bit changed on local",
    modes: Fixtures::ALL_MODES,
    base: F1, local: FX, remote: F1,
    base_changes: [Change.new("", F1, FX)],
    remote_changes: [Change.new("", F1, FX)],
  ),
  ReconcileCase.new(
    description: "both sides modified the file differently",
    modes: Fixtures::SAFE_MODES,
    base: F1, local: F2, remote: FX,
    conflicts: [Conflict.new("", [] of Change, [] of Change)],
  ),
  ReconcileCase.new(
    description: "both sides modified the file differently",
    modes: Fixtures::RESOLVED_MODES,
    base: F1, local: F2, remote: FX,
    base_changes: [Change.new("", F1, F2)],
    remote_changes: [Change.new("", FX, F2)],
  ),
  ReconcileCase.new(
    description: "both sides made the same modification",
    modes: Fixtures::ALL_MODES,
    base: F1, local: F2, remote: F2,
    base_changes: [Change.new("", F1, F2)],
  ),
  ReconcileCase.new(
    description: "local deleted a file remote left alone",
    modes: Fixtures::ALL_MODES,
    base: F1, local: nil, remote: F1,
    base_changes: [Change.new("", F1, nil)],
    remote_changes: [Change.new("", F1, nil)],
  ),
  ReconcileCase.new(
    description: "local deleted a file remote modified, so the content wins",
    modes: Fixtures::ALL_MODES,
    base: F1, local: nil, remote: F2,
    base_changes: [Change.new("", F1, F2)],
    local_changes: [Change.new("", nil, F2)],
  ),
  ReconcileCase.new(
    description: "both sides deleted the file",
    modes: Fixtures::ALL_MODES,
    base: F1, local: nil, remote: nil,
    base_changes: [Change.new("", F1, nil)],
  ),
  ReconcileCase.new(
    description: "ignored on both sides drops out of tracking",
    modes: Fixtures::ALL_MODES,
    base: F1, local: UN, remote: UN,
    base_changes: [Change.new("", F1, nil)],
  ),
  ReconcileCase.new(
    description: "ignored on local but real content on remote is a conflict",
    modes: Fixtures::ALL_MODES,
    base: nil, local: UN, remote: F1,
    conflicts: [Conflict.new("", [] of Change, [] of Change)],
  ),
  ReconcileCase.new(
    description: "unreadable content on local halts that path",
    modes: Fixtures::ALL_MODES,
    base: F1, local: PR, remote: F2,
  ),
  ReconcileCase.new(
    description: "local created a directory",
    modes: Fixtures::ALL_MODES,
    base: nil, local: D1, remote: nil,
    base_changes: [Change.new("", nil, D1)],
    remote_changes: [Change.new("", nil, D1)],
  ),
  ReconcileCase.new(
    description: "local added a file inside a shared directory",
    modes: Fixtures::ALL_MODES,
    base: D0, local: D1, remote: D0,
    base_changes: [Change.new("file", nil, F1)],
    remote_changes: [Change.new("file", nil, F1)],
  ),
  ReconcileCase.new(
    description: "each side added a different file to a shared directory",
    modes: Fixtures::ALL_MODES,
    base: D0,
    local: Fixtures.dir({"a" => F1}),
    remote: Fixtures.dir({"b" => F2}),
    base_changes: [Change.new("a", nil, F1), Change.new("b", nil, F2)],
    local_changes: [Change.new("b", nil, F2)],
    remote_changes: [Change.new("a", nil, F1)],
  ),
  ReconcileCase.new(
    description: "local replaced a file with a directory",
    modes: Fixtures::ALL_MODES,
    base: F1, local: D1, remote: F1,
    base_changes: [Change.new("", F1, D1)],
    remote_changes: [Change.new("", F1, D1)],
  ),
}

describe Pylon::Core::Reconciler do
  CASES.each do |reconcile_case|
    reconcile_case.modes.each do |mode|
      it "#{reconcile_case.description} (#{mode})" do
        reconciliation = Reconciler.reconcile(
          reconcile_case.base,
          reconcile_case.local,
          reconcile_case.remote,
          mode,
        )

        assert_reconciliation(reconciliation, reconcile_case)
      end
    end
  end
end
