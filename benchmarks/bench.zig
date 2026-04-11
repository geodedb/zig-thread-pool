const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("common.zig");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const output = try parseOutputArg(allocator);
    const specs = [_]common.ScenarioSpec{
        .{
            .name = "conn_churn_seq",
            .task_count = 4096,
            .worker_count = 2,
            .submitter_count = 1,
            .queue_capacity = 4096,
            .local_queue_capacity = 64,
            .scratch_bytes = 2048,
        },
        .{
            .name = "producer_contention",
            .task_count = 4096,
            .worker_count = 2,
            .submitter_count = 4,
            .queue_capacity = 4096,
            .local_queue_capacity = 64,
        },
    };
    const variants = [_]thread_pool.SchedulerVariant{ .global_queue, .work_stealing };
    try common.runScenarios(allocator, &specs, &variants, output);
}

fn parseOutputArg(allocator: std.mem.Allocator) !?[]const u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);
    var idx: usize = 0;
    while (idx + 1 < args.len) : (idx += 1) {
        if (std.mem.eql(u8, args[idx], "--output")) return args[idx + 1];
    }
    return null;
}
