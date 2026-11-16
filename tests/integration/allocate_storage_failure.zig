//! SONNY-6593: an allocation failure anywhere in `ThreadPool.init` frees
//! everything init allocated before it.
//!
//! `Core.allocateStorage` built the Core from a struct literal of
//! `try allocator.alloc(...)` calls with no errdefer, and `Core.init`
//! installs its `deinitOwned` errdefer only after `allocateStorage`
//! returns. A failure on the second to seventh allocation leaked the
//! slices allocated before it. The F-002 sweep (spawn_failure.zig) starts
//! at fail_index 10, past every allocation `allocateStorage` makes.
//!
//! Strategy: fail from allocation n = 0, 1, 2, ... (std.testing.FailingAllocator
//! fails allocation n and every one after it) until an init runs with no
//! failure induced, each over its own DebugAllocator so a leak names the
//! index that caused it.
//! Both queue shapes are swept: the default lane only, and a blocking lane
//! (one more ring allocated in `allocateStorage`).

const std = @import("std");
const thread_pool = @import("thread_pool");

const Shape = struct {
    name: []const u8,
    config: thread_pool.Config,
};

const shapes = [_]Shape{
    .{ .name = "default lane", .config = .{ .max_threads = 2, .queue_capacity = 64 } },
    .{ .name = "blocking lane", .config = .{
        .max_threads = 2,
        .queue_capacity = 64,
        .blocking_workers = 1,
        .allow_blocking_lane = true,
        .blocking_queue_capacity = 32,
    } },
};

/// More allocations than any init of these shapes makes; reaching it
/// means init never succeeded.
const max_index = 512;

test "SONNY-6593: every allocation failure in ThreadPool.init frees what init allocated" {
    for (shapes) |shape| {
        var leaked = std.ArrayList(usize).empty;
        defer leaked.deinit(std.testing.allocator);
        var clean_run = false;

        var n: usize = 0;
        while (n < max_index) : (n += 1) {
            var backing = std.heap.DebugAllocator(.{}){};
            var failing = std.testing.FailingAllocator.init(backing.allocator(), .{ .fail_index = n });
            const done = blk: {
                var pool = thread_pool.ThreadPool.init(failing.allocator(), shape.config) catch |err| switch (err) {
                    error.OutOfMemory => break :blk false,
                    else => return err,
                };
                pool.deinit();
                break :blk true;
            };
            const induced = failing.has_induced_failure;
            if (backing.deinit() == .leak) try leaked.append(std.testing.allocator, n);
            if (done and !induced) {
                clean_run = true;
                break;
            }
        }

        if (!clean_run) {
            std.debug.print("SONNY-6593 ({s}): init never succeeded within {d} allocations\n", .{ shape.name, max_index });
            return error.TestUnexpectedResult;
        }
        if (leaked.items.len != 0) {
            std.debug.print("SONNY-6593 ({s}): init leaked when allocation {any} failed\n", .{ shape.name, leaked.items });
            return error.TestUnexpectedResult;
        }
    }
}
