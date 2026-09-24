//! Lock-free SPMC ring queue: per-worker local queue for the `work_stealing` and
//! `lane_extension` scheduler variants.
//!
//! Single producer (owner thread) pushes and pops from `tail` (LIFO). Any thread may
//! steal from `head` in batches via a seq_cst CAS. The batch-steal CAS is the
//! linearization point; stealers copy slots before the CAS and discard on loss. Buffer
//! size must be a power of 2.

const std = @import("std");

/// Lock-free SPMC ring queue modelled after Tokio's
/// `runtime/scheduler/multi_thread/queue.rs` and Go's `runq*` in
/// `runtime/proc.go`. Single producer (owner) pushes to `tail` and pops
/// from `tail` LIFO. Any thread may steal from `head` in batches.
///
/// Correctness sketch:
/// - Owner is the sole writer of `tail` and of slot contents.
/// - Stealers synchronize with each other via a seq_cst CAS on `head`.
///   The CAS is the linearization point: all slot reads within a single
///   batch are committed atomically from the stealer's POV.
/// - Owner never writes to any index `i` where `head <= i < tail`, so
///   stealers that copy slots between their `head` load and their CAS on
///   `head` cannot race the owner — worst case another stealer wins
///   the CAS and this stealer's slot reads are discarded.
/// - Owner-vs-stealer race on the last element: same pattern as
///   Chase-Lev's `popBottom`. Owner does a seq_cst fence and re-reads
///   `head` before claiming the slot; if the stealer has moved head past
///   the slot, the owner backs off.
///
/// Buffer size must be a power of 2.
pub fn RingQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buffer: []std.atomic.Value(T),
        mask: u32,
        head: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
        tail: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

        pub fn init(allocator: std.mem.Allocator, size: usize) !Self {
            std.debug.assert(size > 0 and (size & (size - 1)) == 0);
            std.debug.assert(size <= std.math.maxInt(u32) / 2);
            const buf = try allocator.alloc(std.atomic.Value(T), size);
            for (buf) |*slot| slot.* = std.atomic.Value(T).init(undefined);
            return .{
                .allocator = allocator,
                .buffer = buf,
                .mask = @intCast(size - 1),
            };
        }

        pub fn deinit(self: *Self) void {
            self.allocator.free(self.buffer);
            self.* = undefined;
        }

        pub fn capacity(self: *const Self) usize {
            return self.buffer.len;
        }

        /// Approximate count. Safe from any thread; may be stale.
        pub fn len(self: *const Self) usize {
            const t = self.tail.load(.acquire);
            const h = self.head.load(.acquire);
            const diff = t -% h;
            // Owner's `pop` transiently stores `tail = t-1` before the empty-check;
            // a stealer reading that intermediate tail with a still-current head
            // computes `t -% h` as a wrapped value > capacity. Clamp to 0 so
            // callers (stats peak tracking, empty-victim skip) see a consistent
            // "empty or near-empty" state rather than ~u32_max.
            if (diff > @as(u32, @intCast(self.buffer.len))) return 0;
            return diff;
        }

        /// Owner-only. Push an item to the tail. Returns false if full.
        pub fn tryPush(self: *Self, value: T) bool {
            const t = self.tail.load(.monotonic);
            const h = self.head.load(.acquire);
            if (t -% h >= @as(u32, @intCast(self.buffer.len))) return false;
            self.buffer[t & self.mask].store(value, .unordered);
            // Release ensures the slot write is visible before tail advances.
            self.tail.store(t +% 1, .release);
            return true;
        }

        /// Owner-only. Pop from the tail (LIFO). Returns null if empty.
        pub fn pop(self: *Self) ?T {
            const t = self.tail.load(.monotonic);
            const new_tail = t -% 1;
            // Reserve the slot by dropping tail first; seq_cst pair with
            // stealers' CAS on head resolves the last-element race.
            self.tail.store(new_tail, .seq_cst);
            const h = self.head.load(.seq_cst);
            if (h == t) {
                // Queue was empty — restore tail and bail.
                self.tail.store(t, .monotonic);
                return null;
            }
            const value = self.buffer[new_tail & self.mask].load(.monotonic);
            if (h == new_tail) {
                // Last element: race with stealers.
                if (self.head.cmpxchgStrong(h, h +% 1, .seq_cst, .monotonic) != null) {
                    // A stealer won; queue is now empty.
                    self.tail.store(t, .monotonic);
                    return null;
                }
                // We won — publish the empty state.
                self.tail.store(t, .monotonic);
            }
            return value;
        }

        /// Any thread. Steal up to `(len+1)/2` items into `dst`. Returns the
        /// number stolen (0..dst.len). Copies happen *before* the CAS; on
        /// CAS failure we retry the whole batch. No ABA because `head` is
        /// monotonically increasing within the u32 range we actually use.
        pub fn stealHalf(self: *Self, dst: []T) usize {
            if (dst.len == 0) return 0;
            // Retry budget. The transient `avail > capacity` window (owner
            // mid-pop) and CAS-contention retries should resolve within a
            // handful of iterations; anything longer signals either a genuine
            // livelock (e.g. pre-existing head-past-tail wrap state reached
            // via a still-uncharacterized race in pop/steal) or a degenerate
            // contention pattern that's better served by moving to the next
            // victim. Cap rather than spin forever so shutdown cannot stall
            // waiting for a livelocked worker to leave stealHalf.
            var retries: u32 = 0;
            while (true) {
                if (retries >= 256) return 0;
                retries += 1;
                const h = self.head.load(.acquire);
                // Acquire on tail pairs with the owner's release on push.
                const t = self.tail.load(.acquire);
                const avail = t -% h;
                if (avail == 0) return 0;
                // Owner's `pop` transiently stores `tail = t-1` before checking
                // for the empty race; a stealer observing that intermediate
                // tail alongside an unchanged head sees `avail` wrap past
                // buffer capacity. Treat it as a transient inconsistent read
                // and retry rather than trusting the value.
                if (avail > @as(u32, @intCast(self.buffer.len))) continue;
                // Steal half (round up) — matches Tokio/Go.
                var n: u32 = (avail + 1) / 2;
                if (n > @as(u32, @intCast(dst.len))) n = @intCast(dst.len);

                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    dst[i] = self.buffer[(h +% i) & self.mask].load(.monotonic);
                }

                if (self.head.cmpxchgStrong(h, h +% n, .seq_cst, .monotonic) == null) {
                    return n;
                }
                // CAS failed: another stealer (or owner last-element race)
                // moved head. Retry — the slot reads are discarded.
            }
        }
    };
}

