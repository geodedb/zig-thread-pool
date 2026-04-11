const std = @import("std");

/// Lock-free bounded MPMC queue (Vyukov design).
///
/// Multiple producers call `tryPush`. Multiple consumers call `pop`.
/// Buffer size must be a power of 2.
pub fn BoundedRing(comptime T: type) type {
    return struct {
        const Self = @This();

        const Slot = struct {
            sequence: std.atomic.Value(usize),
            value: T,
        };

        allocator: std.mem.Allocator,
        buffer: []Slot,
        mask: usize,
        head: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
        tail: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            std.debug.assert(size > 0 and (size & (size - 1)) == 0);
            const buf = try allocator.alloc(Slot, size);
            for (buf, 0..) |*slot, i| {
                slot.* = .{
                    .sequence = std.atomic.Value(usize).init(i),
                    .value = undefined,
                };
            }
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

        pub fn tryPush(self: *Self, value: T) bool {
            var tail = self.tail.load(.monotonic);
            while (true) {
                const slot = &self.buffer[tail & self.mask];
                const seq = slot.sequence.load(.acquire);
                const diff = @as(isize, @intCast(seq)) -% @as(isize, @intCast(tail));
                if (diff == 0) {
                    if (self.tail.cmpxchgWeak(tail, tail +% 1, .monotonic, .monotonic)) |actual| {
                        tail = actual;
                        continue;
                    }
                    slot.value = value;
                    slot.sequence.store(tail +% 1, .release);
                    return true;
                } else if (diff < 0) {
                    return false;
                } else {
                    tail = self.tail.load(.monotonic);
                }
            }
        }

        pub fn pop(self: *Self) ?T {
            var head = self.head.load(.monotonic);
            while (true) {
                const slot = &self.buffer[head & self.mask];
                const seq = slot.sequence.load(.acquire);
                const diff = @as(isize, @intCast(seq)) -% @as(isize, @intCast(head +% 1));
                if (diff == 0) {
                    if (self.head.cmpxchgWeak(head, head +% 1, .monotonic, .monotonic)) |actual| {
                        head = actual;
                        continue;
                    }
                    const value = slot.value;
                    slot.sequence.store(head +% self.buffer.len, .release);
                    return value;
                } else if (diff < 0) {
                    return null;
                } else {
                    head = self.head.load(.monotonic);
                }
            }
        }

        pub fn len(self: *Self) usize {
            const t = self.tail.load(.acquire);
            const h = self.head.load(.acquire);
            const diff = @as(isize, @intCast(t)) -% @as(isize, @intCast(h));
            return if (diff < 0) 0 else @as(usize, @intCast(diff));
        }

        pub fn capacity(self: *Self) usize {
            return self.buffer.len;
        }
    };
}

test "bounded ring push pop basic" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    try std.testing.expect(ring.tryPush(10));
    try std.testing.expect(ring.tryPush(20));
    try std.testing.expectEqual(@as(?u32, 10), ring.pop());
    try std.testing.expectEqual(@as(?u32, 20), ring.pop());
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
}

test "bounded ring full rejection" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 2);
    defer ring.deinit();

    try std.testing.expect(ring.tryPush(1));
    try std.testing.expect(ring.tryPush(2));
    try std.testing.expect(!ring.tryPush(3));
    try std.testing.expectEqual(@as(usize, 2), ring.len());
}

test "bounded ring wraparound" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    for (0..2) |round| {
        for (0..4) |i| {
            try std.testing.expect(ring.tryPush(@intCast(round * 4 + i)));
        }
        for (0..4) |i| {
            try std.testing.expectEqual(@as(?u32, @intCast(round * 4 + i)), ring.pop());
        }
    }
}
