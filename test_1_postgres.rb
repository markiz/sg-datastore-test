require "bundler/setup"
Bundler.require
require "benchmark"
require "tarantool16"
require "pp"
require "logger"

THREAD_COUNT = 16

# setup
test_setup = Marshal.load(File.read(ARGV[0]))
DB = if RUBY_PLATFORM =~ /java/
  Sequel.connect("jdbc:postgresql://localhost/datastore_test_1?user=mark&password=123456", max_connections: THREAD_COUNT + 4)
else
  Sequel.connect("postgres://localhost/datastore_test_1?user=mark&password=123456", max_connections: THREAD_COUNT + 4)
end

# DB.loggers << Logger.new("mysql_test.log")

DB.create_table! :vic do
  primary_key :id
  column :sku, :integer, null: false
  column :warehouse, :integer, null: false
  column :condition, :integer, null: false
  column :source, :integer, null: false
  column :price, :decimal, null: false, precision: 10, scale: 4
  column :count, :integer, null: false

  index [:sku, :condition, :source, :warehouse], unique: true
end

VIC = DB[:vic]

def capture_scs(sku, condition, source, count)
  DB.transaction(isolation: :uncommitted) do
    vics = VIC.for_update.where(sku: sku, condition: condition, source: source).where(Sequel[:count] > 0).all
    total_count = vics.map { |vic| vic[:count] }.reduce(0, :+)
    if total_count < count
      return false
    end

    result = []
    updates = []
    taken = 0
    vics.each do |vic|
      break if taken == count
      to_take = [count - taken, vic[:count]].min
      taken += to_take
      result << [vic, to_take]
      VIC.where(id: vic[:id]).update(count: Sequel[:count] - to_take)
    end

    result
  end
end

def release_swcs(sku, warehouse, condition, source, count)
  VIC.where(sku: sku, warehouse: warehouse, condition: condition, source: source).update(count: Sequel[:count] + count)
end



# seed
seed_time = Benchmark.realtime do
  DB[:vic].import(
    [:sku, :warehouse, :condition, :source, :price, :count],
    test_setup[:initial_state].map { |_, v| v.values_at(:sku, :warehouse, :condition, :source, :price, :count) }
  )
end
puts "Seed time: %.4fs" % seed_time

# ops
ops = test_setup[:ops]
queue = ops.dup
mutex = Mutex.new
ops_time = Benchmark.realtime do
  THREAD_COUNT.times.map do
    Thread.new do
      loop do
        row = mutex.synchronize { queue.shift }
        # puts row.inspect
        break unless row
        op, key, count = row
        sku, warehouse, condition, source = key
        if op == :capture
          loop do
            result = capture_scs(sku, condition, source, count)
            if result
              break
            else
              puts "COULDN'T CAPTURE #{[sku, condition, source, count].inspect}, RETRYING"
              sleep(0.005)
            end
          end
        else
          release_swcs(sku, warehouse, condition, source, count)
        end
      end
    end
  end.map(&:join)
end
puts "Ops time: %.4fs for %d ops (%.4f ops / s)" % [ops_time, ops.count, ops.count / ops_time]
binding.pry
