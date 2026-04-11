const std = @import("std");

pub const Accounting = struct {
    total_alloc_bytes: *std.atomic.Value(u64),
    total_free_bytes: *std.atomic.Value(u64),
    live_bytes: *std.atomic.Value(u64),
    peak_live_bytes: *std.atomic.Value(u64),

    pub fn recordAlloc(self: Accounting, bytes: usize) void {
        const amount = @as(u64, @intCast(bytes));
        _ = self.total_alloc_bytes.fetchAdd(amount, .monotonic);
        const live = self.live_bytes.fetchAdd(amount, .monotonic) + amount;
        updatePeak(self.peak_live_bytes, live);
    }

    pub fn recordFree(self: Accounting, bytes: usize) void {
        const amount = @as(u64, @intCast(bytes));
        _ = self.total_free_bytes.fetchAdd(amount, .monotonic);
        _ = self.live_bytes.fetchSub(amount, .monotonic);
    }

    fn updatePeak(counter: *std.atomic.Value(u64), value: u64) void {
        var current = counter.load(.monotonic);
        while (value > current) {
            const previous = counter.cmpxchgWeak(current, value, .monotonic, .monotonic);
            if (previous == null) return;
            current = previous.?;
        }
    }
};

pub const WorkerScratch = struct {
    allocator: std.mem.Allocator,
    accounting: Accounting,
    cap_bytes: usize,
    buffer: ?[]u8 = null,
    fba: ?std.heap.FixedBufferAllocator = null,
    current_bytes: usize = 0,
    peak_bytes: usize = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn init(allocator: std.mem.Allocator, accounting: Accounting, cap_bytes: usize) WorkerScratch {
        return .{
            .allocator = allocator,
            .accounting = accounting,
            .cap_bytes = cap_bytes,
        };
    }

    pub fn beginTask(self: *WorkerScratch) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.ensureBuffer();
        if (self.buffer) |buf| {
            self.fba = std.heap.FixedBufferAllocator.init(buf);
            self.current_bytes = 0;
        }
    }

    pub fn finishTask(self: *WorkerScratch) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.fba) |fba| {
            self.current_bytes = fba.end_index;
            if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
        } else {
            self.current_bytes = 0;
        }
    }

    pub fn alloc(self: *WorkerScratch, comptime T: type, count: usize) ![]T {
        self.mutex.lock();
        defer self.mutex.unlock();
        try self.ensureBuffer();
        if (self.fba == null) return error.ScratchUnavailable;
        var fba = &self.fba.?;
        const slice = try fba.allocator().alloc(T, count);
        self.current_bytes = fba.end_index;
        if (self.current_bytes > self.peak_bytes) self.peak_bytes = self.current_bytes;
        return slice;
    }

    pub fn purge(self: *WorkerScratch) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.buffer) |buf| {
            self.accounting.recordFree(buf.len);
            self.allocator.free(buf);
        }
        self.buffer = null;
        self.fba = null;
        self.current_bytes = 0;
    }

    pub fn bytesCurrent(self: *WorkerScratch) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.current_bytes;
    }

    pub fn bytesPeak(self: *WorkerScratch) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.peak_bytes;
    }

    fn ensureBuffer(self: *WorkerScratch) !void {
        if (self.cap_bytes == 0 or self.buffer != null) return;
        const buf = try self.allocator.alloc(u8, self.cap_bytes);
        self.accounting.recordAlloc(buf.len);
        self.buffer = buf;
        self.fba = std.heap.FixedBufferAllocator.init(buf);
    }
};

test "worker scratch respects fixed cap and purge" {
    var total_alloc = std.atomic.Value(u64).init(0);
    var total_free = std.atomic.Value(u64).init(0);
    var live = std.atomic.Value(u64).init(0);
    var peak = std.atomic.Value(u64).init(0);
    const accounting = Accounting{
        .total_alloc_bytes = &total_alloc,
        .total_free_bytes = &total_free,
        .live_bytes = &live,
        .peak_live_bytes = &peak,
    };

    var scratch = WorkerScratch.init(std.testing.allocator, accounting, 64);
    try scratch.beginTask();
    _ = try scratch.alloc(u8, 32);
    scratch.finishTask();
    try std.testing.expect(scratch.bytesCurrent() >= 32);
    scratch.purge();
    try std.testing.expectEqual(@as(usize, 0), scratch.bytesCurrent());
}
