require "../../spec_helper"
require "../../../src/pylon/core/digests"

describe Pylon::Core::Digests do
  it "asks for each digest once no matter how many changes share it" do
    changes = Changes[
      Change.new("a.rb", nil, Fixtures.f1),
      Change.new("copy_of_a.rb", nil, Fixtures.f1),
      Change.new("b.rb", nil, Fixtures.f2),
    ]

    Digests::Collector.new.required(changes).should eq([Fixtures::D1, Fixtures::D2])
  end

  it "walks into directories and ignores everything without content" do
    subtree = Fixtures.dir({
      "nested" => Fixtures.dir({"file" => Fixtures.f2}),
      "link"   => Fixtures.symlink_relative,
      "odd"    => Fixtures.untracked,
    })

    changes = Changes[
      Change.new("app", nil, subtree),
      Change.new("gone.rb", Fixtures.f1, nil),
    ]

    Digests::Collector.new.required(changes).should eq([Fixtures::D2])
  end

  it "collects every digest in a tree" do
    tree = Fixtures.dir({
      "a.rb"   => Fixtures.f1,
      "nested" => Fixtures.dir({"b.rb" => Fixtures.f2, "copy.rb" => Fixtures.f1}),
      "link"   => Fixtures.symlink_relative,
      "odd"    => Fixtures.untracked,
    })

    Digests.all(tree).should eq(Set{Fixtures::D1, Fixtures::D2})
  end

  it "collects nothing from an absent tree" do
    Digests.all(nil).should be_empty
  end
end
