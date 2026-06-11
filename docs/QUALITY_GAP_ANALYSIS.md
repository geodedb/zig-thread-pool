# Quality Gap Analysis

Last updated: 2026-06-11

## Summary

- **Critical:** 0 | **High:** 3 open + 3 closed | **Medium:** 15 | **Low:** 12 | **Info:** 0 (2026-04-16 pass + legacy, unchanged)
- **2026-06-11 re-review pass:** 11 new findings — **High:** 1 | **Medium:** 6 | **Low:** 4 (plus Q-NEW-01 folded into #59 and NEW-002 folded into #34); **3 legacy items closed** (Q-028, Q-029, Q-006)
- **Total open findings (new audit):** 29 open + 3 closed on 2026-04-16 (QS-002, QS-003, QS-008)
- **Legacy Q-xxx open items carried over:** 12 (from 2026-04-11 audit pass); 3 closed 2026-06-11 (Q-028, Q-029, Q-006)
- **Formal gates (2026-04-16):** `zig fmt` clean, `zig build check` clean, `zig build test` 47 pass / 1 skip / 0 fail; `test-all` + TSan stress all pass post-closure

### Top 5 Risks (2026-06-11 re-review pass, by PriorityScore)

1. **Q-NEW-02** submitBatch leaks waitable descriptors → pool exhaustion (PriorityScore 60, High) — [#107](https://gitlab.com/devnw/zig/thread-pool/-/issues/107)
2. **Q-NEW-03** DESIGN.md documents phantom features (RuntimePreset/wake_strategy/idle_queue) (PriorityScore 36, Medium) — [#108](https://gitlab.com/devnw/zig/thread-pool/-/issues/108)
3. **Q-NEW-08** Watchdog non-interruptible sleep blocks shutdown up to watchdog_interval_ns (PriorityScore 36, Medium) — [#113](https://gitlab.com/devnw/zig/thread-pool/-/issues/113)
4. **QS-001** Split 2745-line src/pool.zig monolith (PriorityScore 80, High, carried) — [#14](https://gitlab.com/devnw/zig/thread-pool/-/issues/14)
5. **Q-NEW-04..07** DESIGN.md / types.zig doc-accuracy cluster (PriorityScore 24 each, Medium) — [#109](https://gitlab.com/devnw/zig/thread-pool/-/issues/109)–[#112](https://gitlab.com/devnw/zig/thread-pool/-/issues/112)

### Closed This Sweep (2026-06-11)

| Gap-ID | Issue | Resolution evidence |
|--------|-------|---------------------|
| Q-028 | [#65](https://gitlab.com/devnw/zig/thread-pool/-/issues/65) | DESIGN.md no longer says "Mutex-protected"; Queue Design (DESIGN.md:86-114) accurately describes BoundedRing Vyukov per-slot sequence MPMC lock-free. **Closed.** |
| Q-029 | [#67](https://gitlab.com/devnw/zig/thread-pool/-/issues/67) | DESIGN.md:277-279 now accurately qualified ("lock-free on the fast paths but not on the wake scan"); Chase-Lev deque documented at DESIGN.md:94-96. **Closed.** |
| Q-006 | (doc-only, no issue) | `lane_extension` is a documented stable public API surface; no longer a gap. Confirmed resolved (per gap determination, recorded in GAP_ANALYSIS_RESOLVED.md). |

### Closed Previous Sweep (2026-04-16)

| Gap-ID | Commit | Issue | Evidence |
|--------|--------|-------|----------|
| QS-002 | `301392b` | [#15](https://gitlab.com/devnw/zig/thread-pool/-/issues/15) | `Core.init` 147 → 60 lines; F-002 errdefer chain preserved |
| QS-003 | `a0259e6` | [#16](https://gitlab.com/devnw/zig/thread-pool/-/issues/16) | Hot-path decomposed; +16.3% conn_churn_seq / +11.7% producer_contention paired A/B |
| QS-008 | `429caab` | [#18](https://gitlab.com/devnw/zig/thread-pool/-/issues/18) | 24 public symbols documented; `grep -c '^///' src/types.zig` = 159 |

## Stack-Ranked Findings — 2026-06-11 Re-Review Pass

All findings `confidence::confirmed` (verified against source at commit `39528a3`).

| Rank | Severity | PriorityScore | Category | Finding | Component | Evidence | Issue URL | Fix Summary | Effort | Status |
|------|----------|---------------|----------|---------|-----------|----------|-----------|-------------|--------|--------|
| 1 | High | 60 | api-contract/reliability | Q-NEW-02 submitBatch accepts `options.waitable=true` but discards every handle → waitable descriptors never released → pool exhaustion after `queue_capacity` such tasks | src/pool.zig:836-888 (:854 discards handle); finalizeTask :2135-2141; wait() :976-999 | submitBatch passes `options` to enqueuePush, binds handle to `\|_\|`; finalizeTask only `releaseDescriptor`s non-waitable; wait() is sole waitable release path but no handle is returned | [#107](https://gitlab.com/devnw/zig/thread-pool/-/issues/107) | Reject waitable in submitBatch (error) or strip+document | S | Open |
| 2 | Medium | 36 | reliability/concurrency | Q-NEW-08 Watchdog `clock.sleep(interval)` non-interruptible → shutdown/deinit blocks up to full `watchdog_interval_ns` | src/pool.zig:1543-1545; join :1057-1061 | watchdog_stop set then thread.join() while watchdog parked in sleep | [#113](https://gitlab.com/devnw/zig/thread-pool/-/issues/113) | stop-condvar timedWait or document worst-case delay | S-M | Open |
| 3 | Medium | 36 | docs | Q-NEW-03 DESIGN.md describes phantom features: RuntimePreset, wake_strategy, scan_parked_workers, idle_queue — none exist in any .zig | docs/DESIGN.md:65-68,153-162 | `grep -rn` finds none in src/ | [#108](https://gitlab.com/devnw/zig/thread-pool/-/issues/108) | Delete Runtime Presets section + dual-strategy framing | S | Open |
| 4 | Medium | 24 | docs | Q-NEW-04 DESIGN.md says `steal_batch_size` default 16; actual 8 | docs/DESIGN.md:295 vs src/types.zig:349 | `steal_batch_size: usize = 8` | [#109](https://gitlab.com/devnw/zig/thread-pool/-/issues/109) | Fix doc value to 8 | S | Open |
| 5 | Medium | 24 | docs | Q-NEW-05 Docs reference nonexistent timestamp mode `completion_only`; actual enum `{full, disabled}` | docs/DESIGN.md:320 + docs/ALGORITHMS.md:518 vs src/types.zig:107-110, build.zig:69 | enum has only full/disabled; build flag {any,full,disabled} | [#110](https://gitlab.com/devnw/zig/thread-pool/-/issues/110) | Drop `completion_only` from both docs | S | Open |
| 6 | Medium | 24 | docs | Q-NEW-06 `queue_capacity` doc claims descriptors bounded by `queue_capacity + sum(local_queue_capacity)`; actually exactly `queue_capacity` allocated | src/types.zig:178-181 vs src/pool.zig:649 | `alloc(TaskDescriptor, normalized.queue_capacity)` | [#111](https://gitlab.com/devnw/zig/thread-pool/-/issues/111) | Fix doc; links to Q-NEW-02 capacity reasoning | S | Open |
| 7 | Medium | 24 | docs | Q-NEW-07 `idle_park_after_ns` doc inverts mechanism (says spin duration; actually parked `timedWait` timeout; spin = `spin_before_park_iters`) | src/types.zig:240-243 vs src/pool.zig:2207,2221 | used as `park_cond.timedWait(..., idle_park_after_ns)` | [#112](https://gitlab.com/devnw/zig/thread-pool/-/issues/112) | Reword doc; clarify spin knob | S | Open |
| 8 | Low | 24 | tests/ergonomics | NEW-003 unit.zig timeout tests use 2s sleeps → ~10s suite inflation | tests/unit.zig:309-360 | two `sleep_ns = 2_000_000_000` fixtures | [#120](https://gitlab.com/devnw/zig/thread-pool/-/issues/120) | Shrink sleeps to ~100ms | S | Open |
| 9 | Low | 16 | docs/observability | Q-NEW-09 parks/wakeups counters count attempts/timeouts not futex events, contradicting docs | src/types.zig:675-677 vs src/pool.zig:2179,2199,2210 | parks++ before timedWait; wakeups++ on early-return + timeout | [#114](https://gitlab.com/devnw/zig/thread-pool/-/issues/114) | Reword docs or move increments | S | Open |
| 10 | Low | 16 | observability/reliability | Q-NEW-10 joinAllWorkers joins overflow threads without updating overflow_retires/overflow_active | src/pool.zig:1080-1085 vs src/types.zig:761-767 | join loop nulls thread, no counter update | [#115](https://gitlab.com/devnw/zig/thread-pool/-/issues/115) | Update counters on shutdown join or doc caveat | S | Open |
| 11 | Low | 16 | maintainability | NEW-001 src/types.zig (978 lines) exceeds 800-line threshold (QS-001 scoped pool.zig only) | src/types.zig (wc -l = 978) | — | [#118](https://gitlab.com/devnw/zig/thread-pool/-/issues/118) | Split config/stats/lane submodules behind re-exports | M | Open |

**Folded (no new issue):**

- **Q-NEW-01** (Medium, docs) — public `ThreadPool.submitBatch` doc at src/pool.zig:2637 still says "atomically" and self-contradicts. This is the live residual of **Q-025**; tracked as a comment + remaining acceptance criterion on [#59](https://gitlab.com/devnw/zig/thread-pool/-/issues/59). Core doc (:830-836) + USAGE.md already fixed.
- **NEW-002** (Low, docs) — 7 additional files lack `//!` module headers (src/memory/scratch.zig, src/pool/desc_cache.zig, src/stats/latency.zig, src/stats/process_memory.zig, src/queue/bounded_ring.zig, src/queue/ring_queue.zig, src/queue/work_deque.zig). Folded into **QR-009** scope via comment on [#34](https://gitlab.com/devnw/zig/thread-pool/-/issues/34) (which already covers pool.zig + types.zig).

## Stack-Ranked Findings — 2026-04-16 Audit Pass

| Rank | Severity | PriorityScore | Category | Finding | Component | Issue URL | Fix Summary | Effort | Status |
|------|----------|---------------|----------|---------|-----------|-----------|-------------|--------|--------|
| 1 | High | 80 | readability | QS-001 Split 2087-line pool.zig into worker/descriptor/lanes/watchdog/stats | src/pool.zig | [#14](https://gitlab.com/devnw/zig/thread-pool/-/issues/14) | 5-way file split, target <700 lines each | L | Open |
| 2 | High | 64 | readability/perf | QS-003 Extract recordTaskStart/invokeTask/finalizeTask from Core.runTask | src/pool.zig:1670-1887 | [#16](https://gitlab.com/devnw/zig/thread-pool/-/issues/16) | Inline helpers, preserve atomic ordering | M | **Closed 2026-04-16 (a0259e6)** — see `GAP_ANALYSIS_RESOLVED.md` |
| 3 | High | 60 | readability | QS-002 Extract allocateStorage/initDescriptorFreelist/initWorkers/spawnWorkers | src/pool.zig:408-554 | [#15](https://gitlab.com/devnw/zig/thread-pool/-/issues/15) | Target 30-40 line orchestrator | M | **Closed 2026-04-16 (301392b)** — see `GAP_ANALYSIS_RESOLVED.md` |
| 4 | High | 60 | docs/api-contract | QS-008 Add /// to 24 undocumented public symbols in types.zig | src/types.zig:4-378 | [#18](https://gitlab.com/devnw/zig/thread-pool/-/issues/18) | Enum + struct + method doc blocks | M | **Closed 2026-04-16 (429caab)** — see `GAP_ANALYSIS_RESOLVED.md` |
| 5 | High | 48 | tests | QR-001 Unit tests for lane/watchdog/overflow slices | tests/unit.zig | [#24](https://gitlab.com/devnw/zig/thread-pool/-/issues/24) | 6 new unit tests + injectable clock | M | Open |
| 6 | High | 48 | reliability/ci-cd | QR-002 CI gate for -Dsingle-pool + comptime safety assertion | build.zig, .gitlab-ci.yml | [#28](https://gitlab.com/devnw/zig/thread-pool/-/issues/28) | Add test-single-pool job | S | Open |
| 7 | Medium | 36 | docs | QS-009 Document ThreadPool.init, registerSubmitter, releaseSubmitter | src/pool.zig:1986-2070 | [#31](https://gitlab.com/devnw/zig/thread-pool/-/issues/31) | /// on 3 methods + F-005 cite | S | Open |
| 8 | Medium | 36 | api-contract | QR-003 Declare ConfigError explicit error set | src/types.zig:234 | [#41](https://gitlab.com/devnw/zig/thread-pool/-/issues/41) | 19-variant error set + signature update | S | Open |
| 9 | Medium | 36 | api-contract | QR-004 Declare SubmitError/WaitError/ShutdownError/RegisterError/PurgeError | src/pool.zig | [#43](https://gitlab.com/devnw/zig/thread-pool/-/issues/43) | Explicit sets through facade | S-M | Open |
| 10 | Medium | 32 | readability | QS-004 Simplify 93-line Core.enqueuePush (8-level indent) | src/pool.zig:1017-1109 | [#34](https://gitlab.com/devnw/zig/thread-pool/-/issues/34) | 3-branch dispatch helper extraction | M | Open |
| 11 | Medium | 32 | docs | QR-009 Add module-level //! headers to pool.zig and types.zig | src/pool.zig, src/types.zig | [#58](https://gitlab.com/devnw/zig/thread-pool/-/issues/58) | Invariants listed at file head | S | Open |
| 12 | Medium | 24 | readability | QS-005 Extract helpers from statsSnapshot/nextTask/idle | src/pool.zig | [#45](https://gitlab.com/devnw/zig/thread-pool/-/issues/45) | Preserve SC handshake verbatim | M | Open |
| 13 | Medium | 24 | api-contract/docs | QR-005 Document SubmitOptions defaults + .block deadlock footgun | src/types.zig:268-275 | [#49](https://gitlab.com/devnw/zig/thread-pool/-/issues/49) | /// on struct + cross-link Config | S | Open |
| 14 | Medium | 24 | api-contract | QR-006 Document or fix Stats.worker_stats aliasing/lifetime | src/types.zig:378-409 | [#53](https://gitlab.com/devnw/zig/thread-pool/-/issues/53) | Either doc + single-caller rule, or dupe slice | S-M | Open |
| 15 | Medium | 24 | reliability/tests | QR-007 Inject clock source for deterministic watchdog tests | src/pool.zig:1176-1203 | [#61](https://gitlab.com/devnw/zig/thread-pool/-/issues/61) | NowFn typedef or watchdogTick extraction | M | Open |
| 16 | Medium | 24 | hygiene (cluster) | QS-HYG Repo hygiene: CODEOWNERS, SECURITY.md, Makefile, zig-0.15.2/, stray binaries, topology.zig | Repo-wide | [#77](https://gitlab.com/devnw/zig/thread-pool/-/issues/77) | Collapsed meta issue (6 sub-tasks) | M | Open |
| 17 | Medium | 24 | reliability/ci-cd | QS-015 Add -Dsanitize=address + scheduled ASan soak | build.zig, .gitlab-ci.yml | [#66](https://gitlab.com/devnw/zig/thread-pool/-/issues/66) | Mirror tsan-stress-soak job | S-M | Open |
| 18 | Medium | 24 | reliability/ci-cd | QS-016 Wire kcov coverage + GitLab coverage stanza | build.zig, .gitlab-ci.yml | [#69](https://gitlab.com/devnw/zig/thread-pool/-/issues/69) | Nightly coverage-linux job | M | Open |
| 19 | Medium | 24 | ci-cd | QS-018 Pre-commit gate: max 1200 line files, max 150 line functions | .pre-commit-config.yaml | [#73](https://gitlab.com/devnw/zig/thread-pool/-/issues/73) | scripts/quality-gate.py | S | Open |
| 20 | Medium | 16 | reliability | QR-008 Test overflow-worker spawn-failure path | src/pool.zig:1205-1221 | — | Suspected — belly-of-rlimit test required | M | Not tracked (below cutoff; confidence suspected) |
| 21 | Medium | 16 | readability | QS-020 35 lines at >=6 indent levels | src/pool.zig | — | Subsumed by QS-001/QS-004/QS-005 | — | Subsumed |
| 22 | Low | 16 | readability | QS-006 Three queue impls duplicate mask+SC idioms | src/queue/*.zig | — | Extract src/queue/common.zig | S | Doc-only |
| 23 | Low | 12 | api | QR-012 Config.hot_spinners + wake_every_n_tasks cross-field coupling | src/types.zig:77-102 | — | Optional nested HotSpinnerConfig (0.3.0 break) | S | Doc-only |
| 24 | Low | 12 | api | QR-013 Config.normalized() `catch X` silently accepts non-pow2 | src/types.zig:197-232 | — | Propagate error or explicit validate ranges | S | Doc-only |
| 25 | Low | 12 | docs | QR-010 Add stress reproducers for closed F-001/F-002/F-004/F-005 | tests/stress/ | — | 4 new TSan-gated stress tests | M | Doc-only |
| 26 | Low | 12 | docs | QR-011 Promote key design choices into docs/adr/ ADR files | docs/ | — | 5 ADR files extracted from docs/* | S-M | Doc-only |
| 27 | Low | 8 | docs | QS-019 Doc nowNs + updatePeakU32 | src/pool.zig:2073-2086 | — | 2 /// blocks | S | Doc-only |
| 28 | Low | 8 | reliability | QS-017 JSON schema for benchmark result files | benchmarks/ | — | draft-07 schema + ajv CI step | S | Doc-only |

**Cutoff note:** All High and Medium findings (scores >= 24) received GitLab issues. Medium finding QR-008 (score 16, confidence::suspected) was explicitly not tracked — the cost of a spawn-failure harness exceeds the expected value absent confirmation. QS-020 is subsumed by QS-001/QS-004/QS-005. Low-severity items (scores 8-16) are tracked in this document only; they will be promoted if they cluster with a related fix or if a maintainer elects to batch-address.

## Legacy Q-xxx Open Items (carried from 2026-04-11 audit)

These items predate the 2026-04-16 QS/QR scan and remain open pending separate resolution. As of 2026-06-11, Q-025 (#59) and Q-027 (#62) are filed as issues; the remainder are tracked in this document only.

| ID | Severity | PriorityScore | Category | Finding | Component | Status |
|------|----------|---------------|----------|---------|-----------|--------|
| Q-023 | Medium | 40 | maintainability | deinitOwned missing recordOwnedFree for inject_queue buffer | pool.zig:678 vs :149 | Open |
| Q-024 | Medium | 40 | api-contract | process_memory.private_peak_bytes reports current not peak on Linux | process_memory.zig:73-74 | Open |
| Q-004 | Medium | 28 | tests | .block backpressure policy untested | tests/*.zig | Partially Fixed |
| Q-025 | Medium | 24 | docs | submitBatch doc says "atomically" — residual public wrapper only (Q-NEW-01) | [#59](https://gitlab.com/devnw/zig/thread-pool/-/issues/59) | Open — residual at pool.zig:2637 (Core doc + USAGE.md fixed) |
| Q-018 | Low | 12 | perf | compare.zig readDocument leak mitigated but no explicit free | compare.zig:45 | Open |
| Q-026 | Low | 12 | readability | Core.waitGroup() ignores self parameter | pool.zig:244-247 | Open |
| Q-030 | Low | 12 | maintainability | Code duplication: nowNs()/Counter/updatePeak | multi-file | Open |
| Q-020 | Low | 8 | maintainability | version constant in root.zig unreferenced | root.zig:16 | Open |
| Q-021 | Low | 8 | cleanup | CODEOWNERS contains placeholder @your-username | CODEOWNERS:3 | **Superseded by QS-HYG sub-task** |
| Q-027 | Low | 8 | readability | Magic sentinel 0xFFFFFFFF raw literal — residual at pool.zig:699 (free_sentinel exists :2304) | [#62](https://gitlab.com/devnw/zig/thread-pool/-/issues/62) | Open — residual at pool.zig:699 |

> **Closed 2026-06-11 (removed from open list):** Q-028 ([#65](https://gitlab.com/devnw/zig/thread-pool/-/issues/65)), Q-029 ([#67](https://gitlab.com/devnw/zig/thread-pool/-/issues/67)), Q-006 (doc-only). See "Closed This Sweep (2026-06-11)" above for evidence.

## Findings by Category (2026-06-11 re-review pass)

### api-contract / reliability

- Q-NEW-02 (High, 60) — submitBatch waitable descriptor leak → pool exhaustion (#107)

### reliability / concurrency

- Q-NEW-08 (Medium, 36) — watchdog non-interruptible sleep blocks shutdown (#113)

### docs (accuracy)

- Q-NEW-03 (Medium, 36) — DESIGN.md phantom features (#108)
- Q-NEW-04 (Medium, 24) — steal_batch_size default 16 vs 8 (#109)
- Q-NEW-05 (Medium, 24) — `completion_only` phantom timestamp mode (#110)
- Q-NEW-06 (Medium, 24) — queue_capacity descriptor-bound overstated (#111)
- Q-NEW-07 (Medium, 24) — idle_park_after_ns mechanism inverted (#112)
- Q-NEW-09 (Low, 16) — parks/wakeups counter semantics (#114)
- Q-NEW-01 (Medium) — submitBatch wrapper "atomically" residual (folded into #59)

### observability / reliability

- Q-NEW-10 (Low, 16) — overflow_retires/active not updated on shutdown join (#115)

### maintainability / tests

- NEW-001 (Low, 16) — types.zig 978 lines > 800 threshold (#118)
- NEW-003 (Low, 24) — unit.zig 2s sleeps inflate suite (#120)
- NEW-002 (Low) — 7 files missing `//!` headers (folded into #34)

## Findings by Category (2026-04-16 pass)

### readability / maintainability

- QS-001 (High, 80) — pool.zig monolith split
- QS-003 (High, 64) — Core.runTask decomposition
- QS-002 (High, 60) — Core.init decomposition
- QS-004 (Medium, 32) — enqueuePush simplification
- QS-005 (Medium, 24) — statsSnapshot/nextTask/idle helpers
- QS-020 (Medium, 16) — subsumed

### docs / api-contract

- QS-008 (High, 60) — types.zig doc coverage
- QS-009 (Medium, 36) — facade doc gaps
- QR-003 (Medium, 36) — ConfigError set
- QR-004 (Medium, 36) — Submit/Wait/Shutdown/Register/Purge sets
- QR-005 (Medium, 24) — SubmitOptions + .block footgun
- QR-006 (Medium, 24) — Stats.worker_stats aliasing
- QR-009 (Medium, 32) — module //! headers

### tests / reliability

- QR-001 (High, 48) — unit tests for lanes/watchdog/overflow
- QR-002 (High, 48) — -Dsingle-pool CI gate
- QR-007 (Medium, 24) — injectable clock
- QS-015 (Medium, 24) — ASan CI
- QS-016 (Medium, 24) — coverage instrumentation
- QS-018 (Medium, 24) — pre-commit size/complexity gate

### hygiene

- QS-HYG (Medium, 24) — cluster meta: CODEOWNERS, SECURITY.md, Makefile/zig-0.15.2, stray binaries, topology.zig

## Remediation Roadmap

### 2026-06-11 Re-Review Pass

**Fix first (correctness/reliability):**

| ID | Fix | Effort | Issue |
|----|-----|--------|-------|
| Q-NEW-02 | Reject (or strip+document) `waitable` in submitBatch; add exhaustion test | S | #107 |
| Q-NEW-08 | Stop-condvar `timedWait` for watchdog, or document worst-case shutdown delay | S-M | #113 |

**Quick doc wins (< 1 day; batchable into one DESIGN.md/types.zig pass):**

| ID | Fix | Effort | Issue |
|----|-----|--------|-------|
| Q-NEW-03 | Delete Runtime Presets + dual wake-strategy framing from DESIGN.md | S | #108 |
| Q-NEW-04 | Fix steal_batch_size default (16 → 8) | S | #109 |
| Q-NEW-05 | Drop `completion_only` from DESIGN.md + ALGORITHMS.md | S | #110 |
| Q-NEW-06 | Fix queue_capacity descriptor-bound doc | S | #111 |
| Q-NEW-07 | Reword idle_park_after_ns (timedWait timeout, not spin) | S | #112 |
| Q-NEW-01 | Rewrite submitBatch wrapper doc (drop "atomically") | S | #59 |
| Q-NEW-09 | Reword parks/wakeups counter docs | S | #114 |
| Q-027 | Replace raw `0xFFFFFFFF` at pool.zig:699 with `free_sentinel` | S | #62 |
| QR-005 | Cross-reference `.block` footgun from submit/submitBatch method docs | S | #49 |

**Low / structural:**

| ID | Fix | Effort | Issue |
|----|-----|--------|-------|
| NEW-003 | Shrink unit.zig timeout sleeps 2s → ~100ms | S | #120 |
| Q-NEW-10 | Update overflow counters on shutdown join (or doc caveat) | S | #115 |
| NEW-002 | Add `//!` headers to 7 remaining modules | S | #34 |
| NEW-001 | Split types.zig into config/stats/lane submodules | M | #118 |

### 2026-04-16 Pass

#### Quick Wins (< 1 day each)

| ID | Fix | Effort | Issue |
|----|-----|--------|-------|
| QR-002 | Add `test-single-pool` CI job + comptime assertion | S | #28 |
| QR-003 | Declare ConfigError; update validate signature | S | #41 |
| QS-009 | /// on ThreadPool.init / register / release | S | #31 |
| QR-005 | /// on SubmitOptions documenting .block footgun | S | #49 |
| QR-009 | //! headers on pool.zig + types.zig | S | #58 |
| QS-018 | Pre-commit size gate script | S | #73 |
| QS-HYG | Individual sub-tasks (CODEOWNERS, SECURITY.md, stray binaries) | S each | #77 |

#### Medium (1-5 days)

| ID | Fix | Effort | Issue |
|----|-----|--------|-------|
| QS-002 | Decompose Core.init | M | #16 |
| QS-003 | Decompose Core.runTask (perf-gated) | M | #18 |
| QS-004 | Simplify enqueuePush | M | #34 |
| QS-005 | Extract statsSnapshot / nextTask / idle helpers | M | #45 |
| QS-008 | Doc 24 types.zig public symbols | M | #21 |
| QR-001 | 6 new unit tests + injectable clock | M | #24 |
| QR-004 | Explicit error sets through facade | S-M | #43 |
| QR-006 | Fix or document Stats.worker_stats aliasing | S-M | #53 |
| QR-007 | Injectable clock / watchdogTick | M | #61 |
| QS-015 | ASan build option + scheduled job | S-M | #66 |
| QS-016 | kcov pipeline | M | #69 |

#### Strategic (> 5 days)

| ID | Fix | Effort | Issue |
|----|-----|--------|-------|
| QS-001 | Split pool.zig into 5 files | L | #14 |

## Scoring Methodology

```text
PriorityScore = Impact(1-5) * Likelihood(1-5) * 4
```

- **Impact**: 5=outage/UB, 4=frequent bugs/major dev drag, 3=moderate, 2=minor, 1=polish.
- **Likelihood**: 5=ubiquitous/touched often, 4=often encountered, 3=sometimes, 2=rare, 1=edge-case.
- **Range**: 4 (lowest) to 100 (highest).
- **Cutoff**: High severity auto-qualifies for a tracked issue regardless of score. Medium qualifies at score >= 24 with `confidence::confirmed`. Low only escalates to an issue if trivially fixable AND part of a cluster (see QS-HYG).
- All new findings tagged `confidence::confirmed` except QR-008 (`confidence::suspected`, not tracked).
