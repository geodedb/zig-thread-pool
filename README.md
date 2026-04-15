# thread-pool

`thread-pool` is a standalone Zig thread-pool library for the `devnw/zig` ecosystem. It provides bounded task descriptors, fixed worker caps, a global-queue baseline, and a local-queue work-stealing scheduler behind one public API.

## Status

- Current Zig target: `0.15.2`
- Scheduler variants shipped: `global_queue`, `work_stealing`
- Current default: `global_queue`
- Benchmark baseline: [benchmarks/results/baseline.json](benchmarks/results/baseline.json)

## Goals

- bounded memory and explainable steady-state footprint
- low submit-side contention under multi-producer load
- explicit shutdown, drain, cancel, and cache-purge semantics
- cross-platform process memory metrics for Linux, macOS, and Windows
- machine-readable benchmark output for regression analysis

## Performance

Direct runtime comparison on this host (`2026-04-15`, `56` workers,
`6` retained samples after `1` warmup discard):

| Scenario | Zig thread-pool | Tokio | Go |
|---|---:|---:|---:|
| `flood_1m` | 535,989 ops/s | 603,864 ops/s | 1,058,859 ops/s |
| `contended_spawn_8x` | 858,960 ops/s | 656,727 ops/s | 3,313,113 ops/s |

See `docs/PERFORMANCE_TRACKING.md` for per-phase deltas and the full
Tokio rt_multi_threaded-parity suite, and see `docs/RUNTIME_COMPARISON.md`
for the current direct Zig/Tokio/Go snapshot.

For direct side-by-side measurements instead of inferred gap estimates, run
`make bench-runtime-compare`. That benchmark uses the vendored
`third_party/tokio` and `third_party/go` submodules and writes a combined
artifact to `benchmarks/results/runtime-comparison-latest.json`.

**Honest assessment:** the old blanket claim that this pool trails both Tokio
and Go on every trivial-task workload is no longer accurate on this host.
Tokio is modestly ahead on `flood_1m`, this pool is ahead on the current
`contended_spawn_8x` run, and Go remains clearly ahead on both scenarios.
Use the direct comparison workflow before making any cross-runtime claim.

## Public API

```zig
const thread_pool = @import("thread_pool");

var pool = try thread_pool.ThreadPool.init(allocator, .{
    .min_threads = 2,
    .max_threads = 4,
    .queue_capacity = 1024,
    .local_queue_capacity = 128,
    .scheduler_variant = .work_stealing,
});
defer pool.deinit();

var wg = pool.waitGroup();
_ = try pool.submit(taskFn, ctx, .{ .wait_group = &wg });
wg.wait();
```

## Commands

```bash
make build
make test
make test-stress
make bench-save
make bench-runtime-compare
make bench-compare
make cross-check
make ci
```

## Repository Docs

- [docs/README.md](docs/README.md)
- [docs/TESTING.md](docs/TESTING.md)
- [docs/RUNTIME_COMPARISON.md](docs/RUNTIME_COMPARISON.md)
- [docs/DESIGN.md](docs/DESIGN.md)
- [docs/GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md)
- [docs/PERFORMANCE_TARGETS.md](docs/PERFORMANCE_TARGETS.md)
- [docs/SCHEDULER_DECISION.md](docs/SCHEDULER_DECISION.md)

## Benchmarks

`zig build bench` runs the CI-safe suite and writes JSON. `zig build scale-bench` runs the broader scenario set intended for scheduled or manual performance runs.

`zig build bench-runtime-compare` runs the shared `flood_1m` and `contended_spawn_8x`
workloads against this pool, Tokio, and Go using the vendored runtime source trees.

The compare tool matches rows by scenario, scheduler, worker count, and submitter count:

```bash
zig build compare-bench -- --baseline benchmarks/results/baseline.json --current benchmarks/results/latest.json
```

## License

Apache-2.0. See [LICENSE](LICENSE).
