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

def remote_configuration(
  root : Sandbox,
  ignores : Array(String) = Array(String).new,
  watch : Bool = false,
  brand : Pylon::Brand = Pylon::Brand::DEFAULT,
  state : String? = nil,
) : Configure
  remote_configuration(root.root, ignores, watch, brand, state)
end

def serve_remote_end(socket : IO) : Channel(Nil)
  finished = Channel(Nil).new(1)

  spawn do
    accepted = Server.accept(socket, socket, IO::Memory.new)
    accepted.run if accepted.is_a?(Server)
    finished.send(nil)
  end

  finished
end
