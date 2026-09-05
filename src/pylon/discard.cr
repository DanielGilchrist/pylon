require "./session/transfer_progress"

module Pylon
  struct Discard
    def keep(relative_path : String, digest : Bytes) : Nil
    end

    def progress(update : Session::TransferProgress) : Nil
    end
  end
end
