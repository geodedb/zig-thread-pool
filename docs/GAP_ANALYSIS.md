# GAP Analysis

Last refreshed: 2026-06-11 (remediation pass: 40+ gaps closed across security, quality, performance, and infra tracks; commit `791604c` and prior; see `docs/GAP_ANALYSIS_RESOLVED.md` for full 2026-06-11 section). Prior gap-sync: AppSec review `docs/APPSEC_REVIEW_2026-06-11_src.md` + security-review findings synced to GitLab; commit `39528a3`). Prior refresh 2026-04-16.

This file mirrors the GitLab issue tracker at
`devnw/zig/thread-pool`; the tracker is authoritative. Resolved gaps are
archived in `docs/GAP_ANALYSIS_RESOLVED.md`.

## Summary

This repository provides a bounded, reusable, observable thread-pool for `devnw/zig`.
The implementation establishes fixed-size workers, bounded descriptors, bounded
queues, three scheduler variants (`global_queue`, `work_stealing`,
`lane_extension`), cross-platform memory sampling hooks, JSON benchmark output,
and a realistic / Tokio / Go runtime-comparison harness. Several requirements
and hardening items remain open and are tracked explicitly as GitLab issues.

## Scope

- standalone thread-pool library
- bounded task descriptors and queues
- `global_queue`, `work_stealing`, and `lane_extension` scheduler variants
- unit, integration, stress, fuzz, bench, and runtime-comparison harnesses
- cross-platform build and process-memory collection hooks

## Non-scope

- geode- or quic-specific application logic
- unbounded adaptive worker growth
- lock-free queue research prototypes beyond the shipped Vyukov/Chase-Lev pair
- production lane-aware scheduler specialisation beyond the shipped
  `lane_extension` variant and its Slices L1-L4b feature set

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

