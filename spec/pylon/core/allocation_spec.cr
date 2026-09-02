require "../../spec_helper"

private FILES = 4_000

private def wide_tree(files : Int32) : Entry
  directories = Hash(String, Entry).new

  20.times do |directory|
    contents = Hash(String, Entry).new
    (files // 20).times { |file| contents["file_#{file}.rb"] = Fixtures.f1 }
    directories["dir_#{directory}"] = Pylon::Core::Directory.new(contents)
  end

  Pylon::Core::Directory.new(directories)
end

private def changes_for(tree : Entry) : Changes
  Changes.expand([Change.new("", nil, tree)])
end

describe "allocation budgets" do
  it "applies thousands of changes in a single pass over each directory" do
    changes = changes_for(wide_tree(FILES))
    changes.size.should be > FILES

    assert_allocates_under(8 * MIB, "applying #{changes.size} changes") do
      Applier.apply(nil, changes)
    end
  end

  it "reconciles two identical trees without allocating" do
    tree = wide_tree(FILES)

    assert_allocates_under(16 * KIB, "reconciling two identical #{FILES} file trees") do
      Reconciler.reconcile(tree, tree, tree)
    end
  end

  it "expands a subtree change proportionally to the tree" do
    tree = wide_tree(FILES)

    assert_allocates_under(4 * MIB, "expanding a #{FILES} file subtree change") do
      changes_for(tree)
    end
  end
end
