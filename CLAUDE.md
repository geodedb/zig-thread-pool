# Claude Notes

## Repository Summary

`thread-pool` is a Zig `0.16.0` library that exposes a bounded thread pool with
`global_queue`, `work_stealing`, and `lane_extension` scheduler variants behind
one API.

The most important directories are:

- `src/` for the pool, types, queues, and stats implementations
- `tests/` for unit, integration, and stress coverage
- `benchmarks/` for the CI-safe suite, scale suite, Tokio-parity bench, and
  direct runtime comparison harness
- `docs/` for design, testing, performance tracking, and handoff notes
- `third_party/tokio` and `third_party/go` for pinned runtime comparisons

## Validation Commands

Run the standard suites from the repository root:

```bash
zig build test --summary all
zig build test-integration --summary all
zig build test-stress --summary all
zig build test-all --summary all
```

Make targets wrap the same flow:

```bash
make test
make test-stress
make ci
```

## Benchmark Commands

```bash
zig build bench -- --output benchmarks/results/latest.json
zig build scale-bench -- --output benchmarks/results/scale-latest.json
zig build bench-tokio-parity -Doptimize=ReleaseFast
zig build bench-realistic -Doptimize=ReleaseFast
zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output benchmarks/results/runtime-comparison-latest.json
```

`bench-realistic` runs latency-focused scenarios (cpu_work, contended,
nested fanout, burst-drain, mixed fast/slow, lane isolation) against this
pool only. It exercises realistic task durations, fairness, and lanes.

`bench-runtime-compare` runs the same scenarios (minus lane isolation) across
this pool, Tokio, and Go from vendored source trees.

The Go comparison path intentionally unsets ambient `GOROOT` so the benchmark
uses the vendored Go checkout instead of the host installation.

## Current Direct Runtime Snapshot

From the 2026-04-17 post-Go-gap-round-2-revert run under Zig 0.16.0 at commit
`acb715d` (code tree byte-identical to `a666ec3` / Go-gap round 1 FINAL; the
Go-gap round 2 plan's Phase 1 and Phase 2 both failed kill gates and were
reverted). 7 retained samples after 1 warmup discard, 56 workers. Raw
artifact: `benchmarks/results/runtime-comparison-latest.json`.

Note (2026-06-11): this snapshot predates the 2026-06-11 audit-remediation pass
(branch audit-2026-06-11, ~20 commits touching pool.zig/clock.zig/sync.zig/stats);
re-run bench-runtime-compare to refresh before using these numbers for decisions.

### Throughput (ops/sec)

| Scenario | Zig thread-pool | Tokio | Go | Zig vs Go |
|---|---:|---:|---:|---:|
| `flood_1m` | 860,073 | 343,795 | 679,626 | 1.27x ahead |
| `contended_spawn_8x` | 1,141,570 | 607,149 | 3,042,676 | 2.67x behind |
| `cpu_work_10us` | 1,070,750 | 449,018 | 554,179 | 1.93x ahead |
| `cpu_work_100us` | 480,783 | 309,121 | 416,573 | 1.15x ahead |
| `contended_cpu_10us` | 1,244,836 | 621,083 | 1,783,701 | 1.43x behind |
| `nested_fanout_4x` | 1,127,801 | 1,392,766 | 2,954,402 | 2.62x behind |
| `burst_drain_burst` | 160,994 | 142,510 | 141,912 | 1.13x ahead |
| `mixed_fast_slow` | 258,541 | 231,506 | 252,541 | 1.02x ahead |

### Latency (p50/p95/p99, microseconds)

| Scenario | Zig | Tokio | Go |
|---|---|---|---|
| `cpu_work_10us` | 38/206/299 | 21/75/281 | 38/129/262 |
| `cpu_work_100us` | 1867/3465/3603 | 3245/5085/5199 | 1680/2187/3957 |
| `contended_cpu_10us` | 113/429/511 | 34/423/489 | 424/796/1139 |
| `nested_fanout_4x` | 23/163/550 | 6/19/104 | 6/100/261 |
| `burst_drain_burst` | 672/1574/1704 | 1159/1886/2081 | 765/1248/1436 |
| `mixed_fast_slow` | 9179/15818/16741 | 9604/17039/19174 | 6297/9925/11699 |

### Interpretation

- Zig wins **5 of 8** scenarios against Go on throughput (`flood_1m`,
  `cpu_work_10us`, `cpu_work_100us`, `burst_drain_burst`, `mixed_fast_slow`)
  and **7 of 8** against Tokio (only `nested_fanout_4x` is a Tokio win —
  fiber amortisation). Previously 4 of 8 vs Go; `mixed_fast_slow` flipped
  from 1.10x behind to 1.02x ahead — within noise, not a real Zig gain, but
  the scenario sits on the parity line and both directions are common.
- Go's in-runtime local-P queue continues to dominate `contended_spawn_8x`,
  `contended_cpu_10us`, and `nested_fanout_4x` on throughput. The Go-gap
  round 2 plan (2026-04-17) attacked these three scenarios via (Phase 1)
  `lifo_slot` rotate semantics matching Go `runqput` / Tokio `LifoSlot`, and
  (Phase 2) batched `submitBatch` fast path collapsing N producer-push
  release-stores into one. **Both phases failed kill gates and were
  reverted**: Phase 1 delivered +0.83% on `nested_fanout_4x` vs +5% gate
  (noise-dominated); Phase 2 regressed `nested_fanout_4x` −19.68% with a
  bimodal B-leg distribution signaling structural contention under child-
  wave `submitBatch`. See
  [`docs/performance/2026-04-17-go-gap-round2/FINAL.md`](docs/performance/2026-04-17-go-gap-round2/FINAL.md)
  for full post-mortem.
