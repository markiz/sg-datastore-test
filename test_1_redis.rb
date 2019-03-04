require "bundler/setup"
Bundler.require
require "benchmark"
require "tarantool16"
require "pp"

THREAD_COUNT = 16

upsert_function = <<LUA
local sku = ARGV[1]
local warehouse = ARGV[2]
local condition = ARGV[3]
local source = ARGV[4]
local price = ARGV[5]
local count = ARGV[6]
local key = sku .. ':' .. warehouse .. ':' .. condition .. ':' .. source
redis.call('hset', 'vic', key, count)
redis.call('hset', 'price', key, price)
local scs_key = sku .. ':' .. condition .. ':' .. source
redis.call('sadd', 'vic:scs:' .. scs_key, key)
return true
LUA

capture_function = <<LUA
local sku = ARGV[1]
local condition = ARGV[2]
local source = ARGV[3]
local count = tonumber(ARGV[4])
local scs_key = sku .. ':' .. condition .. ':' .. source
local keys = redis.call('smembers', 'vic:scs:' .. scs_key)

if #keys == 0 then
  return false
end

local counts = redis.call('hmget', 'vic', unpack(keys))
for i = 1, #counts do
  counts[i] = tonumber(counts[i])
end

local total_count = 0
for i = 1, #keys do
  if counts[i] > 0 then
    total_count = total_count + counts[i]
  end
end

if total_count < count then
  return false
end

local taken = 0
local result = {}
for i = 1, #keys do
  if count - taken == 0 then
    break
  end

  if counts[i] > 0 then
    table.insert(result, keys[i])
    local to_take
    if counts[i] > count - taken then
      to_take = count - taken
    else
      to_take = counts[i]
    end
    redis.call('hincrby', 'vic', keys[i], -to_take)
    table.insert(result, to_take)
    taken = taken + to_take
  end
end

return result
LUA

release_function = <<-LUA
local sku = ARGV[1]
local warehouse = ARGV[2]
local condition = ARGV[3]
local source = ARGV[4]
local count = tonumber(ARGV[5])
local key = sku .. ':' .. warehouse .. ':' .. condition .. ':' .. source
return redis.call('hincrby', 'vic', key, count)
LUA

# setup
test_setup = Marshal.load(File.read(ARGV[0]))
redis = Redis.new
upsert_sha = redis.script(:load, upsert_function)
capture_sha = redis.script(:load, capture_function)
release_sha = redis.script(:load, release_function)
redis.del('vic')
redis.del('price')
scs_keys = redis.keys('vic:scs:*')
redis.del(*scs_keys) if scs_keys.any?

# seed
seed_time = Benchmark.realtime do
  test_setup[:initial_state].each do |_, v|
    redis.evalsha(upsert_sha, [], v.values_at(:sku, :warehouse, :condition, :source, :price, :count))
  end
end
puts "Seed time: %.4fs" % seed_time

# ops
ops = test_setup[:ops]
queue = ops.dup
mutex = Mutex.new
ops_time = Benchmark.realtime do
  THREAD_COUNT.times.map do
    Thread.new do
      client = Redis.new
      loop do
        row = mutex.synchronize { queue.shift }
        break unless row
        op, key, count = row
        sku, warehouse, condition, source = key
        if op == :capture
          loop do
            result = client.evalsha(capture_sha, [], [sku, condition, source, count])
            if result
              break
            else
              puts "COULDN'T CAPTURE #{[sku, condition, source, count].inspect}, RETRYING"
              sleep(0.005)
            end
          end
        else
          client.evalsha(release_sha, [], [sku, warehouse, condition, source, count])
        end
      end
    end
  end.map(&:join)
end
puts "Ops time: %.4fs for %d ops (%.4f ops / s)" % [ops_time, ops.count, ops.count / ops_time]
binding.pry
