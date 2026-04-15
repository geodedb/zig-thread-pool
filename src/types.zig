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
    /// When true, tasks submitted with `.lane = .blocking` are accepted and
    /// routed to a dedicated blocking-lane inject queue served by the workers
    /// reserved via `blocking_workers`. When false, `.lane = .blocking`
    /// submissions return `error.BlockingLaneDisabled`. Independent of
    /// `scheduler_variant` — the default `global_queue` and `work_stealing`
    /// variants also honor the flag.
    allow_blocking_lane: bool = false,
    /// Number of workers carved out of `max_threads` to serve the blocking
    /// lane. Not additive: if `max_threads = 8` and `blocking_workers = 2`,
    /// the pool spawns 8 threads, 2 of which serve blocking and 6 of which
    /// serve the default lane. Blocking workers drain the blocking-lane
    /// inject queue and never touch default-lane work (Slice L1 — dynamic
    /// rebalancing lands in Slice L3). Default workers only drain the
    /// default-lane queue.
    ///
    /// Must be strictly less than `max_threads` (at least one default worker
    /// required). `blocking_workers > 0` requires `allow_blocking_lane = true`.
    /// Default 0 preserves pre-lane-extension behavior byte-for-byte.
    /// See `docs/superpowers/specs/2026-04-15-lane-extension-scheduler-design.md`.
    blocking_workers: u32 = 0,
    /// Slice L2 — capacity of the blocking-lane inject queue. 0 means "use
    /// `queue_capacity`" (L1 behavior). Rounded to power-of-two in
    /// `normalized()`. Ignored when `blocking_workers == 0` (no blocking queue
    /// is allocated in that case). Letting operators size the lanes
    /// independently is the common reason to reach for L2 — a blocking lane
    /// that holds 8 long sleepers needs far less capacity than the default
    /// lane feeding thousands of CPU tasks.
    blocking_queue_capacity: usize = 0,
    /// Slice L2 — pool-wide override for blocking-lane backpressure policy.
    /// `null` means "inherit the caller's `SubmitOptions.backpressure`"
    /// (L1 behavior). Non-null forces the lane's submitters to use this
    /// policy regardless of what the caller asked for. The common use:
    /// force `.return_error` so an overloaded blocking lane cannot stall
    /// request handlers that happen to submit via `.block`.
    blocking_backpressure: ?BackpressurePolicy = null,
    /// Slice L2 — same pattern for the default lane. Symmetry matters:
    /// some deployments want the opposite invariant (force `.block` on
    /// default, `.return_error` on blocking).
    default_backpressure: ?BackpressurePolicy = null,
    /// Slice L3 — when true, default-lane workers fall back to the
    /// blocking inject queue (and steal from blocking workers' local
    /// queues) when their own lane is idle. Off by default because it
    /// violates the "CPU workers never touch blocking lane" isolation
    /// invariant — a blocking task executed on a CPU worker blocks
    /// that core from CPU work, and subsequent default-lane steals may
    /// pick up blocking work from the CPU worker's local queue. Requires
    /// `blocking_workers > 0` (a blocking lane must exist to help).
    ///
    /// Note: blocking-worker → default fallback is ALWAYS on (no config
    /// knob). Idle blocking workers draining CPU backlog is always a
    /// capacity win and does not violate any isolation invariant —
    /// default work landing in a blocking worker's local queue cannot
    /// be stolen by default workers (same-lane-only steal).
    cpu_helps_blocking: bool = false,
    /// Slice L4 — watchdog thread interval. When > 0, a dedicated thread
    /// wakes every `watchdog_interval_ns` and walks default-lane workers
    /// looking for tasks that have been running longer than
    /// `blocking_promotion_timeout_ns`. Zero disables the watchdog entirely
    /// (no thread spawned, no hot-path overhead). Requires
    /// `max_overflow_workers > 0` when set.
    watchdog_interval_ns: u64 = 0,
    /// Slice L4 — how long a default-lane task may run before the watchdog
    /// flags it as stalled. Ignored when `watchdog_interval_ns == 0`.
    /// Default 10ms matches the Tokio "max_blocking_time" rule of thumb.
    blocking_promotion_timeout_ns: u64 = 10_000_000,
    /// Slice L4 — hard cap on overflow-worker slots reserved at init.
    /// Zero disables overflow spawning (watchdog becomes observability-only).
    /// `max_threads + max_overflow_workers` must stay ≤ 64 (the
    /// workers_nonempty bitmap width).
    max_overflow_workers: u32 = 0,
    timestamp_mode: TimestampMode = .full,
    /// Maximum number of tasks a stealer takes from a single victim per steal
    /// attempt. With `queue_kind = .ring`, true batch-steal via stealHalf is
    /// used and values > 1 are correct. With `queue_kind = .chase_lev`,
    /// only single-item steal is correct and the runtime forces this to 1
    /// via `normalized()`.
    steal_batch_size: usize = 8,
    max_submitter_queues: u32 = 0,
    submitter_queue_capacity: usize = 0,

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
        if (cfg.blocking_queue_capacity != 0) {
            cfg.blocking_queue_capacity = std.math.ceilPowerOfTwo(usize, cfg.blocking_queue_capacity) catch cfg.blocking_queue_capacity;
        }
        cfg.steal_batch_size = std.math.clamp(cfg.steal_batch_size, 1, 32);
        if (cfg.queue_kind == .chase_lev) cfg.steal_batch_size = 1;
        if (cfg.wake_coalesce_batch > 1024) cfg.wake_coalesce_batch = 1024;
        if (cfg.submitter_queue_capacity == 0 and cfg.max_submitter_queues > 0) {
            cfg.submitter_queue_capacity = cfg.local_queue_capacity;
        }
        if (cfg.submitter_queue_capacity != 0) {
            cfg.submitter_queue_capacity = std.math.ceilPowerOfTwo(usize, cfg.submitter_queue_capacity) catch cfg.submitter_queue_capacity;
        }
        if (cfg.max_submitter_queues > 64) cfg.max_submitter_queues = 64;
        return cfg;
    }

    pub fn validate(self: Config) !void {
        if (self.max_threads == 0) return error.InvalidMaxThreads;
        if (self.max_threads > 64) return error.TooManyWorkers;
        if (self.min_threads == 0) return error.InvalidMinThreads;
        if (self.min_threads > self.max_threads) return error.InvalidThreadBounds;
        if (self.queue_capacity == 0 or self.queue_capacity > std.math.maxInt(u32)) return error.InvalidQueueCapacity;
        if (self.local_queue_capacity == 0) {
            return error.InvalidLocalQueueCapacity;
        }
        if (self.scheduler_variant == .lane_extension and self.blocking_workers == 0)
            return error.LaneExtensionRequiresBlockingWorkers;
        if (self.inject_batch_size == 0) return error.InvalidInjectBatchSize;
        if (self.hot_spinners >= self.max_threads) return error.InvalidHotSpinners;
        if (self.hot_spinners > 0 and self.wake_every_n_tasks == 0) return error.InvalidWakeThreshold;
        if (self.blocking_workers >= self.max_threads) return error.InvalidBlockingWorkers;
        if (self.blocking_workers > 0 and !self.allow_blocking_lane)
            return error.BlockingLaneWithoutFlag;
        if (self.allow_blocking_lane and self.blocking_workers == 0)
            return error.AllowBlockingLaneRequiresWorkers;
        if (self.blocking_queue_capacity > std.math.maxInt(u32))
            return error.InvalidBlockingQueueCapacity;
        if (self.blocking_queue_capacity > 0 and self.blocking_workers == 0)
            return error.BlockingQueueCapacityWithoutLane;
        if (self.blocking_backpressure != null and self.blocking_workers == 0)
            return error.BlockingBackpressureWithoutLane;
        if (self.cpu_helps_blocking and self.blocking_workers == 0)
            return error.CpuHelpsBlockingWithoutLane;
        if (self.watchdog_interval_ns > 0 and self.max_overflow_workers == 0)
            return error.WatchdogWithoutOverflowCap;
        if (@as(u64, self.max_threads) + @as(u64, self.max_overflow_workers) > 64)
            return error.OverflowCapExceedsBitmap;
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
    /// Slice L4 — cumulative watchdog-observed stalls. Incremented each tick
    /// the watchdog sees a default-lane worker whose current task has been
    /// running longer than `Config.blocking_promotion_timeout_ns`. Always
    /// zero when `Config.watchdog_interval_ns == 0`.
    watchdog_stalls_detected: u64 = 0,
    overflow_spawns: u64 = 0,
    overflow_retires: u64 = 0,
    overflow_active: u64 = 0,
    task_wait_ns: LatencySummary = .{},
    task_exec_ns: LatencySummary = .{},
    memory: ProcessMemoryStats = .{},
    worker_stats: []const WorkerStats = &.{},
};

