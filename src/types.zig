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

/// Controls per-task timestamp behavior.  `full` records submit/start/complete
/// timestamps and populates wait/exec histograms — the legacy v0.2.0 mode.
/// `disabled` skips submit/start clock reads and the histogram observes,
/// saving ~40–80ns per task on Linux.  The complete-time clock read is kept
/// because the idle-purge logic in `idle()` depends on
/// `worker.last_idle_started_ns` to decide when to release scratch buffers.
pub const TimestampMode = enum {
    full,
    disabled,
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

pub const QueueKind = enum {
    /// Chase-Lev work-stealing deque. Correct for single-item steal only.
    chase_lev,
    /// Tokio-style SPMC ring. Supports batch-steal via stealHalf. Default.
    ring,
};

pub const Config = struct {
    min_threads: usize = 0,
    /// Maximum worker threads. Hard capped at 64 because the steal-scan
    /// non-empty-workers bitmap uses a single u64. `validate()` rejects
    /// values > 64 with `error.TooManyWorkers`. 0 means "auto-detect from
    /// CPU count" in `normalized()`; detected values above 64 are clamped.
    max_threads: usize = 0,
    queue_capacity: usize = 1024,
    /// Per-worker incoming-queue capacity. External (non-worker-thread)
    /// submitters rotate pushes across these per-Worker queues to reduce
    /// cacheline contention on the global inject_queue. When `0`,
    /// `normalized()` derives `@max(64, round-up-pow2(queue_capacity / max_threads))`.
    /// User-supplied values are rounded up to the next power of two.
    /// See docs/superpowers/plans/2026-04-14-option3-worker-local-incoming-queues.md.
    incoming_capacity: usize = 0,
    local_queue_capacity: usize = 256,
    inject_batch_size: usize = 32,
    /// `releaseDescriptor` signals blocked submitters on backpressure once
    /// per this many releases, rather than on every release. 0 disables
    /// coalescing (signal every release — the pre-2026-04-12 behavior).
    /// The submitter's `timedWait` on `backpressure_cond` bounds worst-case
    /// missed-signal latency.
    wake_coalesce_batch: u32 = 32,
    /// Number of workers reserved as always-spinning hot workers.
    /// These workers never park; they consume 1 core each at 100% CPU
    /// but catch submits without requiring a futex wake. When > 0, the
    /// submitter skips the wake scan entirely — hot-spinners propagate
    /// wakes themselves every `wake_every_n_tasks` tasks executed.
    ///
    /// Default 0 disables the feature (preserves current behavior).
    /// Must be strictly less than `max_threads` — at least one
    /// non-hot worker is required for the parked-worker fallback.
    /// See docs/superpowers/specs/2026-04-12-phase-f1b-reserved-hot-spinners-design.md.
    hot_spinners: u32 = 0,

    /// Hot-spinner wake propagation threshold. After executing this
    /// many tasks, a hot-spinner issues one `futex_wake` to recruit a
    /// parked worker. Amortizes wake cost across many submits while
    /// bounding worst-case wake latency to ~K × per-task duration.
    /// Ignored when `hot_spinners == 0`. Setting this to 0 while
    /// `hot_spinners > 0` is rejected by `validate()` — would starve
    /// parked workers on long-running tasks.
    wake_every_n_tasks: u32 = 64,
    worker_scratch_cap_bytes: usize = 64 * 1024,
    idle_park_after_ns: u64 = 250_000,
    idle_purge_after_ns: u64 = 5_000_000,
    /// Phase G2 (re-land 2026-04-13): default 0. Once the spin's
    /// `queued_tasks` poll was removed (the dominant cross-core read on
    /// that cacheline), the spin body became pure CPU burn. Setting this
    /// to a non-zero value forces a `spinLoopHint` delay loop with only
    /// a per-iter `state` check — useful for stress tests that need to
    /// reproduce the polless-spin handshake (see tests/stress.zig:516,
    /// :75, :290) but not for normal workloads.
    spin_before_park_iters: usize = 0,
    deinit_timeout_ns: u64 = 30_000_000_000,
    scheduler_variant: SchedulerVariant = .global_queue,
    queue_kind: QueueKind = .ring,
    /// Advisory flag indicating the caller intends to submit blocking tasks.
    /// Currently metadata-only: all lanes share the same worker set.
    /// A future lane_extension scheduler may use this to reserve a dedicated
    /// blocking worker subset. Setting this to false does not prevent submitting
    /// tasks with `.lane = .blocking`.
    allow_blocking_lane: bool = false,
    timestamp_mode: TimestampMode = .full,
    /// Maximum number of tasks a stealer takes from a single victim per steal
    /// attempt. With `queue_kind = .ring`, true batch-steal via stealHalf is
    /// used and values > 1 are correct. With `queue_kind = .chase_lev`,
    /// only single-item steal is correct and the runtime forces this to 1
    /// via `normalized()`.
    steal_batch_size: usize = 8,

    pub fn normalized(self: Config) Config {
        var cfg = self;
        const cpu_guess = @max(std.Thread.getCpuCount() catch 1, 1);
        if (cfg.max_threads == 0) {
            cfg.max_threads = @min(cpu_guess, 64);
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
        if (cfg.incoming_capacity == 0) {
            const per = if (cfg.max_threads == 0) cfg.queue_capacity else cfg.queue_capacity / cfg.max_threads;
            const rounded = std.math.ceilPowerOfTwo(usize, @max(1, per)) catch per;
            cfg.incoming_capacity = @max(64, rounded);
        } else {
            cfg.incoming_capacity = std.math.ceilPowerOfTwo(usize, cfg.incoming_capacity) catch cfg.incoming_capacity;
        }
        cfg.steal_batch_size = std.math.clamp(cfg.steal_batch_size, 1, 32);
        if (cfg.queue_kind == .chase_lev) cfg.steal_batch_size = 1;
        if (cfg.wake_coalesce_batch > 1024) cfg.wake_coalesce_batch = 1024;
        return cfg;
    }

    pub fn validate(self: Config) !void {
        if (self.max_threads == 0) return error.InvalidMaxThreads;
        if (self.max_threads > 64) return error.TooManyWorkers;
        if (self.min_threads == 0) return error.InvalidMinThreads;
        if (self.min_threads > self.max_threads) return error.InvalidThreadBounds;
        if (self.queue_capacity == 0 or self.queue_capacity > std.math.maxInt(u32)) return error.InvalidQueueCapacity;
        if (self.incoming_capacity == 0 or self.incoming_capacity > std.math.maxInt(u32)) return error.InvalidIncomingCapacity;
        if (self.local_queue_capacity == 0) {
            return error.InvalidLocalQueueCapacity;
        }
        if (self.scheduler_variant == .lane_extension) return error.UnsupportedSchedulerVariant;
        if (self.inject_batch_size == 0) return error.InvalidInjectBatchSize;
        if (self.hot_spinners >= self.max_threads) return error.InvalidHotSpinners;
        if (self.hot_spinners > 0 and self.wake_every_n_tasks == 0) return error.InvalidWakeThreshold;
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
        if (previous == 0) {
            @panic("WaitGroup: done() called more times than add()");
        }
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
    started: u64 = 0,
    completed: u64 = 0,
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

test "Config normalized derives incoming_capacity from queue_capacity / max_threads with power-of-2 rounding, min 64" {
    const cfg1 = (Config{ .queue_capacity = 1024, .max_threads = 8, .min_threads = 8 }).normalized();
    try std.testing.expectEqual(@as(usize, 128), cfg1.incoming_capacity);

    const cfg2 = (Config{ .queue_capacity = 1024, .max_threads = 56, .min_threads = 56 }).normalized();
    try std.testing.expectEqual(@as(usize, 64), cfg2.incoming_capacity);

    const cfg3 = (Config{ .queue_capacity = 1024, .max_threads = 6, .min_threads = 6 }).normalized();
    try std.testing.expectEqual(@as(usize, 256), cfg3.incoming_capacity);

    const cfg4 = (Config{ .incoming_capacity = 100, .queue_capacity = 1024, .max_threads = 8, .min_threads = 8 }).normalized();
    try std.testing.expectEqual(@as(usize, 128), cfg4.incoming_capacity);

    const cfg5 = (Config{ .incoming_capacity = 512, .queue_capacity = 1024, .max_threads = 8, .min_threads = 8 }).normalized();
    try std.testing.expectEqual(@as(usize, 512), cfg5.incoming_capacity);
}

test "Config validate rejects incoming_capacity > maxInt(u32)" {
    var cfg = (Config{ .max_threads = 1, .min_threads = 1, .queue_capacity = 64 }).normalized();
    cfg.incoming_capacity = @as(usize, std.math.maxInt(u32)) + 1;
    try std.testing.expectError(error.InvalidIncomingCapacity, cfg.validate());
}
