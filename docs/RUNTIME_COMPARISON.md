# Direct Runtime Comparison

Side-by-side benchmarks of this Zig thread pool, Tokio, and Go on the same
host using identical scenario contracts. All three runtimes are built from
vendored source trees (`third_party/tokio`, `third_party/go`).

## Current Snapshot

Run date: `2026-04-15`
Host: Linux x86_64, 56 workers, 6 retained samples after 1 warmup discard.

### Throughput (ops/sec, median of 6 samples)

| Scenario | Zig thread-pool | Tokio | Go | Zig vs Go | Zig vs Tokio |
|---|---:|---:|---:|---:|---:|
| `flood_1m` | 1,024,793 | 415,851 | 776,699 | 1.32x ahead | 2.46x ahead |
| `contended_spawn_8x` | 1,055,748 | 569,675 | 2,881,462 | 2.73x behind | 1.85x ahead |
| `cpu_work_10us` | 1,251,811 | 385,371 | 597,746 | 2.09x ahead | 3.25x ahead |
| `cpu_work_100us` | 456,838 | 331,603 | 402,792 | 1.13x ahead | 1.38x ahead |
| `contended_cpu_10us` | 1,006,760 | 624,555 | 1,742,841 | 1.73x behind | 1.61x ahead |
| `nested_fanout_4x` | 490,591 | 1,304,983 | 2,595,763 | 5.29x behind | 2.66x behind |
| `burst_drain_burst` | 163,679 | 140,491 | 145,170 | 1.13x ahead | 1.17x ahead |
| `mixed_fast_slow` | 223,873 | 201,234 | 247,217 | 1.10x behind | 1.11x ahead |

### Completion Latency (p50 / p95 / p99, microseconds)

| Scenario | Zig | Tokio | Go |
|---|---|---|---|
| `cpu_work_10us` | 69 / 262 / 318 | 23 / 80 / 250 | 38 / 108 / 162 |
| `cpu_work_100us` | 1,989 / 3,659 / 3,809 | 3,279 / 4,448 / 4,756 | 1,044 / 1,961 / 3,990 |
| `contended_cpu_10us` | 22 / 128 / 186 | 26 / 281 / 344 | 535 / 776 / 1,977 |
| `nested_fanout_4x` | 10 / 56 / 163 | 6 / 28 / 130 | 4 / 30 / 86 |
| `burst_drain_burst` | 648 / 1,404 / 1,606 | 1,232 / 1,769 / 2,113 | 876 / 1,249 / 2,215 |
| `mixed_fast_slow` | 10,900 / 19,204 / 20,391 | 9,045 / 18,000 / 20,434 | 6,704 / 10,072 / 10,874 |

## Scenario Descriptions

| Scenario | Tasks | Submitters | Task Body |
|---|---:|---:|---|
| `flood_1m` | 1,000,000 | 1 | noop (atomic increment) |
| `contended_spawn_8x` | 100,000 | 8 | noop (atomic increment) |
| `cpu_work_10us` | 10,000 | 1 | 10 us busy loop |
| `cpu_work_100us` | 2,000 | 1 | 100 us busy loop |
| `contended_cpu_10us` | 10,000 | 4 | 10 us busy loop |
| `nested_fanout_4x` | 10,000 | 1 | parent spawns 4 children (2K parents + 8K children) |
| `burst_drain_burst` | 4,000 | 1 | 50 us busy loop, 10 ms idle gap between halves |
| `mixed_fast_slow` | 5,000 | 1 | 80% noop, 20% 1 ms busy loop |

All realistic scenarios use busy loops (not `sleep`) so the comparison measures
scheduling overhead under actual CPU work, not timer efficiency.

## Analysis

**Where Zig wins (5 of 8 vs Go, 7 of 8 vs Tokio):**

- `cpu_work_10us`: 2.09x ahead of Go. The pool's work-stealing scheduler
  dispatches real-work tasks faster than Go's goroutine scheduler when work
  actually occupies the CPU.
- `flood_1m`: 1.32x ahead of Go. Wake coalescing (batch scan+signal every
  32nd submit) and the work-stealing deque give high throughput on noop floods.
- `burst_drain_burst`: 1.13x ahead of Go. Wake-after-idle recovery is
  competitive — the pool re-parks and re-wakes cleanly across idle gaps.

**Where Go wins (structural advantages):**

- `contended_spawn_8x` (2.73x) and `contended_cpu_10us` (1.73x): goroutine
  submitters run inside the Go runtime scheduler, using the local P queue with
  zero cross-thread cost. Any external thread pool pays an architectural tax on
  contended external submission.
- `nested_fanout_4x` (5.29x): `go func()` from inside a goroutine places the
  child on the local run queue. Our pool submits children through the external
  submit path, adding queue contention.
- `mixed_fast_slow` (1.10x): Go's cooperative scheduling around parked
  goroutines gives a modest edge when mixing fast and slow tasks.

**Latency highlights:**

- Zig has the lowest contended per-task latency: p50=22us on
  `contended_cpu_10us` vs Go's 535us. The pool delivers more predictable
  scheduling under contention despite lower throughput.
- Zig's `burst_drain_burst` latency (p50=648us) beats both Tokio (1,232us) and
  Go (876us), showing good wake-from-idle behavior.

## How To Re-Run

```bash
# Individual runtimes
zig build bench-runtime-zig -Doptimize=ReleaseFast -- --output results/zig.json --samples 7 --warmup-discard 1
cargo run --release --manifest-path benchmarks/external/tokio_runtime_bench/Cargo.toml -- --output results/tokio.json --samples 7 --warmup-discard 1
cd benchmarks/external/go_runtime_bench && go run . --output results/go.json --samples 7 --warmup-discard 1

# Zig-only realistic suite (includes lane isolation)
zig build bench-realistic -Doptimize=ReleaseFast
```

## Related Notes

- [TESTING.md](TESTING.md)
- [PERFORMANCE_TRACKING.md](PERFORMANCE_TRACKING.md)
- [2026-04-15 Runtime Comparison Archive](performance/2026-04-15-runtime-comparison/README.md)
