require "file_utils"

# A temporary directory tree for one example. `Sandbox.open` creates it and removes it when the
# block ends. Paths given to every method are relative to the sandbox, and `directory` returns a
# sandbox rooted at the child so a test can hand out `local` and `remote` trees.
struct Sandbox
  def self.open(& : Sandbox -> T) : T forall T
    root = File.join(Dir.tempdir, "pylon-spec-#{Random::Secure.hex(8)}")
    Dir.mkdir_p(root)

    begin
      yield new(root)
    ensure
      FileUtils.rm_rf(root)
    end
  end

  def initialize(@root : String) : Nil
  end

  getter root : String

  def path(relative : String) : String
    File.join(@root, relative)
  end

  def directory(relative : String) : Sandbox
    Dir.mkdir_p(path(relative))
    Sandbox.new(path(relative))
  end

  def write(relative : String, content : String | Bytes) : String
    target = path(relative)
    Dir.mkdir_p(File.dirname(target))
    File.write(target, content)
    target
  end

  def read(relative : String) : String
    File.read(path(relative))
  end

  def exists?(relative : String) : Bool
    File.exists?(path(relative))
  end

  def directory?(relative : String) : Bool
    Dir.exists?(path(relative))
  end

  def children(relative : String = "") : Array(String)
    Dir.children(path(relative)).sort!
  end

  def remove(relative : String) : Nil
    FileUtils.rm_rf(path(relative))
  end

  def rename(from : String, to : String) : Nil
    File.rename(path(from), path(to))
  end

  def chmod(relative : String, mode : Int) : Nil
    File.chmod(path(relative), mode)
  end

  def info(relative : String) : File::Info
    File.info(path(relative), follow_symlinks: false)
  end
end
