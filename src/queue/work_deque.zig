const std = @import("std");

/// Lock-free Chase-Lev work-stealing deque.
///
/// The owner thread calls `tryPushBottom` and `popBottom` (both wait-free).
/// Any thread may call `stealTop` (lock-free via CAS on `top`).
/// Buffer size must be a power of 2.
pub fn WorkDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: []std.atomic.Value(T),
        mask: usize,
        top: std.atomic.Value(isize) = std.atomic.Value(isize).init(0),
        bottom: std.atomic.Value(isize) = std.atomic.Value(isize).init(0),

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            std.debug.assert(size > 0 and (size & (size - 1)) == 0);
            const buf = try allocator.alloc(std.atomic.Value(T), size);
            for (buf) |*slot| slot.* = std.atomic.Value(T).init(undefined);
            return .{
                .allocator = allocator,
                .buffer = buf,
                .mask = size - 1,
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        /// Owner-only. Push an item to the bottom of the deque.
        /// Returns false if full.
        pub fn tryPushBottom(self: *Self, value: T) bool {
            const b = self.bottom.load(.monotonic);
            const t = self.top.load(.acquire);
            if (b -% t >= @as(isize, @intCast(self.buffer.len))) return false;
            self.buffer[@as(usize, @intCast(b)) & self.mask].store(value, .unordered);
            // Release store ensures the buffer write is visible before bottom advances.
            self.bottom.store(b +% 1, .release);
            return true;
        }

        /// Owner-only. Pop an item from the bottom of the deque (LIFO).
        /// Returns null if empty.
        pub fn popBottom(self: *Self) ?T {
            const b = self.bottom.load(.monotonic) -% 1;
            // SeqCst store + SeqCst load of top provides the required fence effect.
            self.bottom.store(b, .seq_cst);
            const t = self.top.load(.seq_cst);

            if (t <= b) {
                // Non-empty: at least one element remains.
                const value = self.buffer[@as(usize, @intCast(b)) & self.mask].load(.monotonic);
                if (t == b) {
                    // Last element: race with stealers.
                    if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                        // A stealer won. Deque is now empty.
                        self.bottom.store(t +% 1, .monotonic);
                        return null;
                    }
                    self.bottom.store(t +% 1, .monotonic);
                }
                return value;
            } else {
                // Empty.
                self.bottom.store(t, .monotonic);
                return null;
            }
        }

        /// Any thread. Steal an item from the top of the deque (FIFO).
        /// Returns null if empty or contended.
        pub fn stealTop(self: *Self) ?T {
            // SeqCst load of top ensures ordering with popBottom's SeqCst store.
            const t = self.top.load(.seq_cst);
            const b = self.bottom.load(.acquire);

            if (t >= b) return null;

            const value = self.buffer[@as(usize, @intCast(t)) & self.mask].load(.monotonic);

            if (self.top.cmpxchgStrong(t, t +% 1, .seq_cst, .monotonic) != null) {
                // Another stealer won this slot. Return empty rather than retry
                // to let the caller try another victim.
                return null;
            }

            return value;
        }

        /// Any thread. Steal up to `out.len` items from the top of the deque.
        /// Items are written into `out` starting at index 0.  Returns the
        /// number stolen (0..out.len).  Semantics match `stealTop` for
        /// correctness — last-element races are resolved with seq_cst ordering.
        pub fn stealTopBatch(self: *Self, out: []T) usize {
            if (out.len == 0) return 0;
            while (true) {
                // SeqCst load of top ensures ordering with popBottom's SeqCst store.
                const t = self.top.load(.seq_cst);
                const b = self.bottom.load(.acquire);

                const size = b -% t;
                if (size <= 0) return 0;
                const available: usize = @intCast(size);
                const n = @min(available, out.len);

                for (0..n) |i| {
                    const idx = t +% @as(isize, @intCast(i));
                    out[i] = self.buffer[@as(usize, @intCast(idx)) & self.mask].load(.monotonic);
                }

                const new_top = t +% @as(isize, @intCast(n));
                if (self.top.cmpxchgStrong(t, new_top, .seq_cst, .monotonic) == null) {
                    return n;
                }
                // CAS failed: another stealer or the owner raced.  Retry from
                // the top — `out` may have stale reads but those positions will
                // be overwritten on the retry, and the caller only observes the
                // returned `n` items on success.
            }
        }

        /// Approximate count. Safe to call from any thread.
        /// May momentarily return a slightly stale value.
        pub fn len(self: *Self) usize {
            const b = self.bottom.load(.acquire);
            const t = self.top.load(.acquire);
            const diff = b -% t;
            return if (diff < 0) 0 else @as(usize, @intCast(diff));
        }

        pub fn capacity(self: *Self) usize {
            return self.buffer.len;
        }
    };
}

test "work deque wraparound and stealing" {
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 4);
    defer deque.deinit();

    // Push two items
    try std.testing.expect(deque.tryPushBottom(1));
    try std.testing.expect(deque.tryPushBottom(2));

    // Steal from top (FIFO): expect 1
    try std.testing.expectEqual(@as(?u32, 1), deque.stealTop());

    // Push two more (wraps around in a 4-slot buffer)
    try std.testing.expect(deque.tryPushBottom(3));
    try std.testing.expect(deque.tryPushBottom(4));

    // Pop from bottom (LIFO): expect 4
    try std.testing.expectEqual(@as(?u32, 4), deque.popBottom());

    // Steal from top: expect 2
    try std.testing.expectEqual(@as(?u32, 2), deque.stealTop());

    // Pop from bottom: expect 3
    try std.testing.expectEqual(@as(?u32, 3), deque.popBottom());

    // Empty
    try std.testing.expectEqual(@as(?u32, null), deque.popBottom());
    try std.testing.expectEqual(@as(?u32, null), deque.stealTop());
}

test "work deque full rejection" {
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 2);
    defer deque.deinit();

    try std.testing.expect(deque.tryPushBottom(10));
    try std.testing.expect(deque.tryPushBottom(20));
    try std.testing.expect(!deque.tryPushBottom(30)); // Full

    try std.testing.expectEqual(@as(usize, 2), deque.len());
}

test "work deque last-element owner-vs-steal race (single-threaded)" {
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 4);
    defer deque.deinit();

    try std.testing.expect(deque.tryPushBottom(42));
    // Only one element: popBottom should succeed (no concurrent stealer)
    try std.testing.expectEqual(@as(?u32, 42), deque.popBottom());
    try std.testing.expectEqual(@as(usize, 0), deque.len());
}

test "WorkDeque.stealTopBatch steals multiple items" {
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 16);
    defer deque.deinit();

    for (0..10) |i| {
        _ = deque.tryPushBottom(@intCast(i));
    }

    var out: [16]u32 = undefined;
    const n = deque.stealTopBatch(out[0..5]);
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(@as(u32, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 4), out[4]);
    try std.testing.expectEqual(@as(usize, 5), deque.len());
}

test "WorkDeque.stealTopBatch returns 0 on empty deque" {
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 16);
    defer deque.deinit();
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), deque.stealTopBatch(out[0..]));
}

test "WorkDeque.stealTopBatch caps at available count" {
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 16);
    defer deque.deinit();

    for (0..3) |i| {
        _ = deque.tryPushBottom(@intCast(i));
    }

    var out: [10]u32 = undefined;
    const n = deque.stealTopBatch(out[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(usize, 0), deque.len());
}
