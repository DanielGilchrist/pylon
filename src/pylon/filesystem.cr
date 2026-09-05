require "file_utils"
require "./problem"
require "./missing"
require "./filesystem/pattern"
require "./filesystem/lib_clone"
require "./platform"

module Pylon
  # stdlibs filesystem APIs (`File`, `Dir`, `FileUtils`) report failures (a vanished path,
  # permissions, a full disk) by throwing exceptions and rarely offer non-throwing variants.
  # We want to avoid exceptions as they can leave the application in undesirable states but also
  # make potential failures invisible to the type system. Here we effectively wrap those APIs
  # to explicitly handle the exceptions as they happen and convert them into values. This allows
  # us to encode the potential failures into the return type and force callers to handle them as
  # needed. A missing path is `Missing` where absence is actionable, everything else is a
  # `Problem` carrying the reason.
  module Filesystem
    extend self

    def open(path : String, mode : String = "r", & : ::File -> T) : T | Missing | Problem forall T
      ::File.open(path, mode) { |file| yield file }
    rescue ::File::NotFoundError
      Missing.new
    rescue error : IO::Error
      problem(error)
    end

    def info(path : String) : ::File::Info | Missing | Problem
      ::File.info(path, follow_symlinks: false)
    rescue ::File::NotFoundError
      Missing.new
    rescue error : ::File::Error
      problem(error)
    end

    def each_child(path : String, & : String ->) : Missing | Problem | Nil
      Dir.each_child(path) { |name| yield name }
      nil
    rescue ::File::NotFoundError
      Missing.new
    rescue error : IO::Error
      problem(error)
    end

    def realpath(path : String) : String | Problem
      ::File.realpath(path)
    rescue error : ::File::Error
      problem(error)
    end

    def readlink(path : String) : String | Problem
      ::File.readlink(path)
    rescue error : ::File::Error
      problem(error)
    end

    def write(path : String, content : Bytes) : Problem?
      ::File.write(path, content)
      nil
    rescue error : IO::Error
      problem(error)
    end

    def symlink(target : String, path : String) : Problem?
      ::File.symlink(target, path)
      nil
    rescue error : ::File::Error
      problem(error)
    end

    def chmod(path : String, mode : Int32) : Problem?
      ::File.chmod(path, mode)
      nil
    rescue error : ::File::Error
      problem(error)
    end

    def link(from : String, to : String) : Problem?
      ::File.link(from, to)
      nil
    rescue error : ::File::Error
      problem(error)
    end

    def rename(from : String, to : String) : Problem?
      ::File.rename(from, to)
      nil
    rescue error : ::File::Error
      problem(error)
    end

    def delete(path : String) : Problem?
      ::File.delete?(path)
      nil
    rescue error : ::File::Error
      problem(error)
    end

    def delete_tree(path : String) : Problem?
      FileUtils.rm_r(path)
      nil
    rescue error : ::File::Error
      problem(error)
    end

    def ensure_directory(path : String) : Problem?
      Dir.mkdir_p(path)
      nil
    rescue error : ::File::Error
      problem(error)
    end

    def snapshot(from : String, to : String) : Problem?
      Platform.select do
        macos do
          source = from.check_no_null_byte
          return if LibClone.clonefile(source, to.check_no_null_byte, LibClone::NOFOLLOW) == 0

          Problem.new("could not be cloned (#{Errno.value})")
        end

        linux { link(from, to) }
      end
    end

    private def problem(error : IO::Error) : Problem
      Problem.new(error.message || error.class.name)
    end
  end
end
