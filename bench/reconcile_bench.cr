require "benchmark"
require "../src/pylon/core"

include Pylon::Core

DIRECTORIES  = 8_000
FILES_PER    =     5
DIGEST_ALPHA = "a".to_slice
DIGEST_BETA  = "b".to_slice

def build_tree : Directory
  root = {} of String => Entry

  DIRECTORIES.times do |index|
    contents = {} of String => Entry
    FILES_PER.times { |file| contents["file_#{file}.rb"] = Pylon::Core::File.new(DIGEST_ALPHA) }
    root["dir_#{index}"] = Pylon::Core::Directory.new(contents)
  end

  Pylon::Core::Directory.new(root)
end

def with_one_change(tree : Directory) : Directory
  root = tree.contents.dup
  target = root["dir_4000"]
  raise "expected dir_4000 to be a directory" unless target.is_a?(Directory)

  contents = target.contents.dup
  contents["file_2.rb"] = Pylon::Core::File.new(DIGEST_BETA)
  root["dir_4000"] = Directory.new(contents)

  Directory.new(root)
end

tree = build_tree
changed = with_one_change(tree)
entries = DIRECTORIES * FILES_PER

puts "tree: #{DIRECTORIES} directories, #{entries} files"
puts

before = GC.stats.total_bytes
Reconciler.reconcile(tree, tree, tree)
puts "steady-state allocation: #{(GC.stats.total_bytes - before) // 1024} KiB"

before = GC.stats.total_bytes
Reconciler.reconcile(tree, changed, tree)
puts "one-change allocation:   #{(GC.stats.total_bytes - before) // 1024} KiB"
puts

Benchmark.ips do |x|
  x.report("reconcile, no changes") do
    Reconciler.reconcile(tree, tree, tree)
  end

  x.report("reconcile, one file changed") do
    Reconciler.reconcile(tree, changed, tree)
  end
end
