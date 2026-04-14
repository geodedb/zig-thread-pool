//! Option 3 saturation stress: fill all per-worker incoming rings + the
//! fallback inject_queue, verify backpressure policy triggers correctly
//! and every submitted task eventually completes when backpressure=block.

const std = @import("std");
const thread_pool = @import("thread_pool");

fn tinyTask(_: *anyopaque, _: *thread_pool.TaskContext) void {
    // Non-trivial to slow worker drain, making saturation easy to reach.
    var x: u64 = 0;
    var i: u64 = 0;
    while (i < 1000) : (i += 1) x = x *% 31 +% i;
    std.mem.doNotOptimizeAway(x);
}

test "option3: saturation with backpressure=block completes all submits" {
    // Small pool + tiny capacities ensure saturation is reachable.
    // 4 workers × 16 per-worker + 64 inject fallback = 128 total slots.
    // Submit 512 — so backpressure MUST engage 384+ times.
    const per_worker = 16;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 64, // inject fallback capacity
        .local_queue_capacity = 32,
        .incoming_capacity = per_worker,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    const total: u64 = 512;
    var wg = thread_pool.WaitGroup{};
    var dummy: u8 = 0;
    var i: u64 = 0;
    while (i < total) : (i += 1) {
        _ = try pool.submit(tinyTask, @ptrCast(&dummy), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
    wg.wait();
}

test "option3: saturation with backpressure=return_error reports QueueFull past capacity" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 1,
        .max_threads = 1,
        .queue_capacity = 8,
        .local_queue_capacity = 8,
        .incoming_capacity = 8,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    // Pin the one worker by submitting a blocking task.
    const BlockCtx = struct {
        ev: std.Thread.ResetEvent = .{},
        fn run(ctx_ptr: *anyopaque, _: *thread_pool.TaskContext) void {
            const self: *@This() = @ptrCast(@alignCast(ctx_ptr));
            self.ev.wait();
        }
    };
    var block_ctx = BlockCtx{};
    defer block_ctx.ev.set();

    // Occupy the worker so nothing drains.
    _ = try pool.submit(BlockCtx.run, &block_ctx, .{ .backpressure = .return_error });

    // Fill incoming (capacity 8) + inject fallback (capacity 8) = 16 slots.
    // The 17th (or so) submit past total queue capacity must report QueueFull.
    var got_error = false;
    var i: u32 = 0;
    while (i < 64) : (i += 1) {
        const r = pool.submit(BlockCtx.run, &block_ctx, .{ .backpressure = .return_error });
        if (r) |_| {} else |err| switch (err) {
            error.QueueFull, error.TaskPoolExhausted => {
                got_error = true;
                break;
            },
            else => return err,
        }
    }
    try std.testing.expect(got_error);
}
