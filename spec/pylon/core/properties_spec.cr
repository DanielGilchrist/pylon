require "../../spec_helper"

private CONVERGING_CONTENTS = {nil, Fixtures.f1, Fixtures.f2, Fixtures.f1x, Fixtures.untracked, Fixtures.symlink_relative}
private ALL_CONTENTS        = {nil, Fixtures.f1, Fixtures.f2, Fixtures.f1x, Fixtures.untracked, Fixtures.symlink_relative, Fixtures.problematic}
private NAMES               = {"a", "b"}

private def random_entry(random : Random, depth : Int32, pool : Tuple = ALL_CONTENTS) : Entry?
  if depth <= 0 || random.rand(3) == 0
    return pool[random.rand(pool.size)]
  end

  contents = {} of String => Entry
  NAMES.each do |name|
    if (child = random_entry(random, depth - 1, pool))
      contents[name] = child
    end
  end

  Pylon::Core::Directory.new(contents)
end

private def random_base(random : Random, depth : Int32) : Entry?
  random_entry(random, depth).try(&.syncable)
end

private def readable_twin(entry : Entry?) : Entry?
  case entry
  in Nil, Pylon::Core::File, Pylon::Core::SymbolicLink, Pylon::Core::Untracked
    entry
  in Pylon::Core::Problematic
    Fixtures.f1
  in Pylon::Core::Directory
    contents = {} of String => Entry
    entry.contents.each { |name, child| contents[name] = readable_twin(child) || child }
    Pylon::Core::Directory.new(contents)
  end
end

private def collect_problematic_paths(path : String, entry : Entry?, into : Set(String)) : Nil
  case entry
  in Nil, Pylon::Core::File, Pylon::Core::SymbolicLink, Pylon::Core::Untracked
    nil
  in Pylon::Core::Problematic
    into << path
  in Pylon::Core::Directory
    entry.contents.each do |name, child|
      collect_problematic_paths(Pylon::Core::Paths.join(path, name), child, into)
    end
  end
end

private def dig(entry : Entry?, path : String) : Entry?
  return entry if path.empty?

  current = entry

  path.split('/').each do |name|
    return unless current.is_a?(Pylon::Core::Directory)

    current = current.contents[name]?
  end

  current
end

private def contains_unsyncable?(entry : Entry) : Bool
  return true unless entry.is_a?(Syncable)
  return false unless entry.is_a?(Pylon::Core::Directory)

  entry.contents.each_value.any? { |child| contains_unsyncable?(child) }
end

private def syncable_projection(entry : Entry?) : Entry?
  entry.try(&.syncable)
end

describe "reconciler properties" do
  it "applying a reconciliation leaves nothing further to do" do
    seed = 20260826_u64
    random = Random.new(seed)

    200.times do |iteration|
      Fixtures::ALL_PREFERENCES.each do |mode|
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
      local = random_entry(random, 2, CONVERGING_CONTENTS)
      remote = random_entry(random, 2, CONVERGING_CONTENTS)

      {Fixtures::LOCAL_WINS, Fixtures::REMOTE_WINS}.each do |preferences|
        reconciliation = Reconciler.reconcile(base, local, remote, preferences)
        next unless reconciliation.conflicts.empty?

        next_local = Applier.apply(local, reconciliation.local_changes)
        next_remote = Applier.apply(remote, reconciliation.remote_changes)

        converged =
          syncable_projection(next_local) == syncable_projection(next_remote)

        converged.should be_true,
          "seed=#{seed} iteration=#{iteration} side=#{preferences.winner("")}: replicas diverged\nalpha=#{next_local.inspect}\nbeta=#{next_remote.inspect}"
      end
    end
  end

  it "never records an unsyncable entry in the base" do
    seed = 20260828_u64
    random = Random.new(seed)

    200.times do |iteration|
      Fixtures::ALL_PREFERENCES.each do |mode|
        base = random_base(random, 2)
        local = random_entry(random, 2)
        remote = random_entry(random, 2)

        reconciliation = Reconciler.reconcile(base, local, remote, mode)
        updated = Applier.apply(base, reconciliation.base_changes)

        next if updated.nil?

        contains_unsyncable?(updated).should be_false,
          "seed=#{seed} iteration=#{iteration} mode=#{mode}: base holds unsyncable content"
      end
    end
  end

  it "keeps the base entry for every path that is unreadable on both sides" do
    seed = 20260902_u64
    random = Random.new(seed)

    200.times do |iteration|
      Fixtures::ALL_PREFERENCES.each do |mode|
        local = random_entry(random, 2)
        remote = random.rand(2) == 0 ? local : random_entry(random, 2)
        base = readable_twin(local).try(&.syncable)

        reconciliation = Reconciler.reconcile(base, local, remote, mode)
        updated = Applier.apply(base, reconciliation.base_changes)

        local_unreadable = Set(String).new
        remote_unreadable = Set(String).new
        collect_problematic_paths("", local, local_unreadable)
        collect_problematic_paths("", remote, remote_unreadable)

        (local_unreadable & remote_unreadable).each do |path|
          (dig(updated, path) == dig(base, path)).should be_true,
            "seed=#{seed} iteration=#{iteration} mode=#{mode}: the base changed at unreadable path #{path.inspect}"
        end
      end
    end
  end
end
