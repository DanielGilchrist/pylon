require "../../spec_helper"
require "../../../src/pylon/core/change"

private CONTENTS = {
  nil,
  Fixtures.f1,
  Fixtures.f2,
  Fixtures.f1x,
  Fixtures.symlink_relative,
  Fixtures.symlink_absolute,
  Fixtures.untracked,
  Fixtures.problematic,
}
private NAMES = {"a", "b"}

private def random_entry(random : Random, depth : Int32) : Entry?
  return CONTENTS[random.rand(CONTENTS.size)] if depth <= 0 || random.rand(3) == 0

  contents = Hash(String, Entry).new
  NAMES.each do |name|
    if (child = random_entry(random, depth - 1))
      contents[name] = child
    end
  end

  Pylon::Core::Directory.new(contents)
end

describe "expanding changes" do
  it "leaves a file change alone" do
    changes = [Change.new("a.rb", nil, Fixtures.f1)]

    Changes.expand(changes).size.should eq(1)
  end

  it "leaves a deletion as a single change" do
    Changes.expand([Change.new("app", Fixtures.d1, nil)]).size.should eq(1)
  end

  it "turns a subtree into one change per entry" do
    subtree = Pylon::Core::Directory.new(
      {"models" => Pylon::Core::Directory.new({"user.rb" => Fixtures.f1})},
    )

    expanded = Changes.expand([Change.new("app", nil, subtree)])

    expanded.map(&.path).should eq(["app", "app/models", "app/models/user.rb"])
    root = expanded.first.new
    root.is_a?(Pylon::Core::Directory).should be_true
    root.contents.should be_empty if root.is_a?(Pylon::Core::Directory)
  end

  it "produces the same tree as the change it replaced" do
    seed = 20_260_910_u64
    random = Random.new(seed)

    300.times do |iteration|
      base = random_entry(random, 2)
      target = random_entry(random, 2)
      change = Changes[Change.new("", base, target)]

      direct = Applier.apply(base, change)
      widened = Applier.apply(base, Changes.expand(change))

      (direct == widened).should be_true, "seed=#{seed} iteration=#{iteration}"
    end
  end
end
