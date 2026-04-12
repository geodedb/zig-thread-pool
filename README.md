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

Local Linux x86_64, 2 workers, ReleaseFast:

| Scenario | Throughput | Submit p50 |
|---|---|---|
| `conn_churn_seq/global_queue` (1 producer) | ~711K ops/s | ~1.8 µs |
| `conn_churn_seq/work_stealing` (1 producer) | ~544K ops/s | ~1.8 µs |
| `producer_contention/work_stealing` (4 producers) | ~890K ops/s | ~3.2 µs |
| `tokio_parity/flood_1m` (cpu_count workers) | ~300K ops/s | (block-policy submit) |
| `tokio_parity/contended_spawn_8x` (8 producers, cpu_count workers) | ~497K ops/s | n/a |

See `docs/PERFORMANCE_TRACKING.md` for per-phase deltas and the full
Tokio rt_multi_threaded-parity suite. Run `zig build bench-tokio-parity`
on your own hardware to compare directly to Tokio.

**Honest assessment:** this pool is 5–20× slower than Tokio/Go runtimes on
trivial-task throughput. The architecture (lock-free Vyukov MPMC + Chase-Lev
deques + per-worker scratch) is sound. The remaining gap is dominated by:
batch-stealing (Chase-Lev's single-item proof requires a different deque
design to widen safely), per-worker counter aggregation beyond Phase 2, and
inlining the submit hot path. Use this pool for coarse-grained work where
the per-task overhead is noise; for fine-grained fork/join, use `spice`.

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
make bench-compare
make cross-check
make ci
```

## Repository Docs

- [docs/DESIGN.md](docs/DESIGN.md)
- [docs/GAP_ANALYSIS.md](docs/GAP_ANALYSIS.md)
- [docs/PERFORMANCE_TARGETS.md](docs/PERFORMANCE_TARGETS.md)
- [docs/SCHEDULER_DECISION.md](docs/SCHEDULER_DECISION.md)

## Benchmarks

`zig build bench` runs the CI-safe suite and writes JSON. `zig build scale-bench` runs the broader scenario set intended for scheduled or manual performance runs.

The compare tool matches rows by scenario, scheduler, worker count, and submitter count:

```bash
zig build compare-bench -- --baseline benchmarks/results/baseline.json --current benchmarks/results/latest.json
```

## License

Apache-2.0. See [LICENSE](LICENSE).
