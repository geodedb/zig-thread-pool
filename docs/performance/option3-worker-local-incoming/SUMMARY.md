# Option 3 A/B Measurement — Worker-Local Incoming Queues

**Date:** 2026-04-14
**Main baseline SHA:** `404c2a0` (+ docs commit only)
**Option 3 branch SHA:** `7c9dc29` (branch `feat/option3-worker-local-incoming`)
**Host snapshot at measurement start:** uptime 4d 15h 53m, load avg 23.32/13.68/6.60 (1m/5m/15m, elevated from preceding 20× stress gate — same load faced by both branches), governor `schedutil`, `geode` co-tenant stopped for this session.

## Methodology

Same-session paired A/B. Measurements taken within 10 minutes on the same host with no intervening reboot or config change. Direct binary invocation (`.zig-cache/o/<hash>/thread-pool-tokio-parity`, not `zig build bench-tokio-parity` which auto-runs a single extra iteration). `-Doptimize=ReleaseFast`. n=10 per (branch × scenario). Phase H claim sentinel active on the Option 3 branch (revert gated behind a passing A/B per Q1-C).

## Results

### flood_1m (single submitter, 1M tasks; ops/s, higher is better)

| Branch | n | min | median | mean | max |
|---|---|---|---|---|---|
| main | 10 | 363,249 | 397,126 | 410,857 | 493,184 |
| option3 | 10 | 175,567 | 206,664 | 208,468 | 234,724 |

**Median delta: option3 / main − 1 = −48.0%.**
**Mean delta: −49.3%.**

Every Option 3 run came in BELOW main's minimum. The distributions do not overlap. This is not a noise-floor finding — it's a decisive regression.

### contended_spawn_8x (8 concurrent submitters, 100K tasks each; ops/s, higher is better)

| Branch | n | min | median | mean | max |
|---|---|---|---|---|---|
| main | 10 | 417,753 | 553,828 | 532,874 | 574,727 |
| option3 | 10 | 475,441 | 654,013 | 620,595 | 709,318 |

**Median delta: option3 / main − 1 = +18.1%.**
**Mean delta: +16.5%.**

Option 3 helps the multi-submitter scenario: spreading pushes across 56 cachelines pays off when there are 8 concurrent producers to absorb the cold-line cost.

## Decision

Per the plan's go/no-go criteria (`docs/superpowers/plans/2026-04-14-option3-worker-local-incoming-queues.md` Task 8):

- flood_1m median lift ≥ +10%: **FAIL** (−48%)
- contended_spawn_8x no regression (≥ −5% floor): PASS (+18%)
- Stress 20× ReleaseFast: PASS (0/20 failures — Task 7)

**Verdict: REVERT.**

## Analysis — why flood_1m regressed

The brainstorm (`docs/superpowers/brainstorms/2026-04-14-option3-worker-local-incoming-queues.md`) anticipated this exact failure mode in its "Cost sketch" section:

> "Worst case: if 56 cold-line traversals per submit cost more than the saved coherence storm, this regresses flood_1m. Same-session paired A/B is mandatory."

That's what happened. Under flood_1m's single-submitter workload, the submitter:

- OLD path: pushes every task to the same `inject_queue.tail` cacheline — hot in the submitter's L1, subject to coherence storms as 56 workers read `head`.
- NEW path (Option 3): rotates across 56 worker `incoming.tail` cachelines — cold in submitter's L1 on every new worker target, paying L2/L3 round-trip cost per submit.

On a single-submitter workload, the old hot-line bouncing was cheaper than the new cold-line traversal. With 56 rotations the submitter NEVER gets a cacheline hot — every submit is a forced cacheline miss.

## Analysis — why contended_spawn_8x improved

With 8 concurrent submitters pushing tasks, the OLD single-queue design is the worst case: all 8 submitters contend for the same `tail` cacheline with 56 workers reading `head`. Lock-free CAS retries would spike.

With Option 3, 8 submitters spread writes across 56 incoming queues. Any given (submitter, incoming[X]) pair is hot for that submitter's iterations, and coherence traffic between submitters drops sharply. Net +18%.

This suggests Option 3 is the RIGHT idea for a multi-submitter workload — which aligns with Tokio's actual design philosophy (Tokio supports many concurrent spawners from async context). But flood_1m's single-producer microbenchmark is the wrong measurement target to evaluate it.

## Implications for future work

- **Option 3 as-designed is not a flood_1m optimization.** Per `docs/superpowers/plans/2026-04-13-session-wrap-up-and-next-steps.md`'s own ranking, flood_1m improvement is the primary target for "Tokio parity" — so this cannot ship as-is.
- **The contended_spawn_8x result is real and worth preserving.** If the project's priorities shift toward multi-submitter benchmarks, Option 3 could ship as a configurable variant (e.g., `Config.incoming_enabled: bool`). Not recommended now because it adds complexity without addressing the stated target.
- **A hybrid might work.** Route external submits to incoming ONLY when `Core.incoming_cursor` shows contention (multiple submitters racing on fetchAdd); otherwise fall straight through to inject_queue. This would preserve flood_1m's hot-line advantage while capturing contended_spawn_8x's spread benefit. Conjectural; no plan yet.
- **The single-atomic surface remains exhausted for flood_1m.** This measurement confirms the prior session's conclusion — structural changes require a fundamentally different distribution model, not shuffled versions of the submit hot path.

## Raw data

- `raw-main.txt` — 10 runs on main (flood_1m + contended_spawn_8x each).
- `raw-option3.txt` — 10 runs on Option 3 branch.

## Commits on the reverted branch (preserved for reference, not merged)

- `a9b4fe2` feat(option3): add Config.incoming_capacity with pow2 normalization
- `0b09c8c` fix(option3): move Config.incoming_capacity tests into tests/unit.zig
- `522c2da` feat(option3): per-worker incoming ring lifecycle + Core.incoming_cursor
- `3d6a2cb` fix(option3): remove over-engineered errdefer to avoid double-free
- `f8519dd` feat(option3): route external submits to per-worker incoming + dispatch + wake
- `e99536b` feat(option3): cancelQueuedTasks drains per-worker incoming queues
- `7c9dc29` test(option3): saturation stress — incoming fill + inject fallback + backpressure
