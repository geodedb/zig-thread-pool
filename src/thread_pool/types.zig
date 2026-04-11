const std = @import("std");

pub const SchedulerVariant = enum {
    global_queue,
    work_stealing,
    lane_extension,
};

pub const AllocatorMode = enum {
    caller_supplied,
    caller_supplied_with_worker_scratch,
};

pub const TaskLane = enum {
    default,
    blocking,
    keyed,
};

pub const BackpressurePolicy = enum {
    return_error,
    block,
    block_with_timeout,
};

pub const ShutdownMode = enum {
    drain,
    cancel_pending,
};

pub const TaskState = enum(u8) {
    free,
    reserved,
    queued,
    running,
    completed,
    cancelled,
};

pub const Config = struct {
    min_threads: usize = 0,
    max_threads: usize = 0,
    queue_capacity: usize = 1024,
    local_queue_capacity: usize = 256,
    inject_batch_size: usize = 32,
    worker_scratch_cap_bytes: usize = 64 * 1024,
    idle_park_after_ns: u64 = 250_000,
    idle_purge_after_ns: u64 = 5_000_000,
    idle_shrink_after_ns: u64 = 60_000_000_000,
    spin_before_park_iters: usize = 128,
    scheduler_variant: SchedulerVariant = .global_queue,
    allow_blocking_lane: bool = false,
    allocator_mode: AllocatorMode = .caller_supplied_with_worker_scratch,
    stats_enabled: bool = true,

    pub fn normalized(self: Config) Config {
        var cfg = self;
        const cpu_guess = @max(std.Thread.getCpuCount() catch 1, 1);
        if (cfg.max_threads == 0) {
            cfg.max_threads = cpu_guess;
        }
        if (cfg.min_threads == 0) {
            cfg.min_threads = cfg.max_threads;
        }
        if (cfg.min_threads > cfg.max_threads) {
            cfg.min_threads = cfg.max_threads;
        }
        if (cfg.inject_batch_size == 0) {
            cfg.inject_batch_size = 1;
        }
        return cfg;
    }

    pub fn validate(self: Config) !void {
        if (self.max_threads == 0) return error.InvalidMaxThreads;
        if (self.min_threads == 0) return error.InvalidMinThreads;
        if (self.min_threads > self.max_threads) return error.InvalidThreadBounds;
        if (self.queue_capacity == 0) return error.InvalidQueueCapacity;
        if (self.scheduler_variant == .work_stealing and self.local_queue_capacity == 0) {
            return error.InvalidLocalQueueCapacity;
        }
        if (self.inject_batch_size == 0) return error.InvalidInjectBatchSize;
    }
};

pub const SubmitOptions = struct {
    waitable: bool = false,
    wait_group: ?*WaitGroup = null,
    cancellation_token: ?*CancellationToken = null,
    backpressure: BackpressurePolicy = .return_error,
    timeout_ns: ?u64 = null,
    lane: TaskLane = .default,
};

pub const TaskHandle = struct {
    index: u32 = std.math.maxInt(u32),
    generation: u64 = 0,
    waitable: bool = false,

    pub fn invalid() TaskHandle {
        return .{};
    }

    pub fn isValid(self: TaskHandle) bool {
        return self.waitable and self.index != std.math.maxInt(u32);
    }
};

pub const CancellationToken = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn cancel(self: *CancellationToken) void {
        self.cancelled.store(true, .release);
    }

    pub fn isCancelled(self: *const CancellationToken) bool {
        return self.cancelled.load(.acquire);
    }
};

pub const WaitGroup = struct {
    pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},

    pub fn add(self: *WaitGroup, delta: u32) void {
        _ = self.pending.fetchAdd(delta, .monotonic);
    }

    pub fn done(self: *WaitGroup) void {
        const previous = self.pending.fetchSub(1, .acq_rel);
        if (previous == 1) {
            self.mutex.lock();
            defer self.mutex.unlock();
            self.cond.broadcast();
        }
    }

    pub fn wait(self: *WaitGroup) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.pending.load(.acquire) != 0) {
            self.cond.wait(&self.mutex);
        }
    }

    pub fn pendingCount(self: *const WaitGroup) u32 {
        return self.pending.load(.acquire);
    }
};

pub const LatencySummary = struct {
    count: u64 = 0,
    min_ns: u64 = 0,
    mean_ns: u64 = 0,
    p50_ns: u64 = 0,
    p95_ns: u64 = 0,
    p99_ns: u64 = 0,
    max_ns: u64 = 0,
};

pub const WorkerStats = struct {
    worker_index: usize = 0,
    busy_ns: u64 = 0,
    idle_ns: u64 = 0,
    local_queue_depth: u32 = 0,
    local_queue_peak: u32 = 0,
    parks: u64 = 0,
    wakeups: u64 = 0,
    steals: u64 = 0,
    steal_failures: u64 = 0,
    scratch_current_bytes: u64 = 0,
    scratch_peak_bytes: u64 = 0,
};

pub const ProcessMemoryStats = struct {
    rss_current_bytes: u64 = 0,
    rss_peak_bytes: u64 = 0,
    private_current_bytes: u64 = 0,
    private_peak_bytes: u64 = 0,
};

pub const Stats = struct {
    submitted: u64 = 0,
    started: u64 = 0,
    completed: u64 = 0,
    cancelled: u64 = 0,
    active_workers: u64 = 0,
    parked_workers: u64 = 0,
    retired_workers: u64 = 0,
    queue_depth_current: u64 = 0,
    queue_depth_peak: u64 = 0,
    steals: u64 = 0,
    steal_failures: u64 = 0,
    wakeups: u64 = 0,
    parks: u64 = 0,
    task_desc_live: u64 = 0,
    task_desc_peak: u64 = 0,
    total_alloc_bytes: u64 = 0,
    total_free_bytes: u64 = 0,
    live_bytes: u64 = 0,
    peak_live_bytes: u64 = 0,
    task_wait_ns: LatencySummary = .{},
    task_exec_ns: LatencySummary = .{},
    memory: ProcessMemoryStats = .{},
    worker_stats: []const WorkerStats = &.{},
};

test "Config validation rejects impossible bounds" {
    var cfg = Config{ .max_threads = 1, .min_threads = 2 };
    try std.testing.expectError(error.InvalidThreadBounds, cfg.validate());
}

test "WaitGroup blocks until count reaches zero" {
    var wg = WaitGroup{};
    wg.add(2);
    try std.testing.expectEqual(@as(u32, 2), wg.pendingCount());
    wg.done();
    try std.testing.expectEqual(@as(u32, 1), wg.pendingCount());
    wg.done();
    wg.wait();
    try std.testing.expectEqual(@as(u32, 0), wg.pendingCount());
}
