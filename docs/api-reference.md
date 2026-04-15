# API Reference

This page summarizes the public surface exported from
[src/root.zig](../src/root.zig).

## Primary Types

- `thread_pool.ThreadPool`: owned pool handle with submission, waiting,
  shutdown, and stats methods
- `thread_pool.Config`: pool configuration
- `thread_pool.SubmitOptions`: per-submit behavior such as backpressure, lane,
  waitability, and timeout
- `thread_pool.TaskHandle`: opaque handle returned by waitable submissions
- `thread_pool.WaitGroup`: task-group completion primitive
- `thread_pool.CancellationToken`: cooperative cancellation flag
- `thread_pool.Stats`: snapshot of task counts, latencies, queue depths, memory,
  and worker-local stats

## ThreadPool Methods

- `ThreadPool.init(allocator, config)`: create a pool
- `ThreadPool.deinit()`: shut down and release all owned resources
- `ThreadPool.submit(task_fn, ctx, options)`: enqueue a single task, optionally
  blocking on backpressure
- `ThreadPool.trySubmit(task_fn, ctx, options)`: never blocks; returns
  `error.QueueFull` or `error.TaskPoolExhausted` instead
- `ThreadPool.submitBatch(tasks, options)`: enqueue a slice of
  `thread_pool.BatchTask`
- `ThreadPool.wait(handle)`: wait for a handle created with
  `SubmitOptions.waitable = true`
- `ThreadPool.waitGroup()`: create a fresh wait group for grouping submissions
- `ThreadPool.shutdown(mode, timeout_ns)`: stop the pool with either drain or
  cancel semantics
- `ThreadPool.statsSnapshot()`: read a consistent stats view
- `ThreadPool.purgeWorkerCaches()`: purge per-worker scratch buffers when the
  pool is quiescent

## Config Highlights

Common fields:

- `min_threads`, `max_threads`
- `queue_capacity`, `local_queue_capacity`
- `inject_batch_size`
- `scheduler_variant`
- `allow_blocking_lane`, `blocking_workers`
- `worker_scratch_cap_bytes`
- `idle_park_after_ns`, `idle_purge_after_ns`
- `timestamp_mode`
- `steal_batch_size`

Important constraint: `Config.validate()` is intended for normalized configs.
If you are validating a hand-built config outside `ThreadPool.init()`, call
`config.normalized().validate()` rather than validating the raw struct.

## Scheduler Variants

- `global_queue`
- `work_stealing`
- `lane_extension`

## Submit Options

`SubmitOptions` supports:

- `waitable`
- `wait_group`
- `cancellation_token`
- `backpressure`
- `timeout_ns`
- `lane`

Backpressure policies:

- `return_error`
- `block`
- `block_with_timeout`

Task lanes:

- `default`
- `blocking`

## Queue Implementations

Public queue types are exported for low-level testing and experimentation:

- `thread_pool.BoundedRing`
- `thread_pool.WorkDeque`
- `thread_pool.RingQueue`

## Stats Snapshot

`Stats` includes:

- lifecycle counts: `submitted`, `started`, `completed`, `cancelled`
- queue state: `queue_depth_current`, `queue_depth_peak`
- worker activity: `steals`, `steal_failures`, `wakeups`, `parks`
- memory: process RSS plus pool allocation counters
- latencies: task wait and execution summaries
- per-worker scratch and queue stats

See [DESIGN.md](DESIGN.md) for the implementation-level meaning of each field.
