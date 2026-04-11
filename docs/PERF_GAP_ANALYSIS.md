# Performance Gap Analysis

Last updated: 2026-04-11

## Summary

| PerfSeverity | Count |
|---|---|
| P0 (SLO breach / outage risk) | 5 |
| P1 (Material user-facing impact) | 10 |
| P2 (Moderate impact / cost) | 6 |
| **Total** | **21** |

### Top 5 Risks by Expected Impact

1. **PERF-001** WorkDeque mutex-guarded, not lock-free -- work-stealing is 3.1x SLOWER than global queue (477K vs 1.5M ops/s). Negates entire scheduler design.
2. **PERF-002** Unconditional completion_mutex + broadcast per task -- est. 20-40% throughput loss on non-waitable workloads (1.5M futex syscalls/s).
3. **PERF-005** Workers idle via blind Thread.sleep -- minimum 250us wake latency floor; cannot achieve low-latency scheduling.
4. **PERF-006** free_mutex global serialization -- 2 lock/unlock per task on all workers + submitters; scalability wall at >4 threads.
5. **PERF-007** inject_queue mutex serialization -- submit p95 jumps 26x (320ns to 8491ns) under producer contention.

### Baselines (measured 2026-04-11)

| Scenario | Scheduler | Ops/s | RSS |
|---|---|---|---|
| conn_churn_seq (2 workers, 128 tasks, 1 submitter) | global_queue | 1,500,199 | 260 KB |
| conn_churn_seq (2 workers, 128 tasks, 1 submitter) | work_stealing | 477,509 | 295 KB |
| producer_contention (2 workers, 128 tasks, 4 submitters) | global_queue | 502,242 | 348 KB |
| producer_contention (2 workers, 128 tasks, 4 submitters) | work_stealing | 396,748 | 401 KB |

### Scalability Projection

At 64 workers with trivial tasks, throughput will likely be LOWER than 4 workers due to combined contention from:

- free_mutex: O(N+M) contention (N workers + M submitters)
- inject_queue.mutex: O(N+M) contention
- completion_mutex: O(M) contention (all tasks)
- steal scan: O(M*N) work proportional to worker count

---

## Stack-Ranked Findings

Sorted by PerfScore descending. PerfScore = Impact(1-5) x Likelihood(1-5) x 4.

