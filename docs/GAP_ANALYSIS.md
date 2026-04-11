# GAP Analysis

## Summary

This repository exists to provide a bounded, reusable, observable thread-pool for `devnw/zig`. The initial implementation establishes fixed-size workers, bounded descriptors, bounded queues, two scheduler variants, cross-platform memory sampling hooks, and JSON benchmark output. Several requirements remain open and are tracked explicitly through GitLab work items.

## Scope

- standalone thread-pool library
- bounded task descriptors and queues
- global-queue and work-stealing scheduler variants
- unit, integration, stress, and benchmark harnesses
- cross-platform build and process-memory collection hooks

## Non-scope

- geode- or quic-specific application logic
- unbounded adaptive worker growth
- lock-free queue research prototypes
- production lane-aware scheduler specialization beyond the current API placeholder

## Functional Requirements

- bounded submission and explicit backpressure
- waitable handles and wait groups
- exactly-once execution for accepted tasks
- deterministic shutdown and reject-after-shutdown behavior
- explicit worker cache purge support
- benchmark output as machine-readable JSON

## Non-functional Requirements

- fixed worker cap
- cross-platform compile support
- measurable allocator and RSS behavior
- low-contention scheduler option
- reproducible benchmark comparison workflow

## Initial Risk Register

| Risk | Severity | Status | Notes |
| --- | --- | --- | --- |
| Bounded memory policy not yet proven under larger runs | High | Open | Needs longer churn and oversubscription evidence |
| Default scheduler evidence is still from CI-safe scenarios only | High | Open | Larger manual suite still needed |
| Worker-local cache purge policy is functional but not yet aggressively tuned | Medium | Open | Current purge is time-based and explicit |
| Adaptive sizing is not implemented | Medium | Accepted | Phase 2 work item |
| macOS and Windows memory metrics are compile-covered but not runner-validated | High | Open | Native smoke runners still pending |
| Alloc event counts are not yet distinct from byte accounting | Medium | Open | JSON emits byte metrics now |

## geode/quic Context

- geode has a known RSS regression under repeated QUIC connection churn.
- Recent analysis suggested a plateau around `~1158 MB`, potentially explainable as retained per-thread memory on the order of `~10 MB x 116 threads`.
- This library treats that as a hypothesis to test, not a confirmed root cause.
- The churn scenarios in the benchmark suite are intended to validate or refute retained-per-thread-state explanations with data.

## Issue Mapping

| Gap ID | Title | Issue | Severity | Status | Owner | Acceptance Criteria | Evidence |
| --- | --- | --- | --- | --- | --- | --- | --- |
| G-001 | Public API and lifecycle invariants | [#1](https://gitlab.com/devnw/zig/thread-pool/-/work_items/1) | High | In progress | `@benjiv` | API documented and lifecycle tests pass | `src/thread_pool/pool.zig`, `tests/unit.zig` |
| G-002 | Scheduler baseline: global queue | [#2](https://gitlab.com/devnw/zig/thread-pool/-/work_items/2) | High | In progress | `@benjiv` | Bounded global queue implementation and tests | `src/thread_pool/pool.zig`, `benchmarks/results/baseline.json` |
| G-003 | Scheduler candidate: work stealing | [#3](https://gitlab.com/devnw/zig/thread-pool/-/work_items/3) | High | In progress | `@benjiv` | Local deque + steal path implemented and benchmarked | `src/thread_pool/pool.zig`, `docs/SCHEDULER_DECISION.md` |
| G-004 | Memory model and scratch purge | [#4](https://gitlab.com/devnw/zig/thread-pool/-/work_items/4) | High | In progress | `@benjiv` | Bounded descriptors, scratch caps, purge path | `src/thread_pool/memory/scratch.zig`, `tests/unit.zig` |
| G-005 | Park/unpark and shrink policy | [#5](https://gitlab.com/devnw/zig/thread-pool/-/work_items/5) | Medium | Open | `@benjiv` | Phase-1 park policy documented; shrink deferred | `docs/DESIGN.md` |
| G-006 | Descriptor slab/freelist | [#6](https://gitlab.com/devnw/zig/thread-pool/-/work_items/6) | High | In progress | `@benjiv` | Safe reuse and bounded live count | `src/thread_pool/pool.zig` |
| G-007 | Stats and observability schema | [#7](https://gitlab.com/devnw/zig/thread-pool/-/work_items/7) | High | In progress | `@benjiv` | Snapshot and process memory metrics implemented | `src/thread_pool/stats/process_memory.zig`, `benchmarks/common.zig` |
| G-008 | Unit/integration/stress/fuzz plan | [#8](https://gitlab.com/devnw/zig/thread-pool/-/work_items/8) | High | In progress | `@benjiv` | Test matrix exists and passes | `tests/unit.zig`, `tests/integration.zig`, `tests/stress.zig` |
| G-009 | Benchmark harness and regression gates | [#9](https://gitlab.com/devnw/zig/thread-pool/-/work_items/9) | High | In progress | `@benjiv` | JSON bench + compare tool exist | `benchmarks/common.zig`, `benchmarks/compare.zig` |
| G-010 | Cross-platform matrix | [#10](https://gitlab.com/devnw/zig/thread-pool/-/work_items/10) | Medium | In progress | `@benjiv` | CI jobs compile Linux/macOS/Windows targets | `.gitlab-ci.yml` |
| G-011 | geode/quic-shaped scenarios | [#11](https://gitlab.com/devnw/zig/thread-pool/-/work_items/11) | High | In progress | `@benjiv` | Scenario names and harness coverage exist | `benchmarks/bench.zig`, `benchmarks/scale_bench.zig` |
| G-012 | GAP analysis and performance targets docs | [#12](https://gitlab.com/devnw/zig/thread-pool/-/work_items/12) | High | In progress | `@benjiv` | Docs exist and stay current | `docs/GAP_ANALYSIS.md`, `docs/PERFORMANCE_TARGETS.md` |
| G-013 | Default scheduler selection report | [#13](https://gitlab.com/devnw/zig/thread-pool/-/work_items/13) | Medium | In progress | `@benjiv` | Decision recorded with measured evidence | `docs/SCHEDULER_DECISION.md`, `benchmarks/results/baseline.json` |

## Unresolved Design Decisions

- whether the local deque should stay mutex-backed or move to a lock-free design
- whether waitable handles should use a dedicated completion pool instead of retaining descriptors
- whether allocator event counts should be tracked alongside bytes
- whether a dedicated blocking lane should get its own worker subset in phase 3

## Benchmark TODOs

- validate scale-bench scenarios against longer-running scheduled jobs
- collect larger conn-churn evidence for RSS plateau analysis
- add CSV export if a downstream consumer needs spreadsheet ingestion

## CI/CD TODOs

- native macOS smoke runner
- native Windows smoke runner
- richer fuzz corpus management
- automatic refresh workflow for baseline benchmark artifacts

## Cross-platform Status

| Platform | Status | Notes |
| --- | --- | --- |
| Linux | Running locally | Benchmarks and tests exercised |
| macOS | Compile-target wired | Native runner validation pending |
| Windows | Compile-target wired | Native runner validation pending |

## Next Review Date

2026-04-25
