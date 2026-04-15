# Direct Runtime Comparison

This page records the current direct side-by-side benchmark snapshot for:

- this Zig thread pool
- Tokio from `third_party/tokio`
- Go from `third_party/go`

Unlike older notes that compared against external numbers by assumption, this
flow runs all three implementations on the same host using the same scenario
contract.

## Current Snapshot

Source artifact:
[benchmarks/results/runtime-comparison-latest.json](../benchmarks/results/runtime-comparison-latest.json)

Run date: `2026-04-15`

Method:

- command:
  `zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output benchmarks/results/runtime-comparison-latest.json`
- worker count: `56`
- warmup discard: `1`
- retained samples per runtime/scenario: `6`

### Median Throughput

| Scenario | Zig thread-pool | Tokio | Go |
|---|---:|---:|---:|
| `flood_1m` | 535,989 ops/s | 603,864 ops/s | 1,058,859 ops/s |
| `contended_spawn_8x` | 858,960 ops/s | 656,727 ops/s | 3,313,113 ops/s |

### Sample Spread

| Scenario | Runtime | Stddev |
|---|---|---:|
| `flood_1m` | Zig thread-pool | 13,478 ops/s |
| `flood_1m` | Tokio | 23,310 ops/s |
| `flood_1m` | Go | 95,895 ops/s |
| `contended_spawn_8x` | Zig thread-pool | 49,179 ops/s |
| `contended_spawn_8x` | Tokio | 39,386 ops/s |
| `contended_spawn_8x` | Go | 310,925 ops/s |

## What The Numbers Mean

- On this host, Tokio is about `1.13x` faster than this pool on `flood_1m`.
- On this host, this pool is about `1.31x` faster than Tokio on
  `contended_spawn_8x`.
- Go remains the throughput leader on both scenarios at roughly `1.98x` of Zig
  on `flood_1m` and `3.86x` on `contended_spawn_8x`.

These numbers should be treated as host-specific direct measurements, not as a
universal cross-machine truth.

## How To Re-Run

```bash
git submodule update --init --recursive
zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output benchmarks/results/runtime-comparison-latest.json
```

## Related Notes

- [TESTING.md](TESTING.md)
- [PERFORMANCE_TRACKING.md](PERFORMANCE_TRACKING.md)
- [2026-04-15 Runtime Comparison Archive](performance/2026-04-15-runtime-comparison/README.md)
