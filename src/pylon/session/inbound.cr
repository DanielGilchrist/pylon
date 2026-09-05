module Pylon::Session
  class Inbound
    alias Phase = Connecting | RemoteScanning | ReceivingTree

    record Connecting
    record RemoteScanning, files : Int64, bytes : Int64
    record ReceivingTree, expected : Int64, mark : Int64, since : Time::Instant

    def initialize : Nil
      @bytes = Atomic(Int64).new(0)
      @phase = Connecting.new
    end

    getter phase : Phase

    def arrived(count : Int32) : Nil
      @bytes.add(count.to_i64)
    end

    def bytes : Int64
      @bytes.get
    end

    def scanning(files : Int64, bytes : Int64) : Nil
      @phase = RemoteScanning.new(files, bytes)
    end

    def announced(bytes : UInt32) : Nil
      @phase = ReceivingTree.new(bytes.to_i64, @bytes.get, Time.instant)
    end

    def received(phase : ReceivingTree) : Int64
      Math.min(@bytes.get - phase.mark, phase.expected)
    end
  end
end
