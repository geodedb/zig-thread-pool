# GAP Analysis

## Summary

This repository provides a bounded, reusable, observable thread-pool for `devnw/zig`. The implementation establishes fixed-size workers, bounded descriptors, bounded queues, two scheduler variants, cross-platform memory sampling hooks, and JSON benchmark output. Several requirements remain open and are tracked explicitly through GitLab work items.

## Scope

- standalone thread-pool library
- bounded task descriptors and queues
- global-queue and work-stealing scheduler variants
- unit, integration, stress, and benchmark harnesses
- cross-platform build and process-memory collection hooks

## Non-scope

- geode- or quic-specific application logic
- unbounded adaptive worker growth
- lock-free queue research prototypes
- production lane-aware scheduler specialization beyond the current API placeholder

## Functional Requirements

- bounded submission and explicit backpressure
- waitable handles and wait groups
- exactly-once execution for accepted tasks
- deterministic shutdown and reject-after-shutdown behavior
- explicit worker cache purge support
- benchmark output as machine-readable JSON

## Non-functional Requirements

- fixed worker cap
- cross-platform compile support
- measurable allocator and RSS behavior
- low-contention scheduler option
- reproducible benchmark comparison workflow

## Initial Risk Register

| Risk | Severity | Status | Notes |
| --- | --- | --- | --- |
| Bounded memory policy not yet proven under larger runs | High | Open | Needs longer churn and oversubscription evidence |
| Default scheduler evidence is still from CI-safe scenarios only | High | Open | Larger manual suite still needed |
| Worker-local cache purge policy is functional but not yet aggressively tuned | Medium | Open | Current purge is time-based and explicit |
| Adaptive sizing is not implemented | Medium | Accepted | Phase 2 work item |
| macOS and Windows memory metrics are compile-covered but not runner-validated | High | Open | Native smoke runners still pending |
| Alloc event counts are not yet distinct from byte accounting | Medium | Open | JSON emits byte metrics now |

## geode/quic Context

- geode has a known RSS regression under repeated QUIC connection churn.
- Recent analysis suggested a plateau around `~1158 MB`, potentially explainable as retained per-thread memory on the order of `~10 MB x 116 threads`.
- This library treats that as a hypothesis to test, not a confirmed root cause.
- The churn scenarios in the benchmark suite are intended to validate or refute retained-per-thread-state explanations with data.

## Issue Mapping

