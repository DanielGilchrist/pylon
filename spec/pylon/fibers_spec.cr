require "../spec_helper"
require "../../src/pylon/fibers"

private def contexts_named(name : String) : Int32
  count = 0
  Fiber::ExecutionContext.each { |context| count += 1 if context.name == name }
  count
end

describe Pylon::Fibers do
  it "runs every worker once and waits for all of them" do
    ran = Array(Int32).new(6, 0)

    Pylon::Fibers.parallel(:scan_digest, 6) { |worker| ran[worker] += 1 }

    ran.should eq([1, 1, 1, 1, 1, 1])
  end

  it "keeps one execution context per name however many times it runs" do
    20.times { Pylon::Fibers.parallel(:scan_digest, 4) { |worker| worker } }

    contexts_named("ScanDigest").should eq(1)
  end

  it "grows the context when a later call asks for more workers" do
    Pylon::Fibers.parallel(:write, 2) { |worker| worker }
    Pylon::Fibers.parallel(:write, 8) { |worker| worker }

    contexts_named("Write").should eq(1)
  end

  it "raises a worker's exception in the caller" do
    expect_raises(Exception, "worker 1 broke") do
      Pylon::Fibers.parallel(:write, 3) do |worker|
        raise "worker #{worker} broke" if worker == 1
      end
    end
  end
end
