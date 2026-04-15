# Post-Gen-Tag Profile (v3)

**Date:** 2026-04-15
**HEAD:** `44aecf5` (gen-tag at `85f0aaa` + Option D/G closures)
**Host:** Intel Xeon E5-2680 v4, 2 sockets × 14 cores = 56 threads
**Method:** `perf record -F 999 -g --call-graph dwarf` over 5 invocations
of the full bench (4 scenarios × 5 = 20 scenario runs), 747K samples,
~454B cycles.

Note: profile is *mixed across all 4 tokio-parity scenarios*, not
flood_1m_batched-only as in profile v2 (2026-04-14). flood_1m
dominates wall-clock per invocation (~2.5s) over flood_1m_batched
(~1s) and contended (~0.15s × 2). flood_1m_batched is ~26% of
total samples.

## TL;DR

The inject-head story has been *displaced*. Two attacks on the
v2 #1 hotspot (`BoundedRing.popMany` 16.64%) failed to land:

- Iter 4 (Option D, drain-vs-steal reorder): `flood_1m_batched`
  -3.8% vs +15% gate.
- Iter 5 (Option G, `inject_batch_size` 32→64): only +2.0% on
  target with two regressions on other scenarios.

Re-profile shows the new #1 is **`pool.Core.notifySubmits` at
27.58% inclusive cost** (1.27% self), called from every submit
batch on the producer side. `popMany` has dropped to 8.58%
inclusive in this mixed profile.

## Top inclusive (children) hotspots

```text
69.09%  workerMain                              (worker entry, includes everything below)
28.64%  nextTask                                (worker hot loop)
27.58%  notifySubmits             ←── NEW #1
13.43%  enqueuePush               (self 9.16%)
 9.80%  idle                      (futex wait)
 8.58%  BoundedRing(u64).popMany  (was 16.64% in v2)
 6.99%  releaseDescriptor
 6.35%  submitBatch
 1.97%  enqueueTask
```

## Why notifySubmits dominates

`notifySubmits(count)` is called by every `submit` and every
`submitBatch` after the descriptor is enqueued. Body
(src/pool.zig:731-752):

1. `submitted.fetchAdd(count, .monotonic)`
2. `queued_tasks.fetchAdd(count, .seq_cst)` ← SC handshake
3. `submitted.load(.monotonic)` (for hint)
4. **Loop up to 56 workers, doing `is_parked.load(.seq_cst)` on each**
5. On first parked worker found: lock park_mutex, recheck, signal cond, unlock; break.

The loop is the bottleneck. In `flood_1m_batched`'s steady state
the workers are all running (not parked), so the loop scans all
56 workers' `is_parked` cachelines, finds nothing, and returns
without signaling. **56 SC loads × 15,625 batches × 5 invocations
= ~4.4M SC loads on cross-cacheline `is_parked` flags**.

## Forward-path design: parked-workers bitmap

Mirror the existing `workers_nonempty: u64` pattern (introduced
by `e533955`) for park state.

### Change

Add `parked_workers: std.atomic.Value(u64) align(cache_line)` to
`Core`. Maintain via worker-side `fetchOr`/`fetchAnd` on park /
unpark transitions (single-writer per bit; consumers may observe
stale-but-eventually-consistent state).

### `notifySubmits` body becomes

```zig
fn notifySubmits(self: *Core, count: u64) void {
    if (count == 0) return;
    _ = self.counters.submitted.fetchAdd(count, .monotonic);
    const queue_depth = self.counters.queued_tasks.fetchAdd(count, .seq_cst) +% count;
    updatePeak(&self.counters.queue_depth_peak, queue_depth);

    // Fast-path: no parked workers → no scan, no signal.
    var parked = self.parked_workers.load(.seq_cst);
    if (parked == 0) return;

    // Bias scan toward submitted-hash hint; iterate set bits via @ctz.
    const submitted = self.counters.submitted.load(.monotonic);
    const hint_idx: usize = @intCast(submitted % self.workers.len);
    // ...iterate bits in `parked`, biased to start at hint_idx...
    // ...lock-recheck-signal exactly like today on the first parked match...
}
```

### Park-side maintenance (in `idle`)

Insert before the existing SC handshake:

```zig
const bit = @as(u64, 1) << @intCast(worker_index);
_ = self.parked_workers.fetchOr(bit, .seq_cst);  // SC matches
                                                  // submitter's load
worker.is_parked.store(1, .seq_cst);
// ... existing reload-and-bail check ...
// On bail-out OR after timedWait:
_ = self.parked_workers.fetchAnd(~bit, .seq_cst);
worker.is_parked.store(0, .release);
```

### Correctness

The bitmap is SC-ordered with the existing `queued_tasks` SC fetchAdd.
Two cases:

1. **Submitter sees `parked == 0`:** by SC total order, no worker
   has done `parked_workers.fetchOr` yet → no worker has done
   `is_parked.store(1, SC)` yet → no worker has done
   `queued_tasks.load(SC)` yet → that load *will* observe the
   submitter's increment → worker bails out before park. **No
   lost wakeup.**

2. **Submitter sees `parked != 0`:** scan only set bits, signal
   the first matching parked worker. Even if a bit is stale (worker
   already woke), the lock-recheck-monotonic step inside the loop
   handles it as today.

### Expected gain

If `notifySubmits`' inclusive 27.58% is dominated by the 56-way
scan, replacing it with a single SC load (when `parked == 0`)
should reclaim most of that share. Realistic estimate: 10-20%
throughput gain on `flood_1m_batched`. We need ≥ +15% to clear
the gate.

### Risks

- New SC writes per park cycle (fetchOr + fetchAnd on a single
  shared cacheline). At 56 parks/sec/worker × 56 workers in steady
  state idle that's 3.1k writes/sec — negligible.
- Bitmap could become a contention hotspot if many workers
  park/unpark at the same instant. `workers_nonempty` already
  exists with the same pattern and never showed up in profile —
  same guarantees apply.

## Files

- `perf_flat.txt` — `perf report --no-children`
- `perf_children.txt` — call-graph perf report (graph 0.3)
- `perf_self.txt` — children+self overview
- Raw 6.3 GB perf.data deleted post-extract.

## What this closes / opens

**Closes:** the working hypothesis from v2 that inject-head
contention was the #1 actionable ceiling. Two attacks confirmed
it isn't.

**Opens:** parked-workers bitmap as iter 7's primary attack.
If that lands, re-profile to find the next hotspot.
