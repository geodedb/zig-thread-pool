# Testing

## Standard Validation Matrix

| Scope | Zig command | Make target |
|---|---|---|
| Unit | `zig build test --summary all` | `make test-unit` |
| Integration | `zig build test-integration --summary all` | `make test-integration` |
| Stress | `zig build test-stress --summary all` | `make test-stress` |
| All test suites | `zig build test-all --summary all` | `make test` |
| CI-style aggregate | `make ci` | `make ci` |

## Recommended Order For Scheduler Changes

1. `zig build test --summary all`
2. `zig build test-integration --summary all`
3. `zig build test-stress --summary all`
4. `zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output benchmarks/results/runtime-comparison-latest.json`

The stress suite is the important gate for submission, wake, queue, and
scheduler-path changes.

## Benchmark Commands

### CI-Safe Suite

```bash
zig build bench -- --output benchmarks/results/latest.json
```

### Scale Suite

```bash
zig build scale-bench -- --output benchmarks/results/scale-latest.json
```

### Compare Against A Baseline

```bash
zig build compare-bench -- --baseline benchmarks/results/baseline.json --current benchmarks/results/latest.json
```

### Tokio-Parity Binary

```bash
zig build bench-tokio-parity -Doptimize=ReleaseFast
```

### Direct Zig vs Tokio vs Go Comparison

```bash
git submodule update --init --recursive
zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output benchmarks/results/runtime-comparison-latest.json
```

What this does:

- builds the Zig comparison runner
- runs a Rust benchmark against the vendored Tokio checkout
- bootstraps a local Go toolchain from `third_party/go` if needed
- emits one combined JSON artifact for all three runtimes

## Environment Notes

- The direct runtime comparison path intentionally unsets ambient `GOROOT`.
- The first Go comparison run is slower because the vendored Go toolchain is
  built into `.cache/go-toolchains/<go-commit>`.
- Keep submodules initialized before running Tokio or Go comparisons.

## Current Validation Used For This Snapshot

For the currently documented runtime comparison numbers, the repo was validated
with:

- `zig build bench-runtime-compare -Doptimize=ReleaseFast -- --output benchmarks/results/runtime-comparison-latest.json`

If you need a full code gate before publishing, also run:

```bash
zig build test-all --summary all
```
