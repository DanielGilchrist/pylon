require "benchmark"
require "../src/pylon/core"

include Pylon::Core

DIRECTORIES  = 8_000
FILES_PER    =     5
DIGEST_ALPHA = "a".to_slice
DIGEST_BETA  = "b".to_slice

def build_tree : Directory
  root = Hash(String, Entry).new

  DIRECTORIES.times do |index|
    contents = Hash(String, Entry).new
    FILES_PER.times do |file|
      contents["file_#{file}.rb"] = Pylon::Core::File.new(DIGEST_ALPHA, executable: false)
    end
    root["dir_#{index}"] = Pylon::Core::Directory.new(contents)
  end

  Pylon::Core::Directory.new(root)
end

def with_one_change(tree : Directory) : Directory
  root = tree.contents.dup
  target = root["dir_4000"]
  raise "expected dir_4000 to be a directory" unless target.is_a?(Directory)

  contents = target.contents.dup
  contents["file_2.rb"] = Pylon::Core::File.new(DIGEST_BETA, executable: false)
  root["dir_4000"] = Directory.new(contents)

  Directory.new(root)
end

tree = build_tree
changed = with_one_change(tree)
preferences = Preferences.build(Array(String).new, Array(String).new)
raise "expected empty preferences to build" if preferences.is_a?(Preferences::Invalid)
entries = DIRECTORIES * FILES_PER

puts "tree: #{DIRECTORIES} directories, #{entries} files"
puts

before = GC.stats.total_bytes
Reconciler.reconcile(tree, tree, tree, preferences)
puts "steady-state allocation: #{(GC.stats.total_bytes - before) // 1024} KiB"

before = GC.stats.total_bytes
Reconciler.reconcile(tree, changed, tree, preferences)
puts "one-change allocation:   #{(GC.stats.total_bytes - before) // 1024} KiB"
puts

Benchmark.ips do |x|
  x.report("reconcile, no changes") do
    Reconciler.reconcile(tree, tree, tree, preferences)
  end

  x.report("reconcile, one file changed") do
    Reconciler.reconcile(tree, changed, tree, preferences)
  end
end
