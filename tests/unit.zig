const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

test "work-stealing scheduler executes each accepted task exactly once" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.work_stealing));
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..128) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    try std.testing.expectEqual(@as(u64, 128), counter.value.load(.acquire));
    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 128), stats.completed);
}

test "global scheduler waitable handle completes" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    var counter = common.Counter{};
    const handle = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .waitable = true });
    try pool.wait(handle);
    try std.testing.expectEqual(@as(u64, 1), counter.value.load(.acquire));
}

test "shutdown rejects new submissions" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    try pool.shutdown(.cancel_pending, null);
    var counter = common.Counter{};
    try std.testing.expectError(error.ShutdownInProgress, pool.submit(common.counterTask, @ptrCast(&counter), .{}));
}

test "worker cache purge resets current scratch usage" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.work_stealing));
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var scratch_ctx = common.ScratchTaskContext{ .counter = &counter, .bytes = 1024 };
    for (0..16) |_| {
        _ = try pool.submit(common.scratchTask, @ptrCast(&scratch_ctx), .{ .wait_group = &wg });
    }
    wg.wait();
    try pool.purgeWorkerCaches();

    const stats = pool.statsSnapshot();
    for (stats.worker_stats) |worker| {
        try std.testing.expectEqual(@as(u64, 0), worker.scratch_current_bytes);
    }
}

test "waitable handle generation increments across reuses" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    var counter = common.Counter{};
    const handle1 = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .waitable = true });
    try pool.wait(handle1);

    // Same descriptor index may be reused; generation must differ.
    const handle2 = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .waitable = true });
    try pool.wait(handle2);

    if (handle1.index == handle2.index) {
        try std.testing.expect(handle2.generation > handle1.generation);
    }
}

test "recursive submission through local queues does not deadlock" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.work_stealing));
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var recursive = common.RecursiveContext{
        .pool = &pool,
        .counter = &counter,
        .wait_group = &wg,
        .child_count = 8,
    };

    _ = try pool.submit(common.recursiveTask, @ptrCast(&recursive), .{ .wait_group = &wg });
    wg.wait();

    try std.testing.expectEqual(@as(u64, 9), counter.value.load(.acquire));
}
