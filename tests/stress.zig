const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

test "stress high-volume small-task increments in bounded waves" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 2048,
        .local_queue_capacity = 256,
        .inject_batch_size = 16,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 4096,
        .idle_park_after_ns = 50_000,
        .idle_purge_after_ns = 250_000,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wave: usize = 0;
    while (wave < 5) : (wave += 1) {
        var wg = pool.waitGroup();
        for (0..1_000) |_| {
            _ = try pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg });
        }
        wg.wait();
    }

    try std.testing.expectEqual(@as(u64, 5_000), counter.value.load(.acquire));
}

test "repeated churn returns to a bounded steady state after purge" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 512,
        .local_queue_capacity = 64,
        .inject_batch_size = 8,
        .scheduler_variant = .work_stealing,
        .worker_scratch_cap_bytes = 8192,
        .idle_park_after_ns = 50_000,
        .idle_purge_after_ns = 100_000,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var scratch_ctx = common.ScratchTaskContext{ .counter = &counter, .bytes = 2048 };
    var baseline_live: ?u64 = null;

    for (0..40) |_| {
        var wg = pool.waitGroup();
        for (0..128) |_| {
            _ = try pool.submit(common.scratchTask, @ptrCast(&scratch_ctx), .{ .wait_group = &wg });
        }
        wg.wait();
        try pool.purgeWorkerCaches();
        const stats = pool.statsSnapshot();
        if (baseline_live == null) baseline_live = stats.live_bytes;
        try std.testing.expect(stats.live_bytes <= baseline_live.? + 64 * 1024);
    }
}

test "park handshake: no lost wakeups under submit-while-parking race" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .idle_park_after_ns = 50_000,
        .spin_before_park_iters = 4,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    const total: u64 = 200_000;

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, c: *common.Counter, n: u64) void {
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                // Retry on transient QueueFull from rapid submit bursts.
                while (true) {
                    _ = p.submit(common.counterTask, @ptrCast(c), .{}) catch {
                        std.Thread.sleep(1_000);
                        continue;
                    };
                    break;
                }
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total / 2 });
    const t2 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &counter, total / 2 });
    t1.join();
    t2.join();

    // Wait up to 5s for completion. If any wakeup is lost, the counter stalls.
    const deadline = std.time.nanoTimestamp() + 5 * std.time.ns_per_s;
    while (std.time.nanoTimestamp() < deadline) {
        if (counter.value.load(.acquire) >= total) break;
        std.Thread.sleep(1_000_000);
    }

    try std.testing.expectEqual(total, counter.value.load(.acquire));
}
