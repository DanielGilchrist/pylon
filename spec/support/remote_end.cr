require "../../src/pylon/session/server"

def remote_configuration(
  root : String,
  ignores : Array(String) = Array(String).new,
  watch : Bool = false,
  brand : Pylon::Brand = Pylon::Brand::DEFAULT,
) : Pylon::Wire::Message::Configure
  Pylon::Wire::Message::Configure.new(
    root: root,
    ignores: ignores,
    compression: Pylon::Compress::Zstd::DEFAULT_LEVEL,
    brand: brand,
    state: nil,
    watch: watch,
  )
end

def serve_remote_end(socket : IO) : Nil
  spawn do
    accepted = Pylon::Session::Server.accept(socket, socket, IO::Memory.new)
    accepted.run if accepted.is_a?(Pylon::Session::Server)
  end
end
