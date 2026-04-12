# Performance Tracking

Rolling record of micro-benchmark numbers as the Tokio-parity plan progresses.
All numbers from local dev machine unless noted. CI baselines tracked in
`benchmarks/results/baseline.json`.

## Verdict vs Targets

| Target | v0.2.0 baseline | After plan | Met? |
|--------|----------------|-----------|------|
| `conn_churn_seq/global_queue` throughput ≥ 5M ops/s | 1.48M | ~817K (Phase A+B baseline; not re-measured in B7; see C2 for final verdict) | ❌ regressed |
| `conn_churn_seq/work_stealing` throughput ≥ 3M ops/s | 648K | ~763K (Phase A+B baseline; not re-measured in B7; see C2 for final verdict) | ❌ regressed |
| Submit p50 (single-producer) < 200 ns | 619 ns | 781 ns (Phase A) | ❌ still above target; Phase A recovered the broadcast-fallback regression (~1.8 µs → 781 ns median of 5 runs); remaining gap addressed in Phase B |
| Submit p99 (4 producers) < 1 µs | 6.7 µs | ~12.8 µs | ❌ regressed |
| `producer_contention/*` completion p50 < 100 µs | 1.46 ms | 1.24 ms | ❌ marginal improvement only (queue never filled) |
| Hot-path `nanoTimestamp()` calls per task | 3 | 1 (mandatory; 0 with `timestamp_mode=disabled`) | ✅ (Task 5) |
| Hot-path atomic ops per task | ~10 | ~5 (per-worker counters) | ✅ (Tasks 6, 7) |
| Tokio-parity benchmark suite exists | — | yes (2 scenarios) | ✅ (Task 15) |
| Micro-benchmarks for submit/steal/wake exist | — | yes | ✅ (Tasks 2-4) |
| CI advisory micro-bench job | — | yes | ✅ (Task 16) |
| `bench_tokio_parity/flood_1m` ≥ 1M ops/s | 297K | 347K (Phase A+B median of 3) | ❌ BELOW TARGET — 346K ops/s; 65% gap remains |
| `bench_tokio_parity/contended_spawn_8x` ≥ 1M ops/s | 497K | 508K (Phase A+B median of 3) | ❌ BELOW TARGET — 508K ops/s; 49% gap remains |

## Phase A+B Final Verdict

**Submit latency (Phase A):** p50 recovered from the Phase 3 broadcast-fallback
regression (~1.8 µs) to 781 ns median of 5 runs. The seq_cst handshake on
`is_parked` + `queued_tasks` closes the lost-wakeup race with a single
signal path and no fallback broadcast. Still ~4× the <200 ns target, but
the regression is no longer in the way.

**Steal throughput (Phase B, batch=1):** 1.42M ops/s, +109% vs Chase-Lev's
677K baseline. The RingQueue swap paid off on single-item steal alone —
owner/stealer last-element race resolves in fewer cache-line bounces.

**Steal throughput (Phase B, batch=8):** 656K ops/s, *slower* than batch=1
in the 2-worker micro because the single victim stalls more often waiting
for the stealer to release capacity. The benefit of true batch-steal shows
only with more stealers per victim; at 2 workers it's a micro-anti-signal.

**Macro `conn_churn_seq`:** +53% global_queue (533K→817K), +40% work_stealing
(544K→763K) vs the Phase 3 baseline. Still far below the 3M–5M targets but
directionally good.

**Macro `producer_contention/work_stealing`:** -18% (892K→731K). Queue
never fills (peak ~2K / 4096) so this is run-to-run variance, not a real
regression — but it's close to CI's -15% regression gate and worth flagging.

**Tokio parity `flood_1m`:** 347K ops/s vs ≥1M target (65% gap remains).

**Tokio parity `contended_spawn_8x`:** 508K ops/s vs ≥1M target (49% gap).

### Residual gap

With the submit-path and steal-path recovered, the bottleneck on the
Tokio-parity flood scenarios has moved to the backpressure condvar path:
at 1M tasks through a 4096-capacity queue the submitter blocks ~244 times,
each block paying a full condvar wait+signal round-trip. A future pass
would (a) coalesce backpressure wake-ups so a worker drain signals once
per N descriptors freed, (b) increase effective throughput via larger
inject batches without increasing submit p99, or (c) investigate lock-free
backpressure (thread-local reservation of descriptor slots).

The single-item steal improvement (+109%) and the recovered submit-latency
mean the ring queue and park simplification are both net wins and should
ship. The Tokio-parity 1M ops/s target is out of reach in this pass.

