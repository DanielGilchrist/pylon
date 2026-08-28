require "../../spec_helper"

private CONTENTS = {nil, Fixtures.f1, Fixtures.f2, Fixtures.f1x, Fixtures.untracked}
private NAMES    = {"a", "b"}

private def random_entry(random : Random, depth : Int32) : Entry?
  if depth <= 0 || random.rand(3) == 0
    return CONTENTS[random.rand(CONTENTS.size)]
  end

  contents = {} of String => Entry
  NAMES.each do |name|
    if (child = random_entry(random, depth - 1))
      contents[name] = child
    end
  end

  Entry.directory(contents)
end

private def random_base(random : Random, depth : Int32) : Entry?
  Entry.synchronizable(random_entry(random, depth))
end

private def synchronizable_projection(entry : Entry?) : Entry?
  Entry.synchronizable(entry)
end

describe "reconciler properties" do
  it "applying a reconciliation leaves nothing further to do" do
    seed = 20260826_u64
    random = Random.new(seed)

    200.times do |iteration|
      Fixtures::ALL_MODES.each do |mode|
        base = random_base(random, 2)
        local = random_entry(random, 2)
        remote = random_entry(random, 2)

        first = Reconciler.reconcile(base, local, remote, mode)

        next_base = Applier.apply(base, first.base_changes)
        next_local = Applier.apply(local, first.local_changes)
        next_remote = Applier.apply(remote, first.remote_changes)

        second = Reconciler.reconcile(next_base, next_local, next_remote, mode)

        context = "seed=#{seed} iteration=#{iteration} mode=#{mode}"
        second.base_changes.should be_empty, "#{context}: base changes on second pass"
        second.local_changes.should be_empty, "#{context}: local changes on second pass"
        second.remote_changes.should be_empty, "#{context}: remote changes on second pass"
      end
    end
  end

  it "converges both replicas when there is no conflict" do
    seed = 20260827_u64
    random = Random.new(seed)

    200.times do |iteration|
      base = random_base(random, 2)
      local = random_entry(random, 2)
      remote = random_entry(random, 2)

      reconciliation = Reconciler.reconcile(base, local, remote, SyncMode::TwoWayResolved)
      next unless reconciliation.conflicts.empty?

      next_local = Applier.apply(local, reconciliation.local_changes)
      next_remote = Applier.apply(remote, reconciliation.remote_changes)

      converged = Entry.equal?(
        synchronizable_projection(next_local),
        synchronizable_projection(next_remote),
      )

      converged.should be_true,
        "seed=#{seed} iteration=#{iteration}: replicas diverged\nalpha=#{next_local.inspect}\nbeta=#{next_remote.inspect}"
    end
  end

  it "never records an unsynchronizable entry in the base" do
    seed = 20260828_u64
    random = Random.new(seed)

    200.times do |iteration|
      Fixtures::ALL_MODES.each do |mode|
        base = random_base(random, 2)
        local = random_entry(random, 2)
        remote = random_entry(random, 2)

        reconciliation = Reconciler.reconcile(base, local, remote, mode)
        updated = Applier.apply(base, reconciliation.base_changes)

        next if updated.nil?

        updated.contains_unsynchronizable?.should be_false,
          "seed=#{seed} iteration=#{iteration} mode=#{mode}: base holds unsynchronizable content"
      end
    end
  end
end