test "ring queue: push/pop LIFO" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 8);
    defer q.deinit();

    try std.testing.expect(q.tryPush(1));
    try std.testing.expect(q.tryPush(2));
    try std.testing.expect(q.tryPush(3));
    try std.testing.expectEqual(@as(?u32, 3), q.pop());
    try std.testing.expectEqual(@as(?u32, 2), q.pop());
    try std.testing.expectEqual(@as(?u32, 1), q.pop());
    try std.testing.expectEqual(@as(?u32, null), q.pop());
}

test "ring queue: full rejects push" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 2);
    defer q.deinit();

    try std.testing.expect(q.tryPush(10));
    try std.testing.expect(q.tryPush(20));
    try std.testing.expect(!q.tryPush(30));
    try std.testing.expectEqual(@as(usize, 2), q.len());
}

test "ring queue: stealHalf copies half and advances head" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 16);
    defer q.deinit();
    var i: u32 = 0;
    while (i < 10) : (i += 1) _ = q.tryPush(i);

    var out: [16]u32 = undefined;
    const n = q.stealHalf(out[0..]);
    // (10+1)/2 = 5
    try std.testing.expectEqual(@as(usize, 5), n);
    try std.testing.expectEqual(@as(u32, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 4), out[4]);
    try std.testing.expectEqual(@as(usize, 5), q.len());
}

test "ring queue: stealHalf empty returns 0" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 16);
    defer q.deinit();
    var out: [4]u32 = undefined;
    try std.testing.expectEqual(@as(usize, 0), q.stealHalf(out[0..]));
}

test "ring queue: stealHalf caps at dst.len" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 16);
    defer q.deinit();
    var i: u32 = 0;
    while (i < 10) : (i += 1) _ = q.tryPush(i);

    var out: [2]u32 = undefined;
    const n = q.stealHalf(out[0..]);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(u32, 0), out[0]);
    try std.testing.expectEqual(@as(u32, 1), out[1]);
}

