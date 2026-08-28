require "../../spec_helper"
require "../../../src/pylon/core/change"

private CONTENTS = {nil, Fixtures.f1, Fixtures.f2, Fixtures.f1x}
private NAMES    = {"a", "b"}

private def random_entry(random : Random, depth : Int32) : Entry?
  return CONTENTS[random.rand(CONTENTS.size)] if depth <= 0 || random.rand(3) == 0

  contents = {} of String => Entry
  NAMES.each do |name|
    if (child = random_entry(random, depth - 1))
      contents[name] = child
    end
  end

  Entry.directory(contents)
end

describe "expanding changes" do
  it "leaves a file change alone" do
    changes = [Change.new("a.rb", nil, Fixtures.f1)]

    Change.expand(changes).size.should eq(1)
  end

  it "leaves a deletion as a single change" do
    Change.expand([Change.new("app", Fixtures.d1, nil)]).size.should eq(1)
  end

  it "turns a subtree into one change per entry" do
    subtree = Entry.directory({"models" => Entry.directory({"user.rb" => Fixtures.f1})})

    expanded = Change.expand([Change.new("app", nil, subtree)])

    expanded.map(&.path).should eq(["app", "app/models", "app/models/user.rb"])
    expanded.first.new.not_nil!.contents.should be_empty
  end

  it "produces the same tree as the change it replaced" do
    seed = 20260910_u64
    random = Random.new(seed)

    300.times do |iteration|
      base = random_entry(random, 2)
      target = random_entry(random, 2)
      change = [Change.new("", base, target)]

      direct = Applier.apply(base, change)
      widened = Applier.apply(base, Change.expand(change))

      Entry.equal?(direct, widened).should be_true, "seed=#{seed} iteration=#{iteration}"
    end
  end
end
