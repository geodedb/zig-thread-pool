//! Option 3 Task 3 + 4: external submits via per-worker incoming queues.
//! This scaffolding test just confirms external submits complete when
//! each worker has capacity (no hangs, no crashes, no QueueFull at low load).
//! Distribution-assertion is added in a follow-up when introspection exists.
//!
//! NOTE: While Task 3 is landed (routes external submits to per-worker
//! `incoming`) but Task 4 is NOT yet landed (workers do not yet drain their
//! own `incoming`), the `.work_stealing` variant would hang on external
//! submits because tasks sit in the incoming ring forever. To keep this
//! scaffolding test meaningful during T3, it uses `.global_queue` — whose
//! submit path flows directly into `inject_queue` and is unchanged by T3.
//! T4 will add a second test exercising `.work_stealing`.

const std = @import("std");
const thread_pool = @import("thread_pool");

fn noopTask(_: *anyopaque, _: *thread_pool.TaskContext) void {}

test "option3: external submits complete (global_queue scheduler — baseline)" {
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = 4,
        .max_threads = 4,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = .global_queue,
    });
    defer pool.deinit();

    std.Thread.sleep(5 * std.time.ns_per_ms); // let workers park

    var wg = thread_pool.WaitGroup{};
    // Note: `pool.submit` internally calls `wait_group.add(1)` per task;
    // callers must NOT pre-add. Manual add causes pending to reach 16 but
    // only 8 done() calls → wg.wait() hangs forever.
    var dummy: u8 = 0;
    var i: u32 = 0;
    while (i < 8) : (i += 1) {
        _ = try pool.submit(noopTask, @ptrCast(&dummy), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
    wg.wait();
}
