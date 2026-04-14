# Phase G3 Close-Out — `counters.submitted` Hot-Path Replacement

## Result

- **Baseline:** 566K ops/s (pre-G3, re-profile Task 1, commit `3506b29`).
- **A/B ceiling:** 803K ops/s (+42%, re-profile Task 3, commit `e07b9f7`).
- **G3 result:** 393K ops/s median, n=10 (min=358K, max=483K).
- **Lift:** **-30.6% relative (-173K ops/s absolute) — REGRESSION**.
- **Capture fraction:** -73.1% of A/B ceiling (negative — worse than baseline).
- **Stress:** 20/20 PASS, logged at `docs/performance/phase-g3-close/stress-20x.txt`.
- **Unit:** all PASS including new `g3: Stats.submitted reports exact spawn count` test.

## Sub-changes

1. **Cacheline split (commit `16a14cd`):** `counters.submitted` moved to its own cacheline in the Counters struct.
2. **Layout invariant fix (commit `145e6ea`):** Converted Counters to `extern struct` + added `align(std.atomic.cache_line)` on the embedded `counters` field in Core + comptime `@offsetOf` asserts. Caught a pre-existing latent bug: Zig's auto-layout was silently reordering padding fields to the tail, so pre-G3 Counters padding was inert — all four hot-write atomics were on a single cacheline.
3. **Wake-hint replacement (commits `6444453` + `ad0da23`):** Replaced `:607` load of `counters.submitted` with `Core.wake_hint` (relaxed-atomic u32 via `@atomicLoad`/`@atomicStore`).
4. **Steal-start replacement (commit `54830a4`):** Replaced `nextTask` `:700` cross-thread load with `Worker.steal_hint` (per-worker non-atomic u64; owner-only access verified via single call-site analysis).

## Observability preserved

`Stats.submitted` is still populated by `counters.submitted.fetchAdd` (unchanged) and read by `snapshot()` (unchanged). New unit test at `tests/unit.zig` asserts exact count preservation (commit `8272987`).

## Host-load context

- Load at measurement start: 4.36 / 8.35 / 11.82
- Load at measurement end: 5.73 / 8.35 / 11.72
- 1-minute load was within the ≤6 threshold throughout; 5m/15m elevation is residual from the preceding 20× stress run. Sanity re-run 3 minutes later (load 4.91/7.95/11.50) produced consistent results (379K/414K/377K), confirming the regression is not load-induced noise.

## Recommendation

**HOLD.** Rationale: G3 captured -73.1% of the A/B ceiling — i.e., the implementation is significantly *worse* than baseline, not better. The A/B lift source was not dominated by the three hot-path accesses G3 targeted, OR the chosen replacement mechanisms (per-cacheline split + relaxed-atomic `wake_hint` + per-worker `steal_hint`) introduced coherence/layout costs that exceed whatever savings the load removal produced.

**Do NOT land this branch.** Investigation needed before proceeding:

1. **Re-run perf sched** on G3 (commit `81ca62c`) and compare against `docs/performance/reprofile-2026-04-13/perf-sched-report.md` — identify which call site(s) gained cycles.
2. **Bisect the four sub-changes** — `16a14cd`, `145e6ea`, `6444453`+`ad0da23`, `54830a4` — to isolate which commit(s) contributed regression vs. which (if any) were neutral or positive. The layout-invariant fix (`145e6ea`) is a particular suspect: forcing cacheline alignment on the embedded `counters` field in `Core` may have changed the layout of surrounding hot fields (run queues, worker pointers) in ways that cost more than the split saved.
3. **Re-examine A/B stub** (commit `e07b9f7`) — confirm what it actually removed vs. what G3 removed. The assumption that the three hot-path loads were the A/B lift source may be wrong; the stub may have also disabled the `fetchAdd` write itself, in which case approach (B) — shard the submit counter entirely — is the only way to capture the ceiling.

This plan's output: **hold**.

## Secondary benchmarks

- `contended_spawn_8x` (n=5) median: **550K ops/s** (range 520K–592K). No obvious regression vs. typical contended_spawn values observed during G3 measurement runs (521K–588K inline with flood_1m runs). Specific re-profile Task 4 baseline value not cross-cited here.
- `bench-micro-submit`: p50=329ns, p95=443ns, p99=502ns, min=86ns (100k samples). Typical submit latency.
- `bench-micro-wake`: p50=11.05µs, p95=16.3µs, p99=21.6µs, max=62.9µs (5k samples). Typical wake latency.

The micro-benchmarks look normal, and `contended_spawn_8x` is not visibly regressed. This points to the flood_1m regression being specific to the high-throughput single-submitter dispatch path, not the submit or wake primitives in isolation. Suggests the cost locus is layout/coherence-driven under saturation rather than instruction-count-driven.

Full raw data: `docs/performance/phase-g3-close/baseline-compare.txt` and `docs/performance/phase-g3-close/secondary-benchmarks.txt`.

## Task 7 gate

**Task 7 is GATED OUT.** Per the plan: "Proceed to Task 7 (100× pre-merge stress) only if this report recommends SHIP or SHIP+FOLLOWUP. If HOLD, do NOT run Task 7 until investigation resolves." This report recommends HOLD; Task 7 will not run until the regression is understood and either fixed or the plan is revised.

## Re-measurement under cleaner load

Task 6's initial measurement ran under load 4.36 → 5.73; one geode process was lingering. This re-measurement under load 2.78 (1-min) controls for host state by measuring BOTH pre-G3 main and G3 tip back-to-back.

| Measurement | Median | Min | Max | n |
|---|---|---|---|---|
| Pre-G3 baseline (main `8432cc8`, source-equiv `9da9462`) | 378.5K | 341.2K | 399.2K | 10 |
| G3 tip (`4155d28`) | 385.7K | 357.5K | 435.1K | 10 |

Delta: G3 vs pre-G3 baseline = +1.89% relative, +7,159 ops/s absolute.

### Interpretation

**NOISE / BASELINE-SHIFT.** The pre-G3 baseline itself re-measured at 378.5K today, a -33% shift from the original Task 1 n=10 value of 566K at `3506b29` / `ce0d56b`. Since the source is equivalent (only docs commits on main since the re-profile baseline), the entire 566K → 378K pre-G3 shift is host-environment-driven. Under this cleaner re-measurement, G3 is statistically indistinguishable from pre-G3 (+1.89% is well within run-to-run variance: pre-G3 range 341K–399K, G3 range 358K–435K — heavy overlap).

Task 6's original "-30.6% regression" finding is **INVALIDATED as a G3-attributable regression**. The 393K G3 measurement in Task 6 was approximately correct for current host conditions; the error was using the stale 566K Task 1 baseline as the comparison. The real host baseline today is ~378K, and G3 matches it.

Note the broader concern: the re-profile baseline (Task 1, 566K) that drove the "-42% A/B ceiling" interpretation is itself no longer reproducible on this host. Any percentage comparisons against 566K across the phase-g3 docs are suspect. Before recommending SHIP on G3 (or any follow-on phase), the re-profile baselines must be re-established under current conditions, and the A/B stub delta re-measured paired against a same-host baseline.

Raw data: `remeasure-pre-baseline.txt` and `remeasure-g3.txt` in this directory.
