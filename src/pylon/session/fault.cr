module Pylon::Session
  alias Fault = Stopped | Disconnected | Incompatible | Misbehaved

  record Stopped, detail : String? = nil do
    def explain : String
      reason = @detail
      reason ? "the remote server stopped (#{reason})" : "the remote server stopped"
    end
  end

  record Disconnected, detail : String? = nil do
    def explain : String
      reason = @detail
      reason ? "the remote server disconnected (#{reason})" : "the remote server disconnected"
    end
  end

  record Incompatible, explain : String

  record Misbehaved, detail : String do
    def explain : String
      "the remote server misbehaved: #{@detail}"
    end
  end
end