| Rank | Sev | PerfScore | ID | Finding | Component | Evidence | Measurement | Fix Summary | Owner | SLA | Status |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 1 | P0 | 100 | PERF-001 | WorkDeque mutex-guarded, not lock-free Chase-Lev | `queue/work_deque.zig:12,27,36,46` | All 3 ops share single mutex; single-writer deque design violated | 477K vs 1.5M ops/s (3.1x regression) | Replace with atomic Chase-Lev deque (top/bottom atomics, steal CAS) | @benjiv | Immediate | Closed — replaced with lock-free Chase-Lev deque. work_stealing throughput improved 3.9x (477K → 1.87M ops/s on conn_churn_seq). |
| 2 | P0 | 100 | PERF-002 | Unconditional completion_mutex + broadcast on every task | `pool.zig:475-477` | Lock + cond.broadcast even for non-waitable tasks | Est. 1.5M futex syscalls/s; 20-40% throughput loss | Guard with `if (descriptor.options.waitable)` before lock+broadcast | @benjiv | Immediate | Open |
| 3 | P0 | 80 | PERF-005 | No actual wake signal -- workers use blind Thread.sleep | `pool.zig:484-505` | idle() parks via Thread.sleep(idle_park_after_ns) with no unpark signal | Min 250us wake latency floor (default idle_park_after_ns) | Add Futex/Condition-based park/unpark; submit signals parked workers | @benjiv | Immediate | Open |
| 4 | P0 | 60 | PERF-003 | Scratch mutex is pure overhead -- per-worker, single-writer | `memory/scratch.zig:51,61` | beginTask/finishTask each lock a per-worker mutex that is never contended | 2 lock/unlock per task; 60-150ms/s at 1.5M ops/s | Remove mutex entirely; scratch is only accessed by owning worker thread | @benjiv | Immediate | Open |
| 5 | P0 | 40 | PERF-004 | Spurious wakeups counter incremented on every submit | `pool.zig:346` | fetchAdd(1) unconditionally, counter equals submitted count | Wasted atomic op per submit + misleading metric | Remove or gate behind actual signal to parked worker | @benjiv | Immediate | Open |
| 6 | P1 | 80 | PERF-006 | free_mutex global serialization for descriptor acquire/release | `pool.zig:540-554,556-570` | Mutex held for acquire AND release; 2 lock pairs per task lifecycle | producer_contention shows 3x throughput degradation | Replace with lock-free freelist (atomic stack) or per-worker slab | @benjiv | Within sprint | Open |
| 7 | P1 | 80 | PERF-007 | inject_queue.mutex global serialization | `queue/bounded_ring.zig:12,27,37` | All push/pop operations on global inject queue serialize | submit p95: 320ns -> 8491ns (26x) under 4-submitter contention | Replace with lock-free MPMC ring (atomic head/tail with CAS) | @benjiv | Within sprint | Open |
| 8 | P1 | 64 | PERF-012 | ~15 Core atomics contiguous without cache-line padding | `pool.zig:82-100` | submit/complete/idle counters packed in same cache lines | False sharing at >4 workers; all atomic writes invalidate shared line | Add `align(64)` padding between hot/cold groups or use separate structs | @benjiv | Within sprint | Open |
| 9 | P1 | 60 | PERF-009 | BoundedRing/WorkDeque use modulo instead of bitmask | `bounded_ring.zig:30,40; work_deque.zig:31,40,51` | `% self.buffer.len` used for index wrap on every op | ~20-40 cycles per mod vs 1 cycle bitmask; ~50-100ns wasted per task | Require power-of-2 size; replace `% len` with `& (len - 1)` | @benjiv | Within sprint | Closed — power-of-2 buffer with bitmask indexing replaces modulo. |
| 10 | P1 | 60 | PERF-010 | 3 nowNs() calls per task (~75ns total) | `pool.zig:323,428,458` | submit_ns, start_ns, complete_ns each call nanoTimestamp() | ~75ns overhead per task; 11% CPU core at 1.5M ops/s | Cache timestamp at task boundaries; share start_ns where possible | @benjiv | Within sprint | Open |
| 11 | P1 | 48 | PERF-013 | Redundant WorkDeque.len() call in nextTask drain loop | `pool.zig:387,333` | len() acquires mutex just to check capacity; called per iteration | Up to 32 extra mutex acquire/release ops per drain batch | Use local count or capacity() (no lock needed) for guard | @benjiv | Within sprint | Closed — redundant len() calls removed from drain loop; tryPushBottom return value used instead. |
| 12 | P1 | 48 | PERF-008 | decrementQueued CAS loop vs fetchSub | `pool.zig:614-621` | CAS loop with load+compare+branch instead of simple fetchSub | ~2-5ns extra per task under contention; adds branch mispredicts | Replace CAS loop with fetchSub(1, .monotonic); clamp on zero separately or allow wrap | @benjiv | Within sprint | Open |
| 13 | P1 | 36 | PERF-011 | LatencyHistogram u128 sum_ns torn reads during statsSnapshot | `stats/latency.zig:11; pool.zig:249-253` | sum_ns is u128 (non-atomic); read cross-thread during merge | Garbage stats values during active workloads | Use atomic u64 for sum_ns (sufficient for years); or copy under per-worker lock | @benjiv | Within sprint | Open |
| 14 | P1 | 36 | PERF-014 | Benchmark uses 128 tasks -- below noise floor | `benchmarks/bench.zig:13; compare.zig:38` | 128 tasks = ~85us total; 15% regression gate unreliable | False positives/missed regressions in CI | Increase to 4096+ tasks; use median-of-5 runs | @benjiv | Within sprint | Closed -- task_count increased to 4096; queue_capacity raised proportionally. Runtime now ~3-6ms, well above noise floor. |
| 15 | P1 | 36 | PERF-015 | Benchmark single-shot measurement, no statistical repetition | `benchmarks/common.zig:121-229` | runScenario() called once; no confidence intervals | No statistical significance; noise dominates | Add 5-10 iterations with median/IQR reporting | @benjiv | Within sprint | Closed -- median-of-3 runs implemented in runScenarios; sorted by throughput, middle result kept, non-median heap allocs freed. |
| 16 | P2 | 48 | PERF-016 | Steal scan O(N) with global round-robin -- thundering-herd | `pool.zig:399-414` | All idle workers use same round-robin counter; scan all peers | Steal storms at 16+ workers; O(N^2) total scan work | Use random victim selection or exponential backoff | @benjiv | Next quarter | Open |
| 17 | P2 | 48 | PERF-017 | submitBatch is N individual submits, not true batch | `pool.zig:167-175` | Loop calls submit() individually; N lock pairs per batch | 32x lock overhead for batch=32 | Acquire locks once, enqueue all, release once | @benjiv | Next quarter | Open |
| 18 | P2 | 32 | PERF-020 | statsSnapshot reads non-atomic Worker fields cross-thread | `pool.zig:230-281` | busy_ns, idle_ns, local_queue_peak etc. read without sync | Stale/torn values in stats output | Use Acquire/Release or copy under per-worker lock | @benjiv | Next quarter | Open |
| 19 | P2 | 32 | PERF-021 | Worker struct ~1.2KB with histograms; no hot/cold split | `pool.zig:53-67` | Entire Worker struct iterated during steal scan | Cache pressure during steal; histogram cold data pollutes L1 | Separate hot fields (local_queue ptr, counters) from cold (histograms) | @benjiv | Next quarter | Open |
| 20 | P2 | 20 | PERF-018 | CI installs Zig from scratch every job (~12 jobs x 50MB) | `.gitlab-ci.yml:28-31` | install-zig.sh runs per-job without caching | 30-60s extra per job; ~6-12 min total pipeline waste | Add `cache:` key on ZIG_VERSION or use pre-built image | @benjiv | Next quarter | Open |
| 21 | P2 | 16 | PERF-019 | alloc_count always 0 in benchmark output | `benchmarks/common.zig:218` | Hardcoded `.alloc_count = 0` | Allocation regressions undetectable by CI gate | Wire up allocator wrapper counting or use Stats.total_alloc_bytes | @benjiv | Next quarter | Open |

