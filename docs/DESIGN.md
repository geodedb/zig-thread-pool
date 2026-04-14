# thread-pool Design

## Overview

`thread-pool` is a fixed-capacity, shared-infrastructure thread-pool with two concrete scheduler implementations behind the same public API:

- `global_queue`
- `work_stealing`

The public API stays stable while scheduler selection, queue topology, and instrumentation remain internal.

## Public Surface

- `ThreadPool.init(allocator, config) !ThreadPool`
- `ThreadPool.deinit()`
- `ThreadPool.submit(task_fn, ctx, options) !TaskHandle`
- `ThreadPool.trySubmit(task_fn, ctx, options) !TaskHandle`
- `ThreadPool.submitBatch(tasks, options) !SubmitBatchResult`
- `ThreadPool.wait(handle) !void`
- `ThreadPool.waitGroup() WaitGroup`
- `ThreadPool.shutdown(mode, timeout) !void`
- `ThreadPool.statsSnapshot() Stats`
- `ThreadPool.purgeWorkerCaches() !void`

`ThreadPool.purgeWorkerCaches()` is quiescent-only. It returns
`error.PoolBusy` unless `active_tasks == 0 && queued_tasks == 0`.

## Scheduler Variants

### `global_queue`

- One bounded FIFO inject queue.
- Fixed worker set.
- Workers pop directly from the shared queue.
- Included as the simplest correctness-first baseline and fallback.

### `work_stealing`

- One bounded central inject queue for external submitters.
- One owner-local LIFO slot plus one bounded local queue per worker.
- Local submissions from worker threads prefer the LIFO slot, then the local
  queue.
- Idle workers refill from the inject queue, then attempt steals from peer deques.
- Worker wake selection is configurable:
  - `scan_parked_workers` keeps the legacy submit-path parked-worker scan.
  - `idle_queue` uses a bounded idle-worker ticket queue to pick wake
    candidates without scanning every worker.
- Included as the low-contention candidate and still benchmarked on every baseline run.

### `lane_extension`

- Reserved API tag for keyed or blocking-aware scheduling work.
- Current implementation routes through the same machinery and documents the gap in [GAP_ANALYSIS.md](GAP_ANALYSIS.md).

## Queue Design

### Inject Queue

- Bounded ring buffer.
- Vyukov-style MPMC sequence queue, no unbounded growth.
- Backpressure is explicit: `QueueFull`, or blocking retry with timeout.

### Local Worker Queue

- Bounded owner-local queue with pluggable implementation via `Config.queue_kind`.
- `queue_kind = .ring` is the default Tokio/Go-style SPMC ring.
- `queue_kind = .chase_lev` remains available as the classic Chase-Lev deque.
- Owner pushes and pops from the bottom / tail side; steals happen from the top / head side.

## Memory Model

- Task descriptors are preallocated from a bounded descriptor array.
- Descriptor reuse happens only after task completion and, for waitable tasks, after `wait`.
- Worker scratch allocates one bounded buffer per worker lazily on first use.
- On the normal owning-worker path, scratch begin/alloc/finish are lock-free.
- Scratch buffers can be purged explicitly or after configured idle periods.
- Explicit purge is only legal while the pool is quiescent.
- All pool-owned allocations are counted in `total_alloc_bytes`, `total_free_bytes`, `live_bytes`, and `peak_live_bytes`.

## Runtime Presets

- `RuntimePreset.standard` preserves the stable defaults.
- `RuntimePreset.tokio_parity` is an explicit benchmark-focused preset that
  currently enables:
  - `timestamp_mode = .disabled`
  - `wake_strategy = .idle_queue`

The preset exists as an opt-in configuration surface. It is not silently
forced by the benchmark harness.

## Task Lifecycle

1. Submission validates pool state and acquires a descriptor from the bounded freelist.
2. The descriptor is enqueued either to the caller worker’s local deque or the central inject queue.
3. A worker dequeues, steals, or refills and transitions the descriptor to `running`.
4. The task executes exactly once.
5. The descriptor transitions to `completed` or `cancelled`.
6. Detached descriptors return to the freelist immediately; waitable descriptors return after `wait`.

## Shutdown Semantics

### `drain`

- Reject new submissions.
- Let queued and running work finish.
- Join workers.
- Purge worker scratch.
- Release owned memory.

### `cancel_pending`

- Reject new submissions.
- Cancel tasks still in queues.
- Running tasks continue to completion.
- Join workers and release resources.

## Fairness and Tradeoffs

- `global_queue` is simpler and sometimes slightly smaller in RSS because it lacks per-worker queue state.
- `work_stealing` reduces multi-producer contention and improves local handoff, but it is not currently lock-free.
- Recursive submission is safe because worker-originated tasks preferentially target the caller’s local deque.
- Blocking tasks are supported through lane metadata today and leave room for a future dedicated blocking lane.

## Observability

`statsSnapshot()` reports:

- task lifecycle counters
- queue depth current and peak
- steal and steal-failure counts
- wakeups and parks
- per-worker busy/idle/scratch/local-queue metrics
- wait and execution latency summaries
- Linux/macOS/Windows process memory metrics

## Known Gaps

- Adaptive grow/shrink is intentionally not implemented in phase 1.
- Per-task allocator-count metrics are not yet separate from byte accounting.
- Lane-aware scheduling is tracked for follow-on work rather than enabled by default.
