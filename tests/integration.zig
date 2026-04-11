const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

test "multi-producer contention completes all tasks on work stealing scheduler" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 1024,
        .local_queue_capacity = 128,
        .inject_batch_size = 16,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 4096,
        .idle_park_after_ns = 100_000,
        .idle_purge_after_ns = 500_000,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    const producers = [_]common.ProducerContext{
        .{ .pool = &pool, .counter = &counter, .wait_group = &wg, .task_count = 128 },
        .{ .pool = &pool, .counter = &counter, .wait_group = &wg, .task_count = 128 },
        .{ .pool = &pool, .counter = &counter, .wait_group = &wg, .task_count = 128 },
        .{ .pool = &pool, .counter = &counter, .wait_group = &wg, .task_count = 128 },
    };
    var producer_state = producers;
    var threads: [producer_state.len]std.Thread = undefined;
    for (&threads, &producer_state) |*thread, *producer| {
        thread.* = try std.Thread.spawn(.{}, common.producerMain, .{producer});
    }
    for (threads) |thread| thread.join();
    wg.wait();

    try std.testing.expectEqual(@as(u64, 512), counter.value.load(.acquire));
}

test "batch submission with wait group completes" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, common.defaultConfig(.global_queue));
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var tasks: [32]thread_pool.BatchTask = undefined;
    for (&tasks) |*task| {
        task.* = .{
            .task_fn = common.counterTask,
            .ctx = @ptrCast(&counter),
        };
    }
    try pool.submitBatch(&tasks, .{ .wait_group = &wg });
    wg.wait();

    try std.testing.expectEqual(@as(u64, 32), counter.value.load(.acquire));
}

test "blocking tasks do not wedge the pool" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 3,
        .max_threads = 3,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .worker_scratch_cap_bytes = 1024,
        .idle_park_after_ns = 100_000,
        .idle_purge_after_ns = 500_000,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 200_000 };
    for (0..6) |_| {
        _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg, .lane = .blocking });
    }
    for (0..32) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    try std.testing.expectEqual(@as(u64, 38), counter.value.load(.acquire));
}
