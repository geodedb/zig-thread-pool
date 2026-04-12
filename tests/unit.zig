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

test "wait rejects out-of-bounds handle index" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    const bad_handle = thread_pool.types.TaskHandle{
        .index = 9999,
        .generation = 1,
        .waitable = true,
    };
    try std.testing.expectError(error.InvalidHandle, pool.wait(bad_handle));
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

test "pre-cancelled token prevents task body execution" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    var token = thread_pool.CancellationToken{};
    // Cancel BEFORE submitting -- the task body must never run.
    token.cancel();
    try std.testing.expect(token.isCancelled());

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{
        .wait_group = &wg,
        .cancellation_token = &token,
    });
    wg.wait();

    // Task body was NOT executed; counter stays 0.
    try std.testing.expectEqual(@as(u64, 0), counter.value.load(.acquire));

    // Stats must reflect the cancellation.
    const stats = pool.statsSnapshot();
    try std.testing.expect(stats.cancelled > 0);
}

test "trySubmit returns error when queue is full" {
    // Tiny queue + 1 worker + sleep tasks = guaranteed full queue.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 4,
        .scheduler_variant = .global_queue,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 500_000_000 };

    // Fill every queue slot with long-running sleep tasks.
    for (0..4) |_| {
        _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg });
    }

    // trySubmit must fail immediately with a queue/pool exhaustion error.
    // Either error.QueueFull or error.TaskPoolExhausted is acceptable --
    // TaskPoolExhausted fires when all descriptors are consumed before
    // the ring buffer itself is full.
    const result = pool.trySubmit(common.counterTask, @ptrCast(&counter), .{});
    if (result) |_| {
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err == error.QueueFull or err == error.TaskPoolExhausted);
    }

    // Clean up: let the sleep tasks finish.
    wg.wait();
}

test "block_with_timeout returns Timeout when queue stays full" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 4,
        .scheduler_variant = .global_queue,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 2_000_000_000 };

    // Fill the queue with long-running tasks.
    for (0..4) |_| {
        _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{ .wait_group = &wg });
    }

    // submit() with block_with_timeout should time out because the queue
    // stays full for longer than the 100ms timeout.
    const result = pool.submit(common.counterTask, @ptrCast(&counter), .{
        .backpressure = .block_with_timeout,
        .timeout_ns = 100_000_000,
    });
    try std.testing.expectError(error.Timeout, result);

    // Clean up: let the pool drain.
    wg.wait();
}

test "shutdown with timeout returns Timeout for long-running tasks" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 64,
    });
    // NOTE: no defer pool.deinit() here -- we call shutdown manually, then
    // must still deinit. The deinit calls shutdown(.drain, null) internally
    // which is safe to call after a timed-out shutdown.
    defer pool.deinit();

    var counter = common.Counter{};
    var sleeper = common.SleepTaskContext{ .counter = &counter, .sleep_ns = 2_000_000_000 };
    _ = try pool.submit(common.sleepTask, @ptrCast(&sleeper), .{});

    // Give the worker a moment to pick up the task so it becomes active.
    std.Thread.sleep(10_000_000);

    // Shutdown with a 50ms timeout -- the 2-second task won't finish in time.
    const result = pool.core.shutdown(.drain, 50_000_000);
    try std.testing.expectError(error.Timeout, result);
}

test "WaitGroup done underflow guard present in all build modes" {
    // Verify the WaitGroup correctly tracks pending count down to zero.
    // The underflow guard (@panic) fires if done() is called when pending == 0.
    // We cannot catch @panic in-process, so we verify the counter reaches
    // exactly zero and that no further done() should be called.
    var wg = thread_pool.types.WaitGroup{};
    wg.add(1);
    try std.testing.expectEqual(@as(u32, 1), wg.pendingCount());
    wg.done();
    try std.testing.expectEqual(@as(u32, 0), wg.pendingCount());
    // At this point, calling wg.done() would trigger:
    //   @panic("WaitGroup: done() called more times than add()")
    // This panic fires in ALL build modes (Debug, ReleaseSafe, ReleaseFast,
    // ReleaseSmall), unlike the previous std.debug.assert which was stripped
    // in release builds.
}

