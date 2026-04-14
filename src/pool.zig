const std = @import("std");
const types = @import("types.zig");
const BoundedRing = @import("queue/bounded_ring.zig").BoundedRing;
const WorkDeque = @import("queue/work_deque.zig").WorkDeque;
const RingQueue = @import("queue/ring_queue.zig").RingQueue;
const WorkerScratch = @import("memory/scratch.zig").WorkerScratch;
const Accounting = @import("memory/scratch.zig").Accounting;
const LatencyHistogram = @import("stats/latency.zig").LatencyHistogram;
const process_memory = @import("stats/process_memory.zig");

threadlocal var tls_worker_index: ?usize = null;

/// Runtime context passed to every task function. Provides the worker
/// index, cancellation state, and access to the per-worker scratch allocator.
pub const TaskContext = struct {
    worker_index: usize,
    cancellation_token: ?*types.CancellationToken,
    scratch: *WorkerScratch,
    lane: types.TaskLane,

    pub fn isCancelled(self: *const TaskContext) bool {
        if (self.cancellation_token) |token| return token.isCancelled();
        return false;
    }

    pub fn allocScratch(self: *TaskContext, comptime T: type, count: usize) ![]T {
        return self.scratch.alloc(T, count);
    }
};

/// Function signature for submitted tasks. `ctx` is the opaque pointer
/// passed to submit; `runtime` provides cancellation and scratch access.
pub const TaskFn = *const fn (ctx: *anyopaque, runtime: *TaskContext) void;

/// A task function paired with its context, for use with `submitBatch`.
pub const BatchTask = struct {
    task_fn: TaskFn,
    ctx: *anyopaque,
};

const PoolState = enum(u8) {
    running,
    shutdown_requested,
    stopping,
    stopped,
};

/// Tagged-union wrapper over the two per-worker local queue implementations.
/// Selected per-pool via `Config.queue_kind`. All call sites dispatch through
/// the unified methods (tryPushBottom, popBottom, steal, stealOne, len,
/// capacity) so the rest of `Core` is queue-kind agnostic.
const LocalQueue = union(enum) {
    chase_lev: WorkDeque(u32),
    ring: RingQueue(u32),

    fn init(allocator: std.mem.Allocator, size: usize, kind: types.QueueKind) !LocalQueue {
        return switch (kind) {
            .chase_lev => .{ .chase_lev = try WorkDeque(u32).init(allocator, size) },
            .ring => .{ .ring = try RingQueue(u32).init(allocator, size) },
        };
    }

    fn deinit(self: *LocalQueue) void {
        switch (self.*) {
            .chase_lev => |*q| q.deinit(),
            .ring => |*q| q.deinit(),
        }
    }

    fn tryPushBottom(self: *LocalQueue, value: u32) bool {
        return switch (self.*) {
            .chase_lev => |*q| q.tryPushBottom(value),
            .ring => |*q| q.tryPush(value),
        };
    }

    fn popBottom(self: *LocalQueue) ?u32 {
        return switch (self.*) {
            .chase_lev => |*q| q.popBottom(),
            .ring => |*q| q.pop(),
        };
    }

    /// Steal up to `out.len` items. For chase_lev returns at most 1; for
    /// ring returns up to (len+1)/2 items via stealHalf.
    fn steal(self: *LocalQueue, out: []u32) usize {
        return switch (self.*) {
            .chase_lev => |*q| if (q.stealTop()) |v| blk: {
                out[0] = v;
                break :blk @as(usize, 1);
            } else 0,
            .ring => |*q| q.stealHalf(out),
        };
    }

    /// Single-item drain — used by shutdown to cancel pending tasks.
    fn stealOne(self: *LocalQueue) ?u32 {
        return switch (self.*) {
            .chase_lev => |*q| q.stealTop(),
            .ring => |*q| blk: {
                var buf: [1]u32 = undefined;
                if (q.stealHalf(buf[0..]) == 1) break :blk buf[0];
                break :blk null;
            },
        };
    }

    fn len(self: *LocalQueue) usize {
        return switch (self.*) {
            .chase_lev => |*q| q.len(),
            .ring => |*q| q.len(),
        };
    }

    fn capacity(self: *LocalQueue) usize {
        return switch (self.*) {
            .chase_lev => |*q| q.capacity(),
            .ring => |*q| q.capacity(),
        };
    }
};

const TaskDescriptor = struct {
    // === Hot fields (read on every dispatch and complete) ===
    state: std.atomic.Value(types.TaskState) = std.atomic.Value(types.TaskState).init(.free),
    task_fn: ?TaskFn = null,
    ctx: ?*anyopaque = null,
    options: types.SubmitOptions = .{},
    generation: u64 = 0,

    // === Cold fields (metrics/observability only) ===
    submit_ns: u64 = 0,
    start_ns: u64 = 0,
    complete_ns: u64 = 0,

    /// Debug/ReleaseSafe-only double-dequeue detector. `-1` = unclaimed.
    /// Worker CAS-acquires from -1 to its index in runTask; a failed CAS
    /// means two workers are racing for this descriptor — panic.
    /// Always compiled in (cheap — single i32). Guarded reads/writes are
    /// controlled by `claim_sentinel_enabled` (defined above) — currently
    /// always-on for the Phase H race investigation; revert to
    /// `std.debug.runtime_safety` after Task 4 fix lands.
    claimed_by: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    comptime {
        // Document the intended cache layout: ensure the hot fields fit in
        // one cache line so dispatch never touches the cold metric fields.
        const hot_size = @offsetOf(TaskDescriptor, "submit_ns");
        std.debug.assert(hot_size <= std.atomic.cache_line);
    }
};

/// Sentinel value meaning "the lifo_slot is empty". Chosen as the max u32
/// so descriptor indices (0..queue_capacity-1) never collide.
const LIFO_SLOT_EMPTY: u32 = 0xFFFF_FFFF;

/// Phase H investigation flag — when true, the per-descriptor `claimed_by`
/// sentinel is always active (catches double-dequeue races in ReleaseFast
/// where the race actually reproduces). When false, the sentinel only
/// runs under `std.debug.runtime_safety` (Debug/ReleaseSafe), where the
/// race is masked by safety-check overhead and rarely fires.
///
/// TODO(phase-h): once the double-dequeue race is root-caused and fixed
/// (Task 4 of docs/superpowers/plans/2026-04-13-phase-h-fix-double-dequeue-race.md),
/// flip this back to `std.debug.runtime_safety` or remove the sentinel
/// entirely.
const claim_sentinel_enabled: bool = true;

