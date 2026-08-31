require "file_utils"
require "../spec_helper"
require "../../src/pylon/disk"

include Pylon

private def in_sandbox(& : String, Disk ->)
  root = File.join(Dir.tempdir, "pylon-target-#{Random::Secure.hex(8)}")
  Dir.mkdir_p(root)

  begin
    yield root, Disk.new(root)
  ensure
    FileUtils.rm_rf(root)
  end
end

describe Pylon::Disk do
  it "writes a file and sets the executable bit" do
    in_sandbox do |root, target|
      target.write_file("script.sh", "#!/bin/sh\n".to_slice, true).should be_nil

      File.read(File.join(root, "script.sh")).should eq("#!/bin/sh\n")
      File.info(File.join(root, "script.sh")).permissions.value.should eq(0o755)
    end
  end

  it "replaces an existing file without ever leaving the path missing" do
    in_sandbox do |root, target|
      path = File.join(root, "notes.txt")
      File.write(path, "before")
      original_inode = Fixtures.metadata!(Pylon::Scan::Metadata.of(path)).inode

      target.write_file("notes.txt", "after".to_slice, false).should be_nil

      File.read(path).should eq("after")
      Fixtures.metadata!(Pylon::Scan::Metadata.of(path)).inode.should_not eq(original_inode)
    end
  end

  it "leaves no temporary files behind on success" do
    in_sandbox do |root, target|
      target.write_file("a.txt", "x".to_slice, false)
      target.create_symlink("link", "a.txt")

      strays = Dir.children(root).select(&.starts_with?(Disk::TEMPORARY_PREFIX))
      strays.should be_empty
    end
  end

  it "creates a symlink and reads its target back" do
    in_sandbox do |root, target|
      target.create_symlink("link", "elsewhere.txt").should be_nil

      File.readlink(File.join(root, "link")).should eq("elsewhere.txt")
      Fixtures.metadata!(Pylon::Scan::Metadata.of(File.join(root, "link"))).kind.should eq(Pylon::Scan::Metadata::Kind::SymbolicLink)
    end
  end

  it "replaces an existing symlink" do
    in_sandbox do |root, target|
      target.create_symlink("link", "first").should be_nil
      target.create_symlink("link", "second").should be_nil

      File.readlink(File.join(root, "link")).should eq("second")
    end
  end

  it "toggles the executable bit while preserving other permissions" do
    in_sandbox do |root, target|
      path = File.join(root, "f")
      File.write(path, "x")
      File.chmod(path, 0o640)

      target.set_executable("f", true).should be_nil
      File.info(path).permissions.value.should eq(0o750)

      target.set_executable("f", false).should be_nil
      File.info(path).permissions.value.should eq(0o640)
    end
  end

  it "reports why a directory could not be removed instead of pretending it was" do
    in_sandbox do |root, target|
      stuck = File.join(root, "stuck")
      Dir.mkdir_p(stuck)
      File.write(File.join(stuck, "kept.txt"), "still here")
      File.chmod(stuck, 0o555)

      begin
        problem = target.remove("stuck")
        problem.should be_a(Pylon::Problem)
        File.exists?(File.join(stuck, "kept.txt")).should be_true
      ensure
        File.chmod(stuck, 0o755)
      end
    end
  end

  it "removes files and whole directories" do
    in_sandbox do |root, target|
      Dir.mkdir_p(File.join(root, "app", "models"))
      File.write(File.join(root, "app", "models", "user.rb"), "x")

      target.remove("app").should be_nil
      Dir.exists?(File.join(root, "app")).should be_false
    end
  end

  it "treats removing a missing path as done" do
    in_sandbox do |_, target|
      target.remove("never-existed").should be_nil
    end
  end

  it "does not follow a symlink when removing it" do
    in_sandbox do |root, target|
      File.write(File.join(root, "real.txt"), "keep me")
      target.create_symlink("link", "real.txt")

      target.remove("link").should be_nil
      File.exists?(File.join(root, "real.txt")).should be_true
      File.exists?(File.join(root, "link")).should be_false
    end
  end
end
