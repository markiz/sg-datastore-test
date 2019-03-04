require "bundler/setup"
Bundler.require
require "benchmark"
require "tarantool16"
require "pp"

THREAD_COUNT = 16

init_script = <<LUA
if not box.space.vic then
  box.schema.space.create(
    "vic",
    {
      format = {
        { name = "sku", type = "unsigned" },
        { name = "warehouse", type = "unsigned" },
        { name = "condition", type = "unsigned" },
        { name = "source", type = "unsigned" },
        { name = "price", type = "number" },
        { name = "count", type = "unsigned" }
      }
    }
  )
end

vic = box.space.vic
if not vic.index.primary then
  vic:create_index("primary", { type = "HASH", parts = { "sku", "warehouse", "condition", "source" } })
end

if not vic.index.scs then
  vic:create_index("scs", { type = "TREE", parts = { "sku", "condition", "source" }, unique = false })
end

function seed_db(tuples)
  for i, tuple in ipairs(tuples) do
    vic:insert(tuple)
  end
end

function capture_single_vic_scs(sku, condition, source, count)
  local tuples = vic.index.scs:select({ sku, condition, source })
  local total_count = 0

  for i = 1, #tuples do
    total_count = total_count + tuples[i].count
  end

  if total_count < count then
    return false
  end

  local result = {}
  local taken = 0
  box.begin()
  for i = 1, #tuples do
    local tuple = tuples[i]
    if taken == count then
      break
    end

    local to_take
    if count - taken > tuple.count then
      to_take = tuple.count
    else
      to_take = count - taken
    end
    taken = taken + to_take
    vic:update({ tuple.sku, tuple.warehouse, tuple.condition, tuple.source }, {{ "-", 6, to_take }})
    table.insert(result, { tuple.sku, tuple.warehouse, tuple.condition, tuple.source, to_take })
  end
  box.commit()
  return result
end

function release_single_vic_swcs(sku, warehouse, condition, source, count)
  vic:update({ sku, warehouse, condition, source }, { { "+", 6, count } })
  return true
end
LUA

cleanup_script = <<-LUA
vic:truncate()
LUA

test_setup = Marshal.load(File.read(ARGV[0]))
tar = Tarantool16.new(host: "localhost:3301")
seed_tuples = test_setup[:initial_state].map do |_, v|
  v.values_at(:sku, :warehouse, :condition, :source, :price, :count)
end

tar.eval(init_script, [])
tar.eval(cleanup_script, [])
seed_time = Benchmark.realtime { tar.call("seed_db", [seed_tuples]) }
puts "Seed time: %.4fs" % seed_time

ops = test_setup[:ops]
queue = ops.dup
mutex = Mutex.new
ops_time = Benchmark.realtime do
  THREAD_COUNT.times.map do
    Thread.new do
      client = Tarantool16.new(host: "localhost:3301")
      loop do
        row = mutex.synchronize { queue.shift }
        break unless row
        op, key, count = row
        sku, warehouse, condition, source = key
        if op == :capture
          loop do
            result = client.call("capture_single_vic_scs", [sku, condition, source, count])
            if result
              break
            else
              puts "COULDN'T CAPTURE, RETRYING"
              sleep 0.005
            end
          end
        else
          client.call("release_single_vic_swcs", [sku, warehouse, condition, source, count])
        end
      end
    end
  end.map(&:join)
end
puts "Ops time: %.4fs for %d ops (%.4f ops / s)" % [ops_time, ops.count, ops.count / ops_time]
binding.pry