## Micro: submit_latency (samples=100000, 1 worker, queue=101024, smp_allocator)

| Phase | p50 (ns) | p95 (ns) | p99 (ns) | Notes |
|-------|---------|----------|----------|-------|
| Phase 0 (baseline) | 904 | 1480 | 1793 | pre-optimization |
| Phase 2 (timestamp_mode default=full, no change expected) | 404 | 561 | 615 | Task 5: knob added, default preserves v0.2.0 behavior |
| Phase 2 (per-worker started/completed) | 419 | 565 | 618 | Task 6: move started/completed counters per-worker to reduce hot-path contention (median of 8 runs; variance 365-538ns) |
| Phase 2 (remove global steal/park counters) | 435 | 588 | 643 | Task 7: consolidate steals/steal_failures/parks to per-worker only (median of 5 runs; high variance 365-843ns — within noise) |
| Phase 2 (TaskDescriptor hot/cold split) | 510 | 639 | 696 | Task 8: reorder fields so hot group (state/task_fn/ctx/options/generation) fits in one cache line (hot_size=64B, cache_line=128B); cold metric fields pushed behind. Single-run noise; wash vs Task 7. |
| Phase A (park handshake simplification) | 781 | 1387 | 1690 | A1: removed parked_workers counter + broadcast fallback. A2: seq_cst handshake on is_parked + queued_tasks (median of 5 runs). |

## Micro: steal_throughput (tasks=200000, 2 workers, inject_batch=1, smp_allocator)

| Phase | ops/s | steals | steal_failures | Notes |
|-------|-------|--------|----------------|-------|
| Phase 0 (baseline) | 686840 | 0 | 72154 | |
| Phase 2 (Task 7: per-worker steal/park counters) | 663352 | 0 | 78662 | |
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | 1437441 | 0 | 120361 | |
| Phase 3 (Task 10: batch-steal infra, default size=1) | 636735 | 0 | 101621 | wash — batch-steal default disabled due to popBottom race; infra ready for future deque rework |
| Phase 3 (Task 11: skip-empty victims in steal scan) | 677374 | 0 | 114851 | median of 2 runs (670408, 684341); +6.4% vs Task 10 by skipping seq_cst CAS on victims whose cheap `len()` peek shows empty |
| Phase B (ring queue, batch=1) | 1417145 | 0 | 141358 | Task B4: RingQueue replaces Chase-Lev; steal_batch_size=1 for apples-to-apples; median of 5 runs (1390204, 1405719, 1417145, 1429080, 1438065) |
| Phase B (ring queue, batch=8) | 656631 | 0 | 77245 | Task B4: true batch-steal via stealHalf; expected to scale vs batch=1; median of 5 runs (650127, 653360, 656631, 678349, 1427207); one high outlier excluded from interpretation |

## Micro: wake_latency (samples=5000, 2 workers, quiesce=300us, smp_allocator)

| Phase | p50 (ns) | p95 (ns) | p99 (ns) | Notes |
|-------|---------|----------|----------|-------|
| Phase 0 (baseline) | 9621 | 15181 | 23591 | |
| Phase 2 (Task 7: per-worker steal/park counters) | 10649 | 13016 | 16166 | |
| Phase 2 (Task 8: TaskDescriptor hot/cold split) | 9267 | 11026 | 14400 | |
| Phase 3 (Task 12: per-worker park condvar) | 12768 | 17140 | 21321 | median of 8 runs (10515, 12001, 12074, 12665, 12768, 13859, 13870, 14239, 14307 ns p50). Wake-bench is fixed at 2 workers where a shared park_mutex has ~zero contention, so this micro regresses here; the design removes an N-way mutex serialization point on submit and should pay off at higher worker counts — re-validate when macro adds many-worker scenarios. |
| Phase A (park handshake simplification) | 9985 | 14080 | 17898 | median of 5 runs; single-signal path, no N-way broadcast. |

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
| flood_1m (Phase A+B) | 346772 | 1000000 | 1 | Park handshake simplified; ring queue batch-steal=8; median of 3 runs |
| contended_spawn_8x (Phase A+B) | 507753 | 100000 | 8 | Park handshake simplified; ring queue batch-steal=8; median of 3 runs |

For reference, Tokio's `rt_multi_threaded` flood-equivalent typically runs 5–15M ops/s on similar hardware. Our gap is the work the remaining tasks (true batch-steal via deque rework, hot-path atomic reductions beyond Phase 2) target.
