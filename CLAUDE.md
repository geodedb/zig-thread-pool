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

From the 2026-04-17 post-Go-gap-contended-plan run under Zig 0.16.0 at commit
`7e125a9` (7 retained samples after 1 warmup discard, 56 workers). Raw
artifact: `benchmarks/results/runtime-comparison-latest.json`.

### Throughput (ops/sec)

| Scenario | Zig thread-pool | Tokio | Go | Zig vs Go |
|---|---:|---:|---:|---:|
| `flood_1m` | 1,019,969 | 415,760 | 870,285 | 1.17x ahead |
| `contended_spawn_8x` | 1,219,948 | 621,531 | 2,688,569 | 2.20x behind |
| `cpu_work_10us` | 1,165,591 | 506,882 | 799,481 | 1.46x ahead |
| `cpu_work_100us` | 489,063 | 290,187 | 397,426 | 1.23x ahead |
| `contended_cpu_10us` | 1,059,079 | 611,188 | 2,573,706 | 2.43x behind |
| `nested_fanout_4x` | 1,067,206 | 1,144,458 | 4,140,608 | 3.88x behind |
| `burst_drain_burst` | 160,572 | 138,427 | 146,181 | 1.10x ahead |
| `mixed_fast_slow` | 226,845 | 166,580 | 249,187 | 1.10x behind |

### Latency (p50/p95/p99, microseconds)

| Scenario | Zig | Tokio | Go |
|---|---|---|---|
| `cpu_work_10us` | 74/276/341 | 26/75/268 | 54/305/579 |
| `cpu_work_100us` | 929/2019/2251 | 3294/5289/5455 | 2167/3409/4666 |
| `contended_cpu_10us` | 57/380/469 | 40/320/399 | 167/902/1312 |
| `nested_fanout_4x` | 21/176/702 | 5/18/44 | 3/35/71 |
| `burst_drain_burst` | 795/1608/1712 | 803/1313/1552 | 901/1289/1491 |
| `mixed_fast_slow` | 8588/17080/17914 | 14690/25057/26717 | 7652/11708/12490 |

### Interpretation

- Zig wins **4 of 8** scenarios against Go on throughput (`flood_1m`,
  `cpu_work_10us`, `cpu_work_100us`, `burst_drain_burst`) and **7 of 8**
  against Tokio (only `nested_fanout_4x` is a Tokio win — fiber
  amortisation).
- `nested_fanout_4x` narrowed from 6.19x behind Go → 3.88x behind, and
  absolute Zig throughput nearly doubled (573K → 1,067K ops/s). This is the
  headline result of the 2026-04-16 Go-gap-contended plan: per-Worker
  `DescCache` reduces global-freelist CAS traffic on worker-context submits.
- `contended_spawn_8x` narrowed from 3.86x behind → 2.20x behind, driven by
  the Phase-2 per-submitter `DescCache`. Paired same-session A/B vs Phase-0
  baseline: +35.98%.
- Go's in-runtime local-P queue continues to dominate `contended_spawn_8x`,
  `contended_cpu_10us`, and `nested_fanout_4x` on throughput — closing the
  remaining 2.2–3.9x gap would require attacking Go's fiber-stack
  amortisation, which is out-of-scope for this library's API constraints.
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
