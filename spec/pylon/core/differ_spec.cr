require "../../spec_helper"
require "../../../src/pylon/core/differ"

private alias Differ = Pylon::Core::Differ
private alias Directory = Pylon::Core::Directory
private alias Entry = Pylon::Core::Entry

private CONTENTS = {
  nil,
  Fixtures.f1,
  Fixtures.f2,
  Fixtures.f1x,
  Fixtures.d0,
  Fixtures.symlink_relative,
  Fixtures.symlink_absolute,
  Fixtures.untracked,
  Fixtures.problematic,
}
private NAMES = {"a", "b", "c"}

private def random_entry(random : Random, depth : Int32) : Entry?
  return CONTENTS[random.rand(CONTENTS.size)] if depth <= 0 || random.rand(3) == 0

  contents = Hash(String, Entry).new
  NAMES.each do |name|
    if (child = random_entry(random, depth - 1))
      contents[name] = child
    end
  end

  Directory.new(contents)
end

describe Differ do
  it "says nothing about identical trees" do
    Differ.diff(Fixtures.d1, Fixtures.d1).should be_empty
  end

  it "describes a single changed file, not the whole tree" do
    base = Directory.new({"a" => Fixtures.f1, "b" => Fixtures.f1})
    target = Directory.new({"a" => Fixtures.f2, "b" => Fixtures.f1})

    changes = Differ.diff(base, target)

    changes.size.should eq(1)
    changes.first.path.should eq("a")
  end

  it "describes additions and removals" do
    base = Directory.new({"gone" => Fixtures.f1})
    target = Directory.new({"added" => Fixtures.f2})

    Differ.diff(base, target).map(&.path).sort!.should eq(["added", "gone"])
  end

  it "collapses a replaced subtree into one change" do
    base = Directory.new(
      {"app" => Directory.new({"a" => Fixtures.f1, "b" => Fixtures.f2})},
    )
    target = Directory.new({"app" => Fixtures.f1})

    Differ.diff(base, target).map(&.path).should eq(["app"])
  end

  it "produces changes that rebuild the target exactly" do
    seed = 20_260_915_u64
    random = Random.new(seed)

    400.times do |iteration|
      base = random_entry(random, 3)
      target = random_entry(random, 3)

      rebuilt = Pylon::Core::Applier.apply(base, Differ.diff(base, target))

      (rebuilt == target).should be_true, "seed=#{seed} iteration=#{iteration}"
    end
  end

  it "stays small when little changed" do
    contents = Hash(String, Entry).new
    500.times { |index| contents["file_#{index}.rb"] = Fixtures.f1 }

    base = Directory.new(contents)
    changed = contents.dup
    changed["file_250.rb"] = Fixtures.f2
    target = Directory.new(changed)

    Differ.diff(base, target).size.should eq(1)
  end
end
