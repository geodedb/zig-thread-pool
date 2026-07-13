//! Lock-free bounded MPMC ring queue used as the pool-wide inject queue.
//!
//! Implements the Vyukov bounded MPMC lock-free design: each slot carries a sequence counter so
//! producers and consumers can claim slots without a global lock. Buffer size must be a
//! power of 2. Multiple producers call `tryPush`; multiple consumers call `pop`.

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
        _pad_head: [std.atomic.cache_line - @sizeOf(std.atomic.Value(usize))]u8 = undefined,
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

        /// Reserve up to `buf.len` items in one head RMW and read them out.
        /// Returns the count filled into `buf[0..n]`. Used by the thread pool
        /// inject-drain fast path to cut head-CAS rate by the drain-batch
        /// factor (flood_1m_batched median lift ~+14% at drain=32 vs
        /// per-item pop loop; see 2026-04-14-inject-head-contention audit).
        ///
        /// Correctness (check-then-reserve, 2026-07-13): `tail` may run ahead
        /// of the producers' VALUE/SEQUENCE stores (`tryPush` claims the slot
        /// via a tail CAS *before* writing), so tail-minus-head counts
        /// reserved-but-unpublished slots. The previous implementation
        /// reserved that whole range and then SPUN UNBOUNDED on each slot's
        /// sequence waiting for the mid-push producer — on an oversubscribed
        /// cgroup-throttled host (shared CI runners), consumers spinning in
        /// that loop burn exactly the CPU quota the preempted producer needs
        /// to finish its publish: a livelock observed as multi-hour silent
        /// test-shard hangs. Now the PUBLISHED PREFIX is measured first (one
        /// acquire load per slot) and only that prefix is reserved by the
        /// head CAS — after a CAS win the reserved slots are guaranteed
        /// published (a published, unconsumed slot can only transition via a
        /// consumer that first advances head past it, and head was ours), so
        /// the copy loop needs no waiting at all. A producer stalled on the
        /// FIRST slot truncates the batch to 0 and the caller falls through
        /// to other work-search sources — matching the documented
        /// "prefers freshness over best-effort reservation" contract.
        pub fn popMany(self: *Self, buf: []T) usize {
            if (buf.len == 0) return 0;
            const head = self.head.load(.monotonic);
            const tail = self.tail.load(.acquire);
            const avail_signed = @as(isize, @intCast(tail)) -% @as(isize, @intCast(head));
            if (avail_signed <= 0) return 0;
            const avail: usize = @intCast(avail_signed);
            const want = @min(avail, buf.len);

            // Published-prefix scan: stop at the first slot whose producer
            // has claimed (tail passed it) but not yet published.
            var take: usize = 0;
            while (take < want) : (take += 1) {
                const slot = &self.buffer[(head +% take) & self.mask];
                if (slot.sequence.load(.acquire) != head +% take +% 1) break;
            }
            if (take == 0) return 0;

            if (self.head.cmpxchgStrong(head, head +% take, .monotonic, .monotonic)) |_| {
                return 0;
            }
            var i: usize = 0;
            while (i < take) : (i += 1) {
                const slot = &self.buffer[(head +% i) & self.mask];
                buf[i] = slot.value;
                slot.sequence.store(head +% i +% self.buffer.len, .release);
            }
            return take;
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

test "bounded ring popMany basic" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 8);
    defer ring.deinit();

    for (0..5) |i| try std.testing.expect(ring.tryPush(@intCast(i * 10)));

    var buf: [4]u32 = undefined;
    const n = ring.popMany(buf[0..]);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u32, 0), buf[0]);
    try std.testing.expectEqual(@as(u32, 10), buf[1]);
    try std.testing.expectEqual(@as(u32, 20), buf[2]);
    try std.testing.expectEqual(@as(u32, 30), buf[3]);
    try std.testing.expectEqual(@as(?u32, 40), ring.pop());
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
}

test "bounded ring popMany empty returns zero" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    var buf: [8]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), ring.popMany(buf[0..]));
}

test "bounded ring popMany caps at available" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 8);
    defer ring.deinit();

    for (0..3) |i| try std.testing.expect(ring.tryPush(@intCast(i + 1)));

    var buf: [16]u32 = undefined;
    const n = ring.popMany(buf[0..]);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqual(@as(u32, 1), buf[0]);
    try std.testing.expectEqual(@as(u32, 2), buf[1]);
    try std.testing.expectEqual(@as(u32, 3), buf[2]);
    try std.testing.expectEqual(@as(?u32, null), ring.pop());
}

test "bounded ring popMany interleaved with pop" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 16);
    defer ring.deinit();

    for (0..10) |i| try std.testing.expect(ring.tryPush(@intCast(i)));

    try std.testing.expectEqual(@as(?u32, 0), ring.pop());

    var buf: [4]u32 = undefined;
    const n = ring.popMany(buf[0..]);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u32, 1), buf[0]);
    try std.testing.expectEqual(@as(u32, 4), buf[3]);

    try std.testing.expectEqual(@as(?u32, 5), ring.pop());
}

test "bounded ring popMany after wraparound" {
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 4);
    defer ring.deinit();

    for (0..4) |i| try std.testing.expect(ring.tryPush(@intCast(i)));
    for (0..4) |i| try std.testing.expectEqual(@as(?u32, @intCast(i)), ring.pop());

    for (0..4) |i| try std.testing.expect(ring.tryPush(@intCast(100 + i)));

    var buf: [4]u32 = undefined;
    const n = ring.popMany(buf[0..]);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqual(@as(u32, 100), buf[0]);
    try std.testing.expectEqual(@as(u32, 103), buf[3]);
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

test "bounded ring popMany truncates at a stalled producer instead of spinning" {
    // Regression for the 2026-07-13 consumer livelock: a producer preempted
    // between its tail-claim CAS and its value/sequence publish left
    // `tail > published`, and popMany reserved the whole range then spun
    // unbounded on the unpublished slot. Under the old implementation this
    // test HANGS (the spin never exits — nothing will publish slot 3);
    // under check-then-reserve it returns the published prefix immediately.
    const Ring = BoundedRing(u32);
    var ring = try Ring.init(std.testing.allocator, 8);
    defer ring.deinit();

    try std.testing.expect(ring.tryPush(1));
    try std.testing.expect(ring.tryPush(2));

    // Emulate a mid-push producer: claim the third slot exactly as
    // `tryPush`'s CAS does, but write neither value nor sequence.
    const stalled_tail = ring.tail.load(.monotonic);
    try std.testing.expect(ring.tail.cmpxchgStrong(stalled_tail, stalled_tail +% 1, .monotonic, .monotonic) == null);

    var buf: [8]u32 = undefined;
    // Published prefix (2 items) comes back without touching the stalled slot.
    try std.testing.expectEqual(@as(usize, 2), ring.popMany(buf[0..]));
    try std.testing.expectEqual(@as(u32, 1), buf[0]);
    try std.testing.expectEqual(@as(u32, 2), buf[1]);
    // Stalled slot is now FIRST: nothing consumable — return 0, do not wait.
    try std.testing.expectEqual(@as(usize, 0), ring.popMany(buf[0..]));

    // Producer wakes up and completes its publish (same stores tryPush does).
    const slot = &ring.buffer[@as(usize, @intCast(stalled_tail)) & ring.mask];
    slot.value = 3;
    slot.sequence.store(stalled_tail +% 1, .release);

    try std.testing.expectEqual(@as(usize, 1), ring.popMany(buf[0..]));
    try std.testing.expectEqual(@as(u32, 3), buf[0]);
}
