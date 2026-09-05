require "../src/pylon/disk"
require "../src/pylon/fibers"

include Pylon

SEED = 42_u64

files = (ARGV[0]? || "20000").to_i
sweep = (ARGV[1]? || "1,2,4,8,16").split(',').map(&.to_i)

random = Random.new(SEED)
contents = Array(Bytes).new(files)
total_bytes = 0_i64

files.times do
  weight = random.rand(100)
  lines = weight < 80 ? random.rand(10..80) : weight < 95 ? random.rand(80..1200) : random.rand(
    1200..20_000,
  )
  builder = String::Builder.new
  lines.times { |line| builder << "def item" << line << " end\n" }
  content = builder.to_s.to_slice
  contents << content
  total_bytes += content.size
end

puts "corpus: #{files} files, #{(total_bytes / (1024.0 * 1024.0)).round(1)} MiB in memory"

sweep.each do |workers|
  work = File.tempname("pylon-write-floor")
  disk = Disk.new(work)

  40.times { |part| Dir.mkdir_p(File.join(work, "part#{part}")) }

  started = Time.instant

  if workers <= 1
    files.times do |index|
      failed = disk.write_file("part#{index % 40}/file#{index}.cr", contents[index], false)
      abort("write failed: #{failed.reason}") if failed
    end
  else
    stripe = (files + workers - 1) // workers
    Fibers.parallel(:write, workers) do |worker|
      lower = worker * stripe
      upper = Math.min(lower + stripe, files)
      (lower...upper).each do |index|
        failed = disk.write_file("part#{index % 40}/file#{index}.cr", contents[index], false)
        abort("write failed: #{failed.reason}") if failed
      end
    end
  end

  elapsed = Time.instant - started
  puts "workers=#{workers}: #{elapsed.total_seconds.round(2)}s " \
       "(#{(files / elapsed.total_seconds).round(0)} files/s)"

  FileUtils.rm_rf(work)
end
