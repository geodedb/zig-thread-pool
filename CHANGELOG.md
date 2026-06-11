# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

[Unreleased]: https://gitlab.com/devnw/zig/thread_pool/-/compare/v0.2.1...HEAD
[0.2.1]: https://gitlab.com/devnw/zig/thread_pool/-/releases/v0.2.1
[0.1.0]: https://gitlab.com/devnw/zig/thread_pool/-/releases/v0.1.0