| Risk | Severity | Status | Tracking Issue | Notes |
| --- | --- | --- | --- | --- |
| Bounded memory policy not yet proven at larger runs | High | Open (Partial) | [#80](https://gitlab.com/devnw/zig/thread-pool/-/issues/80) | RISK-01 -- scheduled long-run suite outstanding |
| Default scheduler evidence is still from CI-safe scenarios only | High | Open (Partial) | [#81](https://gitlab.com/devnw/zig/thread-pool/-/issues/81) | RISK-02 -- refresh SCHEDULER_DECISION.md at scale |
| Worker-local cache purge policy is functional but not yet aggressively tuned | Medium | Open (Partial) | [#82](https://gitlab.com/devnw/zig/thread-pool/-/issues/82) | RISK-03 -- sweep `idle_purge_after_ns` |
| Adaptive sizing is not implemented | Informational | Accepted | -- | RISK-04 -- phase 2 non-goal |
| macOS and Windows memory metrics are compile-covered but not runner-validated | High | Open (Partial) | [#83](https://gitlab.com/devnw/zig/thread-pool/-/issues/83) | RISK-05 -- distinct from G-010 matrix gap |
| Alloc event histograms not yet distinct from byte accounting | Low | Open (Partial) | [#85](https://gitlab.com/devnw/zig/thread-pool/-/issues/85) | RISK-06 -- follow-up to DESIGN-03 |

## geode/quic Context

- geode has a known RSS regression under repeated QUIC connection churn.
- Recent analysis suggested a plateau around `~1158 MB`, potentially explainable as retained per-thread memory on the order of `~10 MB x 116 threads`.
- This library treats that as a hypothesis to test, not a confirmed root cause.
- The churn scenarios in the benchmark suite are intended to validate or refute retained-per-thread-state explanations with data. G-011 ([#11](https://gitlab.com/devnw/zig/thread-pool/-/issues/11)) was re-opened after the 2026-04-16 audit confirmed the scenario set is absent from `benchmarks/`.

## Open Gaps by Severity

Each row links to its canonical GitLab issue. Evidence paths are summarised;
see the issue body for full detail.

### High severity (open)

| Gap-ID | Title | Issue | Status | Evidence (summary) |
| --- | --- | --- | --- | --- |
| G-007 | Stats, timing histograms, process-memory metrics (umbrella) | [#7](https://gitlab.com/devnw/zig/thread-pool/-/issues/7) | Partial | `src/stats/`, `src/types.zig:378`; subtasks GAP-0031 + SEC-007 |
| G-011 | geode/quic-shaped regression scenarios | [#11](https://gitlab.com/devnw/zig/thread-pool/-/issues/11) | NotImplemented | Scenario set absent from `benchmarks/`; re-opened 2026-04-16 |
| NFR-003 | Umbrella: measurable allocator and RSS behavior | [#86](https://gitlab.com/devnw/zig/thread-pool/-/issues/86) | Partial | Core wired; GAP-0031 is the fix |
| RISK-01 | Bounded memory policy unproven at larger runs | [#80](https://gitlab.com/devnw/zig/thread-pool/-/issues/80) | Partial | Evidence gap; scheduled long-runs needed |
| RISK-02 | Default scheduler evidence CI-safe only | [#81](https://gitlab.com/devnw/zig/thread-pool/-/issues/81) | Partial | `docs/SCHEDULER_DECISION.md` |
| RISK-05 | macOS/Windows memory metrics not runner-validated | [#83](https://gitlab.com/devnw/zig/thread-pool/-/issues/83) | Partial | `src/stats/process_memory.zig` |

### Medium severity (open)

| Gap-ID | Title | Issue | Status | Evidence (summary) |
| --- | --- | --- | --- | --- |
| G-010 | Cross-platform build and test matrix (umbrella, absorbs CICD-01/02, NFR-002) | [#10](https://gitlab.com/devnw/zig/thread-pool/-/issues/10) | Partial | `.gitlab-ci.yml:105-146, 174-202` |
| GAP-0031 | Linux private_peak_bytes reports current not peak | [#17](https://gitlab.com/devnw/zig/thread-pool/-/issues/17) | NotImplemented | `src/stats/process_memory.zig:58` |
| SEC-007 | `scratch_init_failures` not surfaced in Stats (CWE-755) | [#19](https://gitlab.com/devnw/zig/thread-pool/-/issues/19) | NotImplemented | `src/pool.zig:1622-1624`, `src/types.zig:378` |
| SEC-008 | CI catalog components pinned by tag not SHA (CWE-829) | [#20](https://gitlab.com/devnw/zig/thread-pool/-/issues/20) | NotImplemented | `.gitlab-ci.yml:6-13, 36-42, 45-146` |
| SEC-011 | Descriptor fields non-atomic before queue push (CWE-362) | [#25](https://gitlab.com/devnw/zig/thread-pool/-/issues/25) | Partial | `src/pool.zig:1826-1836` |
| SEC-021 | Fuzz CI job `allow_failure=true` hides regressions (CWE-392) | [#22](https://gitlab.com/devnw/zig/thread-pool/-/issues/22) | NotImplemented | `.gitlab-ci.yml:102` |
| PERF-027 | Hot-path atomic overhead; counter duplication | [#47](https://gitlab.com/devnw/zig/thread-pool/-/issues/47) | Partial | `src/pool.zig` fetchAdd/fetchSub on globals |
| COMPTIME-ELISION (PERF-P-09) | Comptime elision flags for timestamp/scheduler/queue/lane | [#73](https://gitlab.com/devnw/zig/thread-pool/-/issues/73) | Partial | `-Dtimestamp-mode` + `-Dscheduler-variant` landed `c9a05e8`; `-Dqueue-kind` + `-Dlane-extension` deferred |
| Q-025 | `submitBatch` doc-comment says "atomically" but impl is sequential | [#59](https://gitlab.com/devnw/zig/thread-pool/-/issues/59) | NotImplemented | `src/pool.zig:2017` vs `src/pool.zig:594` |
| BENCH-02 | Larger conn-churn RSS-plateau evidence | [#76](https://gitlab.com/devnw/zig/thread-pool/-/issues/76) | NotImplemented | No `conn_churn` scenario (cf. G-011) |
| RISK-03 | Worker-local purge policy not tuned | [#82](https://gitlab.com/devnw/zig/thread-pool/-/issues/82) | Partial | `idle_purge_after_ns=5ms` default |
| GAP-9001 | Lane extension (Slices L1-L4b) retroactive tracking | [#87](https://gitlab.com/devnw/zig/thread-pool/-/issues/87) | Partial | Absorbs LANE-L4c; feature shipped |

### Low severity (open)

| Gap-ID | Title | Issue | Status | Evidence (summary) |
| --- | --- | --- | --- | --- |
| GAP-0027 | Scratch buffer not zeroed between tasks | [#33](https://gitlab.com/devnw/zig/thread-pool/-/issues/33) | NotImplemented | `src/memory/scratch.zig:61,70` |
| GAP-0031 | Linux `private_peak_bytes` reports current not peak (Windows RSS unimplemented) | [#17](https://gitlab.com/devnw/zig/thread-pool/-/issues/17) | Partial | `src/stats/process_memory.zig:57-58`; observed-peak tracking landed `7ab4358`; macOS/Windows contract alignment remains open |
| SEC-014 | `decrementQueued` fetchSub underflow (CWE-682) | [#27](https://gitlab.com/devnw/zig/thread-pool/-/issues/27) | Partial | `src/pool.zig:1930` |
| SEC-016 | `purgeWorkerCaches` TOCTOU (CWE-367) | [#29](https://gitlab.com/devnw/zig/thread-pool/-/issues/29) | Partial | `src/pool.zig:950-951` |
| SEC-018 (#30) | `queue_capacity` non-pow2 on 32-bit bypasses validation (CWE-682) | [#30](https://gitlab.com/devnw/zig/thread-pool/-/issues/30) | Partial | `src/types.zig:216` — distinct from confidential SEC-018 (#23, closed 2026-04-16) |
| PERF-018 | CI reinstalls Zig each job (no cache) | [#42](https://gitlab.com/devnw/zig/thread-pool/-/issues/42) | NotImplemented | `.gitlab-ci.yml:214-222` |
| PERF-025 | `submitInternal` backpressure backoff curve | [#44](https://gitlab.com/devnw/zig/thread-pool/-/issues/44) | NotImplemented | `src/pool.zig` `waitForCapacity` |
| PERF-028 | `LatencyHistogram.bucketIndex` -> `@clz` | [#48](https://gitlab.com/devnw/zig/thread-pool/-/issues/48) | NotImplemented | `src/stats/latency.zig:80-88` |
| PERF-030 | `WorkDeque` top/bottom false sharing | [#52](https://gitlab.com/devnw/zig/thread-pool/-/issues/52) | Partial | `src/queue/work_deque.zig` |
| PERF-031 | No 4+ worker scenarios in CI-safe bench | [#54](https://gitlab.com/devnw/zig/thread-pool/-/issues/54) | NotImplemented | `benchmarks/bench.zig` |
| Q-030 | Duplicated `nowNs` / `Counter` / `updatePeak` | [#70](https://gitlab.com/devnw/zig/thread-pool/-/issues/70) | NotImplemented | `src/pool.zig` + `src/stats/latency.zig` |
| CICD-03 | Automatic baseline benchmark refresh workflow | [#71](https://gitlab.com/devnw/zig/thread-pool/-/issues/71) | NotImplemented | `.gitlab-ci.yml` |
| DESIGN-02 | Waitable dedicated completion pool | [#72](https://gitlab.com/devnw/zig/thread-pool/-/issues/72) | NotImplemented | `src/pool.zig` |
| BENCH-01 | Validate scale-bench vs scheduled jobs | [#74](https://gitlab.com/devnw/zig/thread-pool/-/issues/74) | Partial | `benchmarks/scale_bench.zig` |
| BENCH-03 | CSV export for bench results | [#78](https://gitlab.com/devnw/zig/thread-pool/-/issues/78) | NotImplemented | `benchmarks/compare.zig` |
| RISK-06 | Alloc event histograms distinct from byte accounting | [#85](https://gitlab.com/devnw/zig/thread-pool/-/issues/85) | Partial | `Stats.total_alloc_count` scalar only; histogram work remains open (staleness note added `25665bb`) |

### Informational / Accepted

| Gap-ID | Title | Status | Notes |
| --- | --- | --- | --- |
| APPSEC-F008 | `-Dsingle-pool` comptime elision documented as unsafe with >1 pool | Accepted | `build.zig:36-43`, `src/pool.zig:17`, `CLAUDE.md` |
| RISK-04 | Adaptive sizing | Accepted non-goal | Documented in DESIGN.md |

## Recently Resolved (2026-06-11 remediation pass)

Full resolution entries in `docs/GAP_ANALYSIS_RESOLVED.md`.

| Gap-ID | Issue | Closure Commit | Notes |
| --- | --- | --- | --- |
| GAP-0036 / AP-01 | [#92](https://gitlab.com/devnw/zig/thread-pool/-/issues/92) | `df3832a` | `clock.zig` `.awake`; `sync.zig` timedWait `.awake`; `-\|` at `pool.zig` recordTaskStart/finalizeTask; monotonicity test |
| Q-NEW-02 / Q-025 | [#107](https://gitlab.com/devnw/zig/thread-pool/-/issues/107) / [#59](https://gitlab.com/devnw/zig/thread-pool/-/issues/59) | `01d7f6a` | submitBatch rejects waitable with `error.WaitableUnsupported`; wrapper doc fixed; "atomically" claim removed |
| PERF-NEW-03 | [#117](https://gitlab.com/devnw/zig/thread-pool/-/issues/117) | `29422be` | Escalating backoff spin→yield→sleep; `cancelDescriptor` on cap — no silent drop |
| GAP-0037 / AP-02 | [#93](https://gitlab.com/devnw/zig/thread-pool/-/issues/93) | `e2e7210` + `fd2aca7` | generation now `std.atomic.Value(u64)`; per-field reset avoids plain-store over atomics |
| GAP-0038 / AP-03 | [#94](https://gitlab.com/devnw/zig/thread-pool/-/issues/94) | `bf44fec` | Owner-thread contract documented on 4 APIs; cross-thread best-effort drain fallback; integration test |
| GAP-0039 / AP-04 | [#95](https://gitlab.com/devnw/zig/thread-pool/-/issues/95) | `7ab4358` | `quantileScaled` u128 widening + boundary test |
| GAP-0040 / AP-05 | [#96](https://gitlab.com/devnw/zig/thread-pool/-/issues/96) | `7ab4358` | `drainSubmitterDescCaches` in `deinitOwned` |
| GAP-0041 / AP-06 + Q-020 | [#97](https://gitlab.com/devnw/zig/thread-pool/-/issues/97) / [#56](https://gitlab.com/devnw/zig/thread-pool/-/issues/56) | `7ab4358` | `root.zig` version 0.2.4 + pinning test referencing the constant |
| Q-026 | [#60](https://gitlab.com/devnw/zig/thread-pool/-/issues/60) | `7ab4358` | `waitGroup` asserts running state, uses `self` |
| Q-NEW-10 | [#115](https://gitlab.com/devnw/zig/thread-pool/-/issues/115) | `7ab4358` | `joinAllWorkers` overflow accounting + integration test |
| SEC-020 | [#32](https://gitlab.com/devnw/zig/thread-pool/-/issues/32) | `c2b1446` | `spinLoopHint` in 6 CAS retry loops, failure-path-only placement |
| Q-027 | [#62](https://gitlab.com/devnw/zig/thread-pool/-/issues/62) | `c2b1446` | `free_sentinel` at Core scope, used everywhere incl. `initDescriptorFreelist` |
| GAP-0045 + GAP-0046 + GAP-0029 + SEC-002 + GAP-0034 + GAP-0030 | [#100](https://gitlab.com/devnw/zig/thread-pool/-/issues/100) / [#101](https://gitlab.com/devnw/zig/thread-pool/-/issues/101) / [#37](https://gitlab.com/devnw/zig/thread-pool/-/issues/37) / [#40](https://gitlab.com/devnw/zig/thread-pool/-/issues/40) / [#39](https://gitlab.com/devnw/zig/thread-pool/-/issues/39) / [#38](https://gitlab.com/devnw/zig/thread-pool/-/issues/38) | `3af7bec` | SECURITY.md versions/GitLab/UB-claim/owner; CODEOWNERS `@benjiv`; CHANGELOG date |
| Q-NEW-03 + Q-NEW-04 + Q-NEW-05 + Q-NEW-06 + Q-NEW-07 + Q-NEW-09 | [#108](https://gitlab.com/devnw/zig/thread-pool/-/issues/108)–[#112](https://gitlab.com/devnw/zig/thread-pool/-/issues/112) / [#114](https://gitlab.com/devnw/zig/thread-pool/-/issues/114) | `25665bb` | DESIGN.md phantom features removed, `steal_batch_size` 8, `completion_only` removed, `types.zig` docs corrected |
| QR-005 | [#49](https://gitlab.com/devnw/zig/thread-pool/-/issues/49) | `25665bb` | `.block` deadlock warning on submit wrapper |
| QR-003 + QR-004 | [#41](https://gitlab.com/devnw/zig/thread-pool/-/issues/41) / [#43](https://gitlab.com/devnw/zig/thread-pool/-/issues/43) | `e554f2b` | `ConfigError` 20 members; `SubmitError`/`SubmitBatchError`/`WaitError`/`ShutdownError`/`RegisterSubmitterError` on Core + ThreadPool; `root.zig` re-exports; 4 else-less switch tests |
| Q-NEW-08 | [#113](https://gitlab.com/devnw/zig/thread-pool/-/issues/113) | `e549ec7` | Watchdog condvar `timedWait`; broadcast at both stop sites; <2s deinit test |
| QR-009 + QS-009 + GAP-0044 | [#34](https://gitlab.com/devnw/zig/thread-pool/-/issues/34) / [#28](https://gitlab.com/devnw/zig/thread-pool/-/issues/28) | `0291001` | `//!` headers on 9 files; `///` on 8 Core methods + sync/clock fns |
| PERF-NEW-02 + PERF-NEW-09 + PERF-NEW-04 | [#99](https://gitlab.com/devnw/zig/thread-pool/-/issues/99) / [#124](https://gitlab.com/devnw/zig/thread-pool/-/issues/124) / [#119](https://gitlab.com/devnw/zig/thread-pool/-/issues/119) | `791604c` | 8 counter sites `.release`→`.monotonic`; `finalizeTask` guard comptime-foldable; `gitSha` hoisted ~168→1 forks |
| NEW-003 | [#120](https://gitlab.com/devnw/zig/thread-pool/-/issues/120) | `791604c` | Test sleeps 2s→500/300ms |
| GAP-0054 | [#103](https://gitlab.com/devnw/zig/thread-pool/-/issues/103) | `9c94036` | Makefile `ZIG?=zig`; script fallbacks removed |
| GAP-0042 | [#98](https://gitlab.com/devnw/zig/thread-pool/-/issues/98) | `9c94036` | `ubuntu:24.04` pinned `@sha256:786a8b...` with refresh procedure |
| GAP-0047 | [#102](https://gitlab.com/devnw/zig/thread-pool/-/issues/102) | `9c94036` | RUNTIME_COMPARISON.md Vendored Runtime Pins note; re-pin instruction lives in the doc |
| GAP-0057 | [#106](https://gitlab.com/devnw/zig/thread-pool/-/issues/106) | `9c94036` + `34fe026` | `HASH_RE` tightened, traversal guard, printable sanitization |
| QR-002 | [#24](https://gitlab.com/devnw/zig/thread-pool/-/issues/24) | `9c94036` | `zig-test-unit-single-pool-0.16.0` CI job; local run green |
| GAP-0056 | [#105](https://gitlab.com/devnw/zig/thread-pool/-/issues/105) | `61f88d2` | 2 integration tests; foot-gun confirmed FIXED by pre-existing `141d979` — noted in close comment |
| GAP-0055 | [#104](https://gitlab.com/devnw/zig/thread-pool/-/issues/104) | `61f88d2` | Fuzz 3-variant rotation via `seed%3` + `FUZZ_SCHEDULER` override; WaitGroup op; header updated |

## Previously Resolved (2026-04-16 gap-closure sweep)

Full resolution entries in `docs/GAP_ANALYSIS_RESOLVED.md`.

| Gap-ID | Issue | Closure Commit | Notes |
| --- | --- | --- | --- |
| SEC-018 (F-008 confidential) | [#23](https://gitlab.com/devnw/zig/thread-pool/-/issues/23) | `57f77f7` | CAS-guarded `TaskHandle.wait()` against double-release |
| REV-001 | [#35](https://gitlab.com/devnw/zig/thread-pool/-/issues/35) | `5faccb5` | Panic contract documented + skew observability; ADR at `docs/security/REV-001.md` |
| QS-008 | [#18](https://gitlab.com/devnw/zig/thread-pool/-/issues/18) | `429caab` | 24 public symbols now documented; `grep -c '^///' src/types.zig` = 159 |
| QS-002 | [#15](https://gitlab.com/devnw/zig/thread-pool/-/issues/15) | `301392b` | `Core.init` decomposed 147 → 60 lines; F-002 errdefer preservation verified |
| QS-003 | [#16](https://gitlab.com/devnw/zig/thread-pool/-/issues/16) | `a0259e6` | Hot-path `Core.runTask` decomposed; paired A/B: +16.3% conn_churn_seq / +11.7% producer_contention |
| OBSERVABILITY-PIVOT | [#46](https://gitlab.com/devnw/zig/thread-pool/-/issues/46) | `3356d1d` / `a39092a` / `7c9d2e6` / `5561a46` / `e75f4e0` / `f1e7b67` | R-01/R-02/R-03/R-06/R-10 all landed |

## Duplicates / Conflict Resolutions (2026-04-16 audit)

- **GAP-0031** absorbs Q-024 (same Linux `RssAnon` vs `VmHWM` bug).
- **GAP-0032** absorbs Q-023 (deinitOwned accounting) -- resolved, see RESOLVED doc.
- **SEC-007** absorbs GAP-0022 (`beginTask` error counted but not surfaced).
- **G-010** absorbs CICD-01, CICD-02, NFR-002 (macOS/Windows runners + compile matrix).
- **GAP-9001** absorbs LANE-L4c (lane-extension retroactive tracking).
- **Q-028** and **Q-029** remain distinct (different DESIGN.md paragraphs).
- **G-011** re-opened: `docs/GAP_ANALYSIS_RESOLVED.md:49-55` had claimed closure;
  scan shows the scenario names never landed.

## Security Risk Assessment (post-AppSec-remediation 2026-04-15; remediation pass 2026-06-11)

All three Critical + High memory-safety findings (SEC-005, SEC-017, SEC-004,
SEC-003) closed in commits `de49d69` / `bace578` / `214ca3c`. TSan and fuzz
runs clean. See `docs/performance/appsec-fixes-2026-04-15/FINAL.md` for the
honest 5-12% throughput cost.

**AppSec review 2026-06-11 (`docs/APPSEC_REVIEW_2026-06-11_src.md`, commit
`39528a3`):** re-verified all prior Critical/High findings + the
`submitter_free_mask` shift-UB bug + F-004…F-011 as fixed and not regressed;
the `39528a3` WaitGroup broadcast guard is correct and race-free.

**2026-06-11 remediation pass:** AP-01 (GAP-0036 clock underflow panic-DoS),
AP-02 (GAP-0037 non-atomic generation), AP-03 (GAP-0038 cross-thread DescCache),
AP-04 (GAP-0039 overflow), AP-05 (GAP-0040 DescCache drain), GAP-0042 (base-image
pin), GAP-0054 (Makefile fallback), GAP-0055 (fuzz coverage), GAP-0056 (integration
test for drain foot-gun), GAP-0057 (detect_diamond_deps hardening), SEC-020
(spinLoopHint), GAP-0045/0046 (SECURITY.md), GAP-0029/0030/0034 (repo hygiene),
GAP-0047 (Go submodule note) all closed. **No Critical or High security findings
remain open.** Remaining open security items: SEC-008 (CI tag pinning), SEC-021
(fuzz job `allow_failure`), SEC-007, SEC-011.

Outstanding security items tracked on GitLab (not duplicated here). Snapshot
of `kind::security` status counts after 2026-06-11 remediation pass:

| Severity | Open | Partial | Total |
| --- | ---: | ---: | ---: |
| Critical | 0 | 0 | 0 |
| High | 0 | 0 | 0 |
| Medium | 3 | 1 | 4 |
| Low | 4 | 3 | 7 |
| Info | 0 | 0 | 0 |

Top open security items: SEC-008 (CI tag pinning), SEC-021 (fuzz job
`allow_failure`), SEC-007 (scratch init failures observability), SEC-011
(latent descriptor ordering).

## Cross-platform Status

| Platform | Status | Notes |
| --- | --- | --- |
| Linux | Running locally | Benchmarks and tests exercised |
| macOS | Compile-target wired | Native runner validation pending (#10, #83) |
| Windows | Compile-target wired | Native runner validation pending (#10, #83) |

## Next Review Date

2026-07-11

## Revision History

| Date | Phase | Changes |
| --- | --- | --- |
| 2026-04-11 | Phase 1-3 | Initial gap analysis and security assessment |
| 2026-04-11 | Phase 4 | Deep-dive audit: GAP-0011 through GAP-0022 |
| 2026-04-11 | Phase 5 | Full audit: 10 gaps resolved, 2 partial, 13 new gaps (GAP-0023 through GAP-0035); security assessment updated (8 findings resolved, 8 open) |
| 2026-04-11 | Phase 6 | Security assessment refresh: 7 findings resolved (SEC-001/002/006/009/010/012/013/015); SEC-005 upgraded Critical; SEC-017 added Critical; 5 new findings added (SEC-017/018/019/020/021); SEC-004/007 confirmed Partial |
| 2026-04-11 | Phase 7 | Gap closure: 9 findings closed (SEC-017, SEC-005, SEC-004, SEC-003, GAP-0017, GAP-0024, GAP-0025, GAP-0033, GAP-0035, PERF-002, PERF-011, PERF-022, PERF-023, Q-022). All Critical and High security findings resolved. |
| 2026-04-15 | AppSec remediation | F-001/F-005/F-008 closed; honest 5-12% throughput cost documented |
| 2026-04-16 | Gap sync | Canonical gap set rebuilt (75 -> 38 distinct after dedup). Closed G-001..G-006, G-008, G-009, G-012, G-013 on GitLab. Re-opened G-011. Minted GAP-9001 for LANE-L4b retroactive tracking. Created 30+ GitLab issues for open findings; tables in this file now link to them. |
| 2026-06-11 | Gap sync | Synced AppSec review (`docs/APPSEC_REVIEW_2026-06-11_src.md`) + security-review findings at commit `39528a3`. Created GAP-0036…0042, 0045…0047, 0054…0057 (14 GitLab issues #92-#98, #100-#106). Refreshed evidence on GAP-0031 (#17), G-010 (#10), Q-027 (#62), GAP-0029 (#37), RISK-06 (#85). Closed PERF-029 (#51, condvar-based drain). Noted Q-004 resolved as dup of GAP-0014 (no issue). |
| 2026-06-11 | Remediation pass | Closed 40+ gaps across security (GAP-0036..0042, 0045..0047, 0054..0057, SEC-002/020, GAP-0029/0030/0034), quality (Q-NEW-01..10, Q-020/025..027, QR-002..005/009, QS-009, NEW-003, GAP-0044), and performance (PERF-NEW-02..04/09) tracks. GAP-0031 reduced scope (observed-peak landed, Windows RSS remains open). RISK-06 staleness note added. 40 GitLab issues closed (#32, #37..43, #49, #56, #59, #60, #62, #92..100, #102..117, #119, #120, #124). See `docs/GAP_ANALYSIS_RESOLVED.md` § "2026-06-11 Remediation Pass". |