test "ring queue: wraparound via head advance" {
    const Q = RingQueue(u32);
    var q = try Q.init(std.testing.allocator, 4);
    defer q.deinit();
    try std.testing.expect(q.tryPush(1));
    try std.testing.expect(q.tryPush(2));
    var out: [1]u32 = undefined;
    _ = q.stealHalf(out[0..]); // consumes 1 (since (2+1)/2 = 1)
    try std.testing.expect(q.tryPush(3));
    try std.testing.expect(q.tryPush(4));
    try std.testing.expect(q.tryPush(5));
    try std.testing.expect(!q.tryPush(6)); // full (head=1, tail=5, capacity=4)
}

// SONNY-2448: deterministic replays of the owner-pop vs batch-steal race.
//
// `stealHalf` loads `head` and `tail`, copies up to half the queue, and only
// then claims the copy with a CAS on `head`. A stealer can be preempted
// between the copy and the CAS for any length of time. These replays hold
// that window open: `StealReplay.snapshot` performs stealHalf's steps up to
// the claim, the owner runs `pop`/`tryPush` inside the window, and
// `StealReplay.finish` performs the claim. A claim that fails is a stale
// copy that stealHalf discards and retries, so `finish` then calls the real
// `stealHalf`. Every value handed out, by the owner or by a claimed batch,
// goes through a `Ledger`, which checks that each pushed value was taken
// exactly once and that nothing else was.
//
// In the pool, the three outcomes these replays pin were: a panic on a
// never-written slot (`index out of bounds: index 2863311530` in runTask,
// i.e. 0xAAAAAAAA), a task that never ran and hung its wait group, and a
// task dispatched twice.

/// Test-only record of every value pushed to, and taken from, a replayed
/// queue.
const Ledger = struct {
    pushed: [16]bool = [_]bool{false} ** 16,
    taken: [16]u8 = [_]u8{0} ** 16,
    /// Values handed out that were never pushed: a slot that was never
    /// written, or one whose value was already consumed and overwritten.
    never_pushed: usize = 0,

    fn push(self: *Ledger, q: *RingQueue(u32), value: u32) !void {
        try std.testing.expect(q.tryPush(value));
        self.pushed[value] = true;
    }

    fn take(self: *Ledger, value: u32) void {
        if (value >= self.pushed.len or !self.pushed[value]) {
            self.never_pushed += 1;
            return;
        }
        self.taken[value] += 1;
    }

    /// The owner pops until `pop` reports empty. No queue ever holds more
    /// than `capacity` items, so a pop that returns more has walked past
    /// the items that exist.
    fn drain(self: *Ledger, q: *RingQueue(u32)) !void {
        var pops: usize = 0;
        while (q.pop()) |value| {
            pops += 1;
            if (pops > q.capacity()) return error.PopNeverEmpties;
            self.take(value);
        }
    }

    fn expectNothingNeverPushed(self: *const Ledger) !void {
        if (self.never_pushed != 0) {
            std.debug.print("{d} value(s) handed out were never pushed\n", .{self.never_pushed});
            return error.NeverPushedValue;
        }
    }

    fn expectNoDuplicate(self: *const Ledger) !void {
        for (self.taken, 0..) |count, value| {
            if (count > 1) {
                std.debug.print("value {d} was taken {d} times\n", .{ value, count });
                return error.DuplicateTake;
            }
        }
    }

    fn expectNoneLost(self: *const Ledger) !void {
        for (self.pushed, self.taken, 0..) |pushed, count, value| {
            if (pushed and count == 0) {
                std.debug.print("value {d} was pushed but never taken\n", .{value});
                return error.LostValue;
            }
        }
    }

    fn expectEachTakenOnce(self: *const Ledger) !void {
        try self.expectNothingNeverPushed();
        try self.expectNoDuplicate();
        try self.expectNoneLost();
    }
};

