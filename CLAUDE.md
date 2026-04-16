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

From the 2026-04-16 post-contended-scenarios gap-close run under Zig 0.16.0
at commit `d357bd9` (`6` retained samples after `1` warmup discard, `56`
workers). Raw artifact:
`benchmarks/results/runtime-comparison-latest.json`.

### Throughput (ops/sec)

| Scenario | Zig thread-pool | Tokio | Go | Zig vs Go |
|---|---:|---:|---:|---:|
| `flood_1m` | 1,003,787 | 546,717 | 1,346,758 | 1.34x behind |
| `contended_spawn_8x` | 912,471 | 668,275 | 3,522,449 | 3.86x behind |
| `cpu_work_10us` | 1,122,190 | 708,482 | 797,355 | 1.41x ahead |
| `cpu_work_100us` | 491,989 | 301,782 | 409,109 | 1.20x ahead |
| `contended_cpu_10us` | 1,068,299 | 710,214 | 2,426,316 | 2.27x behind |
| `nested_fanout_4x` | 573,365 | 1,918,439 | 3,550,322 | 6.19x behind |
| `burst_drain_burst` | 162,250 | 141,537 | 146,406 | 1.11x ahead |
| `mixed_fast_slow` | 234,390 | 246,336 | 237,386 | 1.01x behind |

### Latency (p50/p95/p99, microseconds)

| Scenario | Zig | Tokio | Go |
|---|---|---|---|
| `cpu_work_10us` | 66/274/348 | 20/100/190 | 34/148/342 |
| `cpu_work_100us` | 922/2231/2469 | 3235/4969/5114 | 1451/1920/2195 |
| `contended_cpu_10us` | 22/179/258 | 30/255/329 | 424/734/888 |
| `nested_fanout_4x` | 6/37/58 | 4/13/54 | 5/49/139 |
| `burst_drain_burst` | 687/1516/1666 | 783/1418/1564 | 1075/1444/1559 |
| `mixed_fast_slow` | 10590/17232/18128 | 9068/15292/16714 | 4036/8379/12249 |

### Interpretation

- Zig wins **3 of 8** scenarios against Go on throughput (`cpu_work_10us`,
  `cpu_work_100us`, `burst_drain_burst`) and **6 of 8** against Tokio
  (`nested_fanout_4x` and `mixed_fast_slow` are the Tokio wins — fiber
  amortisation).
- Zig retains the best contended per-task latency: p50=22µs on
  `contended_cpu_10us` beating Tokio (30µs) and Go (424µs) by wide margins,
  with the lowest p95/p99 across all three runtimes.
- Nested-fanout p50 halved from 12µs → 6µs (Zig) as the Phase-1 submitter
  registration (below) shifted the main thread off the shared inject queue
  onto an SPSC slot — visible in latency as well as throughput.
- Go's in-runtime local-P queue continues to dominate `contended_spawn_8x`,
  `contended_cpu_10us`, and `nested_fanout_4x` on throughput.
- **2026-04-16 contended-scenarios gap-close** (commits `6029c06..d357bd9`)
  added `registerSubmitter()` calls in `benchmarks/runtime_compare_zig.zig`
  for `contended_cpu_10us` (submitter threads) and for the main thread in
  `nested_fanout_4x` and `mixed_fast_slow`, then plumbed
  `register_submitters: bool` through `benchmarks/common.zig` so
  `bench-realistic` uses the same fairness path. Isolated same-session
  paired A/B deltas on the same ReleaseFast binary: `contended_spawn_8x`
  +7.8%, `contended_cpu_10us` +4.6%, `nested_fanout_4x` +22.7%,
  `mixed_fast_slow` +10.9%. No `src/` changes — pure harness fairness fix
  that exercises the already-shipped per-submitter SPSC queues. Phase-2
  profile-driven `src/` attacks were skipped: `perf_event_paranoid=3`
  blocked `perf record` without sudo, and the three relevant closed-plane
  memories (notifySubmits iter 7–11 + Slice 3a) already rule out the
  plausible attack surface. See
  [`docs/performance/contended-scenarios-2026-04-16/FINAL.md`](docs/performance/contended-scenarios-2026-04-16/FINAL.md).
- Wake coalescing (`wake_coalesce_batch=32`) and per-submitter queues
  (`registerSubmitter` API) remain the key architectural features driving
  the Tokio wins and narrowing the Go gap.
- **Host-state caveat:** Go throughput moved +30% to +75% higher on this
  snapshot vs the 2026-04-15 snapshot (`flood_1m` 772K → 1.35M,
  `contended_cpu_10us` 1.81M → 2.43M) — thermal / CPU-frequency drift, not
  a Go change. `flood_1m` therefore flipped from Zig 1.25x ahead to 1.34x
  behind on cross-snapshot math, but the Zig number itself moved only +4%.
  Read multipliers within a single snapshot; absolute Zig deltas vs
  2026-04-15 mix Phase-1 gains with host drift and cannot be cleanly
  separated.
- QS-003 `Core.runTask` decomposition landed at `a0259e6` with a same-session
  paired A/B showing +16.3% / +11.7% on CI-safe scenarios vs the immediate
  predecessor commit — baked into the Zig numbers here.
- Deltas vs the prior 0.15.2 snapshot are tracked in
  [`docs/performance/appsec-fixes-2026-04-15/FINAL.md`](docs/performance/appsec-fixes-2026-04-15/FINAL.md),
  which also carries the same-compiler bisect (pre-appsec `e9b6b2a` vs
  post-appsec `8cf119d`, both zig 0.16). **Honest remediation cost: 5–12%
  throughput regression on six of eight scenarios, accepted as the price
  of closing 1 Critical + 2 High memory-safety bugs. TSan + fuzz are clean.**
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
