class MemoryKeeper
  record Kept, path : String, digest : Bytes

  getter kept = Array(Kept).new

  def keep(relative_path : String, digest : Bytes) : Nil
    @kept << Kept.new(relative_path, digest)
  end
end
