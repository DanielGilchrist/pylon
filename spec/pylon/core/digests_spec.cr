require "../../spec_helper"

private alias Change = Pylon::Core::Change
private alias Changes = Pylon::Core::Changes
private alias Collector = Pylon::Core::Digests::Collector
private alias Digests = Pylon::Core::Digests
private alias Directory = Pylon::Core::Directory

describe Digests do
  it "asks for each digest once no matter how many changes share it" do
    changes = Changes[
      Change.new("a.rb", nil, Fixtures.f1),
      Change.new("copy_of_a.rb", nil, Fixtures.f1),
      Change.new("b.rb", nil, Fixtures.f2),
    ]

    Collector.new.required(changes, 0).should eq([Fixtures::D1, Fixtures::D2])
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

    Collector.new.required(changes, 0).should eq([Fixtures::D2])
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

describe "Pylon::Core::Digests.fingerprint" do
  it "does not depend on the order directory contents were inserted" do
    forwards = Directory.new({"a.rb" => Fixtures.f1, "b.rb" => Fixtures.f2})
    backwards = Directory.new({"b.rb" => Fixtures.f2, "a.rb" => Fixtures.f1})

    Digests.fingerprint(forwards).should eq(Digests.fingerprint(backwards))
  end

  it "changes when any entry changes" do
    original = Fixtures.dir({"app" => Fixtures.dir({"a.rb" => Fixtures.f1})})
    edited = Fixtures.dir({"app" => Fixtures.dir({"a.rb" => Fixtures.f2})})
    flipped = Fixtures.dir({"app" => Fixtures.dir({"a.rb" => Fixtures.f1x})})

    Digests.fingerprint(original).should_not eq(Digests.fingerprint(edited))
    Digests.fingerprint(original).should_not eq(Digests.fingerprint(flipped))
    Digests.fingerprint(nil).should_not eq(Digests.fingerprint(Directory.new))
  end
end
