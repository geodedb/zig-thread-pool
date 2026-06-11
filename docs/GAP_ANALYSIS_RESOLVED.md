# Gap Analysis -- Resolved

## G-001: Public API and lifecycle invariants [RESOLVED]

- **Issue:** [#1](https://gitlab.com/devnw/zig/thread-pool/-/work_items/1) (closed)
- **Category:** Feature
- **Resolution:** API documented and lifecycle tests implemented
- **Evidence:** `src/thread_pool/pool.zig`, `tests/unit.zig`
- **Resolved date:** 2026-04-11

## G-002: Scheduler baseline: global queue [RESOLVED]

- **Issue:** [#2](https://gitlab.com/devnw/zig/thread-pool/-/work_items/2) (closed)
- **Category:** Feature
- **Resolution:** Bounded global queue implementation with tests and benchmarks
- **Evidence:** `src/thread_pool/pool.zig`, `benchmarks/results/baseline.json`
- **Resolved date:** 2026-04-11

## G-003: Scheduler candidate: work stealing [RESOLVED]

- **Issue:** [#3](https://gitlab.com/devnw/zig/thread-pool/-/work_items/3) (closed)
- **Category:** Feature
- **Resolution:** Local deque + steal path implemented and benchmarked
- **Evidence:** `src/thread_pool/pool.zig`, `docs/SCHEDULER_DECISION.md`
- **Resolved date:** 2026-04-11

## G-004: Memory model and scratch purge [RESOLVED]

- **Issue:** [#4](https://gitlab.com/devnw/zig/thread-pool/-/work_items/4) (closed)
- **Category:** Feature
- **Resolution:** Bounded descriptors, scratch caps, purge path; fuzz stage limitations documented
- **Evidence:** `src/thread_pool/memory/scratch.zig`, `tests/unit.zig`; commit `chore: close GAP-004`
- **Resolved date:** 2026-04-11

## G-006: Descriptor slab/freelist [RESOLVED]

- **Issue:** [#6](https://gitlab.com/devnw/zig/thread-pool/-/work_items/6) (closed)
- **Category:** Feature
- **Resolution:** Safe reuse with bounded live count; generation ABA fix applied
- **Evidence:** `src/thread_pool/pool.zig`
- **Resolved date:** 2026-04-11

## G-007: Stats and observability schema [RESOLVED]

- **Issue:** [#7](https://gitlab.com/devnw/zig/thread-pool/-/work_items/7) (closed)
- **Category:** Feature
- **Resolution:** Snapshot and process memory metrics; per-worker histograms moved from global mutex
- **Evidence:** `src/thread_pool/stats/`, `benchmarks/common.zig`; commit `perf: close GAP-005`
- **Resolved date:** 2026-04-11

## G-009: Benchmark harness and regression gates [RESOLVED]

- **Issue:** [#9](https://gitlab.com/devnw/zig/thread-pool/-/work_items/9) (closed)
- **Category:** Feature
- **Resolution:** JSON bench + compare tool exist; allow_blocking_lane documented as advisory-only
- **Evidence:** `benchmarks/common.zig`, `benchmarks/compare.zig`; commit `docs: close GAP-009`
- **Resolved date:** 2026-04-11

## G-011: geode/quic-shaped scenarios [RE-OPENED 2026-04-16 -- previously mis-marked resolved]

- **Issue:** [#11](https://gitlab.com/devnw/zig/thread-pool/-/issues/11) (re-opened)
- **Status:** NotImplemented
- **Correction:** The 2026-04-11 closure was premature. A 2026-04-16 gap-audit scan of `benchmarks/` for `conn_churn_seq|conn_churn_parallel|short_long_mix|producer_contention|idle_burst_idle|nested_submit|blocking_lane_sim|oversubscription` returned zero matches. The benchmark set diverged to a Tokio-comparison suite and the geode/quic-shaped scenarios were never actually implemented under those names.
- **Action:** Entry retained here for historical accuracy; open tracking moved back to `docs/GAP_ANALYSIS.md` High severity table.
- **Re-opened date:** 2026-04-16

## G-012: GAP analysis and performance targets docs [RESOLVED]

- **Issue:** [#12](https://gitlab.com/devnw/zig/thread-pool/-/work_items/12) (closed)
- **Category:** Docs
- **Resolution:** Documentation exists and is kept current through audit cycles
- **Evidence:** `docs/GAP_ANALYSIS.md`, `docs/PERFORMANCE_TARGETS.md`; commit `docs: close GAP-010`
- **Resolved date:** 2026-04-11

## G-013: Default scheduler selection report [RESOLVED]

- **Issue:** [#13](https://gitlab.com/devnw/zig/thread-pool/-/work_items/13) (closed)
- **Category:** Docs
- **Resolution:** Decision recorded with measured evidence
- **Evidence:** `docs/SCHEDULER_DECISION.md`, `benchmarks/results/baseline.json`
- **Resolved date:** 2026-04-11

---

## Q-003: deinit() hangs forever on stuck task [RESOLVED]

- **Severity:** High
- **Category:** architecture
- **Resolution:** Added `Config.deinit_timeout_ns` (default 30s). `deinit()` now uses this timeout and force-joins worker threads when the deadline expires, emitting a warning diagnostic.
- **Evidence:** `src/thread_pool/types.zig` (deinit_timeout_ns field), `src/thread_pool/pool.zig` (deinit force-join logic)
- **Resolved date:** 2026-04-11

## Q-007: parseOutputArg returns dangling pointer [RESOLVED]

- **Severity:** Medium
- **Category:** architecture
- **Resolution:** Fixed by duping path before returning. Moved single implementation to `benchmarks/common.zig`, eliminating both the dangling pointer and the duplication (Q-010).
- **Evidence:** `benchmarks/common.zig` (parseOutputArg with allocator.dupe)
- **Resolved date:** 2026-04-11

## Q-008: updatePeak CAS function duplicated [RESOLVED]

- **Severity:** Medium
- **Category:** maintainability
- **Resolution:** Made `Accounting.updatePeak` public; `pool.zig` now aliases it instead of duplicating the implementation.
- **Evidence:** `src/thread_pool/stats/accounting.zig` (public updatePeak), `src/thread_pool/pool.zig` (alias)
- **Resolved date:** 2026-04-11

## Q-010: parseOutputArg duplicated [RESOLVED]

- **Severity:** Medium
- **Category:** maintainability
- **Resolution:** Moved single implementation to `benchmarks/common.zig`; `bench.zig` and `scale_bench.zig` now import it.
- **Evidence:** `benchmarks/common.zig` (parseOutputArg)
- **Resolved date:** 2026-04-11

## Q-011: Counter struct duplicated 3 times [WON'T DO]

- **Severity:** Medium
- **Category:** maintainability
- **Resolution:** Won't Do -- Duplication is by-design across independent build modules (tests, benchmarks, examples). Each is a separate Zig compilation unit with no shared import path. The Counter struct is trivial (< 10 lines) and the cost of introducing a cross-module dependency exceeds the maintenance risk.
- **Evidence:** `examples/basic.zig`, `tests/common.zig`, `benchmarks/common.zig`
- **Resolved date:** 2026-04-11

## Q-012: No doc comments on public API [RESOLVED]

- **Severity:** Medium
- **Category:** docs
- **Resolution:** Added `///` doc-comments to all ThreadPool public methods (init, deinit, submit, trySubmit, submitBatch, wait, waitGroup, shutdown, statsSnapshot, purgeWorkerCaches) and exported types.
- **Evidence:** `src/thread_pool/pool.zig`, `src/thread_pool/types.zig`
- **Resolved date:** 2026-04-11

## Q-013: DESIGN.md submitBatch signature stale [RESOLVED]

- **Severity:** Medium
- **Category:** docs
- **Resolution:** Updated `docs/DESIGN.md` to show `!SubmitBatchResult` matching the actual return type.
- **Evidence:** `docs/DESIGN.md`
- **Resolved date:** 2026-04-11

## Q-014: No TaskState lifecycle diagram [RESOLVED]

- **Severity:** Medium
- **Category:** docs
- **Resolution:** Added ASCII state-transition diagram as `///` doc-comment on the TaskState enum showing all valid transitions and their actors.
- **Evidence:** `src/thread_pool/types.zig` (TaskState enum doc-comment)
- **Resolved date:** 2026-04-11

## Q-015: Double-negation in cancellation check [RESOLVED]

- **Severity:** Medium
- **Category:** readability
- **Resolution:** Replaced double-negation with idiomatic `if (token) |t| t.isCancelled() else false` followed by `if (!cancelled)` pattern.
- **Evidence:** `src/thread_pool/pool.zig` (cancellation check in runTask)
- **Resolved date:** 2026-04-11

## Q-016: Core struct 35+ flat fields [RESOLVED]

- **Severity:** Medium
- **Category:** maintainability
- **Resolution:** Grouped fields into Sync (4 fields) and Counters (19 fields) sub-structs. Core now has 12 top-level fields, meeting the < 15 acceptance criteria.
- **Evidence:** `src/thread_pool/pool.zig` (Core struct)
- **Resolved date:** 2026-04-11

## Q-017: recordOwnedAlloc/Free verbose boilerplate [RESOLVED]

- **Severity:** Medium
- **Category:** maintainability
- **Resolution:** Stored a single `Accounting` field on Core, initialized once in `init()`. `recordOwnedAlloc` and `recordOwnedFree` now use `self.accounting` directly.
- **Evidence:** `src/thread_pool/pool.zig` (Core.accounting field, init)
- **Resolved date:** 2026-04-11

## Q-019: private_peak_bytes misuses VmHWM [RESOLVED]

- **Severity:** Low
- **Category:** perf
- **Resolution:** Changed `private_peak_bytes` to use `RssAnon` instead of `VmHWM`, providing actual private memory measurement.
- **Evidence:** `src/thread_pool/stats/process_memory.zig`
- **Resolved date:** 2026-04-11

## Q-022: Dead CI job prepare-zig [RESOLVED]

- **Severity:** Low
- **Category:** ci-cd
- **Resolution:** Removed the dead `prepare-zig` job from `.gitlab-ci.yml`.
- **Evidence:** `.gitlab-ci.yml`
- **Resolved date:** 2026-04-11

## Q-023: CI before_script duplicated 14 times [RESOLVED]

- **Severity:** Low
- **Category:** ci-cd
- **Resolution:** Extracted `.zig-job` template with common `before_script` and used `extends: .zig-job` in all concrete CI jobs.
- **Evidence:** `.gitlab-ci.yml` (.zig-job template, extends directives)
- **Resolved date:** 2026-04-11

## Q-024: Pre-commit zig-fmt excludes benchmarks/examples [RESOLVED]

- **Severity:** Low
- **Category:** ci-cd
- **Resolution:** Added `benchmarks/` and `examples/` to the pre-commit zig-fmt hook args list.
- **Evidence:** `.pre-commit-config.yaml` (zig-fmt args)
- **Resolved date:** 2026-04-11

---

## PERF-020: Non-atomic Worker stats [RESOLVED]

- **Severity:** P2
- **Category:** correctness / stats
- **Resolution:** Converted all Worker stat fields (busy_ns, idle_ns, tasks_completed, tasks_stolen, steal_failures, local_queue_peak) to `std.atomic.Value` with proper load/store/fetchAdd ordering.
- **Evidence:** `src/thread_pool/pool.zig` (Worker struct atomic fields)
- **Resolved date:** 2026-04-11

## PERF-021: Worker struct no hot/cold cache split [RESOLVED]

- **Severity:** P2
- **Category:** performance / cache layout
- **Resolution:** Split `local_queues` into separate dense array for cache-friendly steal scan. Hot worker data (queue pointers) separated from cold data (histograms, stats).
- **Evidence:** `src/thread_pool/pool.zig` (local_queues dense array, Worker struct split)
- **Resolved date:** 2026-04-11

---

## GAP-0011 / SEC-001: Stress test hangs due to worker idle/shutdown race condition [RESOLVED]

- **Issue:** -- (tracked in GAP_ANALYSIS.md only)
- **Category:** Bug
- **Severity:** Critical
- **Resolution:** idle() now checks pool state in spin loop and before park. Workers observe shutdown state transitions promptly.
- **Evidence:** `src/thread_pool/pool.zig` -- idle() includes state.load(.acquire) check in spin and sleep branches; stress tests pass reliably.
- **Resolved date:** 2026-04-11

## GAP-0012: CancellationToken has zero test coverage [RESOLVED]

- **Issue:** -- (tracked in GAP_ANALYSIS.md only)
- **Category:** Test
- **Severity:** Medium
- **Resolution:** Unit tests added exercising cancel-before-run and cancel-during-run paths.
- **Evidence:** `tests/unit.zig:111-138`
- **Resolved date:** 2026-04-11

## GAP-0013: trySubmit() has zero test coverage [RESOLVED]

- **Issue:** -- (tracked in GAP_ANALYSIS.md only)
- **Category:** Test
- **Severity:** Medium
- **Resolution:** Unit test added calling trySubmit on full and non-full queues with return value verification.
- **Evidence:** `tests/unit.zig:140-172`
- **Resolved date:** 2026-04-11

## GAP-0015: Shutdown timeout parameter has zero test coverage [RESOLVED]

- **Issue:** -- (tracked in GAP_ANALYSIS.md only)
- **Category:** Test
- **Severity:** Medium
- **Resolution:** Unit test added exercising shutdown with non-null timeout and verifying timely termination.
- **Evidence:** `tests/unit.zig:204-225`
- **Resolved date:** 2026-04-11

## GAP-0016 / SEC-006: queue_capacity not bounded to u32 range in validate() [RESOLVED]

- **Issue:** -- (tracked in GAP_ANALYSIS.md only)
- **Category:** Security
- **Severity:** Medium
- **Resolution:** validate() now rejects queue_capacity values exceeding maxInt(u32).
- **Evidence:** `src/thread_pool/types.zig:95`
- **Resolved date:** 2026-04-11

## GAP-0018: Dead Config fields: idle_shrink_after_ns, stats_enabled, allocator_mode [RESOLVED]

- **Issue:** -- (tracked in GAP_ANALYSIS.md only)
- **Category:** Code Quality
- **Severity:** Low
- **Resolution:** Dead fields removed from Config struct in types.zig.
- **Evidence:** `src/thread_pool/types.zig` -- fields no longer present
- **Resolved date:** 2026-04-11

## GAP-0019: Dead observability field: Stats.retired_workers always 0 [RESOLVED]

- **Issue:** -- (tracked in GAP_ANALYSIS.md only)
- **Category:** Code Quality
- **Severity:** Low
- **Resolution:** retired_workers field removed from Stats struct.
- **Evidence:** `src/thread_pool/types.zig` -- field no longer present
- **Resolved date:** 2026-04-11

## GAP-0020: TaskLane.keyed is defined but never used [RESOLVED]

- **Issue:** -- (tracked in GAP_ANALYSIS.md only)
- **Category:** Code Quality
- **Severity:** Low
- **Resolution:** .keyed variant removed from TaskLane enum.
- **Evidence:** `src/thread_pool/types.zig` -- variant no longer present
- **Resolved date:** 2026-04-11

## GAP-0021 / SEC-013: Benchmark nowNs() missing negative-timestamp guard [RESOLVED]

- **Issue:** -- (tracked in GAP_ANALYSIS.md only)
- **Category:** Security
- **Severity:** Low
- **Resolution:** nowNs() guard added matching the safe cast pattern from pool.zig.
- **Evidence:** `benchmarks/common.zig:459-462`
- **Resolved date:** 2026-04-11

---

## SEC-002: descriptor.state written non-atomically across threads [RESOLVED]

- **Severity:** High
- **Category:** concurrency / thread safety
- **Resolution:** descriptor.state now uses atomic operations with appropriate ordering.
- **Evidence:** `src/thread_pool/pool.zig` -- descriptor.state wrapped in std.atomic.Value
- **Resolved date:** 2026-04-11

## SEC-009: Non-atomic worker stats read cross-thread [RESOLVED]

- **Severity:** Medium
- **Category:** concurrency / thread safety
- **Resolution:** Worker stat fields converted to atomic operations.
- **Evidence:** `src/thread_pool/pool.zig` -- Worker struct uses atomic fields for all cross-thread stats
- **Resolved date:** 2026-04-11

## SEC-010: incrementQueued uses .monotonic ordering [RESOLVED]

- **Severity:** Medium
- **Category:** concurrency / thread safety
- **Resolution:** incrementQueued store ordering upgraded to `.release` to pair with idle `.acquire` load.
- **Evidence:** `src/thread_pool/pool.zig` -- incrementQueued uses .release ordering
- **Resolved date:** 2026-04-11

## SEC-012: .gitignore missing .env/*.pem/*.key patterns [RESOLVED]

- **Severity:** Low
- **Category:** operational hardening
- **Resolution:** .gitignore updated with secret file patterns.
- **Evidence:** `.gitignore` -- includes `.env`, `*.pem`, `*.key`, `*.p12`, `*.pfx` patterns
- **Resolved date:** 2026-04-11

## SEC-015: cancelQueuedTasks drains via popBottom on non-owning thread [RESOLVED]

- **Severity:** Low
- **Category:** concurrency / thread safety
- **Resolution:** Changed to use stealTop instead of popBottom, which is safe for cross-thread access.
- **Evidence:** `src/thread_pool/pool.zig` -- cancelQueuedTasks uses stealTop
- **Resolved date:** 2026-04-11

---

## SEC-017 / GAP-0035: local_queue_capacity=0 with global_queue causes OOB in release builds [RESOLVED]

- **Severity:** Critical
- **Category:** memory safety / config validation
- **Resolution:** `validate()` now rejects `local_queue_capacity=0` unconditionally for all scheduler variants, not just `work_stealing`. Test confirms error return.
- **Evidence:** `src/thread_pool/types.zig` -- unconditional `if (self.local_queue_capacity == 0) return error.InvalidLocalQueueCapacity;`; commit bace578
- **Resolved date:** 2026-04-11

## SEC-004 / GAP-0017: WaitGroup done() underflow wraps u32 counter silently [RESOLVED]

- **Severity:** High
- **Category:** integer safety
- **Resolution:** Replaced `debug.assert(previous > 0)` with `@panic` that fires in all build modes including ReleaseFast/ReleaseSmall. Underflow is now always detected.
- **Evidence:** `src/thread_pool/types.zig` -- `if (previous == 0) @panic("WaitGroup.done() underflow");`; commit 214ca3c
- **Resolved date:** 2026-04-11

## SEC-003 / PERF-011: LatencyHistogram non-atomic fields read cross-thread [RESOLVED]

- **Severity:** High (security) / P1 (perf)
- **Category:** concurrency / thread safety
- **Resolution:** All LatencyHistogram fields (counts, count, min_ns, max_ns, sum_ns) converted to `std.atomic.Value` with proper load/store ordering. Cross-thread reads in `statsSnapshot()` are now race-free.
- **Evidence:** `src/thread_pool/stats/latency.zig` -- all fields use `std.atomic.Value(u64)`; commit de49d69
- **Resolved date:** 2026-04-11

## SEC-005: UAF via shutdown-timeout-then-deinit [RESOLVED]

- **Severity:** Critical
- **Category:** concurrency / use-after-free
- **Resolution:** `deinit()` now always joins all worker threads before freeing memory, even if a prior `shutdown()` call timed out. The join loop is unconditional regardless of shutdown state.
- **Evidence:** `src/thread_pool/pool.zig` -- deinit thread join logic; commit de49d69
- **Resolved date:** 2026-04-11

## PERF-022 / GAP-0025: BoundedRing head/tail false sharing [RESOLVED]

- **Severity:** P1 (perf) / Medium (gap)
- **Category:** performance / cache layout
- **Resolution:** Added 56-byte padding between `head` and `tail` atomics in `BoundedRing`, placing them on separate cache lines. Eliminates Vyukov false-sharing anti-pattern.
- **Evidence:** `src/thread_pool/queue/bounded_ring.zig` -- `_padding` field between head and tail; commit ca1b0a4
- **Resolved date:** 2026-04-11

## PERF-002: Unconditional completion_mutex broadcast in cancelDescriptor [RESOLVED]

- **Severity:** P0
- **Category:** performance / contention
- **Resolution:** `cancelDescriptor` now checks `if (descriptor.options.waitable)` before locking `completion_mutex` and broadcasting, matching the existing guard in `runTask`. Non-waitable cancel paths skip the mutex entirely.
- **Evidence:** `src/thread_pool/pool.zig` -- cancelDescriptor waitable guard; commit 3299728
- **Resolved date:** 2026-04-11

## Q-022 / GAP-0033: Stats.wakeups permanently zero [RESOLVED]

- **Severity:** High (quality) / Low (gap)
- **Category:** api-contract / observability
- **Resolution:** `statsSnapshot()` now aggregates wakeups from per-worker counters by summing `worker.wakeups.load(.acquire)` across all workers, replacing the dead global counter read.
- **Evidence:** `src/thread_pool/pool.zig` -- statsSnapshot wakeups aggregation; commit da32fee
- **Resolved date:** 2026-04-11

## PERF-023: Counters struct false sharing [RESOLVED]

- **Severity:** P1
- **Category:** performance / cache layout
- **Resolution:** Added cache-line padding between hot counter groups (queued_tasks, active_tasks, submitted, completed) and cold counter groups (steal_failures, peak counters) in the Counters struct.
- **Evidence:** `src/thread_pool/pool.zig` -- Counters struct padding; commit 37fbd6a
- **Resolved date:** 2026-04-11

## GAP-0024: Zero fuzz targets [RESOLVED]

- **Severity:** High
- **Category:** test coverage
- **Resolution:** Added fuzz targets for BoundedRing push/pop sequences and Config validation with arbitrary inputs. Fixed CI fuzz-regression job by removing `|| true` so crashes are surfaced.
- **Evidence:** `tests/fuzz.zig` (fuzz targets), `.gitlab-ci.yml` (fuzz-regression job fix); commits 2dcb123, 6afd41d
- **Resolved date:** 2026-04-11

---

## 2026-04-16 Gap-Sync Closures

Canonical gap set `.cache/audit/gap-detected.json` resolved 39 Implemented / "close" items
during the 2026-04-16 gap-sync run. Entries already covered above are not repeated;
entries closed in this pass are below.

### G-001: Public API and lifecycle invariants [RESOLVED]

- **Issue:** [#1](https://gitlab.com/devnw/zig/thread-pool/-/issues/1) (closed)
- **Category:** Feature / API
- **Resolution:** Public API stable; lifecycle invariants covered by tests.
- **Evidence:** `src/pool.zig:1986-2068`, `tests/unit.zig`, `tests/integration.zig`
- **Resolved date:** 2026-04-16

### G-002: Scheduler baseline with global bounded queue [RESOLVED]

- **Issue:** [#2](https://gitlab.com/devnw/zig/thread-pool/-/issues/2) (closed)
- **Resolution:** `global_queue` variant shipped.
- **Evidence:** `src/types.zig:4`, `src/pool.zig:365`, `benchmarks/bench.zig`
- **Resolved date:** 2026-04-16

### G-003: Local queues and work stealing [RESOLVED]

- **Issue:** [#3](https://gitlab.com/devnw/zig/thread-pool/-/issues/3) (closed)
- **Resolution:** Chase-Lev deque + Vyukov BoundedRing shipped; `work_stealing` variant validated via stress tests.
- **Evidence:** `src/queue/work_deque.zig`, `src/queue/ring_queue.zig`, `src/types.zig:60`, `tests/stress/double_dequeue_race.zig`
- **Resolved date:** 2026-04-16

### G-004: Bounded memory model, allocator policy, scratch purge [RESOLVED]

- **Issue:** [#4](https://gitlab.com/devnw/zig/thread-pool/-/issues/4) (closed)
- **Resolution:** Scratch allocator + purge + bounded descriptor/queue caps.
- **Evidence:** `src/memory/scratch.zig`, `src/pool.zig:949`, `src/types.zig:103`
- **Resolved date:** 2026-04-16

### G-005: Worker park/unpark, idle purge, shrink [RESOLVED]

- **Issue:** [#5](https://gitlab.com/devnw/zig/thread-pool/-/issues/5) (closed)
- **Resolution:** Condvar park/unpark + time-based purge configurable via `idle_purge_after_ns`.
- **Evidence:** `src/pool.zig:1673`, `src/types.zig:104-105`
- **Resolved date:** 2026-04-16

### G-006: Bounded task descriptor slab and freelist [RESOLVED]

- **Issue:** [#6](https://gitlab.com/devnw/zig/thread-pool/-/issues/6) (closed)
- **Resolution:** Slab + freelist + generation ABA protection.
- **Evidence:** `src/pool.zig:1815-1841`
- **Resolved date:** 2026-04-16

### G-008: Unit / integration / stress / fuzz test plan [RESOLVED]

- **Issue:** [#8](https://gitlab.com/devnw/zig/thread-pool/-/issues/8) (closed)
- **Resolution:** Full test matrix in place; docs/TESTING.md canonical reference.
- **Evidence:** `tests/unit.zig`, `tests/integration.zig`, `tests/stress.zig`, `tests/fuzz/pool_fuzz.zig`, `docs/TESTING.md`
- **Resolved date:** 2026-04-16

### G-009: Benchmark harness, result schema, regression gates [RESOLVED]

- **Issue:** [#9](https://gitlab.com/devnw/zig/thread-pool/-/issues/9) (closed)
- **Resolution:** Bench harness, JSON schema, compare tool, scale-bench step all present.
- **Evidence:** `benchmarks/bench.zig`, `benchmarks/compare.zig`, `benchmarks/scale_bench.zig`, `build.zig`
- **Resolved date:** 2026-04-16

### G-012: Maintain GAP analysis and performance-target documents [RESOLVED]

- **Issue:** [#12](https://gitlab.com/devnw/zig/thread-pool/-/issues/12) (closed)
- **Resolution:** Docs updated each audit cycle (this run included).
- **Evidence:** `docs/GAP_ANALYSIS.md`, `docs/GAP_ANALYSIS_RESOLVED.md`, `docs/PERFORMANCE_TARGETS.md`, `docs/SCHEDULER_DECISION.md`
- **Resolved date:** 2026-04-16

### G-013: Default scheduler chosen by measured evidence [RESOLVED]

- **Issue:** [#13](https://gitlab.com/devnw/zig/thread-pool/-/issues/13) (closed)
- **Resolution:** Default `.ring` scheduler selected; decision recorded.
- **Evidence:** `docs/SCHEDULER_DECISION.md`, `src/types.zig:115`
- **Resolved date:** 2026-04-16

### GAP-0014: Backpressure .block policy test coverage [RESOLVED]

- **Category:** Test
- **Severity:** Low (re-scored from Medium in audit)
- **Resolution:** Unit + integration + stress tests all cover `.block` backpressure after commit a572f2c.
- **Evidence:** `tests/unit.zig:614,753,768,830,843,866,980`, `tests/integration.zig:245`, `tests/stress.zig:541`, `tests/stress/double_dequeue_race.zig:52`
- **Resolved date:** 2026-04-16

### GAP-0026: submitBatch wake coalescing [RESOLVED]

- **Category:** Performance
- **Severity:** Low
- **Resolution:** `wake_coalesce_batch=32` wired in `enqueueTask`; one coalesced wake per batch.
- **Evidence:** `src/types.zig:82`, `src/pool.zig:988-998`; project memory `project_wake_coalesce_landed`
- **Resolved date:** 2026-04-16

### GAP-0028: docs/README.md links [RESOLVED]

- **Category:** Docs
- **Severity:** Low
- **Resolution:** `docs/` now contains the referenced `getting-started.md`, `api-reference.md`, `examples.md`, `architecture.md`, `faq.md`.
- **Evidence:** `docs/` tree.
- **Resolved date:** 2026-04-16

### GAP-0032: deinitOwned inject_queue accounting [RESOLVED]

- **Category:** Bug
- **Severity:** Low
- **Resolution:** Symmetric `recordOwnedAlloc` / `recordOwnedFree` in `BoundedRing.deinit`. Absorbs Q-023.
- **Evidence:** `src/pool.zig:1912,1914`
- **Resolved date:** 2026-04-16

### Q-006: `lane_extension` variant accepted by `validate()` [RESOLVED]

- **Category:** Conflict
- **Severity:** Low
- **Resolution:** Prior doc comment claimed `lane_extension` was rejected. Code path at `src/types.zig:243` accepts the variant when `blocking_workers > 0`; `tests/integration.zig:176` exercises it.
- **Evidence:** `src/types.zig:243`, `tests/integration.zig:176`
- **Resolved date:** 2026-04-16

### Q-018: `compare.zig` ArenaAllocator lifecycle [RESOLVED]

- **Resolution:** `benchmarks/compare.zig` now calls `arena.deinit()` on all paths.
- **Evidence:** `benchmarks/compare.zig`
- **Resolved date:** 2026-04-16

### SEC-019: `max_threads` upper bound validation [RESOLVED]

- **Category:** Security / hardening
- **Resolution:** `validate()` rejects `max_threads > 64` via `error.TooManyWorkers`.
- **Evidence:** `src/types.zig:236,263`
- **Resolved date:** 2026-04-16

### PERF-024: submitBatch per-task signaling [RESOLVED]

- **Resolution:** `submitBatch` now coalesces wakeups (see GAP-0026).
- **Evidence:** `src/pool.zig:594,1003-1006`
- **Resolved date:** 2026-04-16

### PERF-026: Single-item steal in work_stealing [RESOLVED]

- **Resolution:** `steal_batch_size=8` via `stealHalf` implementation.
- **Evidence:** `src/types.zig:188-193`, `src/queue/ring_queue.zig`
- **Resolved date:** 2026-04-16

### DESIGN-01: Local deque mutex vs Chase-Lev [RESOLVED]

- **Resolution:** Chase-Lev retained (`.chase_lev`); default `.ring` (lock-free Vyukov).
- **Evidence:** `src/types.zig:60,115`
- **Resolved date:** 2026-04-16

### DESIGN-03: Track alloc event counts alongside bytes [RESOLVED]

- **Resolution:** `Stats.total_alloc_count` wired. Histogram follow-up tracked as RISK-06.
- **Evidence:** `src/types.zig:394`
- **Resolved date:** 2026-04-16

### DESIGN-04: Dedicated blocking-lane worker subset [RESOLVED]

- **Resolution:** Slices L1-L4b shipped (static lane routing, per-lane backpressure, rebalancing, watchdog, overflow spawn). Retroactive tracking issue GAP-9001 created.
- **Evidence:** project memory `project_slice_l1_landed..project_slice_l4b_landed`, `tests/integration.zig` lane coverage
- **Resolved date:** 2026-04-16

### FR-001..FR-006, NFR-001, NFR-004, NFR-005 [RESOLVED]

- **Resolution:** Functional + non-functional acceptance criteria all met (bounded submission, waitable handles, exactly-once, shutdown semantics, purge API, JSON bench output; worker cap; low-contention scheduler option; reproducible runtime-comparison workflow).
- **Evidence:** see gap-detected.json entries FR-001..FR-006, NFR-001, NFR-004, NFR-005 for file:line pointers.
- **Resolved date:** 2026-04-16

### NFR-002 / CICD-01 / CICD-02 -> absorbed by G-010

- **Resolution:** Canonicalised into the G-010 umbrella issue ([#10](https://gitlab.com/devnw/zig/thread-pool/-/issues/10)); tracked there instead of as separate issues.

### LANE-L4c -> absorbed by GAP-9001

- **Resolution:** Memory-only tracking gap for lane extension; absorbed by GAP-9001 ([#87](https://gitlab.com/devnw/zig/thread-pool/-/issues/87)).

### APPSEC-F008: `-Dsingle-pool` opt-in documented as UNSAFE with >1 pool [ACCEPTED]

- **Category:** Informational
- **Resolution:** Documented opt-in tradeoff, not a gap. Hot-path identity check elided at build.zig:36-43 with explicit safety caveat in `CLAUDE.md` and `docs/performance/appsec-fixes-2026-04-15/FINAL.md`.
- **Evidence:** `build.zig:36-43`, `src/pool.zig:17,1297,1312`
- **Resolved date:** 2026-04-16 (accepted, not fixed)

### RISK-04: Adaptive sizing [ACCEPTED]

- **Category:** Informational
- **Resolution:** Phase-2 non-goal, documented in DESIGN.md. No code path.
- **Resolved date:** 2026-04-16 (accepted)

---

## 2026-04-16 Gap-Closure Sweep (7-gap batch)

Six gaps fully closed; one (COMPTIME-ELISION) partially closed and left open with
reduced scope on GitLab. See `docs/gap-closure-report-2026-04-16.md` for the full
report (tests, A/B data, platform-issue audit).

### SEC-018 (F-008 confidential): TaskHandle double-wait races descriptor reuse [RESOLVED]

- **Issue:** [#23](https://gitlab.com/devnw/zig/thread-pool/-/issues/23) (closed)
- **Category:** Security / CWE-416 + CWE-362
- **Severity:** Medium (upgraded from Low during adversarial review)
- **Resolution:** `TaskHandle.wait()` guards the release path with a CAS, so only
  the first waiter to observe terminal state calls `releaseDescriptor`. The
  implementer chose `cmpxchgWeak .acq_rel/.acquire` rather than the originally
  proposed `cmpxchgStrong .acq_rel/.monotonic`; both are correct — weak+acq_rel
  is fine here because the loop structure already tolerates spurious failure and
  acq_rel strengthens the success ordering to publish observation of terminal
  state. Tests cover the race with concurrent waiters.
- **Evidence:** commit `57f77f7`; `src/pool.zig` (CAS-guard in `Core.wait()`);
  stress test + TSan soak clean.
- **Resolved date:** 2026-04-16
- **Distinguishes from:** Public-label SEC-018 tracked at [#30](https://gitlab.com/devnw/zig/thread-pool/-/issues/30) (`queue_capacity` non-pow2 on 32-bit) which remains Partial.

### REV-001: Task panic leaves active_tasks/claim-sentinel/wait_group skewed [RESOLVED]

- **Issue:** [#35](https://gitlab.com/devnw/zig/thread-pool/-/issues/35) (closed)
- **Category:** Security / caller-contract
- **Severity:** Medium
- **Resolution:** Documented panic contract + ADR in `docs/security/REV-001.md`;
  added skew observability so a host with a custom panic handler can detect
  the skewed counters. Default Zig panic still aborts (acceptable).
- **Evidence:** commit `5faccb5`; ADR `docs/security/REV-001.md`; updated
  `src/pool.zig` with observability hooks.
- **Resolved date:** 2026-04-16

### QS-008: Document 24 undocumented public symbols in `src/types.zig` [RESOLVED]

- **Issue:** [#18](https://gitlab.com/devnw/zig/thread-pool/-/issues/18) (closed)
- **Category:** Quality / docs
- **Severity:** High (PriorityScore 60)
- **Resolution:** Added `///` doc comments to the 24 public symbols (enums,
  structs, methods, Stats fields). Final coverage: `grep -c '^///' src/types.zig` = **159**.
- **Evidence:** commit `429caab`; `src/types.zig`.
- **Resolved date:** 2026-04-16

### QS-002: Decompose 147-line `Core.init` with nested errdefers [RESOLVED]

- **Issue:** [#15](https://gitlab.com/devnw/zig/thread-pool/-/issues/15) (closed)
- **Category:** Quality / readability
- **Severity:** High (PriorityScore 60)
- **Resolution:** Extracted `allocateStorage`, `initDescriptorFreelist`,
  `initWorkers`, `spawnWorkers` helpers; `Core.init` reduced from **147 → 60**
  lines. F-002 errdefer chain preserved byte-for-byte — verified by stepping
  through each early-return path and confirming the cleanup order is unchanged.
- **Evidence:** commit `301392b`; `src/pool.zig`.
- **Resolved date:** 2026-04-16

### QS-003: Decompose 130-line hot-path `Core.runTask` [RESOLVED]

- **Issue:** [#16](https://gitlab.com/devnw/zig/thread-pool/-/issues/16) (closed)
- **Category:** Quality / readability + perf
- **Severity:** High (PriorityScore 64)
- **Resolution:** Extracted `recordTaskStart`, `invokeTask`, `finalizeTask`
  inline helpers. Atomic ordering preserved. Paired n=20 A/B measured on
  covered scenarios: **+16.3% conn_churn_seq, +11.7% producer_contention**
  (both stddev-disjoint; no regression elsewhere).
- **Evidence:** commit `a0259e6`; `src/pool.zig`; A/B artifact
  `benchmarks/results/qs003-before.json` (not committed).
- **Resolved date:** 2026-04-16

### OBSERVABILITY-PIVOT: R-01/R-02/R-03/R-06/R-10 observability pivot cluster [RESOLVED]

- **Issue:** [#46](https://gitlab.com/devnw/zig/thread-pool/-/issues/46) (closed)
- **Category:** Perf / observability tracker
- **Severity:** P1 (PerfScore 80)
- **Resolution:** All five sub-items landed across six commits:
  - **R-01** p999 / p9999 from log2 buckets — `3356d1d`
  - **R-02** per-lane wait/exec histograms — `a39092a`
  - **R-03** wake-latency histogram at `cond.wait` return — `7c9d2e6`
  - **R-06** layout heatmap + comptime `@offsetOf` asserts — `5561a46`
  - **R-10** `max_pool_memory_bytes` + `memory_budget_used_bytes` — `e75f4e0`
  - `PERF_GAP_ANALYSIS.md` tracker marked Closed — `f1e7b67`
- **Evidence:** six commits above; `src/stats/latency.zig`, `src/pool.zig`,
  `src/types.zig`.
- **Resolved date:** 2026-04-16

---

### COMPTIME-ELISION (PERF-P-09): Partial closure, issue remains OPEN

- **Issue:** [#73](https://gitlab.com/devnw/zig/thread-pool/-/issues/73) (**open, scope reduced**)
- **Status:** Partial
- **What landed (commit `c9a05e8`):** `-Dtimestamp-mode` and
  `-Dscheduler-variant` build flags with comptime shadowing of the runtime
  `Config` field reads.
- **What deferred:** `-Dqueue-kind` and `-Dlane-extension` — tracked on the
  same GitLab issue with a 2026-04-16 scope-reduce comment.
- **Not in `GAP_ANALYSIS_RESOLVED.md` top-level list** because the issue is
  not closed. Listed here as a breadcrumb only.

## 2026-06-11 Gap-Sync Closures

### PERF-029: Shutdown drain residual poll [RESOLVED]

- **Issue:** [#51](https://gitlab.com/devnw/zig/thread-pool/-/issues/51) (closed)
- **Category:** Performance
- **Severity:** Low
- **Resolution:** The shutdown drain is now condvar-driven rather than a
  fixed-interval busy poll. The drain loop blocks on the default-lane
  backpressure condvar (signalled by `releaseDescriptor` on every task
  completion) and only re-checks state on a 10 ms lost-wakeup safety cap;
  waitable-task completion broadcasts the completion condvar.
- **Evidence:**
  - `src/pool.zig:1033-1045` — `shutdown` drain loop breaks on
    `queued == 0 and active == 0`, otherwise calls
    `waitForCapacity(deadline, .default)` (condvar) instead of `Thread.sleep`;
    comment documents the per-completion signal + 10 ms safety re-check.
  - `src/pool.zig:980-1010` — completion `wait()` uses
    `completion_mutex` + `completion_cond.wait`.
  - `src/pool.zig:2137`, `src/pool.zig:2297` — `finalizeTask` broadcasts
    `completion_cond` on every waitable completion.
- **Resolved date:** 2026-06-11

### Q-004 / GAP-0014: Backpressure `.block` policy test coverage [RESOLVED — duplicate]

- **Issue:** none (Q-004 is a `QUALITY_GAP_ANALYSIS.md` tracker entry; no
  GitLab issue was ever opened).
- **Category:** Test
- **Severity:** Low (Medium in the quality tracker)
- **Resolution:** Confirmed duplicate of the already-resolved **GAP-0014**
  (Backpressure `.block` policy test coverage, resolved 2026-04-16). A
  dedicated unit test exists at `tests/unit.zig:980`
  (`test "backpressure block policy returns when capacity frees"`) plus
  further `.block` coverage across unit/integration/stress suites.
- **Evidence:** `tests/unit.zig:980` (dedicated test) and the GAP-0014
  evidence set (`tests/unit.zig:614,753,768,830,843,866,980`,
  `tests/integration.zig:245`, `tests/stress.zig:541`).
- **Note:** `QUALITY_GAP_ANALYSIS.md` is owned by the quality-tracker agent
  and is intentionally not edited here; recorded as resolved-by-duplicate for
  cross-reference only.
- **Resolved date:** 2026-06-11

---

## 2026-06-11 Remediation Pass

### GAP-0036 / AP-01: Clock underflow panic-DoS [RESOLVED]

- **Issue:** [#92](https://gitlab.com/devnw/zig/thread-pool/-/issues/92) (closed)
- **Category:** Security / correctness
- **Severity:** Medium
- **Resolution:** `src/clock.zig` switched to `.awake` (monotonic); `src/sync.zig` timedWait uses `.awake`; saturating subtraction (`-|`) applied at `pool.zig` recordTaskStart/finalizeTask; monotonicity regression test added.
- **Evidence:** commit `df3832a`; `src/clock.zig:16`; `src/sync.zig:51`; `pool.zig` recordTaskStart/finalizeTask
- **Resolved date:** 2026-06-11

### Q-NEW-02 + Q-025: submitBatch waitable leak + "atomically" doc [RESOLVED]

- **Issue:** [#107](https://gitlab.com/devnw/zig/thread-pool/-/issues/107) (closed); [#59](https://gitlab.com/devnw/zig/thread-pool/-/issues/59) (closed)
- **Category:** Quality / api-contract
- **Severity:** High (Q-NEW-02) + Medium (Q-025)
- **Resolution:** `submitBatch` now returns `error.WaitableUnsupported` when `options.waitable=true`; public wrapper doc no longer says "atomically".
- **Evidence:** commit `01d7f6a`; `src/pool.zig:836-888` (waitable guard); `src/pool.zig:2637` (wrapper doc)
- **Resolved date:** 2026-06-11

### PERF-NEW-03: releaseSubmitter unbounded spin + silent drop [RESOLVED]

- **Issue:** [#117](https://gitlab.com/devnw/zig/thread-pool/-/issues/117) (closed)
- **Category:** Performance / correctness
- **Severity:** P2
- **Resolution:** Escalating backoff (spin→yield→sleep); `cancelDescriptor` called on capacity hit — no silent task drop.
- **Evidence:** commit `29422be`; `src/pool.zig:962-968`
- **Resolved date:** 2026-06-11

### GAP-0037 / AP-02: Non-atomic descriptor.generation [RESOLVED]

- **Issue:** [#93](https://gitlab.com/devnw/zig/thread-pool/-/issues/93) (closed)
- **Category:** Security / concurrency
- **Severity:** Low
- **Resolution:** `descriptor.generation` promoted to `std.atomic.Value(u64)`; per-field reset avoids plain-store over atomics.
- **Evidence:** commits `e2e7210` + `fd2aca7`; `src/pool.zig:235`
- **Resolved date:** 2026-06-11

### GAP-0038 / AP-03: Cross-thread releaseSubmitter DescCache drain [RESOLVED]

- **Issue:** [#94](https://gitlab.com/devnw/zig/thread-pool/-/issues/94) (closed)
- **Category:** Security / concurrency
- **Severity:** Low
- **Resolution:** Owner-thread contract documented on 4 APIs; cross-thread best-effort drain fallback added; integration test covers the path.
- **Evidence:** commit `bf44fec`; `src/pool.zig:904-974`
- **Resolved date:** 2026-06-11

### GAP-0039 / AP-04: quantileScaled overflow [RESOLVED]

- **Issue:** [#95](https://gitlab.com/devnw/zig/thread-pool/-/issues/95) (closed)
- **Category:** Correctness
- **Severity:** Low (Informational in practice)
- **Resolution:** `quantileScaled` intermediate multiply widened to u128; boundary test added.
- **Evidence:** commit `7ab4358`; `src/stats/latency.zig:112`
- **Resolved date:** 2026-06-11

### GAP-0040 / AP-05: deinitOwned DescCache not drained [RESOLVED]

- **Issue:** [#96](https://gitlab.com/devnw/zig/thread-pool/-/issues/96) (closed)
- **Category:** Correctness
- **Severity:** Low (Informational in practice)
- **Resolution:** `drainSubmitterDescCaches` called in `deinitOwned`; `task_desc_live == 0` assertion now passes cleanly.
- **Evidence:** commit `7ab4358`; `src/pool.zig:2479-2486`
- **Resolved date:** 2026-06-11

### GAP-0041 / AP-06 + Q-020: Version drift + unreferenced constant [RESOLVED]

- **Issue:** [#97](https://gitlab.com/devnw/zig/thread-pool/-/issues/97) (closed); [#56](https://gitlab.com/devnw/zig/thread-pool/-/issues/56) (closed)
- **Category:** Quality
- **Severity:** Low
- **Resolution:** `root.zig` version constant updated to 0.2.4; pinning test references the constant; drift and unreferenced-constant findings both closed.
- **Evidence:** commit `7ab4358`; `src/root.zig:42`
- **Resolved date:** 2026-06-11

### Q-026: Core.waitGroup() ignores self [RESOLVED]

- **Issue:** [#60](https://gitlab.com/devnw/zig/thread-pool/-/issues/60) (closed)
- **Category:** Quality / correctness
- **Severity:** Low
- **Resolution:** `waitGroup` now asserts running state and uses `self` correctly.
- **Evidence:** commit `7ab4358`; `src/pool.zig:741`
- **Resolved date:** 2026-06-11

### Q-NEW-10: joinAllWorkers overflow accounting [RESOLVED]

- **Issue:** [#115](https://gitlab.com/devnw/zig/thread-pool/-/issues/115) (closed)
- **Category:** Quality / observability
- **Severity:** Low
- **Resolution:** Overflow counter update on shutdown join + integration test.
- **Evidence:** commit `7ab4358`; `src/pool.zig:1080-1085`
- **Resolved date:** 2026-06-11

### SEC-020: Unbounded CAS spin without spinLoopHint [RESOLVED]

- **Issue:** [#32](https://gitlab.com/devnw/zig/thread-pool/-/issues/32) (closed)
- **Category:** Security / CWE-400
- **Severity:** Low
- **Resolution:** `spinLoopHint` inserted in 6 CAS retry loops; failure-path-only placement avoids unnecessary hints on success.
- **Evidence:** commit `c2b1446`; `src/pool.zig:1816,1852` (and 4 other sites)
- **Resolved date:** 2026-06-11

### Q-027: Magic 0xFFFFFFFF raw literal [RESOLVED]

- **Issue:** [#62](https://gitlab.com/devnw/zig/thread-pool/-/issues/62) (closed)
- **Category:** Quality / readability
- **Severity:** Low
- **Resolution:** `free_sentinel` constant hoisted to Core scope and used everywhere including `initDescriptorFreelist`.
- **Evidence:** commit `c2b1446`; `src/pool.zig:699,2304`
- **Resolved date:** 2026-06-11

### GAP-0045 + GAP-0046 + GAP-0029 + SEC-002 + GAP-0034 + GAP-0030: Repo/SECURITY.md hygiene cluster [RESOLVED]

- **Issues:** [#100](https://gitlab.com/devnw/zig/thread-pool/-/issues/100), [#101](https://gitlab.com/devnw/zig/thread-pool/-/issues/101), [#37](https://gitlab.com/devnw/zig/thread-pool/-/issues/37), [#40](https://gitlab.com/devnw/zig/thread-pool/-/issues/40), [#39](https://gitlab.com/devnw/zig/thread-pool/-/issues/39), [#38](https://gitlab.com/devnw/zig/thread-pool/-/issues/38) (all closed)
- **Category:** Security / hygiene
- **Resolution:** SECURITY.md supported versions updated to 0.2.4; GitLab issue links corrected; "No Undefined Behavior" claim qualified; CODEOWNERS set to `@benjiv`; CHANGELOG placeholder date fixed.
- **Evidence:** commit `3af7bec`; `SECURITY.md`, `CODEOWNERS`, `CHANGELOG.md`
- **Resolved date:** 2026-06-11

### Q-NEW-03 + Q-NEW-04 + Q-NEW-05 + Q-NEW-06 + Q-NEW-07 + Q-NEW-09: DESIGN.md / types.zig doc-accuracy cluster [RESOLVED]

- **Issues:** [#108](https://gitlab.com/devnw/zig/thread-pool/-/issues/108)–[#112](https://gitlab.com/devnw/zig/thread-pool/-/issues/112), [#114](https://gitlab.com/devnw/zig/thread-pool/-/issues/114) (all closed)
- **Category:** Quality / docs
- **Resolution:** DESIGN.md phantom features (RuntimePreset, wake_strategy, idle_queue) removed; `steal_batch_size` corrected to 8; `completion_only` mode removed from docs; `queue_capacity` descriptor-bound doc corrected; `idle_park_after_ns` mechanism clarified; parks/wakeups counter semantics reworded.
- **Evidence:** commit `25665bb`; `docs/DESIGN.md`, `src/types.zig`
- **Resolved date:** 2026-06-11

### QR-005: SubmitOptions .block deadlock footgun undocumented [RESOLVED]

- **Issue:** [#49](https://gitlab.com/devnw/zig/thread-pool/-/issues/49) (closed)
- **Category:** Quality / docs
- **Severity:** Medium
- **Resolution:** `.block` deadlock warning cross-referenced from submit/submitBatch wrapper docs.
- **Evidence:** commit `25665bb`; `src/types.zig:268-275`
- **Resolved date:** 2026-06-11

### QR-003 + QR-004: Explicit error sets [RESOLVED]

- **Issues:** [#41](https://gitlab.com/devnw/zig/thread-pool/-/issues/41), [#43](https://gitlab.com/devnw/zig/thread-pool/-/issues/43) (closed)
- **Category:** Quality / api-contract
- **Severity:** Medium
- **Resolution:** `ConfigError` declared with 20 members; `SubmitError`, `SubmitBatchError`, `WaitError`, `ShutdownError`, `RegisterSubmitterError` declared on Core + ThreadPool; `root.zig` re-exports all; 4 else-less switch tests added.
- **Evidence:** commit `e554f2b`; `src/types.zig`, `src/pool.zig`, `src/root.zig`
- **Resolved date:** 2026-06-11

### Q-NEW-08: Watchdog non-interruptible sleep [RESOLVED]

- **Issue:** [#113](https://gitlab.com/devnw/zig/thread-pool/-/issues/113) (closed)
- **Category:** Quality / reliability
- **Severity:** Medium
- **Resolution:** Watchdog uses condvar `timedWait`; broadcast at both stop sites; <2s deinit test passes.
- **Evidence:** commit `e549ec7`; `src/pool.zig:1543-1545`
- **Resolved date:** 2026-06-11

### QR-009 + QS-009 + GAP-0044: Module headers and Core method docs [RESOLVED]

- **Issues:** [#34](https://gitlab.com/devnw/zig/thread-pool/-/issues/34), [#28](https://gitlab.com/devnw/zig/thread-pool/-/issues/28) (closed)
- **Category:** Quality / docs
- **Severity:** Medium
- **Resolution:** `//!` module-level headers added to 9 source files; `///` doc comments added to 8 Core methods and sync/clock functions.
- **Evidence:** commit `0291001`; `src/pool.zig`, `src/sync.zig`, `src/clock.zig` (and 6 other files)
- **Resolved date:** 2026-06-11

### PERF-NEW-02 + PERF-NEW-09 + PERF-NEW-04 + NEW-003: Counter ordering + elision + gitSha + test sleeps [RESOLVED]

- **Issues:** [#99](https://gitlab.com/devnw/zig/thread-pool/-/issues/99), [#124](https://gitlab.com/devnw/zig/thread-pool/-/issues/124), [#119](https://gitlab.com/devnw/zig/thread-pool/-/issues/119), [#120](https://gitlab.com/devnw/zig/thread-pool/-/issues/120) (all closed)
- **Category:** Performance / quality
- **Resolution:** 8 single-writer observability counter sites changed `.release`→`.monotonic` (ARM64 fence savings); `finalizeTask` idle-purge timestamp guarded by comptime-foldable check; `gitSha()` hoisted to main reducing ~168 git subprocess forks per run to 1; unit test `sleep_ns` reduced from 2s to 500/300ms.
- **Evidence:** commit `791604c`; `src/pool.zig` (8 counter sites, finalizeTask guard); `benchmarks/common.zig:262`
- **Resolved date:** 2026-06-11

### GAP-0054: Makefile/script zig-0.15.2 fallback [RESOLVED]

- **Issue:** [#103](https://gitlab.com/devnw/zig/thread-pool/-/issues/103) (closed)
- **Category:** Infra
- **Severity:** Medium
- **Resolution:** `Makefile` uses `ZIG?=zig`; `scripts/run-runtime-comparison.sh` fallback to gitignored `./zig-0.15.2/zig` removed.
- **Evidence:** commit `9c94036`; `Makefile:4`; `scripts/run-runtime-comparison.sh`
- **Resolved date:** 2026-06-11

### GAP-0042: ubuntu:24.04 floating image tag [RESOLVED]

- **Issue:** [#98](https://gitlab.com/devnw/zig/thread-pool/-/issues/98) (closed)
- **Category:** Security / infra / CWE-829
- **Severity:** Low
- **Resolution:** `ubuntu:24.04` pinned to `@sha256:786a8b...` in `.gitlab-ci.yml`; refresh procedure documented in comments.
- **Evidence:** commit `9c94036`; `.gitlab-ci.yml:238`
- **Resolved date:** 2026-06-11

### GAP-0047: third_party/go submodule tracks master [RESOLVED]

- **Issue:** [#102](https://gitlab.com/devnw/zig/thread-pool/-/issues/102) (closed)
- **Category:** Security / infra
- **Severity:** Low
- **Resolution:** Deliberate no-re-pin to preserve baselines; re-pin instruction documented in `docs/RUNTIME_COMPARISON.md` Vendored Runtime Pins note.
- **Evidence:** commit `9c94036`; `docs/RUNTIME_COMPARISON.md`
- **Resolved date:** 2026-06-11

### GAP-0057: detect_diamond_deps.py hash regex + injection [RESOLVED]

- **Issue:** [#106](https://gitlab.com/devnw/zig/thread-pool/-/issues/106) (closed)
- **Category:** Security / dev-tool
- **Severity:** Low
- **Resolution:** `HASH_RE` tightened; traversal guard added; ANSI/non-printable sanitization applied to stderr output.
- **Evidence:** commits `9c94036` + `34fe026`; `scripts/detect_diamond_deps.py:91,174-177,256-257`
- **Resolved date:** 2026-06-11

### QR-002: -Dsingle-pool CI gate [RESOLVED]

- **Issue:** [#24](https://gitlab.com/devnw/zig/thread-pool/-/issues/24) (closed)
- **Category:** Quality / ci-cd
- **Severity:** High
- **Resolution:** `zig-test-unit-single-pool-0.16.0` CI job added; local run green.
- **Evidence:** commit `9c94036`; `.gitlab-ci.yml`
- **Resolved date:** 2026-06-11

### GAP-0056: No test for global_queue + registerSubmitter + drain foot-gun [RESOLVED]

- **Issue:** [#105](https://gitlab.com/devnw/zig/thread-pool/-/issues/105) (closed)
- **Category:** Quality / tests
- **Severity:** Low (Informational)
- **Resolution:** 2 integration tests added; drain-hang foot-gun confirmed FIXED by pre-existing commit `141d979` (noted in close comment).
- **Evidence:** commit `61f88d2`; `tests/integration.zig`
- **Resolved date:** 2026-06-11

### GAP-0055: Fuzz harness only fuzzes work_stealing [RESOLVED]

- **Issue:** [#104](https://gitlab.com/devnw/zig/thread-pool/-/issues/104) (closed)
- **Category:** Security / tests
- **Severity:** Low
- **Resolution:** 3-variant rotation via `seed%3` + `FUZZ_SCHEDULER` environment override; WaitGroup operation added to fuzz corpus; fuzz harness header updated.
- **Evidence:** commit `61f88d2`; `tests/fuzz/pool_fuzz.zig:21-30`
- **Resolved date:** 2026-06-11