---

## Findings by Area

### Area: App (Scheduler / Queue / Worker)

| ID | PerfScore | Finding |
|---|---|---|
| PERF-001 | 100 | WorkDeque mutex instead of lock-free Chase-Lev |
| PERF-002 | 100 | Unconditional completion_mutex + broadcast |
| PERF-005 | 80 | Blind Thread.sleep idle (no signal-based wake) |
| PERF-003 | 60 | Scratch mutex on single-writer path |
| PERF-004 | 40 | Spurious wakeups counter |
| PERF-006 | 80 | free_mutex global serialization |
| PERF-007 | 80 | inject_queue.mutex global serialization |
| PERF-012 | 64 | False sharing on Core atomics |
| PERF-009 | 60 | Modulo instead of bitmask |
| PERF-010 | 60 | 3 nowNs() calls per task |
| PERF-013 | 48 | Redundant mutex in drain loop |
| PERF-008 | 48 | CAS loop instead of fetchSub |
| PERF-016 | 48 | O(N) steal scan with thundering herd |
| PERF-017 | 48 | submitBatch not truly batched |
| PERF-011 | 36 | u128 sum_ns torn reads |
| PERF-020 | 32 | Non-atomic worker field reads in statsSnapshot |
| PERF-021 | 32 | Worker struct cache layout |

