const std = @import("std");
const thread_pool = @import("thread_pool");

// SONNY-2540: arrival/release handshakes, not elapsed time, prove overlap.
// A harness timeout is a deadlock watchdog, never a performance assertion.
test "hot_spinners: slow tasks recruit parked workers concurrently" {
    try runRecruitment();
}

pub fn runRecruitment() !void {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 2048,
        .local_queue_capacity = 128,
        .scheduler_variant = .work_stealing,
        .hot_spinners = 1,
        .wake_every_n_tasks = 4,
        // Each handshake submits one task; disable batching of notifications.
        .wake_coalesce_batch = 1,
        // Prevent periodic wakeups from rescuing a missing submit notification.
        // The external harness watchdog expires first if recruitment deadlocks.
        .idle_park_after_ns = std.time.ns_per_hour,
    });
    defer pool.deinit();

    const Gate = struct {
        arrived: thread_pool.sync.Semaphore = .{},
        release: thread_pool.sync.Semaphore = .{},
        workers: std.atomic.Value(u32) = .init(0),
        completed: std.atomic.Value(u32) = .init(0),

        fn run(raw: *anyopaque, rt: *thread_pool.TaskContext) void {
            const gate: *@This() = @ptrCast(@alignCast(raw));
            _ = gate.workers.fetchOr(@as(u32, 1) << @intCast(rt.worker_index), .acq_rel);
            gate.arrived.post();
            gate.release.wait();
            _ = gate.completed.fetchAdd(1, .release);
        }
    };
    var gate = Gate{};
    var wg = pool.waitGroup();
    // Ensure error paths release every submitted task before pool destruction.
    var submitted: usize = 0;
    defer {
        for (0..submitted) |_| gate.release.post();
        wg.wait();
    }

    // Observe each park handshake under the same mutex used by scanAndWake.
    // No guessed scheduling delay or sleep establishes this precondition.
    for (pool.core.workers) |*worker| {
        while (true) {
            worker.park_mutex.lock();
            const parked = worker.is_parked.load(.seq_cst) == 1;
            worker.park_mutex.unlock();
            if (parked) break;
            std.Thread.yield() catch {};
        }
    }

    for (0..4) |_| {
        _ = try pool.submit(Gate.run, @ptrCast(&gate), .{ .wait_group = &wg });
        submitted += 1;
        // Hold this worker in its task before recruiting the next one.
        gate.arrived.wait();
    }
    try std.testing.expectEqual(@as(u32, 0), gate.completed.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0b1111), gate.workers.load(.acquire));
    for (0..submitted) |_| gate.release.post();
    submitted = 0;
    wg.wait();
    try std.testing.expectEqual(@as(u32, 4), gate.completed.load(.acquire));
}
