//! F-005 regression: releaseSubmitter must be idempotent, bounds-check idx,
//! and only clear TLS if the calling thread actually owned the slot.

const std = @import("std");
const thread_pool = @import("thread_pool");

test "F-005: releaseSubmitter is idempotent" {
    const gpa = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 2,
        .queue_capacity = 128,
        .max_submitter_queues = 4,
        .submitter_queue_capacity = 64,
    });
    defer pool.deinit();

    const idx = try pool.registerSubmitter();
    pool.releaseSubmitter(idx);
    // Second release must not panic or OOB into a potentially-reused slot.
    pool.releaseSubmitter(idx);
}

test "F-005: releaseSubmitter bounds-checks idx" {
    const gpa = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 2,
        .queue_capacity = 128,
    });
    defer pool.deinit();

    // Out-of-range idx must not OOB or panic.
    pool.releaseSubmitter(9999);
    pool.releaseSubmitter(std.math.maxInt(usize));
}

// Regression: BUG_2026-04-25_submitter_free_mask_shift_ub.md
//
// `Core.init` initialised `submitter_free_mask` with `(1 << n) - 1`, which is
// UB on `u64` when `n == 64` (the documented maximum the clamp produces).
// Pre-fix: panics in safe modes; silently zero-mask in fast modes (every
// `registerSubmitter` returns `error.NoSubmitterSlots`).
test "registerSubmitter: max_submitter_queues = 64 yields 64 distinct slots" {
    const gpa = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 4,
        .queue_capacity = 128,
        .max_submitter_queues = 64,
        .submitter_queue_capacity = 64,
    });
    defer pool.deinit();

    var seen: u64 = 0;
    for (0..64) |_| {
        const slot = try pool.registerSubmitter();
        try std.testing.expect(slot < 64);
        const bit: u64 = @as(u64, 1) << @intCast(slot);
        try std.testing.expectEqual(@as(u64, 0), seen & bit);
        seen |= bit;
    }
    try std.testing.expectEqual(~@as(u64, 0), seen);

    // 65th must fail with NoSubmitterSlots, not crash.
    try std.testing.expectError(error.NoSubmitterSlots, pool.registerSubmitter());
}

// Boundary at n = 1 — the smallest non-zero clamp output. Validates that the
// fix's if/else didn't break the common single-submitter path.
test "registerSubmitter: max_submitter_queues = 1 yields exactly one slot" {
    const gpa = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 2,
        .queue_capacity = 128,
        .max_submitter_queues = 1,
        .submitter_queue_capacity = 64,
    });
    defer pool.deinit();

    const slot = try pool.registerSubmitter();
    try std.testing.expectEqual(@as(usize, 0), slot);
    try std.testing.expectError(error.NoSubmitterSlots, pool.registerSubmitter());
}

// PERF-NEW-03 (#117) regression: releaseSubmitter's drain must not silently
// drop pending submitter-queue entries. A dropped entry strands its
// descriptor in `.queued` forever and leaves queued_tasks unbalanced, so
// shutdown(.drain) hangs and `submitted == completed + cancelled` breaks.
// Post-fix, every drained entry is either re-injected or properly cancelled.
test "PERF-NEW-03: releaseSubmitter drain loses no tasks (drain shutdown + stats balance)" {
    const gpa = std.testing.allocator;
    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = 2,
        .queue_capacity = 128,
        .scheduler_variant = .work_stealing,
        .max_submitter_queues = 2,
        .submitter_queue_capacity = 64,
    });
    defer pool.deinit();

    var hit = std.atomic.Value(u32).init(0);

    const Worker = struct {
        fn bump(raw: *anyopaque, _: *thread_pool.TaskContext) void {
            const counter: *std.atomic.Value(u32) = @ptrCast(@alignCast(raw));
            _ = counter.fetchAdd(1, .release);
        }

        fn run(p: *thread_pool.ThreadPool, counter: *std.atomic.Value(u32)) !void {
            const slot = try p.registerSubmitter();
            for (0..32) |_| {
                _ = try p.submit(bump, @ptrCast(counter), .{});
            }
            // Release on the registering thread so the TLS-guarded
            // desc_cache drain runs and the pending-entry drain executes.
            p.releaseSubmitter(slot);
        }
    };

    const t = try std.Thread.spawn(.{}, Worker.run, .{ &pool, &hit });
    t.join();

    // Pre-fix, a dropped entry left queued_tasks unbalanced and this
    // timed out; post-fix every entry is dispatched or cancelled.
    try pool.shutdown(.drain, 5 * std.time.ns_per_s);

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(stats.submitted, stats.completed + stats.cancelled);
    try std.testing.expectEqual(@as(u64, 32), stats.submitted);
}

// Defense-in-depth (paired with the validate() ceiling added alongside the
// init fix): values above the bitmap cap surface as a typed error rather than
// being silently clamped. `normalized()` still clamps for the public init
// path, so this only affects callers that invoke `Config.validate` directly.
test "Config.validate rejects max_submitter_queues > 64" {
    const cfg: thread_pool.Config = .{
        .max_threads = 4,
        .min_threads = 4,
        .queue_capacity = 128,
        .max_submitter_queues = 65,
        .submitter_queue_capacity = 64,
    };
    try std.testing.expectError(error.SubmitterCapExceedsBitmap, cfg.validate());
}
