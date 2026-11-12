//! SONNY-6375: once `finalizeTask` publishes `.completed`, a `wait()` caller
//! may release the waitable descriptor, which resets `options` and returns
//! the slot to the freelist for the next submit. The worker must not read
//! `descriptor.options` after that point.

const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("../common.zig");

fn runWaitLoop(variant: thread_pool.SchedulerVariant) !void {
    try common.skipIfSchedulerVariantIncompatible(variant);

    var cfg = common.defaultConfig(variant);
    cfg.min_threads = 4;
    cfg.max_threads = 4;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, cfg);
    defer pool.deinit();

    var counter = common.Counter{};
    const rounds: u64 = 2_000;
    for (0..rounds) |_| {
        var wg = pool.waitGroup();
        const handle = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .waitable = true, .wait_group = &wg });
        try pool.wait(handle);
        wg.wait();
    }

    try std.testing.expectEqual(rounds, counter.value.load(.acquire));
}

test "SONNY-6375: waitable release does not race finalizeTask (global_queue)" {
    try runWaitLoop(.global_queue);
}

test "SONNY-6375: waitable release does not race finalizeTask (work_stealing)" {
    try runWaitLoop(.work_stealing);
}
