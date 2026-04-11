const std = @import("std");

pub fn WorkDeque(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: []T,
        top: usize = 0,
        bottom: usize = 0,
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

        pub fn tryPushBottom(self: *Self, value: T) bool {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count == self.buffer.len) return false;
            self.buffer[self.bottom] = value;
            self.bottom = (self.bottom + 1) % self.buffer.len;
            self.count += 1;
            return true;
        }

        pub fn popBottom(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count == 0) return null;
            self.bottom = (self.bottom + self.buffer.len - 1) % self.buffer.len;
            const value = self.buffer[self.bottom];
            self.count -= 1;
            return value;
        }

        pub fn stealTop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.count == 0) return null;
            const value = self.buffer[self.top];
            self.top = (self.top + 1) % self.buffer.len;
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

test "work deque wraparound and stealing" {
    const Deque = WorkDeque(u32);
    var deque = try Deque.init(std.testing.allocator, 3);
    defer deque.deinit();

    try std.testing.expect(deque.tryPushBottom(1));
    try std.testing.expect(deque.tryPushBottom(2));
    try std.testing.expectEqual(@as(?u32, 1), deque.stealTop());
    try std.testing.expect(deque.tryPushBottom(3));
    try std.testing.expect(deque.tryPushBottom(4));
    try std.testing.expectEqual(@as(?u32, 4), deque.popBottom());
    try std.testing.expectEqual(@as(?u32, 2), deque.stealTop());
    try std.testing.expectEqual(@as(?u32, 3), deque.popBottom());
}
