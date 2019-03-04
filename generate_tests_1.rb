require_relative "shared"

ITEM_COUNT = (ARGV[0] || 1000).to_i
OPS_COUNT = (ARGV[1] || 1000000).to_i
WAREHOUSE_COUNT = 3
CONDITION_COUNT = 3
SOURCE_COUNT = 3
PRICE_RANGE = 400..1500
SKU_RANGE = 1..1000
INITIAL_COUNT_RANGE = 0..10
CAPTURE_PROBABILITY = 0.5
RELEASE_PROBABILITY = 1 - CAPTURE_PROBABILITY

test = {}

# seeding phase
items = {}
ITEM_COUNT.times do
  begin
    sku = rand(SKU_RANGE)
    warehouse = rand(1..WAREHOUSE_COUNT)
    condition = rand(1..CONDITION_COUNT)
    source = rand(1..SOURCE_COUNT)
    price = rand(PRICE_RANGE)
    count = rand(INITIAL_COUNT_RANGE)
    key = [sku, warehouse, condition, source]
  end while items[key]

  items[key] = {
    sku: sku,
    warehouse: warehouse,
    condition: condition,
    source: source,
    price: price,
    count: count
  }
end

test[:initial_state] = Marshal.load(Marshal.dump(items))

# ops phase
ops = []
OPS_COUNT.times do
  op = rand < CAPTURE_PROBABILITY ? :capture : :release

  if op == :capture
    begin
      key = items.keys.sample
      item = items[key]
    end until item[:count] > 0
    count = rand(1..[3, item[:count]].min)
    item[:count] -= count
    ops << [op, key, count]
  else
    key = items.keys.sample
    item = items[key]
    count = rand(1..3)
    item[:count] += count
    ops << [op, key, count]
  end
end

test[:ops] = ops
test[:final_state] = Marshal.load(Marshal.dump(items))

$stdout.write Marshal.dump(test)
