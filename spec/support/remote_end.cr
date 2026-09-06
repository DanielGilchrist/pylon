private alias Configure = Pylon::Wire::Message::Configure
private alias Server = Pylon::Session::Server

def remote_configuration(
  root : String,
  ignores : Array(String) = Array(String).new,
  watch : Bool = false,
  brand : Pylon::Brand = Pylon::Brand::DEFAULT,
  state : String? = nil,
) : Configure
  Configure.new(
    root: root,
    ignores: ignores,
    compression: Pylon::Compress::Zstd::DEFAULT_LEVEL,
    brand: brand,
    state: state,
    watch: watch,
    tree_fingerprint: nil,
  )
end

def serve_remote_end(socket : IO) : Nil
  spawn do
    accepted = Server.accept(socket, socket, IO::Memory.new)
    accepted.run if accepted.is_a?(Server)
  end
end
