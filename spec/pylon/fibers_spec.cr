require "../spec_helper"

private alias Fibers = Pylon::Fibers

private def contexts_named(name : Fibers::Name) : Int32
  count = 0
  Fiber::ExecutionContext.each { |context| count += 1 if context.name == name.to_s }
  count
end

private class Blip
  include Fibers::Blocking

  def initialize(@done : Channel(Nil)) : Nil
  end

  def run_blocking : Nil
    @done.send(nil)
  end
end

describe Fibers do
  it "runs every worker once and waits for all of them" do
    ran = Array(Int32).new(6, 0)

    Fibers.parallel(:scan_digest, 6) { |worker| ran[worker] += 1 }

    ran.should eq([1, 1, 1, 1, 1, 1])
  end

  it "keeps one execution context per name however many times it runs" do
    20.times { Fibers.parallel(:scan_digest, 4) { |worker| worker } }

    contexts_named(Fibers::Name::ScanDigest).should eq(1)
  end

  it "runs every worker even when asked for more than the context has threads" do
    workers = Pylon::Fibers::WORKER_THREADS + 5
    ran = Array(Int32).new(workers, 0)

    Fibers.parallel(:write, 2) { |worker| worker }
    Fibers.parallel(:write, workers) { |worker| ran[worker] += 1 }

    ran.all?(1).should be_true
    contexts_named(Fibers::Name::Write).should eq(1)
  end

  it "raises a worker's exception in the caller" do
    expect_raises(Exception, "worker 1 broke") do
      Fibers.parallel(:write, 3) do |worker|
        raise "worker #{worker} broke" if worker == 1
      end
    end
  end
end

describe Fibers, "isolated work" do
  it "keeps one isolated context per name however much work runs on it" do
    done = Channel(Nil).new

    assert_descriptor_change(0) do
      50.times do
        Fibers.isolated(:spinner, Blip.new(done))
        done.receive
      end
    end

    contexts_named(Fibers::Name::Spinner).should eq(1)
  end
end