const Worker = struct {
    thread: ?std.Thread = null,
    scratch: WorkerScratch,
    wait_histogram: LatencyHistogram = .{},
    exec_histogram: LatencyHistogram = .{},
    busy_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    idle_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    local_queue_peak: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    parks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    wakeups: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    steals: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    steal_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    started: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_idle_started_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    scratch_init_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    park_mutex: std.Thread.Mutex = .{},
    park_cond: std.Thread.Condition = .{},
    /// 1 when this worker is parked, 0 otherwise. Fast-path check before
    /// acquiring park_mutex during signal — saves a futex syscall when the
    /// worker isn't actually parked.
    is_parked: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    /// Tokio-style single-slot LIFO cache. When a task is submitted from this
    /// worker's thread, it goes here first (single atomic store); `nextTask`
    /// pops the slot ahead of the local ring. Cross-worker submits never
    /// touch this slot. Stealers never touch this slot either — only the
    /// owner writes to it. Sentinel value `LIFO_SLOT_EMPTY` (0xFFFF_FFFF)
    /// means "no cached task".
    lifo_slot: std.atomic.Value(u32) = std.atomic.Value(u32).init(LIFO_SLOT_EMPTY),
    /// Per-worker MPMC incoming queue. External (non-worker-thread) submits
    /// rotate across these to amortize cacheline pressure. Owner worker pops
    /// via nextTask's incoming check (Task 4). Reuses BoundedRing for v1;
    /// specializing to MPSC is a future optimization.
    incoming: BoundedRing(u32),
};

