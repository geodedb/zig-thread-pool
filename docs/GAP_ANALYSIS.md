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
| G-008 | Unit/integration/stress/fuzz plan | [#8](https://gitlab.com/devnw/zig/thread-pool/-/work_items/8) | High | Partial | `@benjiv` | Test matrix exists and passes; fuzz targets not yet written | `tests/`, `.gitlab-ci.yml` |
| G-009 | Benchmark harness and regression gates | [#9](https://gitlab.com/devnw/zig/thread-pool/-/work_items/9) | High | Closed | `@benjiv` | JSON bench + compare tool exist | `benchmarks/common.zig`, `benchmarks/compare.zig` |
| G-010 | Cross-platform matrix | [#10](https://gitlab.com/devnw/zig/thread-pool/-/work_items/10) | Medium | Partial | `@benjiv` | CI jobs compile Linux/macOS/Windows targets; native runners pending | `.gitlab-ci.yml` |
| G-011 | geode/quic-shaped scenarios | [#11](https://gitlab.com/devnw/zig/thread-pool/-/work_items/11) | High | Closed | `@benjiv` | Scenario names and harness coverage exist | `benchmarks/bench.zig`, `benchmarks/scale_bench.zig` |
| G-012 | GAP analysis and performance targets docs | [#12](https://gitlab.com/devnw/zig/thread-pool/-/work_items/12) | High | Closed | `@benjiv` | Docs exist and stay current | `docs/GAP_ANALYSIS.md`, `docs/PERFORMANCE_TARGETS.md` |
| G-013 | Default scheduler selection report | [#13](https://gitlab.com/devnw/zig/thread-pool/-/work_items/13) | Medium | Closed | `@benjiv` | Decision recorded with measured evidence | `docs/SCHEDULER_DECISION.md`, `benchmarks/results/baseline.json` |
| GAP-0011 | Stress test hangs due to worker idle/shutdown race condition | -- | Critical | Open | `@benjiv` | Stress tests pass under `timeout 60` in ReleaseFast; idle workers observe shutdown within 1 sleep cycle | `src/thread_pool/pool.zig:484-505`, `build.zig:65` |
| GAP-0012 | CancellationToken has zero test coverage | -- | Medium | Open | `@benjiv` | At least one test exercises cancel-before-run and cancel-during-run paths | `src/thread_pool/types.zig:115-125` |
| GAP-0013 | trySubmit() has zero test coverage | -- | Medium | Open | `@benjiv` | At least one test calls trySubmit on full and non-full queues | `src/thread_pool/pool.zig:155-157` |
| GAP-0014 | Backpressure block/block_with_timeout paths have zero test coverage | -- | Medium | Open | `@benjiv` | Tests saturate queue and verify block and block_with_timeout policies | `src/thread_pool/types.zig:20-24`, `src/thread_pool/pool.zig:290-309` |
| GAP-0015 | Shutdown timeout parameter has zero test coverage | -- | Medium | Open | `@benjiv` | At least one test calls shutdown with non-null timeout and verifies behavior | `src/thread_pool/pool.zig:203-228` |
| GAP-0016 | queue_capacity not bounded to u32 range in validate() | -- | Medium | Open | `@benjiv` | validate() rejects queue_capacity > maxInt(u32); test confirms | `src/thread_pool/types.zig:83`, `src/thread_pool/pool.zig:126` |
| GAP-0017 | WaitGroup done() underflow wraps u32 counter silently | -- | Medium | Open | `@benjiv` | done() on zero-count returns error or panics in safe mode; test confirms | `src/thread_pool/types.zig:136-143` |
| GAP-0018 | Dead Config fields: idle_shrink_after_ns, stats_enabled, allocator_mode | -- | Low | Open | `@benjiv` | Fields removed or wired to implementation; no dead config fields remain | `src/thread_pool/types.zig:49,58,59` |
| GAP-0019 | Dead observability field: Stats.retired_workers always 0 | -- | Low | Open | `@benjiv` | Field removed or correctly populated from worker retirement logic | `src/thread_pool/types.zig:196`, `src/thread_pool/pool.zig:263` |
| GAP-0020 | TaskLane.keyed is defined but never used | -- | Low | Open | `@benjiv` | Variant removed or scheduling effect implemented and tested | `src/thread_pool/types.zig:17` |
| GAP-0021 | Benchmark nowNs() missing negative-timestamp guard | -- | Low | Open | `@benjiv` | benchmarks/common.zig nowNs() uses same safe cast as pool.zig:674-676 | `benchmarks/common.zig:427-429` |
| GAP-0022 | beginTask() error silently swallowed in runTask() | -- | Low | Open | `@benjiv` | beginTask error is logged or propagated; silent catch removed | `src/thread_pool/pool.zig:450` |

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
| Worker idle/shutdown race causes stress test hangs | Bug | Critical | Open | GAP-0011 |
| CancellationToken has zero test coverage | Test | Medium | Open | GAP-0012 |
| trySubmit() has zero test coverage | Test | Medium | Open | GAP-0013 |
| Backpressure block/block_with_timeout paths untested | Test | Medium | Open | GAP-0014 |
| Shutdown timeout parameter untested | Test | Medium | Open | GAP-0015 |
| queue_capacity not bounded to u32 range in validate() | Security | Medium | Open | GAP-0016 |
| WaitGroup done() underflow wraps u32 counter silently | Security | Medium | Open | GAP-0017 |
| Dead Config fields: idle_shrink_after_ns, stats_enabled, allocator_mode | Quality | Low | Open | GAP-0018 |
| Dead observability field: Stats.retired_workers always 0 | Quality | Low | Open | GAP-0019 |
| TaskLane.keyed defined but never used | Quality | Low | Open | GAP-0020 |
| Benchmark nowNs() missing negative-timestamp guard | Security | Low | Open | GAP-0021 |
| beginTask() error silently swallowed in runTask() | Quality | Low | Open | GAP-0022 |

## Security Risk Assessment (2026-04-11 -- Phase 4 Scoring)

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
| 1 | SEC-001 | Critical | 60 | idle() does not check pool state; workers stuck in spin/sleep during shutdown | `pool.zig:484-505` | CWE-662, CWE-835 / A11:2021 | `idle()` spin loop checks only `queued_tasks`, never `self.state`; `shouldExit()` unreachable until sleep expires | confirmed | Same-process | 7 days | Open |
| 2 | SEC-005 | Medium | 40 | Double-shutdown race: two threads calling shutdown() both proceed to thread.join() | `pool.zig:203-228` | CWE-362 / A11:2021 | `state.swap(.shutdown_requested)` does not guard against concurrent callers both reaching the join loop | confirmed | Same-process | 90 days | Open |
| 3 | SEC-002 | High | 40 | descriptor.state written non-atomically across threads (UB per C11/Zig model) | `pool.zig:427,466-468` | CWE-362 / A11:2021 | `descriptor.state = .running` at :427, `.completed` at :467 are plain stores read by other threads | confirmed | Same-process | 30 days | Open |
| 4 | SEC-004 | High | 36 | WaitGroup.done() underflow wraps u32 to maxInt, causing infinite hang | `types.zig:136-143` | CWE-191 / A11:2021 | `fetchSub(1, .acq_rel)` with no underflow guard; wraps to 4294967295 | confirmed | Same-process | 30 days | Open |
| 5 | SEC-003 | High | 32 | LatencyHistogram torn reads: merge() reads 64 buckets + u128 without sync | `latency.zig:11,22-31; pool.zig:251-253` | CWE-362 / A11:2021 | `statsSnapshot()` calls `merge(worker.wait_histogram)` on live worker data with no lock | confirmed | Same-process | 30 days | Open |
| 6 | SEC-008 | Medium | 32 | CI catalog components pinned by version tag, not SHA | `.gitlab-ci.yml:6-13` | CWE-829 / A08:2021 | All 8 includes use `@v1.x.x` tags; tag force-push replaces content silently | confirmed | Internet-facing (CI) | 90 days | Open |
| 7 | SEC-009 | Medium | 32 | Non-atomic worker stats read cross-thread by statsSnapshot() | `pool.zig:230-281` | CWE-362 / A11:2021 | `worker.busy_ns`, `.parks`, `.steals` etc. are plain u64 fields read without sync | confirmed | Same-process | 90 days | Open |
| 8 | SEC-006 | Medium | 24 | queue_capacity not bounded to u32; @intCast panic at pool.zig:126 | `types.zig:79-89; pool.zig:126` | CWE-190 / A11:2021 | `validate()` only checks `!= 0`; `@intCast(idx)` panics if capacity > maxInt(u32) | confirmed | Same-process (init) | 90 days | Open |
| 9 | SEC-007 | Medium | 24 | beginTask() error silently swallowed; scratch OOM invisible | `pool.zig:450` | CWE-755 / A11:2021 | `worker.scratch.beginTask() catch {};` discards error | confirmed | Same-process | 90 days | Open |
| 10 | SEC-010 | Medium | 24 | incrementQueued uses .monotonic, idle uses .acquire; weak ordering on ARM | `pool.zig:609-612` | CWE-662 / A11:2021 | Store with `.monotonic` may not be visible to `.acquire` load on ARM in time | suspected | Same-process (ARM only) | 90 days | Open |
| 11 | SEC-014 | Low | 16 | decrementQueued silently drops decrement at zero, masking accounting bugs | `pool.zig:614-621` | CWE-682 / A11:2021 | CAS loop exits when `current == 0` without signaling | confirmed | Same-process | 180 days | Open |
| 12 | SEC-011 | Medium | 12 | Descriptor fields written non-atomically before queue push | `pool.zig:319-337` | CWE-362 / A11:2021 | Plain stores to descriptor fields before `tryPush`; currently safe due to mutex barriers | suspected | Same-process (latent) | 180 days | Open |
| 13 | SEC-012 | Low | 8 | .gitignore missing .env/*.pem/*.key patterns | `.gitignore` | CWE-200 / A05:2021 | No `.env`, `*.pem`, `*.key` patterns present; 0 secrets found in current repo | suspected | Local (preventive) | 180 days | Open |
| 14 | SEC-013 | Low | 8 | Benchmark nowNs() missing negative-timestamp guard | `benchmarks/common.zig:427-429` | CWE-681 / A11:2021 | Bare `@intCast(std.time.nanoTimestamp())` without negative check | confirmed | Same-process (bench) | 180 days | Open |
| 15 | SEC-015 | Low | 8 | cancelQueuedTasks drains via popBottom on non-owning thread | `pool.zig:518-525` | N/A | Safe under current mutex design; breaks if Chase-Lev adopted | suspected | Same-process (latent) | Backlog | Open |
| 16 | SEC-016 | Low | 8 | purgeWorkerCaches TOCTOU with active workers | `pool.zig:283-288` | CWE-367 / A11:2021 | `active_tasks.load` check then iterate; mitigated by scratch mutex | suspected | Same-process | Backlog | Open |

### Summary by Severity

| Severity | Count | Top Risk |
| --- | --- | --- |
| Critical | 1 | SEC-001: idle/shutdown hang (Risk 60) |
| High | 3 | SEC-002: descriptor data race (Risk 40) |
| Medium | 6 | SEC-005: double-shutdown (Risk 40) |
| Low | 6 | SEC-014: counter drift (Risk 16) |

### Findings by Area

**Concurrency / Thread Safety (8 findings)**

- SEC-001 (Critical): idle/shutdown race
- SEC-002 (High): descriptor.state data race
- SEC-003 (High): histogram torn reads
- SEC-005 (Medium): double-shutdown UB
- SEC-009 (Medium): non-atomic worker stats
- SEC-010 (Medium): weak memory ordering
- SEC-011 (Medium): descriptor pre-push writes (latent)
- SEC-016 (Low): purge TOCTOU (benign)

**Integer Safety (3 findings)**

- SEC-004 (High): WaitGroup underflow wrap
- SEC-006 (Medium): queue_capacity @intCast overflow
- SEC-014 (Low): silent decrement drop

**Error Handling (1 finding)**

- SEC-007 (Medium): beginTask() error swallowed

**Supply Chain (1 finding)**

- SEC-008 (Medium): CI tags not SHA-pinned

**Operational Hardening (2 findings)**

- SEC-012 (Low): .gitignore gaps
- SEC-013 (Low): benchmark nowNs() guard

**Latent Design Risks (1 finding)**

- SEC-015 (Low): popBottom cross-thread (blocks Chase-Lev migration)

### Previously Fixed (Verified in Phase 2-3)

| Finding | CWE | Status | Evidence |
| --- | --- | --- | --- |
| Unchecked @intCast on nanoTimestamp() | CWE-681 | Fixed | `pool.zig:674-676` -- negative guard added |
| No bounds check on handle.index in wait() | CWE-129 | Fixed | `pool.zig:179` -- generation check prevents OOB |
| Descriptor generation ABA | CWE-362 | Fixed | `pool.zig:548-549` -- `+%1` with skip-zero |

### How to Verify (Selected Findings)

| ID | Verification Approach |
| --- | --- |
| SEC-001 | Run `timeout 30 zig build test-stress` in ReleaseFast; observe hang. Add `self.state.load(.acquire) != .running` check in idle(); re-run. |
| SEC-002 | ThreadSanitizer (not available in Zig today). Code review confirms plain stores at :427, :467 without atomic wrapper. |
| SEC-004 | Unit test: create WaitGroup, call `done()` without prior `add()`; observe wrap to maxInt and infinite `wait()`. |
| SEC-005 | Spawn two threads both calling `shutdown()`; observe double-join. Fix: CAS on state to claim single shutdown owner. |
| SEC-008 | Verify by checking `.gitlab-ci.yml` includes use `@vX.Y.Z` tags. Fix: replace with `@sha256:<hash>` pinning. |
| SEC-010 | Requires ARM hardware. Stress test with many submitters and few workers; look for tasks visible only after delay. |

### Remediation Roadmap

**Quick Wins (< 1 day each)**

| Priority | ID | Fix | Effort |
| --- | --- | --- | --- |
| 1 | SEC-001 | Add `state.load(.acquire)` check to `idle()` spin and sleep branches; wake parked workers on shutdown | 1-2 hours |
| 2 | SEC-004 | Guard `done()` with `if (previous == 0) @panic("WaitGroup underflow")` in debug, return error in release | 30 min |
| 3 | SEC-006 | Add `if (self.queue_capacity > std.math.maxInt(u32)) return error.InvalidQueueCapacity;` in validate() | 15 min |
| 4 | SEC-007 | Replace `catch {}` with `catch \|err\| { worker.scratch_errors += 1; }` and expose in stats | 30 min |
| 5 | SEC-013 | Copy safe cast pattern from pool.zig:674-676 to benchmarks/common.zig:427 | 10 min |
| 6 | SEC-012 | Append `.env`, `*.pem`, `*.key`, `*.p12`, `*.pfx` to .gitignore | 5 min |
| 7 | SEC-014 | Log or count when decrementQueued hits zero unexpectedly | 15 min |

**Medium Effort (1-5 days)**

| Priority | ID | Fix | Effort |
| --- | --- | --- | --- |
| 8 | SEC-005 | Use CAS on state field to ensure single shutdown owner; second caller returns immediately or waits | 2-4 hours |
| 9 | SEC-002 | Wrap `descriptor.state` in `std.atomic.Value(State)` with appropriate ordering | 4-8 hours |
| 10 | SEC-003 | Snapshot histograms under worker pause or use per-worker atomic snapshots | 4-8 hours |
| 11 | SEC-009 | Move worker stats to atomic counters or snapshot under pause | 2-4 hours |
| 12 | SEC-008 | Replace version tags with SHA-pinned includes in .gitlab-ci.yml; document pin-update process | 2-4 hours |
| 13 | SEC-010 | Upgrade incrementQueued store ordering to `.release` to pair with idle `.acquire` load | 1-2 hours |

**Strategic (> 5 days / deferred)**

| Priority | ID | Fix | Effort |
| --- | --- | --- | --- |
| 14 | SEC-011 | Becomes critical if Chase-Lev adopted; add release fence before push in lock-free path | Part of Chase-Lev migration |
| 15 | SEC-015 | Redesign cancelQueuedTasks for Chase-Lev ownership model | Part of Chase-Lev migration |
| 16 | SEC-016 | Acceptable risk under current mutex design; revisit if locking strategy changes | Backlog |

### Immediate Actions Required

1. **SEC-001 (Critical, Risk 60):** Fix the idle/shutdown race. This is the root cause of stress test hangs and blocks CI reliability. The fix is small (add state check in idle loop) but high-impact.
2. **SEC-004 (High, Risk 36):** Add underflow guard to WaitGroup.done(). An extra `done()` call currently causes an undetectable infinite hang.

### Blockers and Unknowns

- **SEC-010 (suspected):** Weak ordering pair requires ARM hardware to confirm. x86 TSO masks the issue. Confirm with ARM stress tests or upgrade ordering defensively.
- **SEC-011 (suspected):** Latent only. Currently safe under mutex. Becomes a blocker for Chase-Lev lock-free migration.
- **SEC-015 (suspected):** Same as SEC-011 -- safe today, breaks under lock-free design.
- **ThreadSanitizer:** Not available for Zig. Data race findings (SEC-002, SEC-003, SEC-009) are confirmed via code review but cannot be mechanically verified with current tooling.

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
- fuzz targets for queue operations, config validation, and submit/cancel races
- automatic refresh workflow for baseline benchmark artifacts

## Gaps

### GAP-0011: Stress test hangs due to worker idle/shutdown race condition

- **Issue:** --
- **Category:** Bug
- **Severity:** Critical
- **Requirement source:** G-008 (Unit/integration/stress/fuzz plan)
- **Current state (evidence):**
  - `src/thread_pool/pool.zig:484-505` -- idle() spin loop checks only queued_tasks, not pool state
  - `build.zig:65` -- stress tests hardcoded to ReleaseFast
  - `timeout 30 zig build test-stress` -- killed by timeout (reproduced)
- **Why this is a gap:** Workers in idle sleep do not observe shutdown state transitions promptly, causing join() to hang indefinitely.
- **Impact/Risk:** Stress test suite cannot run to completion; CI timeout failures mask real regressions.
- **Recommended fix:** Add pool state check inside idle loop; use futex/condvar wake on shutdown instead of relying on sleep expiry.
- **Acceptance criteria:** `timeout 60 zig build test-stress` passes reliably in ReleaseFast; idle workers observe shutdown within one sleep cycle.

### GAP-0012: CancellationToken has zero test coverage

- **Issue:** --
- **Category:** Test
- **Severity:** Medium
- **Requirement source:** G-008 (Unit/integration/stress/fuzz plan)
- **Current state (evidence):**
  - `src/thread_pool/types.zig:115-125` -- CancellationToken exported via root.zig
  - `tests/` -- no test file references CancellationToken
- **Why this is a gap:** The cancellation path in runTask (pool.zig:449-456) is completely untested.
- **Impact/Risk:** Cancellation bugs (use-after-free, double-exec) could ship undetected.
- **Recommended fix:** Add unit tests exercising cancel-before-run and cancel-during-run scenarios.
- **Acceptance criteria:** At least two tests exercise CancellationToken; coverage includes the runTask cancellation branch.

### GAP-0013: trySubmit() has zero test coverage

- **Issue:** --
- **Category:** Test
- **Severity:** Medium
- **Requirement source:** G-001 (Public API and lifecycle invariants)
- **Current state (evidence):**
  - `src/thread_pool/pool.zig:155-157` -- trySubmit() is the non-blocking submit API
  - `tests/` -- no test calls trySubmit
- **Why this is a gap:** The non-blocking submit path is part of the public API contract but has no regression protection.
- **Impact/Risk:** Breaking changes to trySubmit could ship without detection.
- **Recommended fix:** Add tests calling trySubmit on both full and non-full queues; verify return values.
- **Acceptance criteria:** At least one test calls trySubmit and verifies success/failure return.

### GAP-0014: Backpressure block/block_with_timeout paths have zero test coverage

- **Issue:** --
- **Category:** Test
- **Severity:** Medium
- **Requirement source:** G-001 (Public API and lifecycle invariants), Functional Req: bounded submission and explicit backpressure
- **Current state (evidence):**
  - `src/thread_pool/types.zig:20-24` -- BackpressurePolicy enum with block/block_with_timeout
  - `src/thread_pool/pool.zig:290-309` -- blocking submit implementation
  - `tests/` -- no test saturates queue to trigger backpressure
- **Why this is a gap:** The backpressure mechanism is a core functional requirement with zero test coverage.
- **Impact/Risk:** Deadlocks or silent drops under pressure could go undetected.
- **Recommended fix:** Add tests that fill the queue, then submit with block and block_with_timeout policies; verify blocking behavior and timeout expiry.
- **Acceptance criteria:** Tests cover block (waits then succeeds) and block_with_timeout (returns error on expiry).

### GAP-0015: Shutdown timeout parameter has zero test coverage

- **Issue:** --
- **Category:** Test
- **Severity:** Medium
- **Requirement source:** G-001 (Public API and lifecycle invariants), Functional Req: deterministic shutdown
- **Current state (evidence):**
  - `src/thread_pool/pool.zig:203-228` -- shutdown accepts optional timeout_ns
  - `tests/` -- all shutdown calls use null timeout
- **Why this is a gap:** The timeout-based shutdown path is untested; forced-termination logic may be broken.
- **Impact/Risk:** Applications relying on shutdown timeout could hang in production.
- **Recommended fix:** Add test that submits long-running tasks, calls shutdown with short timeout, verifies pool terminates within timeout.
- **Acceptance criteria:** At least one test exercises shutdown with non-null timeout and verifies timely termination.

### GAP-0016: queue_capacity not bounded to u32 range in validate()

- **Issue:** --
- **Category:** Security
- **Severity:** Medium
- **Requirement source:** G-004 (Memory model and scratch purge)
- **Current state (evidence):**
  - `src/thread_pool/types.zig:83` -- validate() only checks != 0
  - `src/thread_pool/pool.zig:126` -- @intCast(idx) to u32 panics if queue_capacity > maxInt(u32)
- **Why this is a gap:** Unchecked config can cause runtime panic via @intCast overflow.
- **Impact/Risk:** Attacker-controlled or misconfigured capacity causes unrecoverable panic.
- **Recommended fix:** Add `if (self.queue_capacity > std.math.maxInt(u32)) return error.InvalidConfig;` in validate().
- **Acceptance criteria:** validate() rejects capacity > maxInt(u32); test confirms error return.

### GAP-0017: WaitGroup done() underflow wraps u32 counter silently

- **Issue:** --
- **Category:** Security
- **Severity:** Medium
- **Requirement source:** G-001 (Public API and lifecycle invariants)
- **Current state (evidence):**
  - `src/thread_pool/types.zig:136-143` -- fetchSub(1, .monotonic) without underflow check
- **Why this is a gap:** Extra done() call wraps counter to maxInt(u32), causing wait() to hang forever.
- **Impact/Risk:** Logic bugs in task completion counting become infinite hangs instead of detectable errors.
- **Recommended fix:** Check previous value before sub; return error or panic in Debug/ReleaseSafe on underflow.
- **Acceptance criteria:** done() on zero-count is detectable (error or debug panic); test confirms.

### GAP-0018: Dead Config fields: idle_shrink_after_ns, stats_enabled, allocator_mode

- **Issue:** --
- **Category:** Code Quality
- **Severity:** Low
- **Requirement source:** G-005 (Park/unpark and shrink policy)
- **Current state (evidence):**
  - `src/thread_pool/types.zig:49` -- idle_shrink_after_ns defined
  - `src/thread_pool/types.zig:58` -- allocator_mode defined
  - `src/thread_pool/types.zig:59` -- stats_enabled defined
  - `src/thread_pool/pool.zig` -- none of these fields are read
- **Why this is a gap:** Dead fields mislead users into thinking features exist; increases maintenance surface.
- **Impact/Risk:** User confusion; false sense of configurability.
- **Recommended fix:** Remove fields or wire them to implementation. If deferred to Phase 2, add doc comments marking them as reserved/unimplemented.
- **Acceptance criteria:** No dead config fields remain, or each is annotated as unimplemented with tracking reference.

### GAP-0019: Dead observability field: Stats.retired_workers always 0

- **Issue:** --
- **Category:** Code Quality
- **Severity:** Low
- **Requirement source:** G-007 (Stats and observability schema)
- **Current state (evidence):**
  - `src/thread_pool/types.zig:196` -- retired_workers field in Stats
  - `src/thread_pool/pool.zig:263` -- hardcoded to 0
- **Why this is a gap:** Metric reports a permanent zero; misleads observability consumers.
- **Impact/Risk:** Dashboard shows meaningless metric; operator confusion.
- **Recommended fix:** Remove field (no retirement exists) or implement worker retirement and populate.
- **Acceptance criteria:** Field removed or correctly reflects actual worker retirement count.

### GAP-0020: TaskLane.keyed is defined but never used

- **Issue:** --
- **Category:** Code Quality
- **Severity:** Low
- **Requirement source:** Non-scope: lane-aware scheduler specialization
- **Current state (evidence):**
  - `src/thread_pool/types.zig:17` -- TaskLane.keyed variant
  - `src/thread_pool/pool.zig` -- no scheduling logic references .keyed
- **Why this is a gap:** Public enum variant implies scheduling semantics that do not exist.
- **Impact/Risk:** Users may rely on keyed lane for ordering guarantees that are not enforced.
- **Recommended fix:** Remove variant or implement keyed-lane affinity scheduling.
- **Acceptance criteria:** Variant removed, or keyed scheduling implemented with at least one test.

### GAP-0021: Benchmark nowNs() missing negative-timestamp guard

- **Issue:** --
- **Category:** Security
- **Severity:** Low
- **Requirement source:** G-009 (Benchmark harness and regression gates)
- **Current state (evidence):**
  - `benchmarks/common.zig:427-429` -- bare @intCast without negative guard
  - `src/thread_pool/pool.zig:674-676` -- safe version with negative check
- **Why this is a gap:** Inconsistent safety between pool and benchmark code; benchmark can panic on platforms returning negative nanoTimestamp.
- **Impact/Risk:** Benchmark crash on edge-case platforms; inconsistent safety posture.
- **Recommended fix:** Apply same guard as pool.zig:674-676 to benchmarks/common.zig nowNs().
- **Acceptance criteria:** benchmarks/common.zig nowNs() uses safe cast matching pool.zig pattern.

### GAP-0022: beginTask() error silently swallowed in runTask()

- **Issue:** --
- **Category:** Code Quality
- **Severity:** Low
- **Requirement source:** G-007 (Stats and observability schema)
- **Current state (evidence):**
  - `src/thread_pool/pool.zig:450` -- `_ = beginTask(...) catch {};`
- **Why this is a gap:** Errors in task lifecycle hooks are invisible; makes debugging stats discrepancies impossible.
- **Impact/Risk:** Silent data loss in observability pipeline; hard-to-diagnose metric gaps.
- **Recommended fix:** Log the error at debug level, or propagate via stats error counter.
- **Acceptance criteria:** beginTask errors are observable (logged or counted); silent catch removed.

## Cross-platform Status

| Platform | Status | Notes |
| --- | --- | --- |
| Linux | Running locally | Benchmarks and tests exercised |
| macOS | Compile-target wired | Native runner validation pending |
| Windows | Compile-target wired | Native runner validation pending |

## Next Review Date

2026-05-11
