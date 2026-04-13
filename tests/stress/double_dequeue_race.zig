const std = @import("std");
const thread_pool = @import("thread_pool");

fn noop(_: *anyopaque, _: *thread_pool.TaskContext) void {}

test "phase h: double-dequeue race reproducer" {
    // Submit-flood harness targeting the nextTask double-dequeue race window
    // (src/pool.zig:632-712). Uses 16 workers with an aggressive spin count
    // so many workers are mid-spin when wakes arrive, and a minimal noop
    // task body to maximise the rate of descriptor churn through the
    // inject_queue drain + stealHalf overflow path.
    //
    // Baseline: passes on main (race is either masked by the queued_tasks
    // poll or silently produces a duplicate claim). Becomes diagnostic
    // once the Task 2 descriptor sentinel lands — at that point the
    // duplicate claim panics deterministically within this window.
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 16,
        .max_threads = 16,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
        .spin_before_park_iters = 4096,
    });
    defer pool.deinit();

    // Let workers reach their park/spin steady state before the flood.
    std.Thread.sleep(5 * std.time.ns_per_ms);

    const per_producer: u64 = 100_000;
    var wg = pool.waitGroup();

    const Submitter = struct {
        fn run(p: *thread_pool.ThreadPool, g: *thread_pool.WaitGroup, n: u64) void {
            var dummy: u8 = 0;
            var i: u64 = 0;
            while (i < n) : (i += 1) {
                // enqueueTask auto-adds to the wait_group; do NOT call wg.add()
                // explicitly. Use .block so queue-full never drops tasks and
                // the wait-group count stays consistent.
                _ = p.submit(noop, @ptrCast(&dummy), .{
                    .backpressure = .block,
                    .wait_group = g,
                }) catch |err| switch (err) {
                    error.ShutdownInProgress => return,
                    else => return,
                };
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &wg, per_producer });
    const t2 = try std.Thread.spawn(.{}, Submitter.run, .{ &pool, &wg, per_producer });
    t1.join();
    t2.join();

    // Polling deadline rather than wg.wait() so a lost wakeup surfaces as a
    // test failure with a clear pendingCount, not a process-level hang.
    // Matches the pattern used by the existing "phase g2: aggressive spin
    // flood" test in this file's sibling tests/stress.zig.
    const deadline_ns: i128 = 30 * std.time.ns_per_s;
    const start = std.time.nanoTimestamp();
    while (std.time.nanoTimestamp() - start < deadline_ns) {
        if (wg.pendingCount() == 0) break;
        std.Thread.sleep(1 * std.time.ns_per_ms);
    }

    try std.testing.expectEqual(@as(u32, 0), wg.pendingCount());
}