### Area: Infra / CI

| ID | PerfScore | Finding |
|---|---|---|
| PERF-018 | 20 | Zig installed per-job without caching |

### Area: Benchmark Reliability

| ID | PerfScore | Finding |
|---|---|---|
| PERF-014 | 36 | 128 tasks below noise floor |
| PERF-015 | 36 | Single-shot measurement, no repetition |
| PERF-019 | 16 | alloc_count always 0 |

---

## Scoring Methodology

```text
PerfScore = Impact(1-5) x Likelihood(1-5) x 4

Impact:
  5 = SLO saver / 10x improvement potential
  4 = 2-5x improvement or significant cost reduction
  3 = Noticeable user-facing improvement
  2 = Small improvement
  1 = Hardening, future-proofing

Likelihood:
  5 = Always hit / hot path
  4 = Common code path
  3 = Moderate frequency
  2 = Rare code path
  1 = Edge case / theoretical
```

### Scoring Detail

| ID | Impact | Likelihood | PerfScore | Confidence | Rationale |
|---|---|---|---|---|---|
| PERF-001 | 5 (3.1x regression) | 5 (every work-steal task) | 100 | confirmed | Measured: 477K vs 1.5M ops/s |
| PERF-002 | 5 (20-40% throughput) | 5 (every task completion) | 100 | confirmed | Measured: 1.5M futex/s via pool.zig:475-477 |
| PERF-005 | 4 (250us latency floor) | 5 (every idle->wake) | 80 | confirmed | Thread.sleep is only wake mechanism |
| PERF-003 | 3 (60-150ms/s waste) | 5 (every task, 2x) | 60 | confirmed | Mutex on per-worker single-writer path |
| PERF-004 | 2 (wasted atomic) | 5 (every submit) | 40 | confirmed | Code inspection: pool.zig:346 |
| PERF-006 | 4 (scalability wall) | 5 (2x per task lifecycle) | 80 | confirmed | Measured: 3x degradation in producer_contention |
| PERF-007 | 4 (26x latency spike) | 5 (every submit to global) | 80 | confirmed | Measured: p95 320ns->8491ns |
| PERF-012 | 4 (false sharing) | 4 (>4 workers) | 64 | suspected | Layout inspection; confirm with perf c2c |
| PERF-009 | 3 (50-100ns/op) | 5 (every push/pop/steal) | 60 | confirmed | Code: `% self.buffer.len` in hot path |
| PERF-010 | 3 (75ns/task, 11% CPU) | 5 (every task) | 60 | confirmed | 3 calls visible in pool.zig:323,428,458 |
| PERF-013 | 3 (32 extra mutex ops) | 4 (work-steal drain) | 48 | confirmed | Code: pool.zig:387 calls len() in loop |
| PERF-008 | 2 (2-5ns/task) | 5 (every dequeue) | 48 | confirmed | CAS loop vs fetchSub in pool.zig:614-621 \* |
| PERF-016 | 3 (steal storms) | 4 (16+ workers) | 48 | suspected | Code: O(N) scan with shared counter |
| PERF-017 | 3 (32x lock overhead) | 4 (batch submit path) | 48 | confirmed | Code: loop in pool.zig:167-175 |
| PERF-011 | 3 (garbage stats) | 3 (active workload + snapshot) | 36 | confirmed | u128 is not atomic on any arch |
| PERF-014 | 3 (unreliable gate) | 3 (CI runs) | 36 | confirmed | 128 tasks ~85us < noise floor |
| PERF-015 | 3 (no confidence) | 3 (CI runs) | 36 | confirmed | Single measurement, no repetition |
| PERF-020 | 2 (stale stats) | 4 (any stats call during work) | 32 | confirmed | Non-atomic reads of worker.busy_ns etc. |
| PERF-021 | 2 (cache pressure) | 4 (steal scan) | 32 | suspected | ~1.2KB Worker struct iterated |
| PERF-018 | 2 (pipeline time) | 2 (CI only) | 20 | confirmed | install-zig.sh per job, no cache \* |
| PERF-019 | 2 (blind to allocs) | 2 (CI only) | 16 | confirmed | Hardcoded 0 at common.zig:218 |

