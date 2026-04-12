// SPDX-License-Identifier: Apache-2.0
//! Micro-benchmark: work-stealing throughput.
//! One worker's local deque is filled by the owner; the other worker steals.
//! Reports steal counts and task throughput.
const std = @import("std");
const thread_pool = @import("thread_pool");

const task_count = 200_000;

fn noopTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const marker: *volatile u8 = @ptrCast(raw_ctx);
    marker.* +%= 1;
}

pub fn main() !void {
    var steal_batch_size: usize = 8;
    {
        var args = std.process.args();
        _ = args.next(); // skip argv[0]
        while (args.next()) |arg| {
            if (std.mem.startsWith(u8, arg, "--steal_batch_size=")) {
                steal_batch_size = try std.fmt.parseInt(usize, arg["--steal_batch_size=".len..], 10);
            }
        }
    }

    var marker: u8 = 0;

    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 2,
        .queue_capacity = task_count + 1024,
        .local_queue_capacity = 4096,
        .scheduler_variant = .work_stealing,
        .inject_batch_size = 1, // force per-task hand-off to exercise stealing
        .steal_batch_size = steal_batch_size,
    });
    defer pool.deinit();

    var wg = pool.waitGroup();
    const start = std.time.nanoTimestamp();
    for (0..task_count) |_| {
        _ = try pool.submit(noopTask, @ptrCast(&marker), .{ .wait_group = &wg });
    }
    wg.wait();
    const end = std.time.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    const ops_per_sec = @as(f64, @floatFromInt(task_count)) / elapsed_s;

    const stats = pool.statsSnapshot();

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(buf[0..], "steal_throughput steal_batch_size={d} tasks={d} elapsed_ns={d} ops_per_sec={d:.0} steals={d} steal_failures={d}\n", .{ steal_batch_size, task_count, elapsed_ns, ops_per_sec, stats.steals, stats.steal_failures });
    try std.fs.File.stdout().writeAll(line);
}