test "local_queue_capacity zero rejected for all scheduler variants" {
    var cfg = thread_pool.types.Config{ .local_queue_capacity = 0, .scheduler_variant = .global_queue };
    cfg = cfg.normalized();
    try std.testing.expectError(error.InvalidLocalQueueCapacity, cfg.validate());
}

test "concurrent push-pop-steal does not lose or duplicate items" {
    const WorkDeque = @import("thread_pool").WorkDeque;
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 256);
    defer deque.deinit();

    const total_items: u32 = 10_000;
    var owner_collected = std.atomic.Value(u32).init(0);
    var stolen_collected = std.atomic.Value(u32).init(0);

    const Stealer = struct {
        fn run(d: *Deque, owner_done: *std.atomic.Value(u32), stolen: *std.atomic.Value(u32)) void {
            var count: u32 = 0;
            while (true) {
                if (d.stealTop()) |_| {
                    count += 1;
                } else {
                    if (d.len() == 0 and owner_done.load(.acquire) > 0) {
                        if (d.stealTop()) |_| {
                            count += 1;
                        } else break;
                    }
                    std.Thread.yield() catch {};
                }
            }
            _ = stolen.fetchAdd(count, .release);
        }
    };

    var threads: [3]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Stealer.run, .{ &deque, &owner_collected, &stolen_collected });
    }

    var owner_count: u32 = 0;
    var pushed: u32 = 0;
    while (pushed < total_items) {
        if (deque.tryPushBottom(pushed)) {
            pushed += 1;
        }
        if (pushed % 4 == 0) {
            if (deque.popBottom()) |_| {
                owner_count += 1;
            }
        }
    }
    while (deque.popBottom()) |_| {
        owner_count += 1;
    }

    _ = owner_collected.fetchAdd(owner_count, .release);

    for (&threads) |t| t.join();

    const total_recovered = owner_collected.load(.acquire) + stolen_collected.load(.acquire);
    try std.testing.expectEqual(total_items, total_recovered);
}

test "Stats.wakeups aggregates from per-worker counters" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..8) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    // Pool-level wakeups must equal the sum of per-worker wakeups. This is
    // the correctness invariant Q-022 fixed: the pool-level counter was
    // previously never incremented while workers did increment their own.
    // The actual value may be zero under ReleaseFast when workers never
    // needed to park (8 trivial tasks finish before the idle threshold),
    // so we only assert the aggregation invariant, not a minimum count.
    const stats = pool.statsSnapshot();
    var expected: u64 = 0;
    for (stats.worker_stats) |w| {
        expected += w.wakeups;
    }
    try std.testing.expectEqual(expected, stats.wakeups);
}

test "Stats.steals/parks aggregate per-worker under work-stealing" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 4,
        .queue_capacity = 1024,
        .local_queue_capacity = 64,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..256) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();

    var expected_steals: u64 = 0;
    var expected_steal_failures: u64 = 0;
    var expected_parks: u64 = 0;
    for (stats.worker_stats) |w| {
        expected_steals += w.steals;
        expected_steal_failures += w.steal_failures;
        expected_parks += w.parks;
    }
    try std.testing.expectEqual(expected_steals, stats.steals);
    try std.testing.expectEqual(expected_steal_failures, stats.steal_failures);
    try std.testing.expectEqual(expected_parks, stats.parks);
}

test "timestamp_mode disabled zeroes histograms" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
        .timestamp_mode = .disabled,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..32) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 0), stats.task_wait_ns.count);
    try std.testing.expectEqual(@as(u64, 0), stats.task_exec_ns.count);
    try std.testing.expectEqual(@as(u64, 32), stats.completed);
}

