require "./meter"

module Pylon::Session
  class Inbound
    alias Phase = Connecting | RemoteScanning | ReceivingTree

    record Connecting
    record RemoteScanning, files : Int64, hashed_bytes : Int64
    record ReceivingTree, expected : Int64, mark : Int64, since : Time::Instant

    def initialize : Nil
      @meter = Meter.new
      @phase = Connecting.new
    end

    getter meter : Meter
    getter phase : Phase

    def scanning(files : Int64, hashed_bytes : Int64) : Nil
      @phase = RemoteScanning.new(files, hashed_bytes)
    end

    def announced(bytes : UInt32) : Nil
      @phase = ReceivingTree.new(bytes.to_i64, @meter.bytes, Time.instant)
    end

    def received(phase : ReceivingTree) : Int64
      Math.min(@meter.bytes - phase.mark, phase.expected)
    end
  end
end
