require "json"
require "socket"
require "./pdu"

module Pylon::Watch
  FIELDS = %w[name exists new size mode mtime_ns type]

  class Client(T)
    def self.connect(socket_path : String) : Client(UNIXSocket) | PDU::Failure
      Client.new(UNIXSocket.new(socket_path))
    rescue Socket::Error
      PDU::Failure.new("cannot reach the watchman socket at #{socket_path}")
    end

    def self.socket_path : String?
      return ENV["WATCHMAN_SOCK"]? if ENV.has_key?("WATCHMAN_SOCK")

      output = IO::Memory.new
      status = Process.run("watchman", ["get-sockname"], output: output)
      return nil unless status.success?

      JSON.parse(output.to_s)["sockname"]?.try(&.as_s?)
    rescue IO::Error
      nil
    end

    def initialize(@io : T)
    end

    def watch_project(root : String) : PDU::Any
      resolved = canonical(root)
      send(JSON.build { |json| json.array { json.string("watch-project"); json.string(resolved) } })
    end

    def clock(root : String) : PDU::Any
      resolved = canonical(root)
      send(JSON.build { |json| json.array { json.string("clock"); json.string(resolved) } })
    end

    def since(root : String, clock : String, ignores : Array(String)) : PDU::Any
      send(since_request(canonical(root), clock, ignores))
    end

    def subscribe(root : String, name : String, ignores : Array(String)) : PDU::Any
      send(subscribe_request(canonical(root), name, ignores))
    end

    def send(request : String) : PDU::Any
      @io.puts(request)
      @io.flush
      read
    end

    def read : PDU::Any
      PDU.parse(@io.gets)
    end

    def close : Nil
      @io.close
    end

    private def canonical(root : String) : String
      File.realpath(root)
    rescue File::Error
      root
    end

    private def since_request(root : String, clock : String, ignores : Array(String)) : String
      JSON.build do |json|
        json.array do
          json.string("query")
          json.string(root)

          json.object do
            json.field("since", clock)
            json.field("fields") { json.array { json.string("name") } }
            write_expression(json, ignores)
          end
        end
      end
    end

    private def write_expression(json : JSON::Builder, ignores : Array(String)) : Nil
      return if ignores.empty?

      json.field("expression") do
        json.array do
          json.string("not")
          json.array do
            json.string("anyof")

            ignores.each do |pattern|
              json.array do
                json.string("dirname")
                json.string(pattern)
              end
            end
          end
        end
      end
    end

    private def subscribe_request(root : String, name : String, ignores : Array(String)) : String
      JSON.build do |json|
        json.array do
          json.string("subscribe")
          json.string(root)
          json.string(name)

          json.object do
            json.field("defer_vcs", false)
            json.field("fields") do
              json.array { FIELDS.each { |field| json.string(field) } }
            end

            next if ignores.empty?

            json.field("expression") do
              json.array do
                json.string("not")
                json.array do
                  json.string("anyof")

                  ignores.each do |pattern|
                    json.array do
                      json.string("dirname")
                      json.string(pattern)
                    end
                  end
                end
              end
            end
          end
        end
      end
    end
  end
end
