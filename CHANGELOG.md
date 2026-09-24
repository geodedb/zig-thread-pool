# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [0.2.8] - 2026-09-24

### Fixed

- `RingQueue` race between the owner's pop and a batched `stealHalf`
  (SONNY-2448). The owner popped LIFO from `tail` while a stealer's batch
  claim, a CAS on `head` alone, could still land after the owner had taken
  or re-pushed items inside the batch: `head` moved past `tail` (pops of
  consumed and never-written slots, the `index 2863311530` panics), tasks
  were stranded below `head` (hangs), and tasks were handed out twice.
  Affects `work_stealing` and `lane_extension` pools with the default
  `queue_kind = .ring`.
- `sync.Condition.timedWait` could orphan a signal that raced its timeout
  (SONNY-2427).

### Changed

- `RingQueue.pop` is now FIFO: the owner takes the oldest item from `head`
  with the same CAS stealers use (Go `runqget`, Tokio `pop`). This changes
  fork-join locality from v0.2.7: `Worker.lifo_slot` only holds the FIRST
  worker-context submit while it is occupied, so a task spawning N
  children now runs child 1 from the slot and children 2..N oldest-first
  out of the ring, not LIFO over the whole fan-out.

### Tests

- Deterministic replays of the three `RingQueue` interleavings and a
  bounded owner-vs-stealers stress counter (SONNY-2448).
- Five timing-dependent tests rewritten to be deterministic (phase g2,
  desc_cache drain, releaseSubmitter drain, per-lane histograms,
  wake-latency histogram); `lane_extension` waits are deadline-bounded
  (SONNY-2427).

## [0.2.1] - 2026-04-25

### Fixed

- Critical UB in `Core.init` when `max_submitter_queues == 64` (the documented
  maximum the `Config.normalized` clamp produces). The
  `(1 << n) - 1` mask-construction idiom evaluated `1 << 64` on a `u64`,
  which panics in `Debug`/`ReleaseSafe` and silently produces a zero free-mask
  in `ReleaseFast`/`ReleaseSmall` (every `registerSubmitter` call returns
  `error.NoSubmitterSlots`). Fixed by special-casing `n == 64` to
  `std.math.maxInt(u64)` in `src/pool.zig`. See
  [`docs/BUG_2026-04-25_submitter_free_mask_shift_ub.md`](docs/BUG_2026-04-25_submitter_free_mask_shift_ub.md).

### Added

- `Config.validate` now rejects `max_submitter_queues > 64` with
  `error.SubmitterCapExceedsBitmap` (defense-in-depth paired with the
  existing `OverflowCapExceedsBitmap` check). The `normalized()` clamp at
  64 is unchanged, so the public `ThreadPool.init` path is unaffected.
- Three regression tests in `tests/integration/submitter_lifecycle.zig`:
  64-slot success, 1-slot boundary, and `validate()` rejection above the
  bitmap cap. Exercise the full optimisation matrix.

## [0.1.0] - 2026-04-11

### Added

- Initial release
- Basic functionality
- Documentation and examples

Versions 0.2.2 through 0.2.7 are not documented as entries in this file;
see the project's git history and tags for those releases.

[Unreleased]: https://gitlab.com/devnw/zig/thread_pool/-/compare/v0.2.8...HEAD
[0.2.8]: https://gitlab.com/devnw/zig/thread_pool/-/compare/v0.2.7...v0.2.8
[0.2.1]: https://gitlab.com/devnw/zig/thread_pool/-/releases/v0.2.1
[0.1.0]: https://gitlab.com/devnw/zig/thread_pool/-/releases/v0.1.0