- The remaining 1.4–2.7x Go gap on the three contended/nested scenarios is
  likely sustainable within this library's C-ABI-compatible design. Two
  speculative future directions (both out-of-scope of the failed round 2
  plan): a comptime opt-out of the per-Worker `DescCache` field for multi-
  submitter workloads (reclaim round-1 Phase-2's 1.33M ops/s `contended_*`
  ceiling at the cost of round-1 Phase-3's `nested_fanout_4x` gains), or
  accepting the 2.2–2.7x gap as structural.
- **2026-04-16 → 2026-04-17 Go-gap-contended plan** (commits
  `03d225d..7e125a9`) introduced a SPSC `DescCache` primitive
  (`src/pool/desc_cache.zig`, 32-entry LIFO, single-writer), a batched
  freelist take (`acquireDescriptorBatch`), and routed both per-submitter and
  per-worker descriptor acquires through it. Drain-on-release and
  drain-on-deinit preserve the `task_desc_live == 0` invariant. Same-session
  paired A/B deltas: Phase-1 `nested_fanout_4x` +44.8%; Phase-2 cumulative
  `contended_spawn_8x` +35.98%, `contended_cpu_10us` +31.71%,
  `nested_fanout_4x` +65.84%; Phase-3 cumulative `nested_fanout_4x` +81.26%
  (clears +18% gate at 4.51× margin). Phase-3 regresses −5 to −10% vs the
  Phase-2 checkpoint on contended submitter-thread scenarios (Worker size
  1912B → 2048B trade-off for the worker-end `DescCache` field) but remains
  strongly positive vs Phase-0. See
  [`docs/performance/2026-04-16-go-gap-contended/FINAL.md`](docs/performance/2026-04-16-go-gap-contended/FINAL.md).
- Wake coalescing (`wake_coalesce_batch=32`), per-submitter queues
  (`registerSubmitter` API), and now per-worker/per-submitter `DescCache`
  remain the architectural features driving the Tokio wins and narrowing
  the Go gap.
- **Host-state caveat:** Go's absolute throughput varies 30–75% across
  thermal cycles on this host, so cross-snapshot multipliers (Zig vs Go)
  mix real Zig deltas with Go's drift. Example: `contended_cpu_10us`
  "widened" 2.27x → 2.43x despite a +25.93% Zig gain because Go moved
  2.43M → 2.57M between snapshots. Read multipliers within a single
  snapshot; read Zig deltas from same-session paired A/Bs in the phase
  result docs.
- QS-003 `Core.runTask` decomposition landed at `a0259e6` with a same-session
  paired A/B showing +16.3% / +11.7% on CI-safe scenarios vs the immediate
  predecessor commit — baked into the Zig numbers here.
- Deltas vs the prior 0.15.2 snapshot are tracked in
  [`docs/performance/appsec-fixes-2026-04-15/FINAL.md`](docs/performance/appsec-fixes-2026-04-15/FINAL.md),
  which also carries the same-compiler bisect (pre-appsec `e9b6b2a` vs
  post-appsec `8cf119d`, both zig 0.16). **Honest remediation cost: 5–12%
  throughput regression on six of eight scenarios, accepted as the price
  of closing 1 Critical + 2 High memory-safety bugs. TSan + fuzz are clean.**
  A 2026-06-11 appsec pass (round 1 + round 2,
  docs/APPSEC_REVIEW_2026-06-11_src.md and
  docs/APPSEC_REVIEW_2026-06-11_round2.md) closed AP-01..AP-06 (monotonic
  clock, atomic generation, releaseSubmitter contract, u128 quantile, deinit
  drain, version derivation); one accepted Info residual remains (AP2-02,
  cross-thread release under contract violation).
- `thread_pool.version` is now derived from `build.zig.zon` via `build_options`
  (landed `ecbc1e6`, AP2-01 / AP-06 / Q-020).
- Single-pool workloads can opt in to `-Dsingle-pool=true` to elide the
  F-001 hot-path identity check at compile time. Reliably recovers 6–17%
  on `contended_spawn_8x`, `cpu_work_100us`, and `mixed_fast_slow`.
  **UNSAFE with multiple pools in one process** — restores the pre-F-001
  OOB hazard for the index-within-bounds case. See
  [`FINAL.md § Optimisation pass`](docs/performance/appsec-fixes-2026-04-15/FINAL.md#optimisation-pass----dsingle-pool-comptime-elision).
- Instrumented workloads can now opt in to `-Dtimestamp-mode=disabled` and
  `-Dscheduler-variant=<variant>` (landed 2026-04-16 as part of the
  COMPTIME-ELISION pass) to elide latency-histogram writes and scheduler-
  variant branches at compile time. Safe in all configurations.

## Docs Entry Points

- `docs/README.md`
- `docs/TESTING.md`
- `docs/RUNTIME_COMPARISON.md`
- `docs/PERFORMANCE_TRACKING.md`
- `docs/HANDOFF-2026-04-14.md`
