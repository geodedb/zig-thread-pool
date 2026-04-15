# AppSec Remediation — Performance Tracking (2026-04-15)

Spec: `docs/APPSEC_REVIEW_2026-04-15_src.md`
Plan: `docs/superpowers/plans/2026-04-15-appsec-remediation.md`

## Baselines

- `BASELINE-bench.json` — output of `zig build bench` on the starting commit.
- `BASELINE-realistic.json` — output of `zig build bench-realistic -Doptimize=ReleaseFast`.

## Per-step artifacts

Each remediation step produces five files:

- `STEP-<N>-<name>-before-bench.json`
- `STEP-<N>-<name>-after-bench.json`
- `STEP-<N>-<name>-before-realistic.json`
- `STEP-<N>-<name>-after-realistic.json`
- `STEP-<N>-<name>-diff.md` — markdown delta table.

Update the Status and Regression class columns in the table below after each step's diff is reviewed.

## Step progress

| Step | Fix | Status | Regression class |
|------|-----|--------|------------------|
| 1 | F-001 per-pool TLS | done | clean (bench noise, see diff) |
| 2 | F-002 spawn errdefer | done | clean (bench + p95 noise, ruled out by construction) |
| 3 | F-003 atomic free_indices | pending | – |
| 4 | F-006 no unreachable blocking_inject | pending | – |
| 5 | F-005 harden releaseSubmitter | pending | – |
| 6 | F-004 soften WaitGroup.done | pending | – |
| 7 | F-007 clamp parseProcStatusKiB | pending | – |
| 8 | TSan stress run | pending | – |
| 9 | Fuzz harness | pending | – |
