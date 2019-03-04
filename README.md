# Datastore testing for IMS

In this post I will try to summarize my findings regarding the performance of some datastores for a certain highly concurrent write-heavy contention-heavy task.

## Problem description

Let's say we have some inventory in different condition coming from different sources in different warehouses. Internally, this inventory is represented as <code>(sku, warehouse, condition, source, price, count)</code> tuples (or, in case of redis, that data would be split across multiple data structures).

Our system needs to be able do two different things:

* Atomically capture N units of <code>(sku, condition, source)</code> (NOTE: could be across multiple warehouses); return a list of `(sku, warehouse, condition, source, count)` tuples with captured inventory
* Atomically return (release) N units of <code>(sku, warehouse, condition, source)</code>

The "atomicity" part is most significant here and is actually the reason why we do things slower than we could otherwise. It is conceivable that during the huge sale, there would be a lot of demand for a small number of skus, and if we naively do the capture part in two requests (first SELECT available inventory, then REDUCE the counts), it would be possible for that inventory to be gone between the two requests, meaning we would oversell (sell more inventory than we have on hand).

## Test setup design

I have written a small test generator (generate_tests_1.rb) that prepares initial state for X different sku/warehouse/condition/source combos and then generates Y different capture/release operations (the mix here is about 50% captures and 50% releases). If X is small and Y is large, there is going to be a lot of contention for the same skus.

All tests are correct by design (if there is a capture operation, it must succeed). However, in multi-threaded testing it is possible that release and capture operations run in different order from the single-threaded test generator. In such cases, we sleep for 0.005 seconds and repeat the request until it succeeds.

## Tested datastores and notes

I have tested three different storage systems:

* MySQL --- tried and true
* Redis --- popular and also battle-tested
* Tarantool (https://tarantool.io) --- scary Russian tech

Some notes on design and configuration follow.

### MySQL

* Data is stored in a single table, pretty much how you expect it to be laid out
* For capturing we use transaction + SELECT FOR UPDATE combo
* For releasing we simply UPDATE incrementing the counter (no trx)
* Config fine tuning:

    <pre><code>
    innodb_buffer_pool_size = 4096M
    innodb_buffer_pool_instances = 8
    innodb_log_file_size = 512M
    innodb_log_buffer_size = 8M
    innodb_flush_log_at_trx_commit = 2 # This option increases performance by about 200-300%, but can potentially lose ~1 second of transactions in the event of a crash
    </code></pre>
* Version of mysql is vanilla 5.7, no modifications other than the config changes above

### Redis

* Prices and counters are kept as HASHes, indexed by <code>(sku, warehouse, condition, source)</code>
* We have to maintain a map <code>(sku, condition, source) -> (sku, warehouse, condition, source)</code> manually as a poor man index.
* Capture and release are written as lua functions, atomicity is guaranteed by redis design (running script is always blocking everything else)

### Tarantool

* Data is laid out as formatted tuples
* Indexes are supported out of the box
* Capture and release are written as lua functions, similar guarantees to redis (there are some gotchas for tarantool, like implicit yields, but those are not relevant to our case)

## Results

All tests are run in JRuby with 16 concurrent threads on my developer laptop (xps 9560, 4-core i7, ubuntu 18.04). Unlike MRI, JRuby threads are "real threads" (and not "green"). Results are as follows:

* MySQL --- 292.5940s for 1000000 ops (3417.7046 ops / s)
* Redis --- 66.9713s for 1000000 ops (14931.7750 ops / s)
* Tarantool --- 25.3002s for 1000000 ops (39525.3836 ops / s)

(just for the giggles, I also tested postgres with the same code as MySQL and similar tuning options, and it came out at 265.7750s for 1000000 ops (3762.5806 ops / s), slightly better than mysql, but nothing to be crazy about)
