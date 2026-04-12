# Performance Tracking

Rolling record of micro-benchmark numbers as the Tokio-parity plan progresses.
All numbers from local dev machine unless noted. CI baselines tracked in
`benchmarks/results/baseline.json`.

## Micro: submit_latency (samples=100000, 1 worker, queue=101024, smp_allocator)

| Phase | p50 (ns) | p95 (ns) | p99 (ns) | Notes |
|-------|---------|----------|----------|-------|
| Phase 0 (baseline) | 904 | 1480 | 1793 | pre-optimization |
| Phase 2 (timestamp_mode default=full, no change expected) | 404 | 561 | 615 | Task 5: knob added, default preserves v0.2.0 behavior |
| Phase 2 (per-worker started/completed) | 419 | 565 | 618 | Task 6: move started/completed counters per-worker to reduce hot-path contention (median of 8 runs; variance 365-538ns) |

## Micro: steal_throughput (tasks=200000, 2 workers, inject_batch=1, smp_allocator)

| Phase | ops/s | steals | steal_failures |
|-------|-------|--------|----------------|
| Phase 0 (baseline) | 686840 | 0 | 72154 |

## Micro: wake_latency (samples=5000, 2 workers, quiesce=300us, smp_allocator)

| Phase | p50 (ns) | p95 (ns) | p99 (ns) |
|-------|---------|----------|----------|
| Phase 0 (baseline) | 9621 | 15181 | 23591 |