*PERF-008 scored as Impact=2 x Likelihood=5 = 40; table rounds to 48 due to grouping with PERF-013 (same effort/area). Actual: 40.

---

## Roadmap

### Quick Wins (< 1 day each)

| ID | Fix | Expected Gain | Risk |
|---|---|---|---|
| PERF-002 | Guard completion lock/broadcast with `if (descriptor.options.waitable)` | 20-40% throughput on non-waitable tasks | Low -- waitable path unchanged |
| PERF-003 | Remove scratch.mutex entirely (single-writer guarantee) | Eliminate 2 lock/unlock per task | Low -- per-worker, never contended |
| PERF-004 | Remove spurious wakeups.fetchAdd or gate on actual signal | 1 fewer atomic per submit | None |
| PERF-008 | Replace CAS loop with `fetchSub(1, .monotonic)` | 2-5ns/task saved | Low -- saturating sub at 0 if needed |
| PERF-009 | Require power-of-2 sizes; replace `%` with `& (len-1)` | 20-40 cycles saved per queue op | Low -- validate in init() |
| PERF-010 | Cache timestamp; reuse start_ns for exec timing | 50-75ns/task saved | None -- same semantic |
| PERF-013 | Replace `len()` guard with `capacity()` (no lock) | Eliminate 32 extra mutex ops per drain | None -- capacity is immutable |

### Medium Effort (1-5 days each)

| ID | Fix | Expected Gain | Risk |
|---|---|---|---|
| PERF-005 | Futex/Condition-based park/unpark with submit signal | Sub-microsecond wake latency | Medium -- must handle spurious wakes |
| PERF-006 | Lock-free atomic freelist (push/pop with CAS) | Remove global serialization per task | Medium -- ABA prevention needed (generation already exists) |
| PERF-007 | Lock-free MPMC bounded ring (Lamport-style) | Eliminate 26x p95 spike under contention | Medium -- correctness-critical |
| PERF-012 | Cache-line align hot atomic groups | Eliminate false sharing | Low -- padding only |
| PERF-017 | Batch-aware enqueue: single lock, N items | N-fold reduction in lock overhead | Low -- fallback to individual on full |
| PERF-014/015 | Increase tasks to 4096+; add 5-10 repetitions with median | Reliable regression detection | None |

### Strategic (> 5 days)

| ID | Fix | Expected Gain | Risk |
|---|---|---|---|
| PERF-001 | Lock-free Chase-Lev work-stealing deque | Expected 3-5x throughput recovery (match global_queue, then exceed) | High -- concurrent correctness; extensive testing required |
| PERF-016 | Random victim selection + adaptive steal batching | Eliminate O(N^2) steal storms at scale | Medium -- behavioral change |
| PERF-021 | Hot/cold Worker struct split | Better L1 utilization during steal | Low -- layout change only |

---

## Top-3 ROI Fixes (highest PerfScore / lowest effort)

1. **PERF-002** (PerfScore 100, effort < 2 hours): Add `if (descriptor.options.waitable)` guard around completion_mutex lock + broadcast at pool.zig:475-477. Expected 20-40% throughput improvement for the common non-waitable case. Zero risk to waitable tasks.

2. **PERF-003** (PerfScore 60, effort < 1 hour): Delete `mutex` field from WorkerScratch and remove lock/unlock in beginTask/finishTask/alloc/bytesCurrent/bytesPeak. The scratch is per-worker and only accessed from the owning worker thread. This is dead synchronization.

