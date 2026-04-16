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

From the 2026-04-15 post-AppSec-remediation run under Zig 0.16.0 (`6` retained
samples after `1` warmup discard, `56` workers). Raw artifact:
`docs/performance/appsec-fixes-2026-04-15/FINAL-runtime-comparison.json`.

### Throughput (ops/sec)

| Scenario | Zig thread-pool | Tokio | Go | Zig vs Go |
|---|---:|---:|---:|---:|
| `flood_1m` | 1,074,269 | 504,907 | 1,016,708 | 1.06x ahead |
| `contended_spawn_8x` | 880,038 | 655,249 | 4,161,629 | 4.73x behind |
| `cpu_work_10us` | 982,714 | 506,030 | 792,213 | 1.24x ahead |
| `cpu_work_100us` | 416,921 | 380,130 | 441,693 | 1.06x behind |
| `contended_cpu_10us` | 970,439 | 579,571 | 2,546,602 | 2.62x behind |
| `nested_fanout_4x` | 538,931 | 1,306,493 | 4,584,906 | 8.51x behind |
| `burst_drain_burst` | 162,024 | 141,206 | 151,406 | 1.07x ahead |
| `mixed_fast_slow` | 230,765 | 244,296 | 248,029 | 1.07x behind |

### Latency (p50/p95/p99, microseconds)

| Scenario | Zig | Tokio | Go |
|---|---|---|---|
| `cpu_work_10us` | 45/226/301 | 30/74/105 | 33/114/208 |
| `cpu_work_100us` | 1848/3474/3656 | 1402/2925/3010 | 1099/2479/3668 |
| `contended_cpu_10us` | 27/137/192 | 27/223/313 | 34/336/416 |
| `nested_fanout_4x` | 12/61/95 | 6/18/37 | 4/27/62 |
| `burst_drain_burst` | 790/1546/1660 | 757/1196/1255 | 592/1032/2313 |
| `mixed_fast_slow` | 10396/18086/19754 | 4138/8341/11382 | 8575/14882/15886 |

### Interpretation

- Zig wins 3 of 8 scenarios against Go on throughput and 6 of 8 against Tokio.
- Zig has the best contended per-task latency: p50=27µs on `contended_cpu_10us`
  with the lowest p95/p99 of all three runtimes on that scenario — more
  predictable scheduling than Go's 34/336/416.
- Go's in-runtime local-P queue continues to win contended/nested scenarios;
  Tokio wins `nested_fanout_4x` and `mixed_fast_slow` via fiber amortisation.
- Wake coalescing (`wake_coalesce_batch=32`) and per-submitter queues
  (`registerSubmitter` API) remain the key architectural features driving wins.
- Deltas vs the prior 0.15.2 snapshot are tracked in
  [`docs/performance/appsec-fixes-2026-04-15/FINAL.md`](docs/performance/appsec-fixes-2026-04-15/FINAL.md),
  which also carries the same-compiler bisect (pre-appsec `e9b6b2a` vs
  post-appsec `8cf119d`, both zig 0.16). **Honest remediation cost: 5–12%
  throughput regression on six of eight scenarios, accepted as the price
  of closing 1 Critical + 2 High memory-safety bugs. TSan + fuzz are clean.**
  Raw data: `BISECT-e9b6b2a-runtime-comparison.json`.
- Single-pool workloads can opt in to `-Dsingle-pool=true` to elide the
  F-001 hot-path identity check at compile time. Reliably recovers 6–17%
  on `contended_spawn_8x`, `cpu_work_100us`, and `mixed_fast_slow`.
  **UNSAFE with multiple pools in one process** — restores the pre-F-001
  OOB hazard for the index-within-bounds case. See
  [`FINAL.md § Optimisation pass`](docs/performance/appsec-fixes-2026-04-15/FINAL.md#optimisation-pass----dsingle-pool-comptime-elision).

## Docs Entry Points

- `docs/README.md`
- `docs/TESTING.md`
- `docs/RUNTIME_COMPARISON.md`
- `docs/PERFORMANCE_TRACKING.md`
- `docs/HANDOFF-2026-04-14.md`