/// Test-only: `stealHalf` split at its claim.
const StealReplay = struct {
    head: u32,
    n: u32,
    batch: [8]u32 = undefined,

    /// stealHalf's steps before its CAS: load head, then tail; size the
    /// batch at half the queue, rounded up; copy the batch's slots.
    fn snapshot(q: *RingQueue(u32)) StealReplay {
        const h = q.head.load(.acquire);
        const t = q.tail.load(.acquire);
        var steal: StealReplay = .{ .head = h, .n = (t -% h + 1) / 2 };
        std.debug.assert(steal.n <= steal.batch.len);
        for (steal.batch[0..steal.n], 0..) |*slot, i| {
            slot.* = q.buffer[(h +% @as(u32, @intCast(i))) & q.mask].load(.monotonic);
        }
        return steal;
    }

    /// stealHalf's claim: the same CAS on `head`. On success the stealer
    /// owns its copied batch. On failure it discards the copy and retries,
    /// which here is a call to the real `stealHalf`.
    fn finish(self: *const StealReplay, q: *RingQueue(u32), ledger: *Ledger) void {
        if (q.head.cmpxchgStrong(self.head, self.head +% self.n, .seq_cst, .monotonic) == null) {
            for (self.batch[0..self.n]) |value| ledger.take(value);
            return;
        }
        var retry: [8]u32 = undefined;
        const n = q.stealHalf(retry[0..]);
        for (retry[0..n]) |value| ledger.take(value);
    }
};

fn expectHeadNotPastTail(q: *RingQueue(u32)) !void {
    const h = q.head.load(.monotonic);
    const t = q.tail.load(.monotonic);
    if (t -% h > q.capacity()) {
        std.debug.print("head {d} is past tail {d}\n", .{ h, t });
        return error.HeadPastTail;
    }
}

test "ring queue replay (SONNY-2448): a batch claim never moves head past tail" {
    // Old LIFO pop: the owner took 3 and 2 from the tail, the claim (head
    // still 0) landed anyway, and head = 2 was past tail = 1. Later pops
    // returned 1 again, then slots never written, while tail wrapped.
    var q = try RingQueue(u32).init(std.testing.allocator, 8);
    defer q.deinit();
    var ledger: Ledger = .{};
    for ([_]u32{ 1, 2, 3 }) |value| try ledger.push(&q, value);

    const steal = StealReplay.snapshot(&q); // head 0, tail 3: batch {1, 2}
    try std.testing.expectEqual(@as(u32, 2), steal.n);
    ledger.take(q.pop().?);
    ledger.take(q.pop().?);
    steal.finish(&q, &ledger);

    try expectHeadNotPastTail(&q);
    try ledger.drain(&q);
    try ledger.expectEachTakenOnce();
    try std.testing.expectEqual(@as(usize, 0), q.len());

    // The queue is still usable.
    try ledger.push(&q, 4);
    try ledger.drain(&q);
    try ledger.expectEachTakenOnce();
}

test "ring queue replay (SONNY-2448): a push inside an in-flight batch is never lost" {
    // Old LIFO pop: the owner took 3 and 2, then pushed 4 into slot 1,
    // inside the stealer's batch. The claim landed (head 2 == tail 2), so
    // 4 sat below head and no pop or steal could reach it; in the pool
    // that task never ran and its wait group never completed.
    var q = try RingQueue(u32).init(std.testing.allocator, 8);
    defer q.deinit();
    var ledger: Ledger = .{};
    for ([_]u32{ 1, 2, 3 }) |value| try ledger.push(&q, value);

    const steal = StealReplay.snapshot(&q); // batch {1, 2}
    ledger.take(q.pop().?);
    ledger.take(q.pop().?);
    try ledger.push(&q, 4);
    steal.finish(&q, &ledger);

    try ledger.drain(&q);
    try ledger.expectNoneLost();
    try expectHeadNotPastTail(&q);
    try ledger.expectEachTakenOnce();
}

test "ring queue replay (SONNY-2448): the owner and a stealer never take the same item" {
    // Old LIFO pop: the owner took 4 and 3, then 2 from inside the
    // stealer's batch {1, 2}. The claim landed, so 2 was handed out twice;
    // in the pool, the second dispatch of that entry reached runTask.
    var q = try RingQueue(u32).init(std.testing.allocator, 8);
    defer q.deinit();
    var ledger: Ledger = .{};
    for ([_]u32{ 1, 2, 3, 4 }) |value| try ledger.push(&q, value);

    const steal = StealReplay.snapshot(&q); // head 0, tail 4: batch {1, 2}
    try std.testing.expectEqual(@as(u32, 2), steal.n);
    ledger.take(q.pop().?);
    ledger.take(q.pop().?);
    ledger.take(q.pop().?);
    steal.finish(&q, &ledger);

    try ledger.expectNoDuplicate();
    try expectHeadNotPastTail(&q);
    try ledger.drain(&q);
    try ledger.expectEachTakenOnce();
}
