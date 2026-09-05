struct Unrecoverable
  def content(digest : Bytes) : Bytes?
    nil
  end

  def content(digest : Bytes, *, prefer : String) : Bytes?
    nil
  end
end