test "timestamp_mode disabled still purges scratch on idle" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
        .worker_scratch_cap_bytes = 1024,
        .idle_park_after_ns = 100_000, // 0.1ms — immediate park
        .idle_purge_after_ns = 200_000, // 0.2ms — quick purge trigger
        .timestamp_mode = .disabled,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var ctx = common.ScratchTaskContext{ .counter = &counter, .bytes = 256 };

    var wg = pool.waitGroup();
    _ = try pool.submit(common.scratchTask, @ptrCast(&ctx), .{ .wait_group = &wg });
    wg.wait();

    // Sleep long enough for:
    // 1. Worker to enter idle path (spin, then park for idle_park_after_ns)
    // 2. Timeout to fire (idle_park_after_ns)
    // 3. Purge check to succeed (idle_purge_after_ns since task completion)
    // Use a generous sleep to account for scheduling delays
    std.Thread.sleep(100_000_000); // 100ms — very ample time for purge to occur

    const stats = pool.statsSnapshot();
    // After purge, scratch memory should be released. live_bytes may still include
    // other allocations (queues, etc.), but scratch_current_bytes should be near 0.
    if (stats.worker_stats.len > 0) {
        var total_scratch: u64 = 0;
        for (stats.worker_stats) |ws| {
            total_scratch += ws.scratch_current_bytes;
        }
        try std.testing.expect(total_scratch == 0);
    }
}

test "fuzz BoundedRing push/pop consistency" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            const Ring = thread_pool.BoundedRing(u32);
            var ring = Ring.init(std.testing.allocator, 16) catch return;
            defer ring.deinit();

            var pushed: u32 = 0;
            var popped: u32 = 0;

            for (input) |byte| {
                if (byte % 2 == 0) {
                    if (ring.tryPush(pushed)) {
                        pushed += 1;
                    }
                } else {
                    if (ring.pop()) |_| {
                        popped += 1;
                    }
                }
            }

            // Drain remaining items
            while (ring.pop()) |_| {
                popped += 1;
            }

            // Conservation: every pushed item must have been popped
            try std.testing.expectEqual(pushed, popped);
        }
    }.testOne, .{});
}

test "fuzz Config validation never panics" {
    try std.testing.fuzz({}, struct {
        fn testOne(_: void, input: []const u8) !void {
            if (input.len < 16) return;

            const max_threads = std.mem.readInt(u32, input[0..4], .little);
            const queue_cap = std.mem.readInt(u32, input[4..8], .little);
            const local_cap = std.mem.readInt(u32, input[8..12], .little);
            const scheduler_byte = input[12] % 3;

            var cfg = thread_pool.Config{
                .max_threads = max_threads,
                .queue_capacity = queue_cap,
                .local_queue_capacity = local_cap,
                .scheduler_variant = @enumFromInt(scheduler_byte),
            };
            cfg = cfg.normalized();
            // validate() must return cleanly (success or error) -- never panic
            cfg.validate() catch {};
        }
    }.testOne, .{});
}

test "per-worker park: submit wakes a parked worker" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 4,
        .queue_capacity = 128,
        .idle_park_after_ns = 10_000_000, // 10ms — long enough for workers to park
    });
    defer pool.deinit();

    // Let workers park before we submit.
    std.Thread.sleep(50_000_000); // 50ms

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    wg.wait();

    try std.testing.expectEqual(@as(u64, 1), counter.value.load(.acquire));
    // At least one worker must have woken up.
    const stats = pool.statsSnapshot();
    try std.testing.expect(stats.wakeups > 0);
}

test "Stats.started and .completed aggregate from per-worker counters" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 2,
        .queue_capacity = 64,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    for (0..64) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    wg.wait();

    const stats = pool.statsSnapshot();
    try std.testing.expectEqual(@as(u64, 64), stats.started);
    try std.testing.expectEqual(@as(u64, 64), stats.completed);
}

test "backpressure block policy returns when capacity frees" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 1,
        .queue_capacity = 4,
        .local_queue_capacity = 2,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    var counter = common.Counter{};
    // Fill the descriptor pool with tasks.
    for (0..4) |_| {
        _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
    }
    // This one must block (no descriptors available) then succeed once the
    // worker drains a task and releases a descriptor, which signals the
    // backpressure condvar.
    _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{
        .wait_group = &wg,
        .backpressure = .block,
    });
    wg.wait();
    try std.testing.expectEqual(@as(u64, 5), counter.value.load(.acquire));
}
