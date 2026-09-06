require "../../spec_helper"

private alias Applier = Pylon::Core::Applier
private alias Change = Pylon::Core::Change
private alias Changes = Pylon::Core::Changes

private def base_with_d : Pylon::Core::Entry
  Fixtures.dir({"d" => Fixtures.dir({"x" => Fixtures.f1}), "keep.rb" => Fixtures.f2})
end

describe Applier do
  it "returns the base untouched when there are no changes" do
    base = base_with_d

    (Applier.apply(base, Changes.new) == base).should be_true
  end

  it "does not resurrect a deleted directory when deletions inside it land afterwards" do
    applied = Applier.apply(base_with_d, Changes[
      Change.new("d", Fixtures.dir({"x" => Fixtures.f1}), nil),
      Change.new("d/x", Fixtures.f1, nil),
    ])

    Fixtures.directory!(applied).contents.keys.should eq(["keep.rb"])
  end

  it "recreates a deleted directory when a create inside it lands afterwards" do
    applied = Applier.apply(base_with_d, Changes[
      Change.new("d", Fixtures.dir({"x" => Fixtures.f1}), nil),
      Change.new("d/y", nil, Fixtures.f2),
    ])

    Fixtures.directory!(Fixtures.dig!(applied, "d")).contents.keys.should eq(["y"])
  end

  it "lets a later whole tree assignment override earlier child changes" do
    applied = Applier.apply(base_with_d, Changes[
      Change.new("d/x", Fixtures.f1, Fixtures.f2),
      Change.new("d", Fixtures.dir({"x" => Fixtures.f1}), Fixtures.dir({"z" => Fixtures.f1})),
    ])

    Fixtures.directory!(Fixtures.dig!(applied, "d")).contents.keys.should eq(["z"])
  end
end
