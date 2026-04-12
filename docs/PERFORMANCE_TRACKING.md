# Performance Tracking

Rolling record of micro-benchmark numbers as the Tokio-parity plan progresses.
All numbers from local dev machine unless noted. CI baselines tracked in
`benchmarks/results/baseline.json`.

## Micro: submit_latency (samples=100000, 1 worker, queue=101024, smp_allocator)

| Phase | p50 (ns) | p95 (ns) | p99 (ns) | Notes |
|-------|---------|----------|----------|-------|
| Phase 0 (baseline) | 904 | 1480 | 1793 | pre-optimization |

## Micro: steal_throughput (tasks=200000, 2 workers, inject_batch=1, smp_allocator)

| Phase | ops/s | steals | steal_failures |
|-------|-------|--------|----------------|
| Phase 0 (baseline) | 686840 | 0 | 72154 |
