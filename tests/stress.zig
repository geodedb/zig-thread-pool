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

test "RingQueue: 1 owner + 4 stealers — no duplicates, no losses" {
    const allocator = std.testing.allocator;
    const N: u32 = 100_000;
    const M_stealers: u32 = 4;

    var q = try thread_pool.RingQueue(u32).init(allocator, 1024);
    defer q.deinit();

    const seen = try allocator.alloc(std.atomic.Value(u8), N);
    defer allocator.free(seen);
    for (seen) |*s| s.* = std.atomic.Value(u8).init(0);

    var pushed = std.atomic.Value(u32).init(0);
    var stolen = std.atomic.Value(u32).init(0);
    var popped = std.atomic.Value(u32).init(0);

    const Owner = struct {
        fn run(
            ptr_q: *thread_pool.RingQueue(u32),
            pushed_ctr: *std.atomic.Value(u32),
            popped_ctr: *std.atomic.Value(u32),
            seen_arr: []std.atomic.Value(u8),
            total: u32,
        ) void {
            var i: u32 = 0;
            while (i < total) {
                if (ptr_q.tryPush(i)) {
                    _ = pushed_ctr.fetchAdd(1, .release);
                    i += 1;
                } else {
                    // Queue full — drain some locally to make room.
                    while (ptr_q.pop()) |v| {
                        const old = seen_arr[v].fetchAdd(1, .release);
                        std.debug.assert(old == 0);
                        _ = popped_ctr.fetchAdd(1, .release);
                    }
                }
            }
            // Final drain.
            while (ptr_q.pop()) |v| {
                const old = seen_arr[v].fetchAdd(1, .release);
                std.debug.assert(old == 0);
                _ = popped_ctr.fetchAdd(1, .release);
            }
        }
    };

    const Stealer = struct {
        fn run(
            ptr_q: *thread_pool.RingQueue(u32),
            stolen_ctr: *std.atomic.Value(u32),
            seen_arr: []std.atomic.Value(u8),
            done: *std.atomic.Value(u8),
        ) void {
            var buf: [32]u32 = undefined;
            while (done.load(.acquire) == 0) {
                const n = ptr_q.stealHalf(buf[0..]);
                for (buf[0..n]) |v| {
                    const old = seen_arr[v].fetchAdd(1, .release);
                    std.debug.assert(old == 0);
                }
                _ = stolen_ctr.fetchAdd(@intCast(n), .release);
            }
            // Final drain pass after owner signals done.
            var buf2: [32]u32 = undefined;
            while (true) {
                const n = ptr_q.stealHalf(buf2[0..]);
                if (n == 0) break;
                for (buf2[0..n]) |v| {
                    const old = seen_arr[v].fetchAdd(1, .release);
                    std.debug.assert(old == 0);
                }
                _ = stolen_ctr.fetchAdd(@intCast(n), .release);
            }
        }
    };

    var done = std.atomic.Value(u8).init(0);
    var threads: [M_stealers]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, Stealer.run, .{ &q, &stolen, seen, &done });
    }
    const owner = try std.Thread.spawn(.{}, Owner.run, .{ &q, &pushed, &popped, seen, N });
    owner.join();
    done.store(1, .release);
    for (&threads) |*t| t.join();

    try std.testing.expectEqual(N, pushed.load(.acquire));
    try std.testing.expectEqual(N, popped.load(.acquire) + stolen.load(.acquire));
    for (seen) |*s| try std.testing.expectEqual(@as(u8, 1), s.load(.acquire));
}

fn runQueueKindScenario(kind: thread_pool.QueueKind, total: u64) !void {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .queue_kind = kind,
        .scheduler_variant = .work_stealing,
        .steal_batch_size = if (kind == .ring) 8 else 1,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var wg = pool.waitGroup();
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        while (true) {
            _ = pool.submit(common.counterTask, @ptrCast(&counter), .{ .wait_group = &wg }) catch {
                std.Thread.sleep(1_000);
                continue;
            };
            break;
        }
    }
    wg.wait();
    try std.testing.expectEqual(total, counter.value.load(.acquire));
}

test "queue_kind matrix: chase_lev executes all submitted tasks" {
    try runQueueKindScenario(.chase_lev, 50_000);
}

test "queue_kind matrix: ring executes all submitted tasks" {
    try runQueueKindScenario(.ring, 50_000);
}
