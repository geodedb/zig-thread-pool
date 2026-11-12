//! SONNY-6375: `LocalQueue` dispatch must not read a worker queue's atomic
//! `head`/`tail` with a plain load. The owner pushes and pops while other
//! workers steal from the same queue, so any non-atomic copy of the queue
//! state is a data race that ThreadSanitizer reports.

const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("../common.zig");

const Fanout = struct {
    pool: *thread_pool.ThreadPool,
    counter: *common.Counter,

    fn outerTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
        _ = runtime;
        const self: *Fanout = @ptrCast(@alignCast(raw_ctx));
        // Worker-context submits land in this worker's local queue
        // (tryPushBottom) while idle workers steal from it.
        for (0..4) |_| {
            while (true) {
                _ = self.pool.submit(common.counterTask, @ptrCast(self.counter), .{}) catch {
                    thread_pool.clock.sleep(1_000);
                    continue;
                };
                break;
            }
        }
    }
};

fn runStealScenario(kind: thread_pool.types.QueueKind) !void {
    try common.skipIfSchedulerVariantIncompatible(.work_stealing);

    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 4096,
        .local_queue_capacity = 64,
        .inject_batch_size = 16,
        .scheduler_variant = .work_stealing,
        .queue_kind = kind,
        .idle_park_after_ns = 50_000,
        .spin_before_park_iters = 64,
        .timestamp_mode = common.default_timestamp_mode,
    });
    defer pool.deinit();

    var counter = common.Counter{};
    var fanout = Fanout{ .pool = &pool, .counter = &counter };

    const outer_total: u64 = 500;
    var wg = pool.waitGroup();
    for (0..outer_total) |_| {
        while (true) {
            _ = pool.submit(Fanout.outerTask, @ptrCast(&fanout), .{ .wait_group = &wg }) catch {
                thread_pool.clock.sleep(1_000);
                continue;
            };
            break;
        }
    }
    wg.wait();
    try pool.shutdown(.drain, null);

    try std.testing.expectEqual(outer_total * 4, counter.value.load(.acquire));
}

test "SONNY-6375: ring local queue dispatch is race-free under stealing" {
    try runStealScenario(.ring);
}

test "SONNY-6375: chase_lev local queue dispatch is race-free under stealing" {
    try runStealScenario(.chase_lev);
}