test "Config validation rejects impossible bounds" {
    var cfg = Config{ .max_threads = 1, .min_threads = 2 };
    try std.testing.expectError(error.InvalidThreadBounds, cfg.validate());
}

test "Config validation rejects lane_extension without blocking_workers" {
    var cfg = Config{ .max_threads = 2, .min_threads = 1, .scheduler_variant = .lane_extension };
    cfg = cfg.normalized();
    try std.testing.expectError(error.LaneExtensionRequiresBlockingWorkers, cfg.validate());
}

test "Config validation accepts lane_extension with blocking_workers" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .scheduler_variant = .lane_extension,
        .blocking_workers = 1,
        .allow_blocking_lane = true,
    };
    cfg = cfg.normalized();
    try cfg.validate();
}

test "Config validation rejects blocking_workers >= max_threads" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .blocking_workers = 4,
        .allow_blocking_lane = true,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.InvalidBlockingWorkers, cfg.validate());
}

test "Config validation rejects blocking_workers without allow_blocking_lane" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .blocking_workers = 1,
        .allow_blocking_lane = false,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.BlockingLaneWithoutFlag, cfg.validate());
}

test "Config validation rejects allow_blocking_lane without workers" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .blocking_workers = 0,
        .allow_blocking_lane = true,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.AllowBlockingLaneRequiresWorkers, cfg.validate());
}

