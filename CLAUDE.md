# Claude Notes

## Repository Summary

`thread-pool` is a Zig `0.15.2` library that exposes a bounded thread pool with
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

From the 2026-04-15 comparison run (`6` retained samples after `1` warmup
discard, `56` workers):

### Throughput (ops/sec)

| Scenario | Zig thread-pool | Tokio | Go | Zig vs Go |
|---|---:|---:|---:|---:|
| `flood_1m` | 1,024,793 | 415,851 | 776,699 | 1.32x ahead |
| `contended_spawn_8x` | 1,055,748 | 569,675 | 2,881,462 | 2.73x behind |
| `cpu_work_10us` | 1,251,811 | 385,371 | 597,746 | 2.09x ahead |
| `cpu_work_100us` | 456,838 | 331,603 | 402,792 | 1.13x ahead |
| `contended_cpu_10us` | 1,006,760 | 624,555 | 1,742,841 | 1.73x behind |
| `nested_fanout_4x` | 490,591 | 1,304,983 | 2,595,763 | 5.29x behind |
| `burst_drain_burst` | 163,679 | 140,491 | 145,170 | 1.13x ahead |
| `mixed_fast_slow` | 223,873 | 201,234 | 247,217 | 1.10x behind |

### Latency (p50/p95/p99, microseconds)

| Scenario | Zig | Tokio | Go |
|---|---|---|---|
| `cpu_work_10us` | 69/262/318 | 23/80/250 | 38/108/162 |
| `cpu_work_100us` | 1989/3659/3809 | 3279/4448/4756 | 1044/1961/3990 |
| `contended_cpu_10us` | 22/128/186 | 26/281/344 | 535/776/1977 |
| `nested_fanout_4x` | 10/56/163 | 6/28/130 | 4/30/86 |
| `burst_drain_burst` | 648/1404/1606 | 1232/1769/2113 | 876/1249/2215 |
| `mixed_fast_slow` | 10900/19204/20391 | 9045/18000/20434 | 6704/10072/10874 |

### Interpretation

- Zig wins 5 of 8 scenarios against Go on throughput, and 7 of 8 against Tokio.
- `cpu_work_10us` is the standout: `2.09x` ahead of Go and `3.25x` ahead of
  Tokio on tasks with realistic CPU work durations.
- Go wins contended/nested scenarios (in-runtime local P queue advantage).
- Zig has the best contended per-task latency: p50=22us on
  `contended_cpu_10us` vs Go's 535us — much more predictable scheduling.
- Wake coalescing (`wake_coalesce_batch=32`) and per-submitter queues
  (`registerSubmitter` API) are the key architectural features driving wins.

## Docs Entry Points

- `docs/README.md`
- `docs/TESTING.md`
- `docs/RUNTIME_COMPARISON.md`
- `docs/PERFORMANCE_TRACKING.md`
- `docs/HANDOFF-2026-04-14.md`
