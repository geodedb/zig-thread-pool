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

From the 2026-04-16 post-gap-closure run under Zig 0.16.0 at commit `12713c6`
(`6` retained samples after `1` warmup discard, `56` workers). Raw artifact:
`benchmarks/results/runtime-comparison-latest.json`.

### Throughput (ops/sec)

| Scenario | Zig thread-pool | Tokio | Go | Zig vs Go |
|---|---:|---:|---:|---:|
| `flood_1m` | 963,839 | 416,659 | 772,343 | 1.25x ahead |
| `contended_spawn_8x` | 916,337 | 586,802 | 3,832,459 | 4.18x behind |
| `cpu_work_10us` | 1,108,351 | 621,393 | 915,517 | 1.21x ahead |
| `cpu_work_100us` | 460,103 | 310,785 | 420,725 | 1.09x ahead |
| `contended_cpu_10us` | 918,624 | 572,803 | 1,807,198 | 1.97x behind |
| `nested_fanout_4x` | 525,906 | 1,215,754 | 3,175,814 | 6.04x behind |
| `burst_drain_burst` | 164,180 | 140,736 | 145,028 | 1.13x ahead |
| `mixed_fast_slow` | 223,581 | 224,367 | 249,514 | 1.12x behind |

### Latency (p50/p95/p99, microseconds)

| Scenario | Zig | Tokio | Go |
|---|---|---|---|
| `cpu_work_10us` | 61/281/346 | 22/113/329 | 44/138/222 |
| `cpu_work_100us` | 2086/3649/3791 | 3123/4715/4826 | 2107/2709/2926 |
| `contended_cpu_10us` | 22/121/191 | 40/255/323 | 401/706/1297 |
| `nested_fanout_4x` | 12/61/110 | 7/22/137 | 5/25/55 |
| `burst_drain_burst` | 587/1426/1614 | 1488/2110/2835 | 1017/1364/1460 |
| `mixed_fast_slow` | 10731/19084/20488 | 9934/17068/19425 | 7030/11198/12578 |

### Interpretation

- Zig wins **4 of 8** scenarios against Go on throughput (up from 3/8 in the
  prior snapshot — `cpu_work_100us` flipped from 1.06x behind to 1.09x ahead)
  and **6 of 8** against Tokio.
- Zig has the best contended per-task latency: p50=22µs on `contended_cpu_10us`
  beating both Tokio (40µs) and Go (401µs) by a wide margin, with the lowest
  p95/p99 of all three runtimes — more predictable scheduling at the tail.
- Go's in-runtime local-P queue continues to win `contended_spawn_8x`,
  `contended_cpu_10us`, and `nested_fanout_4x`; Tokio wins `nested_fanout_4x`
  and `mixed_fast_slow` via fiber amortisation.
- Wake coalescing (`wake_coalesce_batch=32`) and per-submitter queues
  (`registerSubmitter` API) remain the key architectural features driving wins.
- **Host-state caveat:** Tokio and Go numbers moved ~10–25% lower than the
  2026-04-15 snapshot in parallel, indicating thermal / CPU-frequency drift
  rather than regression. Zig's position *relative to the other runtimes* is
  the trustworthy read; absolute Zig deltas vs the 2026-04-15 snapshot are
  not directly comparable.
- QS-003 `Core.runTask` decomposition landed at `a0259e6` with a same-session
  paired A/B showing +16.3% / +11.7% on CI-safe scenarios vs the immediate
  predecessor commit — the post-gap-closure Zig numbers here bake those wins in.
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
