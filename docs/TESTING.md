# Testing

## Standard Validation Matrix

| Scope | Zig command | Make target |
|---|---|---|
| Unit | `zig build test --summary all` | `make test-unit` |
| Integration | `zig build test-integration --summary all` | `make test-integration` |
| Stress | `zig build test-stress --summary all` | `make test-stress` |
| All test suites | `zig build test-all --summary all` | `make test` |
| CI-style aggregate | `make ci` | `make ci` |
| Public-API fuzz | `zig build fuzz` | – |
| ThreadSanitizer sweep | `zig build test-all -Dtsan` | – |
| Fuzz under TSan | `zig build fuzz -Dtsan` | – |

The current baseline is 84/85 tests passing (1 skipped — the F-004
`WaitGroup.done` regression test is `std.debug.runtime_safety`-gated and
runs only under ReleaseFast).

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

## Public-API Fuzz Harness

`tests/fuzz/pool_fuzz.zig` randomly interleaves `submit` / `trySubmit` /
`registerSubmitter` / `releaseSubmitter` / `shutdown(.drain)` /
`shutdown(.cancel_pending)` across a pool of 2–6 workers for 32–256
operations per iteration. Post-run invariants asserted each iteration:

- `stats.submitted == stats.completed + stats.cancelled`
- `stats.task_desc_live == 0` post-shutdown
- `shutdown()` terminates within 5 seconds (guards infinite-drain bugs)
- `DebugAllocator` reports no leaks

Drive iteration count and seed via environment variables:

```bash
zig build fuzz                                  # 100 iterations, seed 0xC0FFEE
FUZZ_ITERATIONS=5000 FUZZ_SEED=1 zig build fuzz
```

Known limitation: the harness pins `scheduler_variant = .work_stealing`
because `.global_queue` does not drain submitter queues on shutdown,
which would hang `shutdown(.drain)` in the harness. Documented at the
top of `tests/fuzz/pool_fuzz.zig`.

## ThreadSanitizer

Pass `-Dtsan` to any test step to enable `sanitize_thread` on the test
artifact. The stress suite automatically switches from `ReleaseFast` to
`Debug` under `-Dtsan` so the compiler does not elide races before TSan
instruments them.

`-Dtsan` artifacts are built with the LLVM backend (`use_llvm = true`).
Zig 0.16 compiles Debug x86_64 code with the self-hosted backend, which
silently ignores `sanitize_thread`; before SONNY-6375 every `-Dtsan` run
produced an uninstrumented binary and the "zero warnings" baseline below
was not real. An instrumented run reports a much higher MaxRSS in
`--summary all` output than a plain one, which is a quick sanity check.

`zig build test-tsan` runs `tests/tsan.zig`, a small regression suite
that is always built with TSan and the LLVM backend, whether or not
`-Dtsan` is passed.

```bash
zig build test-tsan --summary all                # TSan regression suite
zig build test-all -Dtsan --summary all          # all three test suites
zig build fuzz -Dtsan                            # fuzz harness
```

The TSan baseline on `main` after SONNY-6375 is **zero warnings** across
`test` (122 pass, 2 skip), `test-integration` (31 pass), `test-stress`
(15 pass), and `test-tsan` (5 pass), on x86_64 Linux. Baseline findings are archived in
`docs/performance/appsec-fixes-2026-04-15/TSAN-findings.md`; the nightly
CI soak is provisioned via `.gitlab-ci.yml` jobs `tsan-stress-soak` and
`tsan-fuzz` (scheduled / default-branch / `RUN_TSAN=true`).

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
