# thread-pool Documentation

## Overview

Documentation for setup, API usage, testing, benchmarking, and performance
history.

## Start Here

- [Getting Started](getting-started.md)
- [Testing](TESTING.md)
- [Direct Runtime Comparison](RUNTIME_COMPARISON.md)

## Core Reference

- [API Reference](api-reference.md)
- [Examples](examples.md)
- [Architecture Overview](architecture.md)
- [FAQ](faq.md)

## Quick Links

- [Repository README](../README.md)
- [Contributing](../CONTRIBUTING.md)
- [Security](../SECURITY.md)
- [Changelog](../CHANGELOG.md)
- [Current Handoff](HANDOFF-2026-04-15.md)
- [Previous Handoff (2026-04-14)](HANDOFF-2026-04-14.md)
- [Performance Tracking](PERFORMANCE_TRACKING.md)
- [Design](DESIGN.md)
- [Scheduler Decision](SCHEDULER_DECISION.md)
- [2026-04-14 Codex Review](codex-review-2026-04-14.md)

## Security

- [AppSec Review (2026-04-15)](APPSEC_REVIEW_2026-04-15_src.md) —
  full-src audit; all 7 priority findings fixed.
- [AppSec Remediation Summary](performance/appsec-fixes-2026-04-15/FINAL.md) —
  end-to-end performance ledger + bisect + optimisation pass.
- [TSan Baseline Findings](performance/appsec-fixes-2026-04-15/TSAN-findings.md) —
  zero warnings on current `main`.
- [Remediation Plan](superpowers/plans/2026-04-15-appsec-remediation.md) —
  the 11-task execution plan that produced the fixes.

## Performance Archives

- [2026-04-15 AppSec Remediation Perf Ledger](performance/appsec-fixes-2026-04-15/README.md) —
  BASELINE → per-step → FINAL, with same-compiler bisect and
  `-Dsingle-pool` optimisation data.
- [2026-04-15 Direct Runtime Comparison](performance/2026-04-15-runtime-comparison/README.md)
- [2026-04-15 Post-Gen-Tag Profile](performance/2026-04-15-post-gen-tag-profile/README.md)
- [2026-04-14 Scratch Fast Path + Idle Queue Attempt](performance/2026-04-14-scratch-fastpath-idle-queue/README.md)
