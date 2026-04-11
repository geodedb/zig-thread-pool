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

## G-011: geode/quic-shaped scenarios [RESOLVED]

- **Issue:** [#11](https://gitlab.com/devnw/zig/thread-pool/-/work_items/11) (closed)
- **Category:** Feature
- **Resolution:** Scenario names and harness coverage implemented
- **Evidence:** `benchmarks/bench.zig`, `benchmarks/scale_bench.zig`
- **Resolved date:** 2026-04-11

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
