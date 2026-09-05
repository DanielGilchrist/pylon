require "./compress/lib_zstd"
require "./problem"

module Pylon::Compress
  extend self

  def check(code : LibC::SizeT) : Problem?
    return if LibZstd.is_error(code) == 0

    Problem.new(String.new(LibZstd.error_name(code)))
  end
end
