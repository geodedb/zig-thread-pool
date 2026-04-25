# Bug — `submitter_free_mask` init shifts by `u64`'s bit width when `max_submitter_queues = 64`

**Filed:** 2026-04-25
**Filed by:** graph-storage Phase 1 implementation work (`devnw/zig/graph-storage` `5ead31b`)
**Affected version:** `thread_pool 0.2.0` (current `main` at `ad878c812a5ee000098bc32b6ec3508b45289354`)
**Affected files:** `src/pool.zig:751`, `src/types.zig:395` (cooperating)
**Severity:** Critical (matches the project's own calibration in `docs/APPSEC_REVIEW_2026-04-15_src.md` §1: "memory corruption or UB reachable from documented public API calls")
**Status:** Open

---

## 1. Summary

`Core.init` initializes `submitter_free_mask` with the expression

```zig
self.submitter_free_mask = std.atomic.Value(u64).init(
    (@as(u64, 1) << @intCast(normalized.max_submitter_queues)) - 1,
);
```

at `src/pool.zig:751`. When the caller (or `Config.normalized`'s clamp at `types.zig:395`) sets `max_submitter_queues = 64`, this evaluates `(1 << 64) - 1` on a `u64`. **Shifting a `u64` by 64 is undefined behavior in Zig** (a shift amount equal to or exceeding the operand's bit width). Behaviour by build mode:

| Build mode | Observed behaviour |
|---|---|
| `Debug` / `ReleaseSafe` | Panic: `error: shift amount '64' is too large for operand type 'u64'` |
| `ReleaseFast` / `ReleaseSmall` | Implementation-defined; on x86-64 the SHL instruction masks the shift count to its low 6 bits, so `1 << 64` becomes `1 << 0 == 1`. The mask init becomes `1 - 1 == 0` — **zero free submitter slots** despite having allocated all 64. Every subsequent `registerSubmitter` returns `error.NoSubmitterSlots`. The pool is silently broken. |

The maximum value is documented and reachable from a compliant public-API call. `Config.normalized` (`types.zig:395`) explicitly clamps `max_submitter_queues` to 64; the `DESIGN.md:290` row "64-submitter cap | `submitter_free_mask` is a single `u64`" lists 64 as the intended capacity. So the contract says 64 must work, the validator accepts 64, and `Core.init` then trips UB on it.

`Config.validate` (`types.zig:399-431`) does **not** add a separate bound on `max_submitter_queues`, so the clamp value of 64 is the only gate — and it points the value at the broken init.

---

## 2. Severity rationale

By `APPSEC_REVIEW_2026-04-15_src.md` §1's calibration:

> "Critical" is reserved for memory corruption or UB reachable from documented public API calls.

This bug fits exactly. Reachable from `tp.ThreadPool.init(allocator, .{ .max_submitter_queues = 64, ... })` — the documented maximum. Outcome is mode-dependent UB:

- **Safe modes:** integrity-class panic-as-DoS at startup (`error: shift amount …`). The application crashes before doing useful work; a downstream operator who tested in Debug catches it, but anyone whose dev/test runs use a value < 64 and only sees this in production-shaped fuzz / load tests will be surprised.
- **Fast modes:** silent functional breakage. The pool returns `error.NoSubmitterSlots` from the first `registerSubmitter`. Downstream code that expected the slot to succeed (and probably treated registration failure as fatal or as a fallback to a slower path) sees behaviour that looks like configuration was wrong.

Severity is **Critical** because the fast-mode failure mode is silent and corrupts the *contract* of the API: the caller asked for 64 slots, the API said yes, and then no slot is available. This violates the project's own design invariant and would survive a unit-test pass that only registered <64 submitters.

No exploitability against an attacker: this is a self-inflicted defect, not a security vulnerability. It is filed under the same severity bar because the project's existing calibration uses "Critical" for "UB reachable from documented public API," not for exploitability.

---

## 3. Reproduction

Minimal, self-contained Zig program. Drop into a scratch file and run with each build mode.

```zig
// repro.zig — run with: zig run repro.zig --dep thread_pool ...
const std = @import("std");
const tp = @import("thread_pool");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();

    var pool = try tp.ThreadPool.init(gpa.allocator(), .{
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 64, // documented maximum
        .max_threads = 4,
    });
    defer pool.deinit();

    // Register 64 submitters. Contract: each call returns a distinct slot in
    // [0, 64), and slot allocation only fails after the 64th.
    var slots: [64]usize = undefined;
    for (&slots, 0..) |*s, i| {
        s.* = pool.registerSubmitter() catch |err| {
            std.debug.print("registerSubmitter[{}] failed: {}\n", .{ i, err });
            return err;
        };
    }
    std.debug.print("OK — claimed {} distinct submitter slots\n", .{slots.len});
}
```

Expected behaviour (per `DESIGN.md` and the `Config.normalized` clamp): prints `OK — claimed 64 distinct submitter slots`.

Observed:

| Mode | Output |
|---|---|
| `zig run repro.zig -O Debug` | Panic at `pool.zig:751`: `shift amount '64' is too large for operand type 'u64'` |
| `zig run repro.zig -O ReleaseSafe` | Same panic. |
| `zig run repro.zig -O ReleaseFast` | `registerSubmitter[0] failed: error.NoSubmitterSlots` — the very first registration fails because the free-mask was initialised to `0` (all slots marked busy). |
| `zig run repro.zig -O ReleaseSmall` | Same as `ReleaseFast`. |

A second reproduction confirms the boundary: rerunning with `.max_submitter_queues = 63` succeeds in all build modes — the `(1 << 63) - 1` shift is well-defined.

This bug also surfaces empirically in `devnw/zig/graph-storage` Phase 1 work. The implementation plan there originally specified a test case using `max_submitter_queues = 64`; the implementer encountered the panic during Task 5 and reduced to 32 as a workaround (commit `390f336` in graph-storage).

---

## 4. Root cause

`src/pool.zig:745-754`:

```zig
        if (normalized.max_submitter_queues > 0) {
            self.submitter_queues = try allocator.alloc(LocalQueue, normalized.max_submitter_queues);
            for (self.submitter_queues) |*q| {
                q.* = try LocalQueue.init(allocator, normalized.submitter_queue_capacity, .ring);
            }
            self.submitter_free_mask = std.atomic.Value(u64).init(
                (@as(u64, 1) << @intCast(normalized.max_submitter_queues)) - 1,
            );
            // ...
            self.desc_caches = try allocator.alloc(DescCache, normalized.max_submitter_queues);
        }
```

The expression `(@as(u64, 1) << @intCast(normalized.max_submitter_queues)) - 1` is intended to produce a bitmask with the low `n` bits set. For `n ∈ [1, 63]` this is `(1 << n) - 1` and is correct. For `n = 64` the language semantics make the shift UB; the entire-register pattern `0xFFFF_FFFF_FFFF_FFFF` cannot be expressed by `(1 << 64) - 1` on a fixed-width type.

`Config.normalized` (`types.zig:395`):

```zig
        if (cfg.max_submitter_queues > 64) cfg.max_submitter_queues = 64;
```

The clamp is correct (the bitmap *is* a `u64`, so 64 is the cap) but it leaves the broken init reachable. `Config.validate` does not add a defensive ceiling — the only bound applied is the clamp, which routes the maximum legal value into the bug.

There is one analogous shift at `src/pool.zig:2555` (`laneMask` computing `(1 << blocking_workers) - 1`). It is **safe** because `Config.validate` enforces `blocking_workers < max_threads ≤ 64` (`types.zig:400-401, 423-424`), so `blocking_workers ≤ 63` and the shift never reaches the bit width. This bug is unique to `submitter_free_mask` because the equivalent ceiling for `max_submitter_queues` is the clamp value itself.

---

## 5. Fix

Special-case the full-bitmap value. The mask init becomes:

```zig
            const initial_free_mask: u64 = if (normalized.max_submitter_queues == 64)
                std.math.maxInt(u64)
            else
                (@as(u64, 1) << @intCast(normalized.max_submitter_queues)) - 1;
            self.submitter_free_mask = std.atomic.Value(u64).init(initial_free_mask);
```

Two-line change at `src/pool.zig:751`. No other call site reads or writes `submitter_free_mask` with shift-width assumptions — `:879`, `:883`, `:937`, `:939`, and the `bit` at `:882` all operate on the mask after init, using `idx ∈ [0, 63]` and per-bit ops that never trip the bit-width boundary.

### Optional defense-in-depth

Even with the init fixed, a runtime check in `Config.validate` would clarify intent and make the cap explicit:

```zig
        if (self.max_submitter_queues > 64)
            return error.SubmitterCapExceedsBitmap;
```

(Mirrors the existing `OverflowCapExceedsBitmap` check at `types.zig:430-431`.) The clamp in `normalized()` would still apply, but `validate()` would now refuse silently-clamped-down configurations, surfacing the cap to callers who request more.

This second change is optional — the init fix alone closes the bug. Both together would be consistent with the project's pattern of paired `clamp + validate` for `max_threads + max_overflow_workers`.

### Why not a different idiom

Alternatives considered and rejected:

- `std.math.shl(u64, 1, n) - 1` — `std.math.shl` saturates at the type width, so `shl(u64, 1, 64)` returns 0 and the subtraction underflows to `maxInt(u64)`. This *would* produce the right answer for `n = 64` only via the underflow, but it depends on wraparound semantics that may panic in safe modes for `Subtract Overflow`. Brittle.
- `~@as(u64, 0) >> @intCast(64 - n)` — same shift-UB on the other end when `n = 64` (right-shift by 0 is fine, but the `64 - n` evaluation is also fine; this works). Slightly less obvious to a reader; the if/else is preferred for clarity.
- Bumping the bitmap to `u128` — over-engineering; `DESIGN.md` calls out the 64-cap as deliberate.

---

## 6. Test coverage

Add a regression test to `tests/integration/submitter_lifecycle.zig` (which already covers F-005 register/release):

```zig
test "registerSubmitter — max_submitter_queues = 64 yields 64 distinct slots" {
    const allocator = std.testing.allocator;

    var pool = try tp.ThreadPool.init(allocator, .{
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 64,
        .max_threads = 4,
    });
    defer pool.deinit();

    var seen: u64 = 0;
    for (0..64) |i| {
        const slot = try pool.registerSubmitter();
        try std.testing.expect(slot < 64);
        const bit: u64 = @as(u64, 1) << @intCast(slot);
        try std.testing.expectEqual(@as(u64, 0), seen & bit); // distinct
        seen |= bit;
        _ = i;
    }
    try std.testing.expectEqual(~@as(u64, 0), seen);

    // 65th registration must fail with NoSubmitterSlots, not crash.
    try std.testing.expectError(error.NoSubmitterSlots, pool.registerSubmitter());
}

test "registerSubmitter — max_submitter_queues = 1 still yields exactly one slot" {
    // Boundary at the other end — verifies the if/else branch covers n = 1
    // (the smallest non-zero value the clamp can produce).
    const allocator = std.testing.allocator;

    var pool = try tp.ThreadPool.init(allocator, .{
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 1,
        .max_threads = 4,
    });
    defer pool.deinit();

    const slot = try pool.registerSubmitter();
    try std.testing.expectEqual(@as(usize, 0), slot);
    try std.testing.expectError(error.NoSubmitterSlots, pool.registerSubmitter());
}
```

Both tests should be exercised under the full optimisation matrix the project already runs (`Debug`, `ReleaseSafe`, `ReleaseFast`, `ReleaseSmall`) — see `Makefile` and `tests/` build scripts. Pre-fix, the `= 64` test panics in safe modes and fails immediately with `NoSubmitterSlots` in fast modes. Post-fix, both tests pass in all four modes.

If the optional defense-in-depth `validate()` change in §5 is also applied, add:

```zig
test "Config.validate rejects max_submitter_queues > 64" {
    const cfg = tp.Config{
        .max_threads = 4,
        .max_submitter_queues = 65,
    };
    try std.testing.expectError(error.SubmitterCapExceedsBitmap, cfg.validate());
}
```

Note that `normalized()` still clamps — applications that previously relied on the clamp (passing arbitrary large values and getting 64 back) keep working when they go through `tp.ThreadPool.init` (which calls `normalized()`). `validate()` is a separate path some callers invoke directly; the new error is informational rather than a breaking change for the init path.

---

## 7. Detection

Static analysis options that would have caught this:

- A custom Zig lint rule for `<<` operations on integer literals where the RHS could equal the LHS bit width. Not aware of an off-the-shelf tool that does this for Zig today.
- A grep audit of all `<< @intCast(` shifts in `src/`, cross-referenced against the source variable's clamp ceiling. This bug + the `laneMask` analog are the only sites; the rest (`pool.zig:1670, 1675, 1847, 882`) shift by `worker_index` or `idx` values that are bounded `< 64` by construction.
- Run the existing test suite once with `-O ReleaseFast` (the project's CI matrix should include this — verify and add if missing). A test that exercises `max_submitter_queues = 64` would have surfaced the silent zero-mask in fast modes immediately.

Suggested as follow-up: add a "boundary value" sweep to `tests/fuzz/pool_fuzz.zig` that includes `max_submitter_queues ∈ {1, 32, 63, 64}` along with the existing fuzz inputs.

---

## 8. References

- Affected source: `src/pool.zig:751`, `src/types.zig:395`
- Design contract: `docs/DESIGN.md:290` ("64-submitter cap | `submitter_free_mask` is a single `u64`")
- Related (different defect, same field): `docs/APPSEC_REVIEW_2026-04-15_src.md` F-005 (register/release race + bounds — already remediated in `2e82ec0` / `20a4bbf`)
- Discovering project: `devnw/zig/graph-storage` Task 5 of the shared-engine-thread-pool plan (`docs/superpowers/plans/2026-04-25-shared-engine-thread-pool.md` § Task 5). Implementer commit `390f336` documents the workaround (use `max_submitter_queues = 32`).
- Cross-session memory entry: `~/.claude/projects/-data-home-benji-src-devnw-zig-graph-storage/memory/reference_thread_pool_dep.md`
- Zig language reference on shift semantics: <https://ziglang.org/documentation/master/#Bit-Shifts> ("the shift amount must be less than the number of bits in the integer type being shifted")

---

## 9. Implementer checklist

For the agent picking this up:

- [ ] Reproduce §3 in all four build modes against current `main` (`ad878c8`). Record output.
- [ ] Apply the §5 init fix at `src/pool.zig:751` (the if/else against `== 64`).
- [ ] Add the §6 regression tests to `tests/integration/submitter_lifecycle.zig`.
- [ ] Decide on the optional §5 `validate()` defense-in-depth — recommended yes, since it costs ~3 lines and clarifies the contract.
- [ ] Run the project's full test matrix (`make test` or equivalent — see `Makefile`) under all optimisation levels.
- [ ] Update `CHANGELOG.md` with a `### Fixed` entry referencing this bug doc.
- [ ] Bump version (`build.zig.zon`): patch-level bump from `0.2.0` to `0.2.1` is appropriate (bugfix, no API change).
- [ ] Notify downstream consumers — at minimum `devnw/zig/graph-storage` (the plan's Task 5 spec snippet still says `64`; once the dep is fixed and bumped, the plan can be updated to use the documented maximum). The existing `docs/2026-04-25-shared-engine-thread-pool.md` referenced from the graph-storage plan is also a touchpoint.
