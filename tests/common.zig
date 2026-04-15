const std = @import("std");
const thread_pool = @import("thread_pool");

pub const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

pub fn defaultConfig(variant: thread_pool.SchedulerVariant) thread_pool.Config {
    return .{
        .min_threads = 2,
        .max_threads = 2,
        .queue_capacity = 512,
        .local_queue_capacity = 64,
        .inject_batch_size = 8,
        .worker_scratch_cap_bytes = 4096,
        .idle_park_after_ns = 100_000,
        .idle_purge_after_ns = 500_000,
        .scheduler_variant = variant,
    };
}

pub fn counterTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const counter: *Counter = @ptrCast(@alignCast(raw_ctx));
    _ = counter.value.fetchAdd(1, .monotonic);
}

pub const ScratchTaskContext = struct {
    counter: *Counter,
    bytes: usize,
};

pub fn scratchTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    const ctx: *ScratchTaskContext = @ptrCast(@alignCast(raw_ctx));
    _ = runtime.allocScratch(u8, ctx.bytes) catch {};
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
}

pub const SleepTaskContext = struct {
    counter: *Counter,
    sleep_ns: u64,
};

pub fn sleepTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *SleepTaskContext = @ptrCast(@alignCast(raw_ctx));
    std.Thread.sleep(ctx.sleep_ns);
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
}

pub const GateTaskContext = struct {
    counter: *Counter,
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    release: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

pub fn gateTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *GateTaskContext = @ptrCast(@alignCast(raw_ctx));
    ctx.started.store(true, .release);
    while (!ctx.release.load(.acquire)) {
        std.Thread.sleep(100_000);
    }
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
}

pub const RecursiveContext = struct {
    pool: *thread_pool.ThreadPool,
    counter: *Counter,
    wait_group: *thread_pool.WaitGroup,
    child_count: usize,
};

pub fn recursiveTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *RecursiveContext = @ptrCast(@alignCast(raw_ctx));
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
    for (0..ctx.child_count) |_| {
        _ = ctx.pool.submit(counterTask, @ptrCast(ctx.counter), .{ .wait_group = ctx.wait_group }) catch {};
    }
}

pub const ProducerContext = struct {
    pool: *thread_pool.ThreadPool,
    counter: *Counter,
    wait_group: *thread_pool.WaitGroup,
    task_count: usize,
};

pub fn producerMain(ctx: *ProducerContext) void {
    var i: usize = 0;
    while (i < ctx.task_count) : (i += 1) {
        _ = ctx.pool.submit(counterTask, @ptrCast(ctx.counter), .{ .wait_group = ctx.wait_group }) catch |err| switch (err) {
            error.ShutdownInProgress => return,
            else => return,
        };
    }
}
