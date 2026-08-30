module Pylon::Wire
  record Invalid, reason : String

  class Truncated < Exception
    def self.contain(& : -> T) : T | Invalid forall T
      yield
    rescue truncated : Truncated
      Invalid.new(truncated.message || "the stream was cut mid-message")
    rescue error : IO::Error
      Invalid.new(error.message || "the stream failed mid-message")
    end
  end
end
