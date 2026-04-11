const std = @import("std");

pub fn BoundedRing(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: []T,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,
        mutex: std.Thread.Mutex = .{},

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            return .{
                .allocator = allocator,
                .buffer = try allocator.alloc(T, size),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        pub fn tryPush(self: *Self, value: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count == self.buffer.len) return false;
            self.buffer[self.tail] = value;
            self.tail = (self.tail + 1) % self.buffer.len;
            self.count += 1;
            return true;
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count == 0) return null;
            const value = self.buffer[self.head];
            self.head = (self.head + 1) % self.buffer.len;
            self.count -= 1;
            return value;
        }

        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.count;
        }

        pub fn capacity(self: *Self) usize {
            return self.buffer.len;
        }
    };
}

test "bounded ring full and empty behavior" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 2);
    defer ring.deinit();

    try std.testing.expect(ring.tryPush(1));
    try std.testing.expect(ring.tryPush(2));
    try std.testing.expect(!ring.tryPush(3));
    try std.testing.expectEqual(@as(?u32, 1), ring.pop());
    try std.testing.expectEqual(@as(?u32, 2), ring.pop());
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
}