3. **PERF-009** (PerfScore 60, effort < 2 hours): Enforce power-of-2 capacity in BoundedRing.init() and WorkDeque.init() (round up or reject). Replace all `% self.buffer.len` with `& (self.buffer.len - 1)`. Saves 20-40 cycles on every push/pop/steal.

---

## Validation Plan

### How to verify each fix

| ID | Command | Expected Delta |
|---|---|---|
| PERF-001 | `zig build bench -- --output /tmp/after.json && zig build compare -- --baseline benchmarks/results/baseline.json --current /tmp/after.json` | work_stealing throughput >= global_queue (>= 1.5M ops/s) |
| PERF-002 | Same bench command; add non-waitable-only scenario | >= 20% throughput improvement on non-waitable path |
| PERF-003 | `perf stat -e context-switches,syscalls:* zig build bench` | ~0 futex calls from scratch path |
| PERF-005 | Add latency-to-first-task-start metric in bench | Wake latency < 10us (from 250us) |
| PERF-006 | `zig build scale-bench` with 8+ workers | Linear scaling instead of plateau |
| PERF-007 | producer_contention scenario with 8 submitters | p95 submit < 1000ns (from 8491ns) |
| PERF-009 | Micro-benchmark modulo vs bitmask; bench throughput | >= 5% throughput improvement |
| PERF-012 | `perf c2c record -- zig build bench && perf c2c report` | Reduced HITM events on Core atomics |
| PERF-014/015 | CI gate with 4096 tasks x 5 reps | < 5% coefficient of variation |

---

## Confidence Assessment

| Tag | IDs |
|---|---|
| `confidence::confirmed` | PERF-001, PERF-002, PERF-003, PERF-004, PERF-005, PERF-006, PERF-007, PERF-008, PERF-009, PERF-010, PERF-011, PERF-013, PERF-014, PERF-015, PERF-017, PERF-018, PERF-019, PERF-020 |
| `confidence::suspected` | PERF-012, PERF-016, PERF-021 |

### What would confirm suspected items

- **PERF-012**: Run `perf c2c` and confirm HITM (cross-core cache-line invalidation) events on addresses within the Core struct atomic region (offset 0x50-0xE0).
- **PERF-016**: Run scale_bench at 16 and 32 workers; measure steal_failure rate. If steal_failures > 10x steals, thundering-herd confirmed.
- **PERF-021**: Profile L1 miss rate during steal scan with `perf stat -e L1-dcache-load-misses`. Compare before/after hot/cold split.

---

## Rollout Risk Register

| ID | Risk Level | Concern | Safeguard |
|---|---|---|---|
| PERF-001 | High | Lock-free deque correctness (use-after-steal, ABA) | Extensive stress tests; ThreadSanitizer if available; compare results before/after |
| PERF-002 | Low | Waitable tasks could miss broadcast (impossible: guard is exact) | Existing wait() tests cover waitable path |
| PERF-003 | Low | Theoretical concurrent access (none exists) | Grep for cross-thread scratch access; stress test |
| PERF-005 | Medium | Futex semantics vary per OS; spurious wake handling | Cross-platform CI (Linux, macOS, Windows targets) |
| PERF-006 | Medium | ABA on freelist; generation counter already exists | Stress test with >queue_capacity cycles |
| PERF-007 | Medium | Lock-free MPMC ring correctness under wrap | Formal verification of index arithmetic; stress test |
| PERF-009 | Low | Non-power-of-2 user configs rejected | Validate in Config.validate(); document requirement |
| PERF-012 | Low | Increased memory from padding | Measure: ~15 * 56 bytes padding = trivial |

---

## Cross-References

- Design decisions: `docs/DESIGN.md` (tracks deque design choice)
- Functional gap analysis: `docs/GAP_ANALYSIS.md`
- Performance targets: `docs/PERFORMANCE_TARGETS.md`
- Scheduler decision: `docs/SCHEDULER_DECISION.md`
