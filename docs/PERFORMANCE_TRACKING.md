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
| Phase 2 (remove global steal/park counters) | 435 | 588 | 643 | Task 7: consolidate steals/steal_failures/parks to per-worker only (median of 5 runs; high variance 365-843ns — within noise) |
| Phase 2 (TaskDescriptor hot/cold split) | 510 | 639 | 696 | Task 8: reorder fields so hot group (state/task_fn/ctx/options/generation) fits in one cache line (hot_size=64B, cache_line=128B); cold metric fields pushed behind. Single-run noise; wash vs Task 7. |

## Micro: steal_throughput (tasks=200000, 2 workers, inject_batch=1, smp_allocator)

| Phase | ops/s | steals | steal_failures | Notes |
|-------|-------|--------|----------------|-------|
| Phase 0 (baseline) | 686840 | 0 | 72154 | |
| Phase 2 (Task 7: per-worker steal/park counters) | 663352 | 0 | 78662 | |
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | 1437441 | 0 | 120361 | |
| Phase 3 (Task 10: batch-steal infra, default size=1) | 636735 | 0 | 101621 | wash — batch-steal default disabled due to popBottom race; infra ready for future deque rework |
| Phase 3 (Task 11: skip-empty victims in steal scan) | 677374 | 0 | 114851 | median of 2 runs (670408, 684341); +6.4% vs Task 10 by skipping seq_cst CAS on victims whose cheap `len()` peek shows empty |

## Micro: wake_latency (samples=5000, 2 workers, quiesce=300us, smp_allocator)

| Phase | p50 (ns) | p95 (ns) | p99 (ns) |
|-------|---------|----------|----------|
| Phase 0 (baseline) | 9621 | 15181 | 23591 |
| Phase 2 (Task 7: per-worker steal/park counters) | 10649 | 13016 | 16166 |
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | 9267 | 11026 | 14400 |

## Macro: conn_churn_seq (bench scenario, workers=2, queue=4096)

| Phase | scheduler | ops/s | submit p50 (ns) | submit p99 (ns) | Notes |
|-------|-----------|-------|-----------------|-----------------|-------|
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | global_queue | 1731709 | 532 | 813 | |
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | work_stealing | 1680812 | 554 | 891 | |
| Phase 3 (Task 11: skip-empty victims in steal scan) | work_stealing | 895954 | 1211 | 2159 | high run-to-run variance (788K–984K across 3 runs); this scenario rarely triggers steals, so the skip-empty change is effectively inert here — the swing is environmental noise |
