require "../../spec_helper"

private alias Change = Pylon::Core::Change
private alias Changes = Pylon::Core::Changes
private alias Problem = Pylon::Problem
private alias Relocation = Pylon::Core::Relocation

private def pairs_of(extraction : Pylon::Core::Relocation::Extraction) : Array({String, String})
  extraction.relocations.map { |relocation| {relocation.from, relocation.to} }
end

private def tree : Pylon::Core::Entry
  Fixtures.dir({"a.rb" => Fixtures.f1, "deep" => Fixtures.dir({"b.rb" => Fixtures.f2})})
end

describe Relocation do
  it "pairs a deleted tree with the same tree created elsewhere" do
    extraction = Relocation.extract(Changes[
      Change.new("lib", tree, nil),
      Change.new("kept.rb", nil, Fixtures.f2),
      Change.new("moved", nil, tree),
    ])

    pairs_of(extraction).should eq([{"lib", "moved"}])
    extraction.changes.map(&.path).should eq(["kept.rb"])
  end

  it "pairs a deleted file with an identical file created elsewhere" do
    extraction = Relocation.extract(Changes[
      Change.new("new/name.rb", nil, Fixtures.f1x),
      Change.new("old/name.rb", Fixtures.f1x, nil),
    ])

    pairs_of(extraction).should eq([{"old/name.rb", "new/name.rb"}])
    extraction.changes.should be_empty
  end

  it "leaves a tree that differs from the deleted one as a delete and a create" do
    grown = Fixtures.dir(
      {"a.rb" => Fixtures.f1, "deep" => Fixtures.dir(
        {"b.rb" => Fixtures.f2},
      ), "c.rb" => Fixtures.f1},
    )
    changes = Changes[Change.new("lib", tree, nil), Change.new("moved", nil, grown)]

    extraction = Relocation.extract(changes)

    extraction.relocations.should be_empty
    extraction.changes.should eq(changes)
  end

  it "does not pair a file whose mode changed on the way" do
    extraction = Relocation.extract(
      Changes[Change.new("a.rb", Fixtures.f1, nil), Change.new("b.rb", nil, Fixtures.f1x)],
    )

    extraction.relocations.should be_empty
  end

  it "never treats a replacement as a move" do
    extraction = Relocation.extract(
      Changes[Change.new("a.rb", Fixtures.f1, Fixtures.f2), Change.new("b.rb", nil, Fixtures.f1)],
    )

    extraction.relocations.should be_empty
  end

  it "pairs each deletion at most once and leaves the other copies as creates" do
    extraction = Relocation.extract(Changes[
      Change.new("one.rb", Fixtures.f1, nil),
      Change.new("first.rb", nil, Fixtures.f1),
      Change.new("second.rb", nil, Fixtures.f1),
    ])

    pairs_of(extraction).should eq([{"one.rb", "first.rb"}])
    extraction.changes.map(&.path).should eq(["second.rb"])
  end

  it "keeps a pair apart when a third path differs from the destination only in case" do
    extraction = Relocation.extract(Changes[
      Change.new("a.rb", Fixtures.f1, nil),
      Change.new("B.rb", nil, Fixtures.f1),
      Change.new("b.rb", Fixtures.f2, nil),
    ])

    extraction.relocations.should be_empty
  end

  it "leaves a rename that changes only the letter case to the delete-first path" do
    changes = Changes[Change.new("Readme.md", Fixtures.f1, nil), Change.new(
      "README.md",
      nil,
      Fixtures.f1,
    )]

    extraction = Relocation.extract(changes)

    extraction.relocations.should be_empty
    extraction.changes.should eq(changes)
  end

  it "returns the changes untouched when nothing pairs" do
    changes = Changes[Change.new("a.rb", nil, Fixtures.f1), Change.new("b.rb", Fixtures.f2, nil)]

    extraction = Relocation.extract(changes)

    extraction.relocations.should be_empty
    extraction.changes.should eq(changes)
  end

  it "refuses to move the sync root, a path onto itself, or a path into itself" do
    file = Fixtures.file!(Fixtures.f1)

    Relocation.parse("", "x", file).should be_a(Problem)
    Relocation.parse("x", "", file).should be_a(Problem)
    Relocation.parse("x", "x", file).should be_a(Problem)
    Relocation.parse("x", "x/y", file).should be_a(Problem)
    Relocation.parse("x/y", "x", file).should be_a(Problem)
    Relocation.parse("x", "xy", file).should be_a(Relocation)
  end

  it "refuses to move an entry that is not syncable" do
    Relocation.parse("a", "b", Fixtures.untracked).should be_a(Problem)
    Relocation.parse("a", "b", Fixtures.problematic).should be_a(Problem)
    Relocation.parse("a", "b", nil).should be_a(Problem)
  end
end
