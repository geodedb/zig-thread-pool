const std = @import("std");

pub const SchedulerVariant = enum {
    global_queue,
    work_stealing,
    lane_extension,
};

pub const TaskLane = enum {
    default,
    blocking,
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

/// Task lifecycle state machine:
///
///     free ──> reserved ──> queued ──> running ──> completed
///      ^                                  │            │
///      │                                  └──> cancelled│
///      │                                       │       │
///      └───────────────────────────────────────-┴───────┘
///
/// - `free`:      Descriptor slot available for reuse.
/// - `reserved`:  Slot claimed by acquireDescriptor; being populated.
/// - `queued`:    Task enqueued in inject or local queue.
/// - `running`:   Worker thread is executing the task function.
/// - `completed`: Task finished normally; awaiting wait() or auto-release.
/// - `cancelled`: Task was cancelled before or during execution.
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
    spin_before_park_iters: usize = 128,
    deinit_timeout_ns: u64 = 30_000_000_000,
    scheduler_variant: SchedulerVariant = .global_queue,
    /// Advisory flag indicating the caller intends to submit blocking tasks.
    /// Currently metadata-only: all lanes share the same worker set.
    /// A future lane_extension scheduler may use this to reserve a dedicated
    /// blocking worker subset. Setting this to false does not prevent submitting
    /// tasks with `.lane = .blocking`.
    allow_blocking_lane: bool = false,

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
        if (cfg.local_queue_capacity != 0) {
            cfg.local_queue_capacity = std.math.ceilPowerOfTwo(usize, cfg.local_queue_capacity) catch cfg.local_queue_capacity;
        }
        if (cfg.queue_capacity != 0) {
            cfg.queue_capacity = std.math.ceilPowerOfTwo(usize, cfg.queue_capacity) catch cfg.queue_capacity;
        }
        return cfg;
    }

    pub fn validate(self: Config) !void {
        if (self.max_threads == 0) return error.InvalidMaxThreads;
        if (self.min_threads == 0) return error.InvalidMinThreads;
        if (self.min_threads > self.max_threads) return error.InvalidThreadBounds;
        if (self.queue_capacity == 0 or self.queue_capacity > std.math.maxInt(u32)) return error.InvalidQueueCapacity;
        if (self.local_queue_capacity == 0) {
            return error.InvalidLocalQueueCapacity;
        }
        if (self.scheduler_variant == .lane_extension) return error.UnsupportedSchedulerVariant;
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
        std.debug.assert(previous > 0);
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
    active_tasks: u64 = 0,
    parked_workers: u64 = 0,
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
    total_alloc_count: u64 = 0,
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

test "Config validation rejects lane_extension variant" {
    var cfg = Config{ .max_threads = 2, .min_threads = 1, .scheduler_variant = .lane_extension };
    cfg = cfg.normalized();
    try std.testing.expectError(error.UnsupportedSchedulerVariant, cfg.validate());
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

test "Config normalized rounds local_queue_capacity to power of two" {
    const cfg = (Config{ .local_queue_capacity = 100 }).normalized();
    try std.testing.expectEqual(@as(usize, 128), cfg.local_queue_capacity);

    const cfg2 = (Config{ .local_queue_capacity = 256 }).normalized();
    try std.testing.expectEqual(@as(usize, 256), cfg2.local_queue_capacity);

    const cfg3 = (Config{ .local_queue_capacity = 1 }).normalized();
    try std.testing.expectEqual(@as(usize, 1), cfg3.local_queue_capacity);
}

test "Config normalized rounds queue_capacity to power of two" {
    const cfg = (Config{ .queue_capacity = 1000 }).normalized();
    try std.testing.expectEqual(@as(usize, 1024), cfg.queue_capacity);
}
