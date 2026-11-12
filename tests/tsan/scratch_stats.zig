//! SONNY-6375: `statsSnapshot` reads every worker's scratch byte counters
//! while the owning workers update them from `beginTask` / `alloc` /
//! `finishTask` and the idle-path `purge`. Those counters must be read and
//! written atomically, or ThreadSanitizer reports a data race.

const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("../common.zig");

test "SONNY-6375: statsSnapshot scratch counters are race-free" {
    try common.skipIfSchedulerVariantIncompatible(.work_stealing);

    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 512,
        .local_queue_capacity = 64,
        .inject_batch_size = 8,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 4096,
        .idle_park_after_ns = 50_000,
        .idle_purge_after_ns = 50_000,
        .timestamp_mode = common.default_timestamp_mode,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var scratch_ctx = common.ScratchTaskContext{ .counter = &counter, .bytes = 2048 };

    const waves: u64 = 20;
    const per_wave: u64 = 64;
    for (0..waves) |_| {
        var wg = pool.waitGroup();
        for (0..per_wave) |_| {
            _ = try pool.submit(common.scratchTask, @ptrCast(&scratch_ctx), .{ .wait_group = &wg });
        }
        // Sample while workers run tasks, then again while they go idle
        // and purge their scratch buffers.
        while (wg.pendingCount() != 0) _ = pool.statsSnapshot();
        wg.wait();
        for (0..64) |_| _ = pool.statsSnapshot();
        thread_pool.clock.sleep(100_000);
        _ = pool.statsSnapshot();
    }

    try std.testing.expectEqual(waves * per_wave, counter.value.load(.acquire));
}
