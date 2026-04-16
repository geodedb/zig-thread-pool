# Baseline medians (HEAD 56c109a355eb4316450a216a74cc619b7809183b)

Captured: 2026-04-16T00:00:00Z

| Scenario | Zig median ops/sec | Go median ops/sec | Gap |
|----------|-------------------:|------------------:|----:|
| contended_spawn_8x   | 916,337   | 3,832,459 | 4.18x behind |
| contended_cpu_10us   | 918,624   | 1,807,198 | 1.97x behind |
| nested_fanout_4x     | 525,906   | 3,175,814 | 6.04x behind |
| mixed_fast_slow      | 223,581   | 249,514   | 1.12x behind |

Source: `baseline.json` (this directory).
