struct Unrecoverable
  def recovered_content(digest : Bytes) : Bytes?
    nil
  end

  def base_content(digest : Bytes, path : String) : Bytes?
    nil
  end
end