/// Synchronization primitives for task completion. Worker parking uses
/// per-Worker park_mutex/park_cond to avoid contention on a shared mutex.
const Sync = struct {
    completion_mutex: std.Thread.Mutex = .{},
    completion_cond: std.Thread.Condition = .{},
    /// Backpressure primitives: blocked submitters (when queue/descriptor
    /// pool is full) sleep on `backpressure_cond` rather than polling with
    /// a fixed-interval `Thread.sleep`. `releaseDescriptor` signals the
    /// condvar when capacity becomes available. `backpressure_waiters` is
    /// an atomic fast-path counter so the producer path can skip acquiring
    /// `backpressure_mutex` entirely when nobody is blocked.
    backpressure_mutex: std.Thread.Mutex = .{},
    backpressure_cond: std.Thread.Condition = .{},
    backpressure_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Atomic counters tracking pool-wide task and worker events.
/// Fields are grouped by access pattern with cache-line padding
/// between groups to reduce false sharing between submit and worker paths.
const Counters = extern struct {
    const cache_line_size = std.atomic.cache_line;
    const field_size = @sizeOf(std.atomic.Value(u64));

    // === Hot write group (submit path, queued_tasks only) ===
    // `queued_tasks` is read by workers in nextTask; `submitted` was moved to
    // its own cacheline (below) so submitter writes to `submitted` do not
    // stall worker reads of `queued_tasks`.
    queued_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad0a: [cache_line_size - field_size]u8 = undefined,

    // === Cumulative submit counter (observability-only, off hot read path) ===
    // Written at every spawn(); read only by snapshot() (cold path). Isolated
    // onto its own cacheline to decouple from `queued_tasks` write contention.
    submitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad0b: [cache_line_size - field_size]u8 = undefined,

    // === Hot write group (worker path) ===
    active_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cancelled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad1: [cache_line_size - 2 * field_size]u8 = undefined,

    // === Diagnostic/cold counters ===
    wakeups: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queue_depth_peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    task_desc_live: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    task_desc_peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_alloc_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_free_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_alloc_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    live_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak_live_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    comptime {
        // Cacheline isolation invariants: each hot-write counter owns a distinct line.
        std.debug.assert(@offsetOf(Counters, "queued_tasks") == 0);
        std.debug.assert(@offsetOf(Counters, "submitted") == cache_line_size);
        std.debug.assert(@offsetOf(Counters, "active_tasks") == 2 * cache_line_size);
    }
};

const Core = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    accounting: Accounting = undefined,
    state: std.atomic.Value(PoolState) = std.atomic.Value(PoolState).init(.running),
    workers: []Worker,
    local_queues: []LocalQueue,
    descriptors: []TaskDescriptor,
    free_indices: []u32,
    free_top_tagged: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    inject_queue: BoundedRing(u32),
    /// Round-robin target cursor for external submits (Task 3). Relaxed
    /// atomic fetchAdd; the `% workers.len` happens at the use site.
    /// Values wrap naturally at u32 max. Not referenced in Task 2; wired
    /// up in Task 3.
    incoming_cursor: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    sync: Sync = .{},
    counters: Counters align(std.atomic.cache_line) = .{},
    worker_stats_buffer: []types.WorkerStats,

    pub fn init(self: *Core, allocator: std.mem.Allocator, config: types.Config) !void {
        var normalized = config.normalized();
        try normalized.validate();

        self.* = .{
            .allocator = allocator,
            .config = normalized,
            .workers = try allocator.alloc(Worker, normalized.max_threads),
            .local_queues = try allocator.alloc(LocalQueue, normalized.max_threads),
            .descriptors = try allocator.alloc(TaskDescriptor, normalized.queue_capacity),
            .free_indices = try allocator.alloc(u32, normalized.queue_capacity),
            .inject_queue = try BoundedRing(u32).init(allocator, normalized.queue_capacity),
            .worker_stats_buffer = try allocator.alloc(types.WorkerStats, normalized.max_threads),
        };
        errdefer self.deinitOwned();

        self.accounting = .{
            .total_alloc_bytes = &self.counters.total_alloc_bytes,
            .total_free_bytes = &self.counters.total_free_bytes,
            .total_alloc_count = &self.counters.total_alloc_count,
            .live_bytes = &self.counters.live_bytes,
            .peak_live_bytes = &self.counters.peak_live_bytes,
        };

        self.recordOwnedAlloc(self.workers.len * @sizeOf(Worker));
        self.recordOwnedAlloc(self.local_queues.len * @sizeOf(LocalQueue));
        self.recordOwnedAlloc(self.descriptors.len * @sizeOf(TaskDescriptor));
        self.recordOwnedAlloc(self.free_indices.len * @sizeOf(u32));
        self.recordOwnedAlloc(self.worker_stats_buffer.len * @sizeOf(types.WorkerStats));
        self.recordOwnedAlloc(self.inject_queue.capacity() * @sizeOf(u32));

        for (self.descriptors, 0..) |*descriptor, idx| {
            descriptor.* = .{};
            // Build a singly-linked freelist: each slot points to the next.
            // The last slot uses the sentinel 0xFFFFFFFF (empty).
            self.free_indices[idx] = if (idx + 1 < normalized.queue_capacity)
                @as(u32, @intCast(idx + 1))
            else
                0xFFFFFFFF;
        }

        // Tagged pointer: high 32 = ABA counter (starts 0), low 32 = head index.
        self.free_top_tagged = std.atomic.Value(u64).init(@as(u64, 0));

        // Option 3: initialize per-worker incoming rings FIRST, with a
        // tracked count so partial-init failures clean up precisely.
        // BoundedRing.init is fallible (allocator failure); if it fails
        // partway, the errdefer below deinits only the rings that succeeded.
        var incoming_initialized: usize = 0;
        errdefer {
            var i: usize = 0;
            while (i < incoming_initialized) : (i += 1) {
                self.recordOwnedFree(self.workers[i].incoming.capacity() * @sizeOf(u32));
                self.workers[i].incoming.deinit();
            }
        }
        for (self.workers) |*worker| {
            worker.incoming = try BoundedRing(u32).init(allocator, normalized.incoming_capacity);
            self.recordOwnedAlloc(worker.incoming.capacity() * @sizeOf(u32));
            incoming_initialized += 1;
        }

        for (self.workers, self.local_queues) |*worker, *lq| {
            lq.* = try LocalQueue.init(allocator, normalized.local_queue_capacity, normalized.queue_kind);
            const already_initialized_incoming = worker.incoming;
            worker.* = .{
                .scratch = WorkerScratch.init(allocator, self.accounting, normalized.worker_scratch_cap_bytes),
                .last_idle_started_ns = std.atomic.Value(u64).init(nowNs()),
                .incoming = already_initialized_incoming,
            };
            self.recordOwnedAlloc(lq.capacity() * @sizeOf(u32));
        }

        for (self.workers, 0..) |*worker, idx| {
            worker.thread = try std.Thread.spawn(.{}, workerMain, .{ self, idx });
        }
    }

    pub fn deinit(self: *Core) void {
        self.shutdown(.drain, self.config.deinit_timeout_ns) catch {
            std.log.warn("thread-pool deinit timed out after {d}ms with {d} active tasks and {d} queued", .{
                self.config.deinit_timeout_ns / std.time.ns_per_ms,
                self.counters.active_tasks.load(.acquire),
                self.counters.queued_tasks.load(.acquire),
            });
            self.joinAllWorkers();
        };
        self.deinitOwned();
    }

    pub fn trySubmit(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.submitInternal(task_fn, ctx, options, false);
    }

    pub fn submit(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.submitInternal(task_fn, ctx, options, true);
    }

    pub const SubmitBatchResult = struct {
        submitted: usize,
    };

    pub fn submitBatch(self: *Core, tasks: []const BatchTask, options: types.SubmitOptions) !SubmitBatchResult {
        for (tasks, 0..) |task, idx| {
            _ = self.submit(task.task_fn, task.ctx, options) catch |err| {
                if (idx == 0) return err;
                return .{ .submitted = idx };
            };
        }
        return .{ .submitted = tasks.len };
    }

    pub fn wait(self: *Core, handle: types.TaskHandle) !void {
        if (!handle.isValid()) return error.InvalidHandle;
        if (handle.index >= self.descriptors.len) return error.InvalidHandle;

        self.sync.completion_mutex.lock();
        defer self.sync.completion_mutex.unlock();

        while (true) {
            const descriptor = &self.descriptors[handle.index];
            if (descriptor.generation != handle.generation) return error.InvalidHandle;
            switch (descriptor.state.load(.acquire)) {
                .completed, .cancelled => {
                    self.releaseDescriptor(handle.index);
                    return;
                },
                .free => return error.InvalidHandle,
                else => self.sync.completion_cond.wait(&self.sync.completion_mutex),
            }
        }
    }

    pub fn waitGroup(self: *Core) types.WaitGroup {
        _ = self;
        return .{};
    }

    pub fn shutdown(self: *Core, mode: types.ShutdownMode, timeout_ns: ?u64) !void {
        const old_state = self.state.swap(.shutdown_requested, .acq_rel);
        if (old_state != .running) {
            // Another shutdown is already in progress or completed.
            // Ensure all threads are joined before returning.
            self.joinAllWorkers();
            return;
        }

        if (mode == .cancel_pending) {
            try self.cancelQueuedTasks();
        }

        const deadline = if (timeout_ns) |ns| nowNs() + ns else 0;
        while (true) {
            const queued = self.counters.queued_tasks.load(.acquire);
            const active = self.counters.active_tasks.load(.acquire);
            if (queued == 0 and active == 0) break;
            if (deadline != 0 and nowNs() >= deadline) return error.Timeout;

            // Wait on the backpressure condvar, which releaseDescriptor signals on
            // every completion. Cap at 10ms so we re-check state even if a signal
            // is lost. Reuse waitForCapacity to avoid code duplication and register
            // as a waiter so releaseDescriptor takes the signal fast-path.
            self.waitForCapacity(deadline);
        }

        self.joinAllWorkers();
    }

    fn joinAllWorkers(self: *Core) void {
        // Signal all workers to exit
        self.state.store(.stopping, .release);
        // Wake every worker so they observe the state change and exit.
        for (self.workers) |*w| {
            w.park_mutex.lock();
            w.park_cond.broadcast();
            w.park_mutex.unlock();
        }
        // Wake any submitters blocked on backpressure so they observe the
        // state change and return error.ShutdownInProgress instead of
        // sleeping forever.
        self.sync.backpressure_mutex.lock();
        self.sync.backpressure_cond.broadcast();
        self.sync.backpressure_mutex.unlock();

        // Join all threads
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
        }
        self.state.store(.stopped, .release);
    }

    /// Wait for descriptor/queue capacity to free up, bounded by `deadline`
    /// (absolute nanoseconds; 0 = no deadline). Cap each wait at 10ms so we
    /// re-check state periodically even if a signal is missed.
    fn waitForCapacity(self: *Core, deadline: u64) void {
        _ = self.sync.backpressure_waiters.fetchAdd(1, .monotonic);
        defer _ = self.sync.backpressure_waiters.fetchSub(1, .monotonic);

        self.sync.backpressure_mutex.lock();
        defer self.sync.backpressure_mutex.unlock();

        const wait_ns: u64 = if (deadline != 0) blk: {
            const now = nowNs();
            break :blk if (now >= deadline) 0 else @min(deadline - now, 10_000_000);
        } else 10_000_000;

        if (wait_ns > 0) {
            self.sync.backpressure_cond.timedWait(&self.sync.backpressure_mutex, wait_ns) catch {};
        }
    }

    pub fn statsSnapshot(self: *Core) types.Stats {
        var aggregate_wakeups: u64 = 0;
        var aggregate_started: u64 = 0;
        var aggregate_completed: u64 = 0;
        var aggregate_steals: u64 = 0;
        var aggregate_steal_failures: u64 = 0;
        var aggregate_parks: u64 = 0;
        for (self.workers, 0..) |*worker, idx| {
            const w_wakeups = worker.wakeups.load(.acquire);
            const w_started = worker.started.load(.acquire);
            const w_completed = worker.completed.load(.acquire);
            const w_steals = worker.steals.load(.acquire);
            const w_steal_failures = worker.steal_failures.load(.acquire);
            const w_parks = worker.parks.load(.acquire);
            aggregate_wakeups += w_wakeups;
            aggregate_started += w_started;
            aggregate_completed += w_completed;
            aggregate_steals += w_steals;
            aggregate_steal_failures += w_steal_failures;
            aggregate_parks += w_parks;
            self.worker_stats_buffer[idx] = .{
                .worker_index = idx,
                .busy_ns = worker.busy_ns.load(.acquire),
                .idle_ns = worker.idle_ns.load(.acquire),
                .local_queue_depth = @as(u32, @intCast(self.local_queues[idx].len())),
                .local_queue_peak = worker.local_queue_peak.load(.acquire),
                .parks = w_parks,
                .wakeups = w_wakeups,
                .steals = w_steals,
                .steal_failures = w_steal_failures,
                .started = w_started,
                .completed = w_completed,
                .scratch_current_bytes = @as(u64, @intCast(worker.scratch.bytesCurrent())),
                .scratch_peak_bytes = @as(u64, @intCast(worker.scratch.bytesPeak())),
            };
        }

        const memory = process_memory.sample() catch types.ProcessMemoryStats{};

        var merged_wait = LatencyHistogram{};
        var merged_exec = LatencyHistogram{};
        for (self.workers) |*worker| {
            merged_wait.merge(&worker.wait_histogram);
            merged_exec.merge(&worker.exec_histogram);
        }

        return .{
            .submitted = self.counters.submitted.load(.acquire),
            .started = aggregate_started,
            .completed = aggregate_completed,
            .cancelled = self.counters.cancelled.load(.acquire),
            .active_tasks = self.counters.active_tasks.load(.acquire),
            .queue_depth_current = self.counters.queued_tasks.load(.acquire),
            .queue_depth_peak = self.counters.queue_depth_peak.load(.acquire),
            .steals = aggregate_steals,
            .steal_failures = aggregate_steal_failures,
            .wakeups = aggregate_wakeups,
            .parks = aggregate_parks,
            .task_desc_live = self.counters.task_desc_live.load(.acquire),
            .task_desc_peak = self.counters.task_desc_peak.load(.acquire),
            .total_alloc_bytes = self.counters.total_alloc_bytes.load(.acquire),
            .total_free_bytes = self.counters.total_free_bytes.load(.acquire),
            .total_alloc_count = self.counters.total_alloc_count.load(.acquire),
            .live_bytes = self.counters.live_bytes.load(.acquire),
            .peak_live_bytes = self.counters.peak_live_bytes.load(.acquire),
            .task_wait_ns = merged_wait.summary(),
            .task_exec_ns = merged_exec.summary(),
            .memory = memory,
            .worker_stats = self.worker_stats_buffer,
        };
    }

    pub fn purgeWorkerCaches(self: *Core) !void {
        if (self.counters.active_tasks.load(.acquire) != 0) return error.PoolBusy;
        for (self.workers) |*worker| {
            worker.scratch.purge();
        }
    }

    fn submitInternal(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions, allow_block: bool) !types.TaskHandle {
        const deadline = if (allow_block and options.backpressure == .block_with_timeout and options.timeout_ns != null)
            nowNs() + options.timeout_ns.?
        else
            0;

        while (true) {
            if (self.state.load(.acquire) != .running) return error.ShutdownInProgress;
            if (self.enqueueTask(task_fn, ctx, options)) |handle| {
                return handle;
            } else |err| switch (err) {
                error.QueueFull, error.TaskPoolExhausted => {
                    if (!allow_block or options.backpressure == .return_error) return err;
                    if (deadline != 0 and nowNs() >= deadline) return error.Timeout;
                    self.waitForCapacity(deadline);
                },
                else => return err,
            }
        }
    }

    fn enqueueTask(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        const descriptor_index = self.acquireDescriptor() orelse return error.TaskPoolExhausted;
        errdefer self.releaseDescriptor(descriptor_index);

        if (options.wait_group) |wait_group| {
            wait_group.add(1);
        }

        const descriptor = &self.descriptors[descriptor_index];
        descriptor.task_fn = task_fn;
        descriptor.ctx = ctx;
        descriptor.options = options;
        descriptor.submit_ns = if (self.config.timestamp_mode == .full) nowNs() else 0;
        descriptor.start_ns = 0;
        descriptor.complete_ns = 0;
        descriptor.state.store(.queued, .release);

        var queued = false;
        if (self.config.scheduler_variant == .work_stealing and tls_worker_index != null) {
            const wi = tls_worker_index.?;
            // Try the LIFO slot first. Owner-only write; if the slot is empty,
            // a plain store is sufficient — no stealer writes to this slot.
            // If the slot is full, fall through to the local ring.
            const w = &self.workers[wi];
            if (w.lifo_slot.load(.monotonic) == LIFO_SLOT_EMPTY) {
                w.lifo_slot.store(descriptor_index, .release);
                queued = true;
            } else {
                queued = self.local_queues[wi].tryPushBottom(descriptor_index);
                if (queued) {
                    const local_len = @as(u32, @intCast(self.local_queues[wi].len()));
                    updatePeakU32(&w.local_queue_peak, local_len);
                }
            }
        }
        if (!queued) {
            queued = self.inject_queue.tryPush(descriptor_index);
        }
        if (!queued) {
            if (options.wait_group) |wait_group| wait_group.done();
            return error.QueueFull;
        }

        _ = self.counters.submitted.fetchAdd(1, .monotonic);
        self.incrementQueued();

        // Wake one parked worker. Scan `is_parked` across workers starting at a
        // round-robin offset so load spreads across the pool. The submit-before-park
        // handshake (see idle()) guarantees: if any worker is about to miss this
        // task because it's heading to park, its `is_parked := 1` store is ordered
        // with its reload of `queued_tasks`. So either we observe `is_parked == 1`
        // and signal it, OR the worker reloads `queued_tasks` and sees our push —
        // no lost wakeup. No broadcast fallback is needed.
        const submitted = self.counters.submitted.load(.monotonic);
        const hint_idx: usize = @intCast(submitted % self.workers.len);
        var off: usize = 0;
        while (off < self.workers.len) : (off += 1) {
            const idx = (hint_idx + off) % self.workers.len;
            const w = &self.workers[idx];
            if (w.is_parked.load(.seq_cst) == 1) {
                w.park_mutex.lock();
                // Re-check under the mutex: the worker may have unparked between our
                // load and this acquire. The signal is a no-op if it isn't parked —
                // but we do not want to hold the mutex for a worker that is running.
                if (w.is_parked.load(.monotonic) == 1) {
                    w.park_cond.signal();
                }
                w.park_mutex.unlock();
                break;
            }
        }

        return if (options.waitable)
            .{
                .index = descriptor_index,
                .generation = descriptor.generation,
                .waitable = true,
            }
        else
            types.TaskHandle.invalid();
    }

    fn workerMain(self: *Core, worker_index: usize) void {
        tls_worker_index = worker_index;
        defer tls_worker_index = null;

        while (true) {
            if (self.shouldExit()) break;

            const maybe_descriptor = self.nextTask(worker_index);
            if (maybe_descriptor == null) {
                self.idle(worker_index);
                continue;
            }

            self.runTask(worker_index, maybe_descriptor.?);
        }
    }

    fn nextTask(self: *Core, worker_index: usize) ?u32 {
        var worker = &self.workers[worker_index];
        var lq = &self.local_queues[worker_index];

        // Phase H (Task 4b): decrementQueued() is NOT called here. It moved to
        // runTask's CAS-success path so that a ghost duplicate index emitted
        // by any queue path (the upstream race tracked in Task 3 diagnosis)
        // does not cause an unbalanced decrement. Without this move, a
        // single duplicate emission causes queued_tasks to go net-negative
        // by 1; at steady state the race churns millions of duplicates and
        // underflows queued_tasks to a huge u64, which deadlocks shutdown
        // (shouldExit requires queued_tasks == 0).
        //
        // Semantics: queued_tasks now counts "items the scheduler believes
        // are still pending execution" across {submitted, not-yet-claimed}
        // PLUS {popped-by-nextTask, not-yet-claimed-by-runTask-CAS}. Park
        // handshake and shutdown's drain loop both still see 0 iff every
        // submitted item has been claimed (real) or discarded (duplicate).
        if (self.config.scheduler_variant == .work_stealing) {
            // LIFO slot first: owner-only swap-to-empty. Most-recently-submitted
            // task runs next. This is the hot path for "task spawns task".
            const cached = worker.lifo_slot.swap(LIFO_SLOT_EMPTY, .acquire);
            if (cached != LIFO_SLOT_EMPTY) {
                return cached;
            }

            if (lq.popBottom()) |descriptor_index| {
                return descriptor_index;
            }

            if (self.inject_queue.pop()) |descriptor_index| {
                var moved: usize = 1;
                while (moved < self.config.inject_batch_size) : (moved += 1) {
                    const extra = self.inject_queue.pop() orelse break;
                    if (!lq.tryPushBottom(extra)) {
                        _ = self.inject_queue.tryPush(extra);
                        break;
                    }
                }
                const local_len = @as(u32, @intCast(lq.len()));
                updatePeakU32(&worker.local_queue_peak, local_len);
                return descriptor_index;
            }

            // Use worker_index mixed with submitted count for pseudo-random start.
            // Avoids global atomic fetchAdd contention that causes thundering-herd
            // when all idle workers get sequential starting indices.
            const start = (worker_index +% @as(usize, @truncate(self.counters.submitted.load(.monotonic)))) % self.workers.len;
            var offset: usize = 0;
            while (offset < self.workers.len) : (offset += 1) {
                const victim_index = (start + offset) % self.workers.len;
                if (victim_index == worker_index) continue;
                // Cheap peek before paying the seq_cst CAS cost in steal().
                // len() reads bottom and top with acquire loads; under contention it
                // may return a stale value, but skipping a victim that *appears* empty
                // just means we move to the next one — correctness is unaffected.
                if (self.local_queues[victim_index].len() == 0) continue;
                var stolen: [32]u32 = undefined;
                const budget = @min(self.config.steal_batch_size, stolen.len);
                const n = self.local_queues[victim_index].steal(stolen[0..budget]);
                if (n > 0) {
                    // Keep the first for ourselves, push the rest to our local deque.
                    // No decrement here — runTask's CAS-success path decrements for
                    // `first`; items pushed to lq will decrement when their eventual
                    // runTask CAS succeeds (or be silently skipped if duplicate).
                    const first = stolen[0];
                    for (stolen[1..n]) |idx| {
                        if (!lq.tryPushBottom(idx)) {
                            // Local deque full — put overflow on the inject queue so it isn't lost.
                            _ = self.inject_queue.tryPush(idx);
                        }
                    }
                    _ = worker.steals.fetchAdd(n, .release);
                    const local_len: u32 = @intCast(lq.len());
                    updatePeakU32(&worker.local_queue_peak, local_len);
                    return first;
                }
            }

            _ = worker.steal_failures.fetchAdd(1, .release);
            return null;
        }

        if (self.inject_queue.pop()) |descriptor_index| {
            return descriptor_index;
        }
        return null;
    }

    fn runTask(self: *Core, worker_index: usize, descriptor_index: u32) void {
        var worker = &self.workers[worker_index];
        var descriptor = &self.descriptors[descriptor_index];

        // Phase H fix: atomically transition .queued → .running. Any other
        // state means the descriptor was already claimed, already completed,
        // or has been recycled — drop this dispatch. This closes the wide-
        // overlap race where a duplicate descriptor_index emitted by a queue
        // path arrives after the first claimant already ran and released.
        // The CAS failure branch is a silent skip — duplicate emissions are
        // not an error in this layer; the upstream queue-path root cause is
        // tracked as residual Phase H work.
        //
        // Task 4b: on a successful CAS we also decrementQueued. nextTask
        // intentionally does NOT decrement (see the big comment there),
        // because a duplicate emission would otherwise unbalance the
        // counter and deadlock shutdown. Ghost duplicates fail this CAS
        // and silently return without decrementing — so queued_tasks stays
        // equal to "submissions minus successful dispatches plus dropped
        // ghosts' original double-count cancellation", i.e. it reaches 0
        // iff every real submission has been dispatched or cancelled.
        if (descriptor.state.cmpxchgStrong(.queued, .running, .acq_rel, .acquire)) |_| {
            return;
        }
        self.decrementQueued();

        // Task 2 sentinel: catches tight-overlap sibling where two workers
        // both pass the state CAS (shouldn't happen — CAS is serializing —
        // but the sentinel remains as a defense-in-depth assertion).
        if (claim_sentinel_enabled) {
            const wi_i32: i32 = @intCast(worker_index);
            if (descriptor.claimed_by.cmpxchgStrong(-1, wi_i32, .acq_rel, .acquire)) |other| {
                std.debug.panic(
                    "double-dequeue: descriptor {d} claimed by worker {d}, now worker {d} also tried to claim it",
                    .{ descriptor_index, other, wi_i32 },
                );
            }
        }
        const timestamps_enabled = self.config.timestamp_mode == .full;
        const start_ns = if (timestamps_enabled) nowNs() else 0;
        descriptor.start_ns = start_ns;

        if (timestamps_enabled) {
            const wait_ns = start_ns - descriptor.submit_ns;
            worker.wait_histogram.observe(wait_ns);
        }

        _ = worker.started.fetchAdd(1, .monotonic);
        _ = self.counters.active_tasks.fetchAdd(1, .monotonic);

        if (timestamps_enabled) {
            const idle_started_ns = worker.last_idle_started_ns.load(.acquire);
            if (idle_started_ns != 0 and start_ns >= idle_started_ns) {
                _ = worker.idle_ns.fetchAdd(start_ns - idle_started_ns, .release);
            }
        }

        var runtime = TaskContext{
            .worker_index = worker_index,
            .cancellation_token = descriptor.options.cancellation_token,
            .scratch = &worker.scratch,
            .lane = descriptor.options.lane,
        };

        const cancelled = if (descriptor.options.cancellation_token) |token| token.isCancelled() else false;
        if (!cancelled) {
            worker.scratch.beginTask() catch {
                _ = worker.scratch_init_failures.fetchAdd(1, .release);
            };
            descriptor.task_fn.?(descriptor.ctx.?, &runtime);
            worker.scratch.finishTask();
        } else {
            descriptor.state.store(.cancelled, .release);
            _ = self.counters.cancelled.fetchAdd(1, .monotonic);
        }

        // Always update last_idle_started_ns so the idle-purge logic in idle() works
        // regardless of timestamp_mode. Read the clock once.
        const complete_ns = nowNs();
        worker.last_idle_started_ns.store(complete_ns, .release);

        if (timestamps_enabled) {
            descriptor.complete_ns = complete_ns;
            const exec_ns = complete_ns - start_ns;
            _ = worker.busy_ns.fetchAdd(exec_ns, .release);
            worker.exec_histogram.observe(exec_ns);
        }

        _ = self.counters.active_tasks.fetchSub(1, .monotonic);
        if (descriptor.state.load(.acquire) != .cancelled) {
            descriptor.state.store(.completed, .release);
            _ = worker.completed.fetchAdd(1, .monotonic);
        }

        if (descriptor.options.wait_group) |wait_group| {
            wait_group.done();
        }

        // Clear the claim sentinel before wait_group.done() observers can
        // re-submit / re-acquire this descriptor slot. Paired with the
        // CAS-acquire at the top of runTask.
        if (claim_sentinel_enabled) {
            descriptor.claimed_by.store(-1, .release);
        }

        if (descriptor.options.waitable) {
            self.sync.completion_mutex.lock();
            self.sync.completion_cond.broadcast();
            self.sync.completion_mutex.unlock();
        } else {
            self.releaseDescriptor(descriptor_index);
        }
    }

    fn idle(self: *Core, worker_index: usize) void {
        var worker = &self.workers[worker_index];
        // Phase G2 (re-land 2026-04-13): no `counters.queued_tasks` poll.
        // The submit path writes that line with .seq_cst on every submit;
        // 56 workers × spin_iters shared loads per park cycle dominated
        // cross-core traffic on the line. Removing the poll lifted
        // flood_1m ~9% in the original G2 (commit c335189 / 60ad076).
        //
        // Handshake correctness is unaffected: the mutex-guarded SC
        // reload at `worker.is_parked.store(1, .seq_cst)` below is the
        // actual lost-wakeup guard (see comment block at the park site).
        // The spin-poll was a latency shortcut, not a correctness mechanism.
        //
        // The original G2 also added an end-of-spin local-work probe
        // (lifo_slot, local_queue.len, inject_queue.len). Post-impl A/B
        // (commit 60ad076) showed the probe was inert — same probability-
        // of-engagement failure as Phase F1's short-spin. Re-land omits
        // the probe and drops `spin_before_park_iters` default to 0
        // (in src/types.zig); a polless spin is pure CPU burn so the
        // default-off knob preserves the spin only for explicit opt-ins
        // (e.g. the existing stress tests at tests/stress.zig:75,290,528).
        //
        // Phase H's `runTask` state-CAS gate (pool.zig:763) defends
        // against the duplicate-emission race that the original G2
        // timing change unmasked — see docs/PERFORMANCE_TRACKING.md
        // § Phase H. Path-agnostic defense; this re-land cannot revive
        // the SIGSEGV that forced the original revert.
        var spins: usize = 0;
        while (spins < self.config.spin_before_park_iters) : (spins += 1) {
            if (self.state.load(.acquire) != .running) return;
            std.atomic.spinLoopHint();
        }

        if (self.state.load(.acquire) != .running) return;

        _ = worker.parks.fetchAdd(1, .release);

        worker.park_mutex.lock();
        // SC total-order handshake:
        //   submitter:  push → queued_tasks.fetchAdd(.seq_cst) → is_parked.load(.seq_cst)
        //   worker:     is_parked.store(.seq_cst) → queued_tasks.load(.seq_cst) → wait
        // Both cross-variable pairs are SC, so either the submitter observes
        // is_parked == 1 (and signals us) OR our queued_tasks load sees the
        // submitter's increment. IRIW is excluded. No lost wakeup.
        //
        // Note: queued_tasks.fetchAdd on the submit path MUST be .seq_cst (not
        // .release). Release stores only create HB with SC loads when the load
        // reads that store's specific value — if the SC load observes an earlier
        // value, no HB edge forms and the IRIW scenario is permitted.
        worker.is_parked.store(1, .seq_cst);
        if (self.counters.queued_tasks.load(.seq_cst) != 0 or self.state.load(.acquire) != .running) {
            worker.is_parked.store(0, .release);
            worker.park_mutex.unlock();
            _ = worker.wakeups.fetchAdd(1, .release);
            return;
        }
        worker.park_cond.timedWait(&worker.park_mutex, self.config.idle_park_after_ns) catch {};
        worker.is_parked.store(0, .release);
        worker.park_mutex.unlock();
        _ = worker.wakeups.fetchAdd(1, .release);

        if (self.config.worker_scratch_cap_bytes != 0 and self.config.idle_purge_after_ns != 0) {
            const now = nowNs();
            if (now - worker.last_idle_started_ns.load(.acquire) >= self.config.idle_purge_after_ns) {
                worker.scratch.purge();
            }
        }
    }

    fn shouldExit(self: *Core) bool {
        const state = self.state.load(.acquire);
        if (state == .running) return false;
        return self.counters.queued_tasks.load(.acquire) == 0 and self.counters.active_tasks.load(.acquire) == 0;
    }

    fn cancelQueuedTasks(self: *Core) !void {
        // Task 4b: no decrementQueued here — it moved into cancelDescriptor's
        // CAS-success path. Matches the nextTask/runTask split so a ghost
        // duplicate index popped during cancellation drains doesn't
        // double-decrement (which would underflow queued_tasks and
        // deadlock shouldExit).
        while (self.inject_queue.pop()) |descriptor_index| {
            self.cancelDescriptor(descriptor_index);
        }
        if (self.config.scheduler_variant == .work_stealing) {
            // Drain LIFO slots too.
            for (self.workers) |*w| {
                const cached = w.lifo_slot.swap(LIFO_SLOT_EMPTY, .acquire);
                if (cached != LIFO_SLOT_EMPTY) {
                    self.cancelDescriptor(cached);
                }
            }
            for (self.local_queues) |*lq| {
                while (lq.stealOne()) |descriptor_index| {
                    self.cancelDescriptor(descriptor_index);
                }
            }
        }
    }

    fn cancelDescriptor(self: *Core, descriptor_index: u32) void {
        const descriptor = &self.descriptors[descriptor_index];
        // Gate with the same state CAS pattern runTask uses. A duplicate
        // index emitted by a queue path will find state != .queued (already
        // cancelled, running, completed, or free) and silently return.
        // Only the first valid cancellation decrements queued_tasks.
        if (descriptor.state.cmpxchgStrong(.queued, .cancelled, .acq_rel, .acquire)) |_| {
            return;
        }
        self.decrementQueued();
        if (claim_sentinel_enabled) {
            descriptor.claimed_by.store(-1, .release);
        }
        _ = self.counters.cancelled.fetchAdd(1, .monotonic);
        if (descriptor.options.wait_group) |wait_group| wait_group.done();
        // Only broadcast for waitable tasks (matches runTask pattern)
        if (descriptor.options.waitable) {
            self.sync.completion_mutex.lock();
            self.sync.completion_cond.broadcast();
            self.sync.completion_mutex.unlock();
        } else {
            self.releaseDescriptor(descriptor_index);
        }
    }

    const free_sentinel: u32 = 0xFFFFFFFF;

    fn acquireDescriptor(self: *Core) ?u32 {
        while (true) {
            const tagged = self.free_top_tagged.load(.acquire);
            const head = @as(u32, @truncate(tagged));
            if (head == free_sentinel) return null;
            const aba = @as(u32, @truncate(tagged >> 32));
            const next = self.free_indices[head];
            const new_tagged = @as(u64, aba +% 1) << 32 | @as(u64, next);
            if (self.free_top_tagged.cmpxchgWeak(tagged, new_tagged, .acq_rel, .acquire)) |_| {
                continue;
            }
            var descriptor = &self.descriptors[head];
            const prev_generation = descriptor.generation;
            descriptor.* = .{};
            descriptor.generation = prev_generation +% 1;
            if (descriptor.generation == 0) descriptor.generation = 1;
            if (claim_sentinel_enabled) {
                descriptor.claimed_by.store(-1, .release);
            }
            descriptor.state.store(.reserved, .release);
            const live = self.counters.task_desc_live.fetchAdd(1, .monotonic) + 1;
            updatePeak(&self.counters.task_desc_peak, live);
            return head;
        }
    }

    fn releaseDescriptor(self: *Core, descriptor_index: u32) void {
        var descriptor = &self.descriptors[descriptor_index];
        descriptor.task_fn = null;
        descriptor.ctx = null;
        descriptor.options = .{};
        descriptor.submit_ns = 0;
        descriptor.start_ns = 0;
        descriptor.complete_ns = 0;
        descriptor.state.store(.free, .release);
        _ = self.counters.task_desc_live.fetchSub(1, .monotonic);

        while (true) {
            const tagged = self.free_top_tagged.load(.acquire);
            const head = @as(u32, @truncate(tagged));
            const aba = @as(u32, @truncate(tagged >> 32));
            self.free_indices[descriptor_index] = head;
            const new_tagged = @as(u64, aba +% 1) << 32 | @as(u64, descriptor_index);
            if (self.free_top_tagged.cmpxchgWeak(tagged, new_tagged, .acq_rel, .acquire)) |_| {
                continue;
            }
            break;
        }

        // Wake one blocked submitter (if any) now that a descriptor is
        // available. Fast-path: skip the mutex entirely when no submitter
        // is blocked — the common uncontended case.
        if (self.sync.backpressure_waiters.load(.monotonic) > 0) {
            self.sync.backpressure_mutex.lock();
            self.sync.backpressure_cond.signal();
            self.sync.backpressure_mutex.unlock();
        }
    }

    fn recordOwnedAlloc(self: *Core, bytes: usize) void {
        self.accounting.recordAlloc(bytes);
    }

    fn recordOwnedFree(self: *Core, bytes: usize) void {
        self.accounting.recordFree(bytes);
    }

    fn deinitOwned(self: *Core) void {
        for (self.workers) |*worker| {
            worker.scratch.purge();
        }
        for (self.workers) |*w| {
            self.recordOwnedFree(w.incoming.capacity() * @sizeOf(u32));
            w.incoming.deinit();
        }
        for (self.local_queues) |*lq| {
            self.recordOwnedFree(lq.capacity() * @sizeOf(u32));
            lq.deinit();
        }
        self.inject_queue.deinit();
        self.recordOwnedFree(self.worker_stats_buffer.len * @sizeOf(types.WorkerStats));
        self.allocator.free(self.worker_stats_buffer);
        self.recordOwnedFree(self.free_indices.len * @sizeOf(u32));
        self.allocator.free(self.free_indices);
        self.recordOwnedFree(self.descriptors.len * @sizeOf(TaskDescriptor));
        self.allocator.free(self.descriptors);
        self.recordOwnedFree(self.local_queues.len * @sizeOf(LocalQueue));
        self.allocator.free(self.local_queues);
        self.recordOwnedFree(self.workers.len * @sizeOf(Worker));
        self.allocator.free(self.workers);
    }

    fn incrementQueued(self: *Core) void {
        // Must be .seq_cst: the submit-path park handshake requires this store
        // to participate in the SC total order so that the IRIW scenario
        // (submitter reads is_parked=0 AND worker reads queued_tasks=0) is
        // excluded. See the comment in idle() for the full argument.
        const queue_depth = self.counters.queued_tasks.fetchAdd(1, .seq_cst) +% 1;
        updatePeak(&self.counters.queue_depth_peak, queue_depth);
    }

    fn decrementQueued(self: *Core) void {
        _ = self.counters.queued_tasks.fetchSub(1, .release);
    }
};

