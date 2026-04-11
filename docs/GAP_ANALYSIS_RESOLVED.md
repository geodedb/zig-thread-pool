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
