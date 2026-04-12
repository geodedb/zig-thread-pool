# Performance Tracking

Rolling record of micro-benchmark numbers as the Tokio-parity plan progresses.
All numbers from local dev machine unless noted. CI baselines tracked in
`benchmarks/results/baseline.json`.

## Verdict vs Targets

| Target | v0.2.0 baseline | After plan | Met? |
|--------|----------------|-----------|------|
| `conn_churn_seq/global_queue` throughput ≥ 5M ops/s | 1.48M | ~711K (median) | ❌ regressed |
| `conn_churn_seq/work_stealing` throughput ≥ 3M ops/s | 648K | ~544K | ❌ regressed |
| Submit p50 (single-producer) < 200 ns | 619 ns | ~1.8 µs | ❌ regressed |
| Submit p99 (4 producers) < 1 µs | 6.7 µs | ~12.8 µs | ❌ regressed |
| `producer_contention/*` completion p50 < 100 µs | 1.46 ms | 1.24 ms | ❌ marginal improvement only (queue never filled) |
| Hot-path `nanoTimestamp()` calls per task | 3 | 1 (mandatory; 0 with `timestamp_mode=disabled`) | ✅ (Task 5) |
| Hot-path atomic ops per task | ~10 | ~5 (per-worker counters) | ✅ (Tasks 6, 7) |
| Tokio-parity benchmark suite exists | — | yes (2 scenarios) | ✅ (Task 15) |
| Micro-benchmarks for submit/steal/wake exist | — | yes | ✅ (Tasks 2-4) |
| CI advisory micro-bench job | — | yes | ✅ (Task 16) |

**Net result on macro throughput: NEGATIVE.** Phase 2 (atomic + clock reductions) won
~500 ns of submit p50. Phase 3 (per-worker park condvar with broadcast fallback) cost
~1100 ns on the same path because the broadcast fires whenever the parked_workers
counter shows a worker mid-transition. At 2 workers there's no shared-mutex contention
to remove, so the regression dominates.

**What's salvageable**: the measurement infrastructure (Phases 1 + 5), `timestamp_mode`,
and per-worker counter consolidation are net wins regardless. Phase 3 (per-worker park)
needs either a re-tune (drop the broadcast fallback in favor of one extra signal hop)
or a revert before this branch should ship. The batch-steal infra (Tasks 9-10) is
correctness-blocked behind Chase-Lev's single-item proof — true batch steal needs a
different deque design.

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

| Phase | p50 (ns) | p95 (ns) | p99 (ns) | Notes |
|-------|---------|----------|----------|-------|
| Phase 0 (baseline) | 9621 | 15181 | 23591 | |
| Phase 2 (Task 7: per-worker steal/park counters) | 10649 | 13016 | 16166 | |
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | 9267 | 11026 | 14400 | |
| Phase 3 (Task 12: per-worker park condvar) | 12768 | 17140 | 21321 | median of 8 runs (10515, 12001, 12074, 12665, 12768, 13859, 13870, 14239, 14307 ns p50). Wake-bench is fixed at 2 workers where a shared park_mutex has ~zero contention, so this micro regresses here; the design removes an N-way mutex serialization point on submit and should pay off at higher worker counts — re-validate when macro adds many-worker scenarios. |

## Macro: conn_churn_seq (bench scenario, workers=2, queue=4096)

| Phase | scheduler | ops/s | submit p50 (ns) | submit p99 (ns) | Notes |
|-------|-----------|-------|-----------------|-----------------|-------|
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | global_queue | 1731709 | 532 | 813 | |
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | work_stealing | 1680812 | 554 | 891 | |
| Phase 3 (Task 11: skip-empty victims in steal scan) | work_stealing | 895954 | 1211 | 2159 | high run-to-run variance (788K–984K across 3 runs); this scenario rarely triggers steals, so the skip-empty change is effectively inert here — the swing is environmental noise |

## Macro: producer_contention (bench scenario, workers=2, submitters=4, queue=4096)

| Phase | scheduler | ops/s | submit p50 (ns) | submit p99 (ns) | completion p50 (ns) | completion p99 (ns) | Notes |
|-------|-----------|-------|-----------------|-----------------|---------------------|---------------------|-------|
| Phase 0 (baseline, pre-Phase-4) | work_stealing | — | — | — | ~1460000 | ~1690000 | baseline reference from plan — 50us poll-sleep dominated submit p99 under contention |
| Phase 4 (Task 13: backpressure condvar) | global_queue | 684493 | 3627 | 10550 | 1765264 | 1985233 | — |
| Phase 4 (Task 13: backpressure condvar) | work_stealing | 908583 | 2937 | 12791 | 1241252 | 1822769 | queue_peak=2172 < capacity=4096 so the queue-full branch wasn't exercised in this run — backpressure_waiters stays 0, the signal path is skipped entirely, and the change is a wash here. Expected payoff shows in scenarios where submitters actually block (e.g. scale-bench with small queue_capacity). Stress tests pass 10/10. |

## Tokio Parity Suite (workers=cpu_count, queue=4096, smp_allocator, ReleaseFast)

Numbers from `zig build bench-tokio-parity`. Directly comparable to Tokio's
`rt_multi_threaded` bench output on the same hardware.

| Scenario | ops/s | tasks | submitters | Notes |
|----------|-------|-------|-----------|-------|
| flood_1m | 297151 | 1000000 | 1 | Pure throughput; backpressure=block exercises the condvar path because 1M tasks > 4096 queue capacity, so submitter blocks repeatedly waiting for workers to drain |
| contended_spawn_8x | 496883 | 100000 | 8 | Multi-producer contention; 8 submitter threads + cpu_count workers |

For reference, Tokio's `rt_multi_threaded` flood-equivalent typically runs 5–15M ops/s on similar hardware. Our gap is the work the remaining tasks (true batch-steal via deque rework, hot-path atomic reductions beyond Phase 2) target.