/// A bounded, fixed-capacity thread pool with configurable scheduling.
///
/// Supports two scheduler variants behind the same API: `global_queue`
/// (single shared FIFO) and `work_stealing` (per-worker deques with
/// steal-from-peer). All submissions are non-blocking by default; use
/// `SubmitOptions.backpressure` for blocking behavior when the queue is full.
pub const ThreadPool = struct {
    core: *Core,

    /// Create a new thread pool with the given configuration.
    /// Workers are spawned immediately and begin polling for tasks.
    /// The allocator is retained for the pool's lifetime and used for
    /// internal allocations (descriptors, queues, scratch buffers).
    pub fn init(allocator: std.mem.Allocator, config: types.Config) !ThreadPool {
        const core = try allocator.create(Core);
        errdefer allocator.destroy(core);
        try core.init(allocator, config);
        return .{ .core = core };
    }

    /// Shut down the pool and release all resources.
    /// Drains remaining tasks up to `Config.deinit_timeout_ns` (default 30s),
    /// then force-joins worker threads. After this call the pool is unusable.
    pub fn deinit(self: *ThreadPool) void {
        const allocator = self.core.allocator;
        self.core.deinit();
        allocator.destroy(self.core);
        self.* = undefined;
    }

    /// Submit a task without blocking. Returns `error.QueueFull` or
    /// `error.TaskPoolExhausted` immediately if capacity is exhausted,
    /// regardless of the backpressure policy in `options`.
    pub fn trySubmit(self: *ThreadPool, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.core.trySubmit(task_fn, ctx, options);
    }

    /// Submit a task, optionally blocking per `options.backpressure`.
    /// Returns a `TaskHandle` that can be passed to `wait()` if
    /// `options.waitable` is true; otherwise returns an invalid handle.
    pub fn submit(self: *ThreadPool, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.core.submit(task_fn, ctx, options);
    }

    /// Submit multiple tasks atomically. Returns the count of tasks
    /// successfully enqueued. If the first task fails, the error propagates;
    /// subsequent failures return a partial `SubmitBatchResult`.
    pub fn submitBatch(self: *ThreadPool, tasks: []const BatchTask, options: types.SubmitOptions) !Core.SubmitBatchResult {
        return self.core.submitBatch(tasks, options);
    }

    /// Block until a waitable task completes or is cancelled.
    /// The task descriptor is released upon return. Passing an invalid
    /// or non-waitable handle returns `error.InvalidHandle`.
    pub fn wait(self: *ThreadPool, handle: types.TaskHandle) !void {
        return self.core.wait(handle);
    }

    /// Return a new `WaitGroup` for coordinating completion of a batch
    /// of tasks. Pass `&wg` via `SubmitOptions.wait_group`, then call
    /// `wg.wait()` to block until all tasks in the group finish.
    pub fn waitGroup(self: *ThreadPool) types.WaitGroup {
        return self.core.waitGroup();
    }

    /// Initiate graceful or immediate shutdown.
    /// `.drain` waits for all queued and active tasks to complete.
    /// `.cancel_pending` cancels queued tasks, then waits for active ones.
    /// Pass a `timeout_ns` to bound the wait; returns `error.Timeout`
    /// if the deadline elapses with tasks still in flight.
    pub fn shutdown(self: *ThreadPool, mode: types.ShutdownMode, timeout_ns: ?u64) !void {
        return self.core.shutdown(mode, timeout_ns);
    }

    /// Capture a point-in-time snapshot of pool statistics including
    /// submission counts, latency histograms, memory usage, and
    /// per-worker metrics. Worker stats are read without synchronization
    /// and may be approximate while tasks are actively running.
    pub fn statsSnapshot(self: *ThreadPool) types.Stats {
        return self.core.statsSnapshot();
    }

    /// Release scratch memory held by idle workers. Returns
    /// `error.PoolBusy` if any tasks are currently active, since
    /// purging during execution would corrupt scratch allocators.
    pub fn purgeWorkerCaches(self: *ThreadPool) !void {
        return self.core.purgeWorkerCaches();
    }
};

fn nowNs() u64 {
    const ts = std.time.nanoTimestamp();
    return if (ts < 0) 0 else @as(u64, @intCast(ts));
}

const updatePeak = Accounting.updatePeak;

fn updatePeakU32(counter: *std.atomic.Value(u32), value: u32) void {
    var current = counter.load(.monotonic);
    while (value > current) {
        const previous = counter.cmpxchgWeak(current, value, .monotonic, .monotonic);
        if (previous == null) return;
        current = previous.?;
    }
}
