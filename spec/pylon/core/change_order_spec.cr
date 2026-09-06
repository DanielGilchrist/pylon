require "../../spec_helper"
require "../../../src/pylon/core/changes"

private alias Change = Pylon::Core::Change
private alias Changes = Pylon::Core::Changes

private NOTHING_LATE = Set(Bytes).new

describe "Pylon::Core::Changes#ordered_for_writing" do
  it "moves deletions behind every other change without disturbing their order" do
    changes = Changes[
      Change.new("gone.rb", Fixtures.f1, nil),
      Change.new("kept.rb", nil, Fixtures.f1),
      Change.new("dir", Fixtures.d1, nil),
      Change.new("swapped.rb", Fixtures.f1, Fixtures.f2),
    ]

    changes.ordered_for_writing(NOTHING_LATE).map(&.path).should eq(
      ["kept.rb", "swapped.rb", "gone.rb", "dir"],
    )
  end

  it "moves late digests behind other writes but ahead of deletions" do
    changes = Changes[
      Change.new("late.rb", Fixtures.f1, Fixtures.f2),
      Change.new("gone.rb", Fixtures.f1, nil),
      Change.new("kept.rb", nil, Fixtures.f1),
    ]

    ordered = changes.ordered_for_writing(Set{Fixtures::D2})

    ordered.map(&.path).should eq(["kept.rb", "late.rb", "gone.rb"])
  end

  it "runs a delete first when a surviving path differs only in case" do
    changes = Changes[
      Change.new("README.md", nil, Fixtures.f1),
      Change.new("Readme.md", Fixtures.f1, nil),
      Change.new("gone.rb", Fixtures.f1, nil),
    ]

    ordered = changes.ordered_for_writing(NOTHING_LATE).map(&.path)
    ordered.should eq(["Readme.md", "README.md", "gone.rb"])
  end

  it "leaves a list without deletions untouched" do
    changes = Changes[
      Change.new("a.rb", nil, Fixtures.f1),
      Change.new("b.rb", Fixtures.f1, Fixtures.f2),
    ]

    changes.ordered_for_writing(NOTHING_LATE).should eq(changes)
  end
end
