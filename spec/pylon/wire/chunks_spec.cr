require "../../spec_helper"

private CHUNK_BYTES  = Pylon::Wire::Chunks::CHUNK_BYTES
private alias Chunks = Pylon::Wire::Chunks
private DIGEST_BYTES = Pylon::Wire::DIGEST_BYTES
private alias Dictionary = Pylon::Wire::Dictionary
private FORMAT = Pylon::Wire::FORMAT
private alias Reader = Pylon::Wire::Reader
private alias Zstd = Pylon::Compress::Zstd

private def read_back(io : IO::Memory) : {Bytes?, Reader}
  io.rewind
  reader = Reader.new(io)
  {Chunks.read_all(reader, Zstd.new, Chunks.scratch), reader}
end

describe Chunks do
  it "round trips content spanning several chunks" do
    content = Bytes.new(CHUNK_BYTES * 2 + 7) { |index| (index % 251).to_u8 }
    io = IO::Memory.new
    Chunks.write_all(io, content, Zstd.new, Chunks.scratch)

    collected, reader = read_back(io)

    reader.failed?.should be_false
    collected.should eq(content)
  end

  it "accepts a chunk of exactly the chunk size" do
    content = Bytes.new(CHUNK_BYTES) { |index| (index % 13).to_u8 }
    io = IO::Memory.new
    Chunks.write_all(io, content, Zstd.new, Chunks.scratch)

    collected, reader = read_back(io)

    reader.failed?.should be_false
    collected.should eq(content)
  end

  it "returns nothing when the stream was invalidated by its writer" do
    io = IO::Memory.new
    Chunks.write_chunk(io, "partial".to_slice, Zstd.new, Chunks.scratch)
    Chunks.write_end(io, valid: false)

    collected, reader = read_back(io)

    reader.failed?.should be_false
    collected.should be_nil
  end

  it "refuses a chunk claiming more raw bytes than the chunk size" do
    io = IO::Memory.new
    io.write_bytes(2_u32, FORMAT)
    io.write_bytes((CHUNK_BYTES + 1).to_u32, FORMAT)

    _, reader = read_back(io)

    reader.failed?.should be_true
    reader.reason.should contain("raw bytes")
  end

  it "refuses a chunk claiming more packed bytes than fit the scratch buffer" do
    scratch = Chunks.scratch
    io = IO::Memory.new
    io.write_bytes((scratch.size + 2).to_u32, FORMAT)
    io.write_bytes(1_u32, FORMAT)

    _, reader = read_back(io)

    reader.failed?.should be_true
    reader.reason.should contain("packed bytes")
  end

  it "refuses a content item that exceeds the sync limit rather than buffering without bound" do
    content = Bytes.new(CHUNK_BYTES * 3) { |index| (index % 251).to_u8 }
    io = IO::Memory.new
    Chunks.write_all(io, content, Zstd.new, Chunks.scratch)
    io.rewind

    reader = Reader.new(io)
    collected = Chunks.read_all(
      reader,
      Zstd.new,
      Chunks.scratch,
      limit: CHUNK_BYTES * 2,
    )

    collected.should be_nil
    reader.failed?.should be_true
    reader.reason.should contain("sync limit")
  end

  it "refuses a tree payload that arrived invalidated" do
    io = IO::Memory.new
    Chunks.write_chunk(io, "half a tree".to_slice, Zstd.new, Chunks.scratch)
    Chunks.write_end(io, valid: false)
    io.rewind

    reader = Reader.new(io)
    Chunks.read_entry(reader).should be_nil
    reader.failed?.should be_true
    reader.reason.should contain("invalidated")
  end
end

describe "dictionary payloads in the contents framing" do
  it "round trips the base digest and the frame without recompressing it" do
    frame = Random.new(41).random_bytes(70_000)
    base = Bytes.new(DIGEST_BYTES, 7_u8)
    digest = Bytes.new(DIGEST_BYTES, 9_u8)
    contents = Pylon::Wire::Contents{digest => Dictionary.new(base, frame)}

    io = IO::Memory.new
    Chunks.write_contents(io, contents)
    io.rewind
    decoded = Chunks.read_contents(Reader.new(io))

    payload = decoded[digest]?
    payload.should be_a(Dictionary)
    next unless payload.is_a?(Dictionary)

    payload.base.should eq(base)
    payload.frame.should eq(frame)
  end
end