| Gap ID | Title | Issue | Severity | Status | Owner | Acceptance Criteria | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G-001 | Public API and lifecycle invariants | [#1](https://gitlab.com/devnw/zig/thread-pool/-/work_items/1) | High | Closed | `@benjiv` | API documented and lifecycle tests pass | `src/thread_pool/pool.zig`, `tests/unit.zig` |
| G-002 | Scheduler baseline: global queue | [#2](https://gitlab.com/devnw/zig/thread-pool/-/work_items/2) | High | Closed | `@benjiv` | Bounded global queue implementation and tests | `src/thread_pool/pool.zig`, `benchmarks/results/baseline.json` |
| G-003 | Scheduler candidate: work stealing | [#3](https://gitlab.com/devnw/zig/thread-pool/-/work_items/3) | High | Closed | `@benjiv` | Local deque + steal path implemented and benchmarked | `src/thread_pool/pool.zig`, `docs/SCHEDULER_DECISION.md` |
| G-004 | Memory model and scratch purge | [#4](https://gitlab.com/devnw/zig/thread-pool/-/work_items/4) | High | Closed | `@benjiv` | Bounded descriptors, scratch caps, purge path | `src/thread_pool/memory/scratch.zig`, `tests/unit.zig` |
| G-005 | Park/unpark and shrink policy | [#5](https://gitlab.com/devnw/zig/thread-pool/-/work_items/5) | Medium | Closed | `@benjiv` | Park via condvar (PERF-005); shrink accepted as non-goal; dead fields removed (GAP-0018/0019) | `src/thread_pool/pool.zig`, `docs/DESIGN.md` |
| G-006 | Descriptor slab/freelist | [#6](https://gitlab.com/devnw/zig/thread-pool/-/work_items/6) | High | Closed | `@benjiv` | Safe reuse and bounded live count; generation ABA fix applied | `src/thread_pool/pool.zig` |
| G-007 | Stats and observability schema | [#7](https://gitlab.com/devnw/zig/thread-pool/-/work_items/7) | High | Closed | `@benjiv` | Snapshot and process memory metrics; per-worker histograms | `src/thread_pool/stats/`, `benchmarks/common.zig` |
| G-008 | Unit/integration/stress/fuzz plan | [#8](https://gitlab.com/devnw/zig/thread-pool/-/work_items/8) | High | Closed | `@benjiv` | Test matrix exists and passes; fuzz targets added (GAP-0024 closed); commits 2dcb123, 6afd41d | `tests/`, `tests/fuzz.zig`, `.gitlab-ci.yml` |
| G-009 | Benchmark harness and regression gates | [#9](https://gitlab.com/devnw/zig/thread-pool/-/work_items/9) | High | Closed | `@benjiv` | JSON bench + compare tool exist | `benchmarks/common.zig`, `benchmarks/compare.zig` |
| G-010 | Cross-platform matrix | [#10](https://gitlab.com/devnw/zig/thread-pool/-/work_items/10) | Medium | Partial | `@benjiv` | CI jobs compile Linux/macOS/Windows targets; native runners pending | `.gitlab-ci.yml` |
| G-011 | geode/quic-shaped scenarios | [#11](https://gitlab.com/devnw/zig/thread-pool/-/work_items/11) | High | Closed | `@benjiv` | Scenario names and harness coverage exist | `benchmarks/bench.zig`, `benchmarks/scale_bench.zig` |
| G-012 | GAP analysis and performance targets docs | [#12](https://gitlab.com/devnw/zig/thread-pool/-/work_items/12) | High | Closed | `@benjiv` | Docs exist and stay current | `docs/GAP_ANALYSIS.md`, `docs/PERFORMANCE_TARGETS.md` |
| G-013 | Default scheduler selection report | [#13](https://gitlab.com/devnw/zig/thread-pool/-/work_items/13) | Medium | Closed | `@benjiv` | Decision recorded with measured evidence | `docs/SCHEDULER_DECISION.md`, `benchmarks/results/baseline.json` |
| GAP-0011 | Stress test hangs due to worker idle/shutdown race condition | -- | Critical | Closed | `@benjiv` | idle() checks state in spin loop and before park | `src/thread_pool/pool.zig` |
| GAP-0012 | CancellationToken has zero test coverage | -- | Medium | Closed | `@benjiv` | Test at unit.zig:111-138 | `tests/unit.zig:111-138` |
| GAP-0013 | trySubmit() has zero test coverage | -- | Medium | Closed | `@benjiv` | Test at unit.zig:140-172 | `tests/unit.zig:140-172` |
| GAP-0014 | Backpressure block/block_with_timeout paths have zero test coverage | -- | Medium | Partial | `@benjiv` | block_with_timeout tested; .block policy still untested | `tests/unit.zig`, `src/thread_pool/pool.zig:290-309` |
| GAP-0015 | Shutdown timeout parameter has zero test coverage | -- | Medium | Closed | `@benjiv` | Test at unit.zig:204-225 | `tests/unit.zig:204-225` |
| GAP-0016 | queue_capacity not bounded to u32 range in validate() | -- | Medium | Closed | `@benjiv` | types.zig:95 validates | `src/thread_pool/types.zig:95` |
| GAP-0017 | WaitGroup done() underflow wraps u32 counter silently | -- | High | Closed | `@benjiv` | @panic in all build modes replaces debug.assert; commit 214ca3c | `src/thread_pool/types.zig` |
| GAP-0018 | Dead Config fields: idle_shrink_after_ns, stats_enabled, allocator_mode | -- | Low | Closed | `@benjiv` | Fields removed from types.zig | `src/thread_pool/types.zig` |
| GAP-0019 | Dead observability field: Stats.retired_workers always 0 | -- | Low | Closed | `@benjiv` | Field removed | `src/thread_pool/types.zig` |
| GAP-0020 | TaskLane.keyed is defined but never used | -- | Low | Closed | `@benjiv` | Removed from enum | `src/thread_pool/types.zig` |
| GAP-0021 | Benchmark nowNs() missing negative-timestamp guard | -- | Low | Closed | `@benjiv` | Guard added at benchmarks/common.zig:459-462 | `benchmarks/common.zig:459-462` |
| GAP-0022 | beginTask() error silently swallowed in runTask() | -- | Low | Partial | `@benjiv` | Error now counted via atomic but not exposed in Stats | `src/thread_pool/pool.zig` |
| GAP-0024 | Zero fuzz targets | -- | High | Closed | `@benjiv` | Fuzz targets for BoundedRing and Config validation added; CI fuzz job fixed; commits 2dcb123, 6afd41d | `tests/fuzz.zig`, `.gitlab-ci.yml` |
| GAP-0025 | BoundedRing head/tail false sharing | -- | Medium | Closed | `@benjiv` | Cache-line padding between head and tail; commit ca1b0a4 | `src/thread_pool/queue/bounded_ring.zig` |
| GAP-0026 | submitBatch signals workers individually | -- | Low | Open | `@benjiv` | Batch signal or coalesced wake implemented | `src/thread_pool/pool.zig:213-221` |
| GAP-0027 | Scratch buffer not zeroed between tasks | -- | Low | Open | `@benjiv` | Scratch zeroed or documented as intentionally uncleared | `src/thread_pool/memory/scratch.zig:51-57` |
| GAP-0028 | docs/README.md links to 5 non-existent files | -- | Low | Open | `@benjiv` | All README links resolve to existing files | `docs/README.md` |
| GAP-0029 | SECURITY.md references "GitHub issues" but project is on GitLab | -- | Low | Open | `@benjiv` | SECURITY.md references GitLab issues | `SECURITY.md` |
| GAP-0030 | CHANGELOG.md has placeholder date/description | -- | Low | Open | `@benjiv` | CHANGELOG entries have real dates and descriptions | `CHANGELOG.md` |
| GAP-0031 | process_memory.private_peak_bytes reports current not peak on Linux | -- | Medium | Open | `@benjiv` | private_peak_bytes tracks high-water mark across snapshots | `src/thread_pool/stats/process_memory.zig` |
| GAP-0032 | deinitOwned missing recordOwnedFree for inject_queue buffer | -- | Low | Open | `@benjiv` | recordOwnedFree called for inject_queue buffer in deinit | `src/thread_pool/pool.zig:678` |
| GAP-0033 | counters.wakeups never incremented -- Stats.wakeups always 0 | -- | Low | Closed | `@benjiv` | statsSnapshot aggregates wakeups from per-worker counters; commit da32fee | `src/thread_pool/pool.zig` |
| GAP-0034 | CODEOWNERS contains placeholder @your-username | -- | Low | Open | `@benjiv` | CODEOWNERS has real usernames | `CODEOWNERS` |
| GAP-0035 | local_queue_capacity=0 with global_queue causes OOB in release builds | -- | Critical | Closed | `@benjiv` | validate() rejects local_queue_capacity=0 unconditionally; test confirms; commit bace578 | `src/thread_pool/types.zig` |

## Audit Findings (2026-04-11 -- Phase 1-3)

The following findings were identified and addressed during the initial full codebase audit:

| Finding | Domain | Severity | Status | Commit |
| --- | --- | --- | --- | --- |
| Descriptor generation ABA bug | Quality | Critical | Closed | `fix: close GAP-001` |
| submitBatch partial-failure reporting | Quality | High | Closed | `fix: close GAP-002` |
| lane_extension variant silently falls through | Quality | High | Closed | `fix: close GAP-003` |
| Fuzz corpus empty | Gap | High | Documented | `chore: close GAP-004` |
| latency_mutex serializes all workers | Perf | P1 | Closed | `perf: close GAP-005` |
| Mutex-backed WorkDeque limits scalability | Perf | P1 | Deferred | Phase 2; lock-free Chase-Lev design tracked in DESIGN.md |
| Unchecked @intCast on nanoTimestamp() | Security | Medium | Closed | `fix: close GAP-007` |
| No bounds check on handle.index in wait() | Security | Medium | Closed | `fix: close GAP-008` |
| allow_blocking_lane has no effect | Quality | Medium | Documented | `docs: close GAP-009` |
| GAP_ANALYSIS.md statuses stale | Quality | Medium | Closed | This update |

## Audit Findings (2026-04-11 -- Phase 4)

Deep-dive audit uncovering test coverage gaps, dead code, and safety issues. Platform issues skipped (--skip-issues); tracked here only.

| Finding | Domain | Severity | Status | Gap-ID |
| --- | --- | --- | --- | --- |
| Worker idle/shutdown race causes stress test hangs | Bug | Critical | Closed | GAP-0011 |
| CancellationToken has zero test coverage | Test | Medium | Closed | GAP-0012 |
| trySubmit() has zero test coverage | Test | Medium | Closed | GAP-0013 |
| Backpressure block/block_with_timeout paths untested | Test | Medium | Partial | GAP-0014 |
| Shutdown timeout parameter untested | Test | Medium | Closed | GAP-0015 |
| queue_capacity not bounded to u32 range in validate() | Security | Medium | Closed | GAP-0016 |
| WaitGroup done() underflow wraps u32 counter silently | Security | High | Closed | GAP-0017 |
| Dead Config fields: idle_shrink_after_ns, stats_enabled, allocator_mode | Quality | Low | Closed | GAP-0018 |
| Dead observability field: Stats.retired_workers always 0 | Quality | Low | Closed | GAP-0019 |
| TaskLane.keyed defined but never used | Quality | Low | Closed | GAP-0020 |
| Benchmark nowNs() missing negative-timestamp guard | Security | Low | Closed | GAP-0021 |
| beginTask() error silently swallowed in runTask() | Quality | Low | Partial | GAP-0022 |

## Audit Findings (2026-04-11 -- Phase 5)

Full audit uncovering new coverage, performance, documentation, and safety gaps.

| Finding | Domain | Severity | Status | Gap-ID |
| --- | --- | --- | --- | --- |
| Zero fuzz targets | Test | High | Closed | GAP-0024 |
| BoundedRing head/tail false sharing | Performance | Medium | Closed | GAP-0025 |
| submitBatch signals workers individually | Performance | Low | Open | GAP-0026 |
| Scratch buffer not zeroed between tasks | Security | Low | Open | GAP-0027 |
| docs/README.md links to 5 non-existent files | Docs | Low | Open | GAP-0028 |
| SECURITY.md references "GitHub issues" but project is on GitLab | Docs | Low | Open | GAP-0029 |
| CHANGELOG.md has placeholder date/description | Docs | Low | Open | GAP-0030 |
| process_memory.private_peak_bytes reports current not peak on Linux | Bug | Medium | Open | GAP-0031 |
| deinitOwned missing recordOwnedFree for inject_queue buffer | Bug | Low | Open | GAP-0032 |
| counters.wakeups never incremented -- Stats.wakeups always 0 | Quality | Low | Closed | GAP-0033 |
| CODEOWNERS contains placeholder @your-username | Docs | Low | Open | GAP-0034 |
| local_queue_capacity=0 with global_queue causes OOB in release builds | Security | Critical | Closed | GAP-0035 |

## Security Risk Assessment (2026-04-11 -- Phase 4-6 Scoring)

Last updated: 2026-04-11

### Threat Model Summary

**Asset:** A bounded, reusable thread-pool library for Zig, intended as infrastructure for `devnw/zig` and the `geode` QUIC stack.

**Trust boundaries:**

- Library consumer (application code) configures and submits tasks -- partially trusted.
- Worker threads execute user-supplied function pointers -- trusted (same process).
- CI/CD pipeline includes external catalog components -- partially trusted upstream.

**Attack surfaces:**

- Config validation path (init-time, local).
- Task submission path (runtime, same-process).
- Shutdown/lifecycle path (runtime, same-process).
- CI pipeline supply chain (build-time, internet-facing).
- Observability/stats snapshot path (runtime, same-process, read-only).

**Exploitation context:** This is a library, not a network service. All findings are exploitable only from within the same process or CI pipeline. There are no internet-facing attack surfaces at the library level. The supply chain vector (SEC-008) is the only finding with an internet-facing component.

**Secrets scan:** Zero secrets found across manual regex, semgrep, and git history scans.

**Dependencies:** Zero Zig dependencies. `install-zig.sh` uses SHA-256 verification (correct).

### Scoring Framework

```text
Risk Score = Impact(1-5) x Likelihood(1-5) x 4
```

| Scale | 1 | 2 | 3 | 4 | 5 |
| --- | --- | --- | --- | --- | --- |
| **Impact** | Hardening | Info leak, limited | Data tampering, DoS | PII/cred leak, auth bypass | RCE, priv-esc, cross-tenant |
| **Likelihood** | Theoretical | Rare conditions | Requires auth/specific | Remote, constrained | Pre-auth, trivial |

### Stack-Ranked Security Findings

| Rank | ID | Severity | Risk Score | Finding | Component | CWE / OWASP | Evidence | Confidence | Exploit Surface | SLA | Status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| 1 | SEC-005 | Critical | 40 | UAF via shutdown-timeout-then-deinit: `shutdown()` times out, `deinit()` calls `shutdown()` again which returns immediately (state already `.shutdown_requested`), then frees workers/descriptors while threads still running | `pool.zig:178-198, 249-277` | CWE-416, CWE-362 / A11:2021 | `shutdown()` at :250 swaps state to `.shutdown_requested`; timeout at :262 returns `error.Timeout`; `deinit()` at :179 calls `shutdown()` again; second call sees `old_state != .running` at :251, returns immediately; `deinitOwned()` at :198 frees workers/queues while threads still run | confirmed | Same-process | 7 days | Closed -- deinit now always joins threads before freeing; commit de49d69 |
| 2 | SEC-017 | Critical | 40 | local_queue_capacity=0 with global_queue causes OOB write in release builds | `types.zig:96`, `queue/work_deque.zig:19` | CWE-787 / A03:2021 | `validate()` only rejects `local_queue_capacity=0` for `work_stealing` at :96; `Core.init` unconditionally creates `WorkDeque` at `pool.zig:165`; `WorkDeque.init` asserts `size > 0` (stripped in release); `mask = size - 1 = maxInt(usize)`; recursive task submission from worker triggers `buffer[b & maxInt(usize)]` -- OOB write | confirmed | Same-process (init) | 7 days | Closed -- validate() now rejects local_queue_capacity=0 for all scheduler variants; commit bace578 |
| 3 | SEC-004 | High | 36 | WaitGroup.done() underflow wraps u32 to maxInt, causing permanent hang | `types.zig:148-150` | CWE-191 / A11:2021 | `fetchSub(1, .acq_rel)` at :149; `debug.assert(previous > 0)` at :150 stripped in release builds; wraps to 4294967295, `wait()` blocks forever | confirmed | Same-process | 30 days | Closed -- @panic replaces debug.assert; underflow detected in all build modes; commit 214ca3c |
| 4 | SEC-003 | High | 32 | LatencyHistogram torn reads: merge() reads 64 buckets + scalar fields without sync | `stats/latency.zig:7-19`, `pool.zig:300-303` | CWE-362 / A11:2021 | `statsSnapshot()` calls `merge(worker.wait_histogram)` on live worker data; `observe()` at latency.zig:13-19 writes `counts`, `count`, `sum_ns`, `min_ns`, `max_ns` non-atomically; concurrent `merge()` at :22-31 reads same fields without lock | confirmed | Same-process | 30 days | Closed -- all histogram fields converted to std.atomic.Value; commit de49d69 |
| 5 | SEC-008 | Medium | 32 | CI catalog components pinned by version tag, not SHA | `.gitlab-ci.yml:6-13` | CWE-829 / A08:2021 | All 8 includes use `@v1.x.x` tags; tag force-push replaces content silently | confirmed | Internet-facing (CI) | 90 days | Open |
| 6 | SEC-021 | Medium | 24 | Fuzz regression CI job unconditionally passes (OR-true + allow_failure) | `.gitlab-ci.yml:122-124` | CWE-392 / A11:2021 | Script uses OR-true fallback; allow_failure at :124; job can never fail; zero meaningful fuzz coverage in CI | confirmed | CI pipeline | 90 days | Open |
| 7 | SEC-007 | Medium | 24 | beginTask() error counted via atomic but not exposed in Stats API | `pool.zig:510-511` | CWE-755 / A11:2021 | `worker.scratch.beginTask() catch { _ = worker.scratch_init_failures.fetchAdd(1, .release); }` -- error counted but `scratch_init_failures` not surfaced in `statsSnapshot()` or `WorkerStats` | confirmed | Same-process | 90 days | Partial |
| 8 | SEC-014 | Low | 16 | decrementQueued fetchSub potential underflow | `pool.zig:696-698` | CWE-682 / A11:2021 | `fetchSub(1, .release)` with no underflow guard; if counter reaches 0 unexpectedly, wraps to maxInt | confirmed | Same-process | 180 days | Open |
| 9 | SEC-011 | Medium | 12 | Descriptor fields written non-atomically before queue push; correct but fragile invariant | `pool.zig:319-337` | CWE-362 / A11:2021 | Plain stores to descriptor fields before `tryPush`; currently safe due to mutex barriers | suspected | Same-process (latent) | 180 days | Open |
| 10 | SEC-018 | Low | 8 | queue_capacity non-power-of-two on 32-bit targets bypasses validation | `types.zig:85-87` | CWE-682 / A11:2021 | `ceilPowerOfTwo(usize, cfg.queue_capacity)` at :86 can overflow on 32-bit targets; `catch` fallback keeps original non-power-of-two value; `BoundedRing` depends on power-of-two mask for correct indexing | suspected | Same-process (32-bit only) | 180 days | Open |
| 11 | SEC-019 | Low | 8 | max_threads has no upper bound validation | `types.zig:92` | CWE-400 / A05:2021 | `validate()` checks `max_threads > 0` but has no cap; extremely large values cause resource exhaustion via thread creation at `pool.zig:174` | suspected | Same-process (init) | 180 days | Open |
| 12 | SEC-020 | Low | 8 | Unbounded CAS spin in acquireDescriptor/releaseDescriptor without spinLoopHint | `pool.zig:616-636, 649-659` | CWE-400 / A11:2021 | `while (true)` CAS loops at :616 and :649 have no `spinLoopHint()` call; under high contention, spinning threads waste CPU and delay progress | confirmed | Same-process | Backlog | Open |
| 13 | SEC-016 | Low | 8 | purgeWorkerCaches TOCTOU with active workers | `pool.zig:332-337` | CWE-367 / A11:2021 | `active_tasks.load` check at :333 then iterate; worker could start task between check and purge; mitigated by scratch mutex | suspected | Same-process | Backlog | Open |

### Summary by Severity (Open + Partial)

| Severity | Count | Open | Partial | Closed | Top Risk |
| --- | --- | --- | --- | --- | --- |
| Critical | 2 | 0 | 0 | 2 | SEC-005, SEC-017: both closed |
| High | 2 | 0 | 0 | 2 | SEC-004, SEC-003: both closed |
| Medium | 4 | 3 | 1 | 0 | SEC-008: CI tag pinning (Risk 32), SEC-021: fuzz job no-op (Risk 24) |
| Low | 5 | 5 | 0 | 0 | SEC-014: counter underflow (Risk 16), SEC-018/019/020/016 (Risk 8) |
| **Total** | **13** | **8** | **1** | **4** | |

### Findings by Area (Open + Partial)

**Concurrency / Thread Safety (2 findings remaining open)**

- SEC-011 (Medium): descriptor pre-push writes (latent)
- SEC-016 (Low): purge TOCTOU (benign under current mutex)
- ~~SEC-005 (Critical): Closed -- commit de49d69~~
- ~~SEC-003 (High): Closed -- commit de49d69~~

**Memory Safety (0 findings remaining open)**

- ~~SEC-017 (Critical): Closed -- commit bace578~~

**Integer Safety (2 findings remaining open)**

- SEC-014 (Low): decrementQueued fetchSub underflow
- SEC-018 (Low): ceilPowerOfTwo overflow on 32-bit
- ~~SEC-004 (High): Closed -- commit 214ca3c~~

**Error Handling / Observability (1 finding)**

- SEC-007 (Medium): beginTask() error counted but not in Stats API

**Supply Chain / CI (2 findings)**

- SEC-008 (Medium): CI tags not SHA-pinned
- SEC-021 (Medium): fuzz regression job unconditionally passes

**Resource Exhaustion / Hardening (2 findings)**

- SEC-019 (Low): max_threads no upper bound
- SEC-020 (Low): unbounded CAS spin without spinLoopHint

### Resolved Findings (Verified 2026-04-11)

| ID | Severity | Finding | CWE | Resolution | Evidence |
| --- | --- | --- | --- | --- | --- |
| SEC-001 | Critical | idle/shutdown race -- workers stuck in spin/sleep during shutdown | CWE-662, CWE-835 | Fixed | `pool.zig:549-555` -- `idle()` checks `self.state.load(.acquire) != .running` in spin loop (:551), before park (:555), and inside park mutex (:562) |
| SEC-002 | High | descriptor.state data race -- non-atomic writes across threads | CWE-362 | Fixed | `descriptor.state` is now `std.atomic.Value(TaskState)` with `.release` stores and `.acquire` loads throughout pool.zig |
| SEC-006 | Medium | queue_capacity not bounded to u32 in validate() | CWE-190 | Fixed | `types.zig:95` now validates `self.queue_capacity > std.math.maxInt(u32)` |
| SEC-009 | Medium | Non-atomic worker stats read cross-thread by statsSnapshot() | CWE-362 | Fixed | All worker stats (`busy_ns`, `parks`, `steals`, `steal_failures`, `last_idle_started_ns`, `scratch_init_failures`) are now `std.atomic.Value(u64)` with acquire/release at `pool.zig:63-71` |
| SEC-010 | Medium | incrementQueued uses .monotonic ordering; weak on ARM | CWE-662 | Fixed | `incrementQueued` at `pool.zig:692` now uses `.release` ordering, pairing correctly with idle's `.acquire` load |
| SEC-012 | Low | .gitignore missing .env/*.pem/*.key patterns | CWE-200 | Fixed | `.gitignore:57-61` now includes `.env*`, `*.pem`, `*.key`, `*.p12`, `*.pfx` |
| SEC-013 | Low | Benchmark nowNs() missing negative-timestamp guard | CWE-681 | Fixed | `benchmarks/common.zig:459-461` uses safe pattern: `const ts = std.time.nanoTimestamp(); return if (ts < 0) 0 else @intCast(ts)` |
| SEC-015 | Low | cancelQueuedTasks drains via popBottom on non-owning thread | N/A | Fixed | `cancelQueuedTasks` at `pool.zig:594` now uses `stealTop()` instead of `popBottom` |
| SEC-017 | Critical | local_queue_capacity=0 OOB write in release builds | CWE-787 | Fixed | `validate()` rejects `local_queue_capacity=0` unconditionally; commit bace578 |
| SEC-005 | Critical | UAF via shutdown-timeout-then-deinit | CWE-416, CWE-362 | Fixed | `deinit()` now always joins threads before freeing memory; commit de49d69 |
| SEC-004 | High | WaitGroup.done() underflow wraps u32 to maxInt | CWE-191 | Fixed | `@panic` replaces `debug.assert`; underflow detected in all build modes; commit 214ca3c |
| SEC-003 | High | LatencyHistogram torn reads on cross-thread merge | CWE-362 | Fixed | All histogram fields converted to `std.atomic.Value`; commit de49d69 |

### Previously Fixed (Verified in Phase 2-3)

| Finding | CWE | Status | Evidence |
| --- | --- | --- | --- |
| Unchecked @intCast on nanoTimestamp() | CWE-681 | Fixed | `pool.zig:674-676` -- negative guard added |
| No bounds check on handle.index in wait() | CWE-129 | Fixed | `pool.zig:179` -- generation check prevents OOB |
| Descriptor generation ABA | CWE-362 | Fixed | `pool.zig:548-549` -- `+%1` with skip-zero |

### How to Verify (Selected Open Findings)

| ID | Verification Approach |
| --- | --- |
| SEC-005 | Call `shutdown(timeout_ns = 1)` while long tasks run; observe `error.Timeout`; then call `deinit()`; workers access freed memory. Fix: `deinit()` must join threads even after timeout, or `shutdown()` second call must not skip the join loop. |
| SEC-017 | Create pool with `Config{ .scheduler_variant = .global_queue, .local_queue_capacity = 0 }`; in ReleaseFast, submit a recursive task from within a worker; observe OOB write via segfault or corruption. Fix: validate `local_queue_capacity > 0` unconditionally in `validate()`. |
| SEC-004 | Unit test in ReleaseFast: create WaitGroup, call `done()` without prior `add()`; observe wrap to maxInt and permanent `wait()` hang. Fix: add saturating check or return error in release builds. |
| SEC-003 | Code review confirms `observe()` writes non-atomic fields concurrently with `merge()` reads at `stats/latency.zig:13-31`. Fix: snapshot histograms under worker pause or use per-bucket atomics. |
| SEC-008 | Verify `.gitlab-ci.yml` includes at :6-13 use `@vX.Y.Z` tags. Fix: replace with `@sha256:<hash>` pinning. |
| SEC-021 | Run grep for OR-true in .gitlab-ci.yml and confirm fuzz job at :122 always exits 0. Fix: remove OR-true and allow_failure, or gate on actual fuzz coverage. |
| SEC-018 | On a 32-bit target, pass `queue_capacity = maxInt(u32)` to `Config.normalized()`; `ceilPowerOfTwo` overflows and fallback keeps non-power-of-two; `BoundedRing` indexing corrupts. |
| SEC-019 | Pass `max_threads = 1_000_000` to `Config`; `pool.init` attempts to spawn 1M threads. Fix: add reasonable upper bound (e.g., `4 * cpu_count` or configurable cap). |
| SEC-020 | Under high descriptor churn, observe CPU spike from CAS spin at `acquireDescriptor`/`releaseDescriptor` (`pool.zig:616-636, 649-659`). Fix: add `std.atomic.spinLoopHint()` inside loop body. |

### Remediation Roadmap

**Quick Wins (< 1 day each)**

| Priority | ID | Severity | Fix | Effort |
| --- | --- | --- | --- | --- |
| 1 | SEC-017 | Critical | ~~Add unconditional `local_queue_capacity=0` rejection~~ | Done -- commit bace578 |
| 2 | SEC-005 | Critical | ~~Always join threads before freeing in deinit()~~ | Done -- commit de49d69 |
| 3 | SEC-004 | High | ~~Add release-build underflow check~~ | Done -- commit 214ca3c |
| 4 | SEC-007 | Medium | Expose `scratch_init_failures` in `WorkerStats` and `statsSnapshot()` | 30 min |
| 5 | SEC-021 | Medium | Remove OR-true from fuzz job script; remove or condition allow_failure on actual fuzz target existence | 15 min |
| 6 | SEC-014 | Low | Add debug counter/log when fetchSub would underflow | 15 min |
| 7 | SEC-020 | Low | Add `std.atomic.spinLoopHint()` inside CAS loops in `acquireDescriptor`/`releaseDescriptor` | 10 min |
| 8 | SEC-019 | Low | Add `if (self.max_threads > 4096) return error.InvalidMaxThreads;` or configurable cap in `validate()` | 10 min |
| 9 | SEC-018 | Low | Validate power-of-two result explicitly after `ceilPowerOfTwo`; return error on overflow | 15 min |

**Medium Effort (1-5 days)**

| Priority | ID | Severity | Fix | Effort |
| --- | --- | --- | --- | --- |
| 10 | SEC-003 | High | ~~Convert histogram fields to atomics~~ | Done -- commit de49d69 |
| 11 | SEC-008 | Medium | Replace version tags with SHA-pinned includes in .gitlab-ci.yml; document pin-update process | 2-4 hours |

**Strategic (> 5 days / deferred)**

| Priority | ID | Severity | Fix | Effort |
| --- | --- | --- | --- | --- |
| 12 | SEC-011 | Medium | Becomes critical if Chase-Lev adopted; add release fence before push in lock-free path | Part of Chase-Lev migration |
| 13 | SEC-016 | Low | Acceptable risk under current mutex design; revisit if locking strategy changes | Backlog |

### Immediate Actions Required

All three Critical/High security findings have been closed:

1. ~~**SEC-017 (Critical, Risk 40):**~~ Closed -- `validate()` rejects `local_queue_capacity=0` unconditionally; commit bace578.
2. ~~**SEC-005 (Critical, Risk 40):**~~ Closed -- `deinit()` now always joins threads before freeing; commit de49d69.
3. ~~**SEC-004 (High, Risk 36):**~~ Closed -- `@panic` replaces `debug.assert` for underflow detection in all build modes; commit 214ca3c.

### Blockers and Unknowns

- **SEC-011 (suspected):** Latent only. Currently safe under mutex. Becomes a blocker for Chase-Lev lock-free migration.
- **SEC-016 (suspected):** Same as SEC-011 -- safe today, breaks under lock-free design.
- **SEC-018 (suspected):** Requires 32-bit target to confirm. `ceilPowerOfTwo` overflow path needs validation on 32-bit hardware or cross-compilation test.
- **SEC-019 (suspected):** Resource exhaustion is platform-dependent; reasonable upper bound TBD based on deployment constraints.
- **ThreadSanitizer:** Not available for Zig. Remaining data race finding SEC-003 (histogram torn reads) is confirmed via code review but cannot be mechanically verified with current tooling.

## Unresolved Design Decisions

- whether the local deque should stay mutex-backed or move to a lock-free design
- whether waitable handles should use a dedicated completion pool instead of retaining descriptors
- whether allocator event counts should be tracked alongside bytes
- whether a dedicated blocking lane should get its own worker subset in phase 3

## Benchmark Gaps

- validate scale-bench scenarios against longer-running scheduled jobs
- collect larger conn-churn evidence for RSS plateau analysis
- add CSV export if a downstream consumer needs spreadsheet ingestion

## CI/CD Gaps

- native macOS smoke runner
- native Windows smoke runner
- ~~fuzz targets for queue operations, config validation, and submit/cancel races (tracked as GAP-0024) -- Closed: commits 2dcb123, 6afd41d~~
- automatic refresh workflow for baseline benchmark artifacts
- ~~fuzz regression job unconditionally passes (tracked as SEC-021) -- `|| true` removed: commit 6afd41d~~

## Gaps

### GAP-0014: Backpressure .block policy has zero test coverage

- **Issue:** --
- **Category:** Test
- **Severity:** Medium
- **Requirement source:** G-001 (Public API and lifecycle invariants), Functional Req: bounded submission and explicit backpressure
- **Current state (evidence):**
  - `src/thread_pool/pool.zig:290-309` -- blocking submit implementation
  - `tests/unit.zig` -- block_with_timeout tested, but `.block` policy untested
- **Why this is a gap:** The `.block` backpressure path (unconditional wait) is a core functional requirement with zero test coverage.
- **Impact/Risk:** Deadlocks under .block policy could go undetected.
- **Recommended fix:** Add test that fills the queue, then submits with `.block` policy; verify it eventually succeeds after a worker drains the queue.
- **Acceptance criteria:** At least one test exercises `.block` policy and verifies correct blocking/unblocking behavior.

### GAP-0017: WaitGroup done() underflow wraps u32 counter silently in release builds [CLOSED]

- **Issue:** --
- **Category:** Security
- **Severity:** High
- **Status:** Closed
- **Resolution:** Replaced `debug.assert` with `@panic` for underflow detection in all build modes. Commit 214ca3c.
- **Evidence:** `src/thread_pool/types.zig` -- `if (previous == 0) @panic("WaitGroup.done() underflow");`
- **Resolved date:** 2026-04-11

### GAP-0022: beginTask() error counted but not exposed in Stats

- **Issue:** --
- **Category:** Code Quality
- **Severity:** Low
- **Requirement source:** G-007 (Stats and observability schema)
- **Current state (evidence):**
  - `src/thread_pool/pool.zig` -- Error now counted via atomic increment but not included in Stats snapshot
- **Why this is a gap:** beginTask errors are counted internally but invisible to observability consumers via statsSnapshot().
- **Impact/Risk:** Operators cannot detect scratch allocation failures through the stats API.
- **Recommended fix:** Add `scratch_errors` field to Stats struct and populate it from the atomic counter in statsSnapshot().
- **Acceptance criteria:** Stats.scratch_errors field exists and reflects actual beginTask error count.

### GAP-0024: Zero fuzz targets [CLOSED]

- **Issue:** --
- **Category:** Test
- **Severity:** High
- **Status:** Closed
- **Resolution:** Fuzz targets added for BoundedRing push/pop sequences and Config validation with arbitrary inputs. CI fuzz-regression job fixed (removed `|| true`). Commits 2dcb123, 6afd41d.
- **Evidence:** `tests/fuzz.zig` (fuzz targets), `.gitlab-ci.yml` (fuzz-regression job)
- **Resolved date:** 2026-04-11

### GAP-0025: BoundedRing head/tail false sharing [CLOSED]

- **Issue:** --
- **Category:** Performance
- **Severity:** Medium
- **Status:** Closed
- **Resolution:** Added cache-line padding (56 bytes) between head and tail atomics in BoundedRing. Commit ca1b0a4.
- **Evidence:** `src/thread_pool/queue/bounded_ring.zig` -- `_padding` field between head and tail
- **Resolved date:** 2026-04-11

### GAP-0026: submitBatch signals workers individually

- **Issue:** --
- **Category:** Performance
- **Severity:** Low
- **Requirement source:** Non-functional Req: low-contention scheduler option
- **Current state (evidence):**
  - `src/thread_pool/pool.zig:213-221` -- submitBatch signals one worker per task in batch
- **Why this is a gap:** Signaling N workers for N tasks in a batch causes N condvar broadcasts instead of a coalesced wake.
- **Impact/Risk:** Unnecessary syscall overhead for large batches; minor latency impact.
- **Recommended fix:** Signal min(batch_size, idle_workers) workers after pushing all tasks, not per-task.
- **Acceptance criteria:** submitBatch performs at most one signal per worker needed; benchmark shows no regression.

### GAP-0027: Scratch buffer not zeroed between tasks

- **Issue:** --
- **Category:** Security
- **Severity:** Low
- **Requirement source:** G-004 (Memory model and scratch purge)
- **Current state (evidence):**
  - `src/thread_pool/memory/scratch.zig:51-57` -- scratch reset moves pointer but does not zero memory
- **Why this is a gap:** Task N+1 can observe residual data from task N in the scratch buffer.
- **Impact/Risk:** Information leakage between tasks in the same worker. Low severity because all tasks run in the same process.
- **Recommended fix:** Zero scratch memory on reset, or document that scratch contents are not guaranteed to be zeroed between tasks.
- **Acceptance criteria:** Scratch is zeroed between tasks, or documentation explicitly states the non-zeroing contract.

### GAP-0028: docs/README.md links to 5 non-existent files

- **Issue:** --
- **Category:** Docs
- **Severity:** Low
- **Requirement source:** G-012 (GAP analysis and performance targets docs)
- **Current state (evidence):**
  - `docs/README.md` -- contains links to files that do not exist in the repository
- **Why this is a gap:** Broken documentation links degrade developer onboarding experience.
- **Impact/Risk:** Contributor confusion; appears unmaintained.
- **Recommended fix:** Fix or remove broken links; add link-checking to CI.
- **Acceptance criteria:** All links in docs/README.md resolve to existing files.

### GAP-0029: SECURITY.md references "GitHub issues" but project is on GitLab

- **Issue:** --
- **Category:** Docs
- **Severity:** Low
- **Requirement source:** Operational correctness
- **Current state (evidence):**
  - `SECURITY.md` -- references "GitHub issues" for vulnerability reporting
- **Why this is a gap:** Misdirects security reporters to a non-existent GitHub issue tracker.
- **Impact/Risk:** Security vulnerabilities may not be reported through the correct channel.
- **Recommended fix:** Update SECURITY.md to reference GitLab issues or the correct reporting mechanism.
- **Acceptance criteria:** SECURITY.md references the correct GitLab project for issue reporting.

### GAP-0030: CHANGELOG.md has placeholder date/description

- **Issue:** --
- **Category:** Docs
- **Severity:** Low
- **Requirement source:** Operational correctness
- **Current state (evidence):**
  - `CHANGELOG.md` -- contains placeholder date and/or description entries
- **Why this is a gap:** Placeholder content suggests the changelog is not actively maintained.
- **Impact/Risk:** Users cannot determine release history or changes between versions.
- **Recommended fix:** Fill in actual dates and descriptions for each release entry.
- **Acceptance criteria:** All CHANGELOG.md entries have real dates and meaningful descriptions.

### GAP-0031: process_memory.private_peak_bytes reports current not peak on Linux

- **Issue:** --
- **Category:** Bug
- **Severity:** Medium
- **Requirement source:** G-007 (Stats and observability schema), Non-functional Req: measurable allocator and RSS behavior
- **Current state (evidence):**
  - `src/thread_pool/stats/process_memory.zig` -- reads current RSS value, not high-water mark
- **Why this is a gap:** The field name says "peak" but the value is the current snapshot, not the historical maximum.
- **Impact/Risk:** Misleading memory metrics; operators may miss transient memory spikes.
- **Recommended fix:** Track high-water mark across snapshots, or rename the field to reflect actual semantics.
- **Acceptance criteria:** private_peak_bytes tracks actual peak across all snapshots, or field is renamed to match semantics.

### GAP-0032: deinitOwned missing recordOwnedFree for inject_queue buffer

- **Issue:** --
- **Category:** Bug
- **Severity:** Low
- **Requirement source:** G-007 (Stats and observability schema)
- **Current state (evidence):**
  - `src/thread_pool/pool.zig:678` -- inject_queue buffer freed without calling recordOwnedFree
- **Why this is a gap:** Owned memory accounting becomes inaccurate after deinit; stats show leaked bytes.
- **Impact/Risk:** Misleading memory accounting in stats; may trigger false-positive leak detection.
- **Recommended fix:** Call recordOwnedFree for inject_queue buffer before freeing.
- **Acceptance criteria:** recordOwnedFree called for inject_queue buffer; owned_bytes reaches zero after full deinit.

### GAP-0033: counters.wakeups never incremented -- Stats.wakeups always 0 [CLOSED]

- **Issue:** --
- **Category:** Code Quality
- **Severity:** Low
- **Status:** Closed
- **Resolution:** statsSnapshot now aggregates wakeups from per-worker counters instead of reading the dead global counter. Commit da32fee.
- **Evidence:** `src/thread_pool/pool.zig` -- statsSnapshot sums `worker.wakeups.load(.acquire)` across all workers
- **Resolved date:** 2026-04-11

### GAP-0034: CODEOWNERS contains placeholder @your-username

- **Issue:** --
- **Category:** Docs
- **Severity:** Low
- **Requirement source:** Operational correctness
- **Current state (evidence):**
  - `CODEOWNERS` -- contains `@your-username` placeholder
- **Why this is a gap:** CODEOWNERS is non-functional; GitLab will not assign reviewers correctly.
- **Impact/Risk:** No automatic review assignment; PRs/MRs may lack required approvals.
- **Recommended fix:** Replace placeholder with actual GitLab username(s).
- **Acceptance criteria:** CODEOWNERS contains real usernames; GitLab assigns reviewers on MR creation.

### GAP-0035: local_queue_capacity=0 with global_queue causes OOB in release builds [CLOSED]

- **Issue:** --
- **Category:** Security
- **Severity:** Critical
- **Status:** Closed
- **Resolution:** validate() now rejects local_queue_capacity=0 unconditionally for all scheduler variants. Test confirms error return. Commit bace578.
- **Evidence:** `src/thread_pool/types.zig` -- unconditional `if (self.local_queue_capacity == 0) return error.InvalidLocalQueueCapacity;`
- **Resolved date:** 2026-04-11

## Cross-platform Status

| Platform | Status | Notes |
| --- | --- | --- |
| Linux | Running locally | Benchmarks and tests exercised |
| macOS | Compile-target wired | Native runner validation pending |
| Windows | Compile-target wired | Native runner validation pending |

## Next Review Date

2026-05-11

## Revision History

| Date | Phase | Changes |
| --- | --- | --- |
| 2026-04-11 | Phase 1-3 | Initial gap analysis and security assessment |
| 2026-04-11 | Phase 4 | Deep-dive audit: GAP-0011 through GAP-0022 |
| 2026-04-11 | Phase 5 | Full audit: 10 gaps resolved, 2 partial, 13 new gaps (GAP-0023 through GAP-0035); security assessment updated (8 findings resolved, 8 open) |
| 2026-04-11 | Phase 6 | Security assessment refresh: 7 findings resolved (SEC-001/002/006/009/010/012/013/015); SEC-005 upgraded Critical (UAF via shutdown-timeout-then-deinit, Risk 40); SEC-017 added Critical (OOB write, Risk 40); 5 new findings added (SEC-017/018/019/020/021); SEC-004/007 confirmed Partial; 13 open findings remain |
| 2026-04-11 | Phase 7 | Gap closure: 9 findings closed (SEC-017, SEC-005, SEC-004, SEC-003, GAP-0017, GAP-0024, GAP-0025, GAP-0033, GAP-0035, PERF-002, PERF-011, PERF-022, PERF-023, Q-022). All Critical and High security findings resolved. |