test "Config validation rejects blocking_queue_capacity without blocking_workers" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .blocking_queue_capacity = 128,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.BlockingQueueCapacityWithoutLane, cfg.validate());
}

test "Config validation rejects blocking_backpressure without blocking_workers" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .blocking_backpressure = .return_error,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.BlockingBackpressureWithoutLane, cfg.validate());
}

test "Config normalized rounds blocking_queue_capacity to power of two" {
    const cfg = (Config{ .blocking_queue_capacity = 100 }).normalized();
    try std.testing.expectEqual(@as(usize, 128), cfg.blocking_queue_capacity);
}

test "Config validation rejects cpu_helps_blocking without blocking_workers" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .cpu_helps_blocking = true,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.CpuHelpsBlockingWithoutLane, cfg.validate());
}

test "Config validation rejects watchdog without overflow cap" {
    var cfg = Config{
        .max_threads = 4,
        .min_threads = 4,
        .watchdog_interval_ns = 1_000_000,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.WatchdogWithoutOverflowCap, cfg.validate());
}

test "Config validation rejects overflow cap that overflows bitmap" {
    var cfg = Config{
        .max_threads = 60,
        .min_threads = 60,
        .max_overflow_workers = 8,
    };
    cfg = cfg.normalized();
    try std.testing.expectError(error.OverflowCapExceedsBitmap, cfg.validate());
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
