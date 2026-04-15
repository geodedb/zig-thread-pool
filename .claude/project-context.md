# Claude Project Context

## Start Here

- Read `CLAUDE.md` for the short operational summary.
- Read `docs/TESTING.md` before changing scheduler or queue behavior.
- Read `docs/RUNTIME_COMPARISON.md` before making claims about Tokio or Go.

## Commands Used Most Often

```bash
zig build test-all --summary all
zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output benchmarks/results/runtime-comparison-latest.json
zig build compare-bench -- --baseline benchmarks/results/baseline.json --current benchmarks/results/latest.json
```

## Current Performance Snapshot

Current direct benchmark medians on this host:

- `flood_1m`: Zig `535,989`, Tokio `603,864`, Go `1,058,859` ops/s
- `contended_spawn_8x`: Zig `858,960`, Tokio `656,727`, Go `3,313,113` ops/s

These come from `benchmarks/results/runtime-comparison-latest.json`.

## Practical Notes

- Initialize submodules before runtime-comparison work:
  `git submodule update --init --recursive`
- Do not force the comparison path to use the ambient Go installation.
  `scripts/ensure-local-go.sh` and `scripts/run-runtime-comparison.sh` handle
  the pinned Go toolchain setup.
- The `test-stress` suite is the important gate for scheduler-path changes.
