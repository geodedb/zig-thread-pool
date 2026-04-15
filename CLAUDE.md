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
zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output benchmarks/results/runtime-comparison-latest.json
```

`bench-runtime-compare` builds:

- this pool via `benchmarks/runtime_compare_zig.zig`
- Tokio from `third_party/tokio`
- Go from a pinned local toolchain bootstrapped out of `third_party/go`

The Go comparison path intentionally unsets ambient `GOROOT` so the benchmark
uses the vendored Go checkout instead of the host installation.

## Current Direct Runtime Snapshot

From `benchmarks/results/runtime-comparison-latest.json` on 2026-04-15
(`10` retained samples after `1` warmup discard, `56` workers):

| Scenario | Zig thread-pool | Tokio | Go |
|---|---:|---:|---:|
| `flood_1m` | 1,141,058 ops/s | 428,545 ops/s | 768,076 ops/s |
| `contended_spawn_8x` | 836,904 ops/s | 582,075 ops/s | 2,899,822 ops/s |

Interpretation:

- This pool is `1.49x` ahead of Go and `2.66x` ahead of Tokio on `flood_1m`.
- Go remains `3.46x` ahead on `contended_spawn_8x` (architectural: goroutines submit to local P queues, our external submitters use the shared inject queue).
- Wake coalescing (`wake_coalesce_batch=32`, default) reduced scan+signal cost from per-submit to every 32nd submit.

## Docs Entry Points

- `docs/README.md`
- `docs/TESTING.md`
- `docs/RUNTIME_COMPARISON.md`
- `docs/PERFORMANCE_TRACKING.md`
- `docs/HANDOFF-2026-04-14.md`
