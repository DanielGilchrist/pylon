module Pylon::Session
  module SSH
    extend self

    def command(
      host : String,
      remote_command : String,
      config : String? = nil,
      port : String? = nil,
    ) : Array(String)
      arguments = Array(String).new

      if (config_path = config)
        arguments << "-F" << config_path
      end

      if (port_number = port)
        arguments << "-p" << port_number
      end

      arguments << host << remote_command
      arguments
    end
  end
end
