record Timed, deliver_at : Time::Instant, chunk : Bytes

def read_chunk(from : IO, buffer : Bytes) : Bytes?
  read = from.read(buffer)
  return if read.zero?

  chunk = Bytes.new(read)
  chunk.copy_from(buffer.to_unsafe, read)
  chunk
rescue IO::Error
  nil
end

def deliver(to : IO, chunk : Bytes) : Bool
  to.write(chunk)
  to.flush
  true
rescue IO::Error
  false
end

def close_quietly(io : IO) : Nil
  io.close
rescue IO::Error
end

def start(executable : String, arguments : Array(String)) : Process | String
  Process.new(executable, arguments, input: :pipe, output: :pipe, error: :inherit)
rescue error : IO::Error
  error.message || "the command could not be started"
end

def pump(from : IO, to : IO, delay : Time::Span, rate : Float64, finished : Channel(Int64)) : Nil
  queue = Channel(Timed).new(1024)
  moved = 0_i64

  spawn do
    buffer = Bytes.new(65_536)

    while (chunk = read_chunk(from, buffer))
      queue.send(Timed.new(Time.instant + delay, chunk))
    end

    queue.close
  end

  spawn do
    available_at = Time.instant

    while (item = queue.receive?)
      ready_at = {item.deliver_at, available_at}.max
      pause = ready_at - Time.instant
      sleep(pause) if pause > Time::Span.zero
      break unless deliver(to, item.chunk)

      moved += item.chunk.size
      available_at = rate > 0 ? {ready_at, Time.instant}.max + (item.chunk.size / rate).seconds : available_at
    end

    close_quietly(to)
    finished.send(moved)
  end
end

delay_ms = ARGV.shift?.try(&.to_f?)
rate = ARGV.shift?.try(&.to_f?)
executable = ARGV.shift?

if delay_ms.nil? || rate.nil? || executable.nil?
  abort("usage: latency_proxy <delay-ms> <rate-bytes-per-second> <command> [arguments]")
end

started = start(executable, ARGV)
abort("latency_proxy: #{started}") if started.is_a?(String)

child = started
delay = (delay_ms / 1000.0).seconds
upstream = Channel(Int64).new
downstream = Channel(Int64).new

pump(STDIN, child.input, delay, rate, upstream)
pump(child.output, STDOUT, delay, rate, downstream)

sent = upstream.receive
received = downstream.receive
STDERR.puts("latency_proxy: #{(sent / 1_048_576.0).round(2)} MiB to the remote, #{(received / 1_048_576.0).round(2)} MiB back")
exit(child.wait.success? ? 0 : 1)
