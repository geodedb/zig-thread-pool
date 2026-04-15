const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

fn waitUntilGateStarted(ctx: *common.GateTaskContext) !void {
    const deadline = std.time.nanoTimestamp() + (5 * std.time.ns_per_s);
    while (std.time.nanoTimestamp() < deadline) {
        if (ctx.started.load(.acquire)) return;
        std.Thread.sleep(100_000);
    }
    return error.Timeout;
}

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
    const result = try pool.submitBatch(&tasks, .{ .wait_group = &wg });
    try std.testing.expectEqual(@as(usize, 32), result.submitted);
    wg.wait();

    try std.testing.expectEqual(@as(u64, 32), counter.value.load(.acquire));
}

test "blocking tasks do not wedge the pool" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
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

test "blocking lane rejected when allow_blocking_lane is false" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 16,
        .local_queue_capacity = 8,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 512,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    const result = pool.submit(common.counterTask, @ptrCast(&counter), .{ .lane = .blocking });
    try std.testing.expectError(error.BlockingLaneDisabled, result);
}

test "default-lane submissions unaffected by blocking_workers = 0" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..64) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();
    try std.testing.expectEqual(@as(u64, 64), counter.value.load(.acquire));
}

test "blocking worker isolates CPU pool from stalled blocking task" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};

    // One blocking task that sleeps 200ms — would hog a worker if no isolation.
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 200 * std.time.ns_per_ms };
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg, .lane = .blocking });

    // 100 CPU tasks that should all complete well before the blocking task.
    for (0..100) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }

    wg.wait();
    try std.testing.expectEqual(@as(u64, 101), counter.value.load(.acquire));
}

test "lane_extension variant accepted with blocking_workers > 0" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .lane_extension,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 100_000 };
    for (0..4) |_| {
        _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg, .lane = .blocking });
    }
    for (0..16) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();
    try std.testing.expectEqual(@as(u64, 20), counter.value.load(.acquire));
}

test "blocking_backpressure config forces return_error on full blocking queue" {
    // Slice L2: Config.blocking_backpressure overrides caller's SubmitOptions.backpressure.
    // One blocking worker sleeps, filling the tiny blocking queue; the next
    // blocking submit is asked to .block but must see return_error per config.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 64,
        .local_queue_capacity = 16,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .blocking_queue_capacity = 2,
        .blocking_backpressure = .return_error,
        .worker_scratch_cap_bytes = 512,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var gate = common.GateTaskContext{ .counter = &counter };
    // Long sleep so the blocking worker stays occupied while we fill the queue.
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 100 * std.time.ns_per_ms };

    // Deterministically occupy the blocking worker, then fill the queue.
    _ = try pool.submit(common.gateTask, @ptrCast(&gate), .{ .wait_group = &wg, .lane = .blocking });
    try waitUntilGateStarted(&gate);
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{
        .wait_group = &wg,
        .lane = .blocking,
        .backpressure = .return_error,
    });
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{
        .wait_group = &wg,
        .lane = .blocking,
        .backpressure = .return_error,
    });

    // The caller asks to .block, but blocking_backpressure = .return_error
    // forces QueueFull.
    const result = pool.submit(
        common.sleepTask,
        @ptrCast(&sleeper),
        .{ .wait_group = &wg, .lane = .blocking, .backpressure = .block },
    );
    try std.testing.expectError(error.QueueFull, result);

    gate.release.store(true, .release);
    wg.wait();
}

test "full blocking queue does not block default-lane submitters" {
    // Slice L2 cross-lane isolation: a full blocking queue with .block policy
    // must not serialize default-lane submitters on shared mutex/cond.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 128,
        .local_queue_capacity = 32,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .blocking_queue_capacity = 2,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var gate = common.GateTaskContext{ .counter = &counter };
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 50 * std.time.ns_per_ms };

    // Saturate the blocking lane deterministically: 1 gated task in flight +
    // 2 queued.
    _ = try pool.submit(common.gateTask, @ptrCast(&gate), .{ .wait_group = &wg, .lane = .blocking });
    try waitUntilGateStarted(&gate);
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{
        .wait_group = &wg,
        .lane = .blocking,
        .backpressure = .return_error,
    });
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{
        .wait_group = &wg,
        .lane = .blocking,
        .backpressure = .return_error,
    });

    // Default-lane submissions: must complete quickly regardless of the
    // blocking-lane saturation.
    const start = std.time.nanoTimestamp();
    for (0..64) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    const elapsed_submit_ns: u64 = @intCast(std.time.nanoTimestamp() - start);
    // 64 non-contended submits should take far less than one blocking sleep.
    try std.testing.expect(elapsed_submit_ns < 25 * std.time.ns_per_ms);

    gate.release.store(true, .release);
    wg.wait();
    // 3 blocking + 64 default = 67 tasks.
    try std.testing.expectEqual(@as(u64, 67), counter.value.load(.acquire));
}

test "blocking_queue_capacity sized independently of queue_capacity" {
    // Slice L2: blocking_queue_capacity is honored; default-queue capacity
    // stays large enough to absorb many default-lane submits.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 512,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .blocking_queue_capacity = 4,
        .worker_scratch_cap_bytes = 1024,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var gate = common.GateTaskContext{ .counter = &counter };
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 100 * std.time.ns_per_ms };

    // 1 gated task in flight + 4 queued = 5 accepted. The 6th must fail.
    _ = try pool.submit(common.gateTask, @ptrCast(&gate), .{ .wait_group = &wg, .lane = .blocking });
    try waitUntilGateStarted(&gate);
    for (0..4) |_| {
        _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{
            .wait_group = &wg,
            .lane = .blocking,
            .backpressure = .return_error,
        });
    }
    const overflow = pool.submit(
        common.sleepTask,
        @ptrCast(&sleeper),
        .{ .wait_group = &wg, .lane = .blocking, .backpressure = .return_error },
    );
    try std.testing.expectError(error.QueueFull, overflow);

    // Default lane (capacity 512) still accepts plenty.
    for (0..256) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    gate.release.store(true, .release);
    wg.wait();
    // 5 blocking sleepers + 256 default counters = 261.
    try std.testing.expectEqual(@as(u64, 261), counter.value.load(.acquire));
}
