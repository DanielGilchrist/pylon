module Pylon::Session
  struct Staging(R)
    struct Unrecoverable
      def recovered_content(digest : Bytes) : Bytes?
        nil
      end
    end
  end
end
