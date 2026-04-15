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
threadlocal var tls_submitter_index: ?usize = null;

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

/// Queue-slot payload: `{generation_tag: u32 high, index: u32 low}` packed
/// into a u64. Consumers check `entryGen(entry) == descriptor.generation`
/// (truncated) before the state CAS in `runTask` / `cancelDescriptor` to
/// reject stale entries — entries that were enqueued against a prior
/// generation of the same descriptor slot. Without this tag, a stale
/// entry emitted by a queue path can succeed at `state.cmpxchg(.queued,
/// .running)` on the new generation's `.queued` state, producing a
/// double-dispatch (confirmed under the Option D drain-vs-steal reorder;
/// also a latent race under the default drain-first order, just with a
/// much narrower window). See
/// `docs/superpowers/specs/2026-04-15-option-c-drain-hint-design.md`
/// "Post-mortem iteration 2" for the diagnosis.
pub const QueueEntry = u64;

inline fn packEntry(index: u32, generation: u64) QueueEntry {
    return (@as(u64, @as(u32, @truncate(generation))) << 32) | @as(u64, index);
}
inline fn entryIndex(entry: QueueEntry) u32 {
    return @as(u32, @truncate(entry));
}
inline fn entryGen(entry: QueueEntry) u32 {
    return @as(u32, @truncate(entry >> 32));
}

/// Tagged-union wrapper over the two per-worker local queue implementations.
/// Selected per-pool via `Config.queue_kind`. All call sites dispatch through
/// the unified methods (tryPushBottom, popBottom, steal, stealOne, len,
/// capacity) so the rest of `Core` is queue-kind agnostic.
const LocalQueue = union(enum) {
    chase_lev: WorkDeque(QueueEntry),
    ring: RingQueue(QueueEntry),

    fn init(allocator: std.mem.Allocator, size: usize, kind: types.QueueKind) !LocalQueue {
        return switch (kind) {
            .chase_lev => .{ .chase_lev = try WorkDeque(QueueEntry).init(allocator, size) },
            .ring => .{ .ring = try RingQueue(QueueEntry).init(allocator, size) },
        };
    }

    fn deinit(self: *LocalQueue) void {
        switch (self.*) {
            .chase_lev => |*q| q.deinit(),
            .ring => |*q| q.deinit(),
        }
    }

    fn tryPushBottom(self: *LocalQueue, value: QueueEntry) bool {
        return switch (self.*) {
            .chase_lev => |*q| q.tryPushBottom(value),
            .ring => |*q| q.tryPush(value),
        };
    }

    fn popBottom(self: *LocalQueue) ?QueueEntry {
        return switch (self.*) {
            .chase_lev => |*q| q.popBottom(),
            .ring => |*q| q.pop(),
        };
    }

    /// Steal up to `out.len` items. For chase_lev returns at most 1; for
    /// ring returns up to (len+1)/2 items via stealHalf.
    fn steal(self: *LocalQueue, out: []QueueEntry) usize {
        return switch (self.*) {
            .chase_lev => |*q| if (q.stealTop()) |v| blk: {
                out[0] = v;
                break :blk @as(usize, 1);
            } else 0,
            .ring => |*q| q.stealHalf(out),
        };
    }

    /// Single-item drain — used by shutdown to cancel pending tasks.
    fn stealOne(self: *LocalQueue) ?QueueEntry {
        return switch (self.*) {
            .chase_lev => |*q| q.stealTop(),
            .ring => |*q| blk: {
                var buf: [1]QueueEntry = undefined;
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
    /// means two workers are racing for this descriptor — panic. Guarded
    /// reads/writes are gated by `claim_sentinel_enabled` (defined below).
    claimed_by: std.atomic.Value(i32) = std.atomic.Value(i32).init(-1),

    comptime {
        // Document the intended cache layout: ensure the hot fields fit in
        // one cache line so dispatch never touches the cold metric fields.
        const hot_size = @offsetOf(TaskDescriptor, "submit_ns");
        std.debug.assert(hot_size <= std.atomic.cache_line);
    }
};

/// Sentinel value meaning "the lifo_slot is empty". Chosen as the max u64
/// so packed {gen, index} entries (low 32 bits are index) never collide —
/// widened from u32 to carry the generation tag.
const LIFO_SLOT_EMPTY: QueueEntry = 0xFFFF_FFFF_FFFF_FFFF;

/// When `true`, the per-descriptor `claimed_by` sentinel is active: every
/// successful state CAS in `runTask` / `cancelQueuedTasks` also CAS-claims
/// `claimed_by` from `-1` to the worker index, and a failed claim panics
/// (catches double-dequeue races). Tied to `std.debug.runtime_safety` so
/// Debug / ReleaseSafe builds keep the detector; ReleaseFast drops the
/// extra CAS pair from the dispatch hot path now that the Phase H race is
/// fixed (see `docs/performance/phase-h/`).
const claim_sentinel_enabled: bool = std.debug.runtime_safety;

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
    /// Owner-private upper bound on `local_queues[worker_index]` length.
    /// Incremented on every push by the owner; decremented on every
    /// successful pop. Stealers reduce real length below this value —
    /// reconciled to 0 when `popBottom` returns null. Used to drive
    /// 0↔1 transitions of `Core.workers_nonempty` WITHOUT reading the
    /// queue's stealer-written `head` cacheline every pop.
    owned_queue_len: usize = 0,
    /// Tokio-style single-slot LIFO cache. When a task is submitted from this
    /// worker's thread, it goes here first (single atomic store); `nextTask`
    /// pops the slot ahead of the local ring. Cross-worker submits never
    /// touch this slot. Stealers never touch this slot either — only the
    /// owner writes to it. Sentinel value `LIFO_SLOT_EMPTY` (0xFFFF_FFFF)
    /// means "no cached task".
    lifo_slot: std.atomic.Value(QueueEntry) = std.atomic.Value(QueueEntry).init(LIFO_SLOT_EMPTY),
    /// Which lane this worker serves. Set once at spawn and never mutated
    /// in Slice L1 (dynamic rebalancing in L3 may soften this). Workers
    /// with `serves_lane = .blocking` drain the blocking-lane inject queue
    /// and only steal from other `.blocking` workers; default workers drain
    /// the default-lane queue and only steal from `.default` workers. See
    /// docs/superpowers/specs/2026-04-15-lane-extension-scheduler-design.md.
    serves_lane: types.TaskLane = .default,
    /// Slice L4 — timestamp (ns) when the currently-executing task was
    /// dispatched. Zero means idle (no task running). Written unconditionally
    /// in `runTask` when `Config.watchdog_interval_ns > 0`; skipped entirely
    /// when the watchdog is disabled to preserve zero-overhead hot path.
    /// The watchdog thread reads this on every tick to detect stalls.
    current_task_started_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    is_overflow: bool = false,
    overflow_retired: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Synchronization primitives for task completion. Worker parking uses
/// per-Worker park_mutex/park_cond to avoid contention on a shared mutex.
const Sync = struct {
    completion_mutex: std.Thread.Mutex = .{},
    completion_cond: std.Thread.Condition = .{},
    /// Backpressure primitives: blocked submitters (when queue/descriptor
    /// pool is full) sleep on a lane-scoped condvar rather than polling with
    /// a fixed-interval `Thread.sleep`. `releaseDescriptor` signals the
    /// condvars when capacity becomes available. `*_waiters` is an atomic
    /// fast-path counter so the producer path can skip acquiring the mutex
    /// entirely when nobody is blocked.
    ///
    /// Slice L2 splits the backpressure primitives per lane so a full
    /// blocking queue cannot thundering-herd wake default-lane submitters,
    /// and vice versa. When `blocking_workers == 0` the blocking primitives
    /// are initialized but never touched.
    default_backpressure_mutex: std.Thread.Mutex = .{},
    default_backpressure_cond: std.Thread.Condition = .{},
    default_backpressure_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    blocking_backpressure_mutex: std.Thread.Mutex = .{},
    blocking_backpressure_cond: std.Thread.Condition = .{},
    blocking_backpressure_waiters: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
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

    // === Hot write group (blocking-lane submit path) ===
    // Parallel to `queued_tasks`, but only touched by `.lane = .blocking`
    // submits and their matching `runTask`/`cancelDescriptor` decrements.
    // Keeping blocking-lane counter-traffic off the default-lane cacheline
    // is a prerequisite for the park handshake: a default worker's SC load
    // of `queued_tasks` must not see blocking-lane increments, else it
    // would unpark repeatedly on cross-lane submits with nothing to do.
    queued_tasks_blocking: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad1b: [cache_line_size - field_size]u8 = undefined,

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
    // Slice L4 — watchdog observability. Incremented each time the watchdog
    // thread sees a default-lane worker that has been running one task for
    // longer than `Config.blocking_promotion_timeout_ns`. Cumulative across
    // the pool's lifetime; a single long-stalled task may be counted more
    // than once (once per watchdog tick it remains stalled).
    watchdog_stalls_detected: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overflow_spawns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overflow_retires: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    overflow_active: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    comptime {
        // Cacheline isolation invariants: each hot-write counter owns a distinct line.
        std.debug.assert(@offsetOf(Counters, "queued_tasks") == 0);
        std.debug.assert(@offsetOf(Counters, "submitted") == cache_line_size);
        std.debug.assert(@offsetOf(Counters, "active_tasks") == 2 * cache_line_size);
        std.debug.assert(@offsetOf(Counters, "queued_tasks_blocking") == 3 * cache_line_size);
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
    inject_queue: BoundedRing(QueueEntry),
    /// Blocking-lane inject queue. Present iff `config.blocking_workers > 0`.
    /// Fed by `.lane = .blocking` submits; drained by workers whose
    /// `serves_lane == .blocking`. When `blocking_workers == 0` this stays
    /// null and the default-lane path is byte-for-byte identical to pre-L1
    /// behavior (A/B regression gate).
    blocking_inject: ?BoundedRing(QueueEntry) = null,
    sync: Sync = .{},
    counters: Counters align(std.atomic.cache_line) = .{},
    worker_stats_buffer: []types.WorkerStats,
    /// Bit `i` set iff worker `i`'s local queue is believed non-empty.
    /// Owner-side updates only on 0↔1 transitions. Replaces the
    /// 55-victim `len()` peek loop in nextTask with one u64 load.
    /// Max 64 workers (enforced by Config.validate).
    workers_nonempty: std.atomic.Value(u64) align(std.atomic.cache_line) = std.atomic.Value(u64).init(0),
    submitter_queues: []LocalQueue = &.{},
    submitter_nonempty: std.atomic.Value(u64) align(std.atomic.cache_line) = std.atomic.Value(u64).init(0),
    submitter_free_mask: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Slice L4 — optional watchdog thread. Spawned when
    /// `config.watchdog_interval_ns > 0`. Walks default-lane workers every
    /// interval looking for stalled tasks (task duration exceeds
    /// `config.blocking_promotion_timeout_ns`). Stalls increment
    /// `counters.watchdog_stalls_detected` and trigger overflow-worker
    /// spawn up to `config.max_overflow_workers`.
    watchdog_thread: ?std.Thread = null,
    /// Signals the watchdog thread to exit. Set by `joinAllWorkers` before
    /// join. Read by `watchdogMain` on each tick.
    watchdog_stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn init(self: *Core, allocator: std.mem.Allocator, config: types.Config) !void {
        var normalized = config.normalized();
        try normalized.validate();

        const total_worker_slots = normalized.max_threads + normalized.max_overflow_workers;
        self.* = .{
            .allocator = allocator,
            .config = normalized,
            .workers = try allocator.alloc(Worker, total_worker_slots),
            .local_queues = try allocator.alloc(LocalQueue, total_worker_slots),
            .descriptors = try allocator.alloc(TaskDescriptor, normalized.queue_capacity),
            .free_indices = try allocator.alloc(u32, normalized.queue_capacity),
            .inject_queue = try BoundedRing(QueueEntry).init(allocator, normalized.queue_capacity),
            .blocking_inject = if (normalized.blocking_workers > 0)
                try BoundedRing(QueueEntry).init(allocator, if (normalized.blocking_queue_capacity > 0)
                    normalized.blocking_queue_capacity
                else
                    normalized.queue_capacity)
            else
                null,
            .worker_stats_buffer = try allocator.alloc(types.WorkerStats, total_worker_slots),
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
        if (self.blocking_inject) |*bi| {
            self.recordOwnedAlloc(bi.capacity() * @sizeOf(u32));
        }

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

        for (self.workers[0..normalized.max_threads], self.local_queues[0..normalized.max_threads], 0..) |*worker, *lq, idx| {
            lq.* = try LocalQueue.init(allocator, normalized.local_queue_capacity, normalized.queue_kind);
            worker.* = .{
                .scratch = WorkerScratch.init(allocator, self.accounting, normalized.worker_scratch_cap_bytes),
                .last_idle_started_ns = std.atomic.Value(u64).init(nowNs()),
                .serves_lane = if (idx < normalized.blocking_workers) .blocking else .default,
            };
            self.recordOwnedAlloc(lq.capacity() * @sizeOf(u32));
        }

        for (normalized.max_threads..total_worker_slots) |oidx| {
            self.local_queues[oidx] = try LocalQueue.init(allocator, normalized.local_queue_capacity, normalized.queue_kind);
            self.workers[oidx] = .{
                .scratch = WorkerScratch.init(allocator, self.accounting, normalized.worker_scratch_cap_bytes),
                .last_idle_started_ns = std.atomic.Value(u64).init(nowNs()),
                .serves_lane = .default,
                .is_overflow = true,
            };
            self.recordOwnedAlloc(self.local_queues[oidx].capacity() * @sizeOf(u32));
        }

        if (normalized.max_submitter_queues > 0) {
            self.submitter_queues = try allocator.alloc(LocalQueue, normalized.max_submitter_queues);
            for (self.submitter_queues) |*sq| {
                sq.* = try LocalQueue.init(allocator, normalized.submitter_queue_capacity, normalized.queue_kind);
            }
            self.submitter_free_mask = std.atomic.Value(u64).init((@as(u64, 1) << @intCast(normalized.max_submitter_queues)) - 1);
            self.recordOwnedAlloc(self.submitter_queues.len * @sizeOf(LocalQueue));
        }

        for (self.workers[0..normalized.max_threads], 0..) |*worker, idx| {
            worker.thread = try std.Thread.spawn(.{}, workerMain, .{ self, idx });
        }

        if (normalized.watchdog_interval_ns > 0) {
            self.watchdog_thread = try std.Thread.spawn(.{}, watchdogMain, .{self});
        }
    }

    pub fn deinit(self: *Core) void {
        self.shutdown(.drain, self.config.deinit_timeout_ns) catch {
            std.log.warn("thread-pool deinit timed out after {d}ms with {d} active tasks and {d} queued", .{
                self.config.deinit_timeout_ns / std.time.ns_per_ms,
                self.counters.active_tasks.load(.acquire),
                self.totalQueuedTasks(),
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

    /// Submit up to `tasks.len` work items, amortizing per-batch atomic cost.
    ///
    /// Batches the three submitter-side atomics (`counters.submitted`,
    /// `queued_tasks` seq_cst increment, parked-worker wake scan) across the
    /// whole batch: one `fetchAdd(n)` on each counter and one wake scan that
    /// signals up to `n` parked workers. A 2026-04-14 ceiling A/B showed that
    /// removing these per-task atomics lifts flood_1m throughput by ~30%;
    /// amortizing them with this API captures a large fraction of that.
    ///
    /// Backpressure honors `options.backpressure`: on queue-full or
    /// descriptor-exhaust mid-batch, blocking policies drain the accumulated
    /// notify so workers can make progress, then retry; `.return_error`
    /// returns a partial `SubmitBatchResult.submitted` reflecting the count
    /// of tasks actually queued.
    pub fn submitBatch(self: *Core, tasks: []const BatchTask, options: types.SubmitOptions) !SubmitBatchResult {
        if (tasks.len == 0) return .{ .submitted = 0 };

        const effective = self.effectiveBackpressure(options);
        const deadline = if (effective == .block_with_timeout and options.timeout_ns != null)
            nowNs() + options.timeout_ns.?
        else
            0;

        var submitted: usize = 0;
        var pending_notify: u64 = 0;
        var i: usize = 0;
        while (i < tasks.len) {
            if (self.state.load(.acquire) != .running) {
                if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
                if (submitted == 0) return error.ShutdownInProgress;
                return .{ .submitted = submitted };
            }
            if (self.enqueuePush(tasks[i].task_fn, tasks[i].ctx, options)) |_| {
                pending_notify += 1;
                submitted += 1;
                i += 1;
            } else |err| switch (err) {
                error.QueueFull, error.TaskPoolExhausted => {
                    if (effective == .return_error) {
                        if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
                        if (submitted == 0) return err;
                        return .{ .submitted = submitted };
                    }
                    if (deadline != 0 and nowNs() >= deadline) {
                        if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
                        if (submitted == 0) return error.Timeout;
                        return .{ .submitted = submitted };
                    }
                    if (pending_notify > 0) {
                        self.notifySubmits(pending_notify, options.lane);
                        pending_notify = 0;
                    }
                    self.waitForCapacity(deadline, options.lane);
                },
                error.BlockingLaneDisabled => {
                    // Config rejects this lane. Flush pending then propagate
                    // the error regardless of backpressure — no amount of
                    // waiting will unblock a disabled lane.
                    if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
                    if (submitted == 0) return err;
                    return .{ .submitted = submitted };
                },
            }
        }
        if (pending_notify > 0) self.notifySubmits(pending_notify, options.lane);
        return .{ .submitted = submitted };
    }

    pub fn registerSubmitter(self: *Core) !usize {
        while (true) {
            const mask = self.submitter_free_mask.load(.acquire);
            if (mask == 0) return error.NoSubmitterSlots;
            const idx: usize = @ctz(mask);
            const bit: u64 = @as(u64, 1) << @intCast(idx);
            if (self.submitter_free_mask.cmpxchgWeak(mask, mask & ~bit, .acq_rel, .monotonic) == null) {
                tls_submitter_index = idx;
                _ = self.submitter_nonempty.fetchOr(bit, .release);
                return idx;
            }
        }
    }

    pub fn releaseSubmitter(self: *Core, idx: usize) void {
        tls_submitter_index = null;
        while (self.submitter_queues[idx].stealOne()) |entry| {
            _ = self.inject_queue.tryPush(entry);
        }
        const bit: u64 = @as(u64, 1) << @intCast(idx);
        _ = self.submitter_nonempty.fetchAnd(~bit, .release);
        _ = self.submitter_free_mask.fetchOr(bit, .release);
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
            const queued = self.totalQueuedTasks();
            const active = self.counters.active_tasks.load(.acquire);
            if (queued == 0 and active == 0) break;
            if (deadline != 0 and nowNs() >= deadline) return error.Timeout;

            // Wait on the default-lane backpressure condvar, which
            // releaseDescriptor signals on every completion (both lanes are
            // signaled, so either queue draining progresses the shutdown).
            // Cap at 10ms so we re-check state even if a signal is lost.
            self.waitForCapacity(deadline, .default);
        }

        self.joinAllWorkers();
    }

    fn joinAllWorkers(self: *Core) void {
        // Signal all workers to exit
        self.state.store(.stopping, .release);
        // Stop the watchdog FIRST so it cannot spawn new overflow workers
        // while we are joining. The watchdog only reads worker atomics and
        // spawns threads — stopping it before the worker join pass ensures
        // no new threads appear after we start joining.
        if (self.watchdog_thread) |thread| {
            self.watchdog_stop.store(true, .release);
            thread.join();
            self.watchdog_thread = null;
        }
        // Wake every worker so they observe the state change and exit.
        for (self.workers) |*w| {
            w.park_mutex.lock();
            w.park_cond.broadcast();
            w.park_mutex.unlock();
        }
        // Wake any submitters blocked on backpressure so they observe the
        // state change and return error.ShutdownInProgress instead of
        // sleeping forever. Broadcast both lanes because either may have
        // waiters parked on a full queue.
        self.sync.default_backpressure_mutex.lock();
        self.sync.default_backpressure_cond.broadcast();
        self.sync.default_backpressure_mutex.unlock();
        self.sync.blocking_backpressure_mutex.lock();
        self.sync.blocking_backpressure_cond.broadcast();
        self.sync.blocking_backpressure_mutex.unlock();

        // Join all threads (regular + any active overflow workers)
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
        }
        self.state.store(.stopped, .release);
    }

    /// Wait for descriptor/queue capacity to free up on `lane`, bounded by
    /// `deadline` (absolute nanoseconds; 0 = no deadline). Cap each wait at
    /// 10ms so we re-check state periodically even if a signal is missed.
    ///
    /// Split per-lane (L2): a full blocking queue parks blocking-lane
    /// submitters only, leaving default-lane submitters free to proceed.
    fn waitForCapacity(self: *Core, deadline: u64, lane: types.TaskLane) void {
        const waiters = self.backpressureWaiters(lane);
        const mtx = self.backpressureMutex(lane);
        const cond = self.backpressureCond(lane);

        _ = waiters.fetchAdd(1, .monotonic);
        defer _ = waiters.fetchSub(1, .monotonic);

        mtx.lock();
        defer mtx.unlock();

        const wait_ns: u64 = if (deadline != 0) blk: {
            const now = nowNs();
            break :blk if (now >= deadline) 0 else @min(deadline - now, 10_000_000);
        } else 10_000_000;

        if (wait_ns > 0) {
            cond.timedWait(mtx, wait_ns) catch {};
        }
    }

    inline fn backpressureWaiters(self: *Core, lane: types.TaskLane) *std.atomic.Value(u32) {
        return switch (lane) {
            .default => &self.sync.default_backpressure_waiters,
            .blocking => &self.sync.blocking_backpressure_waiters,
        };
    }

    inline fn backpressureMutex(self: *Core, lane: types.TaskLane) *std.Thread.Mutex {
        return switch (lane) {
            .default => &self.sync.default_backpressure_mutex,
            .blocking => &self.sync.blocking_backpressure_mutex,
        };
    }

    inline fn backpressureCond(self: *Core, lane: types.TaskLane) *std.Thread.Condition {
        return switch (lane) {
            .default => &self.sync.default_backpressure_cond,
            .blocking => &self.sync.blocking_backpressure_cond,
        };
    }

    /// Effective backpressure policy for a submit: `Config.blocking_backpressure`
    /// / `Config.default_backpressure` forces the lane's policy when non-null
    /// (L2), otherwise the caller's `SubmitOptions.backpressure` wins.
    inline fn effectiveBackpressure(self: *const Core, options: types.SubmitOptions) types.BackpressurePolicy {
        return switch (options.lane) {
            .blocking => self.config.blocking_backpressure orelse options.backpressure,
            .default => self.config.default_backpressure orelse options.backpressure,
        };
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
            .queue_depth_current = self.totalQueuedTasks(),
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
            .watchdog_stalls_detected = self.counters.watchdog_stalls_detected.load(.acquire),
            .overflow_spawns = self.counters.overflow_spawns.load(.acquire),
            .overflow_retires = self.counters.overflow_retires.load(.acquire),
            .overflow_active = self.counters.overflow_active.load(.acquire),
            .task_wait_ns = merged_wait.summary(),
            .task_exec_ns = merged_exec.summary(),
            .memory = memory,
            .worker_stats = self.worker_stats_buffer,
        };
    }

    pub fn purgeWorkerCaches(self: *Core) !void {
        if (self.counters.active_tasks.load(.acquire) != 0) return error.PoolBusy;
        if (self.totalQueuedTasks() != 0) return error.PoolBusy;
        for (self.workers) |*worker| {
            worker.scratch.purge();
        }
    }

    fn submitInternal(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions, allow_block: bool) !types.TaskHandle {
        const effective = self.effectiveBackpressure(options);
        const deadline = if (allow_block and effective == .block_with_timeout and options.timeout_ns != null)
            nowNs() + options.timeout_ns.?
        else
            0;

        while (true) {
            if (self.state.load(.acquire) != .running) return error.ShutdownInProgress;
            if (self.enqueueTask(task_fn, ctx, options)) |handle| {
                return handle;
            } else |err| switch (err) {
                error.QueueFull, error.TaskPoolExhausted => {
                    if (!allow_block or effective == .return_error) return err;
                    if (deadline != 0 and nowNs() >= deadline) return error.Timeout;
                    self.waitForCapacity(deadline, options.lane);
                },
                else => return err,
            }
        }
    }

    fn enqueueTask(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        const handle = try self.enqueuePush(task_fn, ctx, options);

        // Always update counters so the SC park handshake sees queued work.
        const prev_submitted = self.counters.submitted.fetchAdd(1, .monotonic);
        const lane_counter = self.queuedTasksCounter(options.lane);
        const queue_depth = lane_counter.fetchAdd(1, .seq_cst) +% 1;
        updatePeak(&self.counters.queue_depth_peak, queue_depth);

        // Coalesce wake scans: only do the expensive worker scan + futex
        // signal every `wake_coalesce_batch` submits. Between flushes, parked
        // workers that attempt to re-park bail immediately via the SC
        // queued_tasks handshake (they see > 0 and return without sleeping).
        // Using the pool-wide submitted counter avoids TLS state that leaks
        // across pool lifetimes. The first submit (prev_submitted=0) always
        // wakes to ensure at least one worker is active.
        const batch: u64 = self.config.wake_coalesce_batch;
        if (batch <= 1 or prev_submitted % batch == 0) {
            self.scanAndWake(options.lane);
        }

        return handle;
    }

    /// Per-task push path without the submitter-side notify atomics.
    /// Callers are responsible for calling `notifySubmits(n, lane)` with the
    /// number of successful pushes (single `notifySubmits(1, lane)` for plain
    /// `submit`, batched `notifySubmits(count, lane)` for `submitBatch`).
    ///
    /// Lane routing rules (Slice L1):
    /// - `.lane = .blocking` with `!allow_blocking_lane` → `error.BlockingLaneDisabled`
    /// - `.lane = .blocking` with `blocking_workers > 0` → blocking-lane inject queue;
    ///   never routed through LIFO slot or local queues.
    /// - `.lane = .blocking` with `blocking_workers == 0` → falls back to default
    ///   inject queue (user opted in via allow_blocking_lane but reserved no workers).
    /// - `.lane = .default` with TLS submitter being a blocking worker → skips
    ///   LIFO/local path (a blocking worker's caches must not hold default-lane work);
    ///   goes straight to the default inject queue.
    fn enqueuePush(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        if (options.lane == .blocking and !self.config.allow_blocking_lane) {
            return error.BlockingLaneDisabled;
        }

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

        const entry = packEntry(descriptor_index, descriptor.generation);
        var queued = false;

        if (options.lane == .blocking) {
            // Blocking-lane submit: go directly to the blocking inject queue.
            // Config.validate enforces allow_blocking_lane → blocking_workers > 0,
            // so blocking_inject is guaranteed non-null here.
            if (self.blocking_inject) |*bi| {
                queued = bi.tryPush(entry);
            } else unreachable;
        } else {
            // Default-lane submit: LIFO/local fast path, gated on TLS worker
            // being a default-lane worker. work_stealing and lane_extension
            // both use per-worker queues; global_queue skips them.
            const uses_local = self.config.scheduler_variant == .work_stealing or
                self.config.scheduler_variant == .lane_extension;
            if (uses_local and tls_worker_index != null) {
                const wi = tls_worker_index.?;
                const w = &self.workers[wi];
                if (w.serves_lane == .default) {
                    if (w.lifo_slot.load(.monotonic) == LIFO_SLOT_EMPTY) {
                        w.lifo_slot.store(entry, .release);
                        queued = true;
                    } else {
                        const was_empty = w.owned_queue_len == 0;
                        queued = self.local_queues[wi].tryPushBottom(entry);
                        if (queued) {
                            w.owned_queue_len += 1;
                            if (was_empty) self.markWorkerNonEmpty(wi);
                            updatePeakU32(&w.local_queue_peak, @intCast(w.owned_queue_len));
                        }
                    }
                }
            }
            if (!queued and tls_submitter_index != null) {
                const si = tls_submitter_index.?;
                queued = self.submitter_queues[si].tryPushBottom(entry);
            }
            if (!queued) {
                queued = self.inject_queue.tryPush(entry);
            }
        }

        if (!queued) {
            if (options.wait_group) |wait_group| wait_group.done();
            return error.QueueFull;
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

    /// Batched submitter-side notify: bumps `counters.submitted` and the
    /// lane's `queued_tasks*` counter by `count` (single seq_cst fetchAdd
    /// for the park handshake), then wakes at most one parked worker that
    /// serves `lane`.
    ///
    /// Must be called after `enqueuePush` has succeeded `count` times for
    /// the same lane since the last notify. A single seq_cst fetchAdd(count)
    /// carries the same SC total-order guarantee as `count` individual
    /// fetchAdds — a parking worker's SC load of the lane counter either
    /// observes the bumped value (and bails out of park) or precedes it,
    /// and the `is_parked` SC pair excludes IRIW regardless of batch size.
    ///
    /// Lane scope: when `blocking_workers == 0` the wake scan covers all
    /// workers (byte-for-byte identical to the pre-lane-extension path —
    /// A/B regression gate). When `blocking_workers > 0` the scan covers
    /// only workers in `lane`'s range, avoiding cross-lane wakeups that
    /// would spin-loop through `nextTask` and re-park immediately.
    ///
    /// Waking exactly one worker per notify — not `count` — matches the
    /// single-submit path and avoids a thundering-herd on the inject queue's
    /// head cacheline. Measured: a wake-up-to-`count` variant regressed
    /// flood_1m_batched throughput ~50% vs this wake-one variant.
    fn notifySubmits(self: *Core, count: u64, lane: types.TaskLane) void {
        if (count == 0) return;
        _ = self.counters.submitted.fetchAdd(count, .monotonic);
        const lane_counter = self.queuedTasksCounter(lane);
        const queue_depth = lane_counter.fetchAdd(count, .seq_cst) +% count;
        updatePeak(&self.counters.queue_depth_peak, queue_depth);
        self.scanAndWake(lane);
    }

    /// Scan workers in `lane` for one parked worker and signal it.
    /// Extracted from notifySubmits so enqueueTask can call it
    /// independently after coalesced counter updates.
    fn scanAndWake(self: *Core, lane: types.TaskLane) void {
        const nb: usize = self.config.blocking_workers;
        const scan_start: usize = if (lane == .blocking) 0 else nb;
        const scan_end: usize = if (lane == .blocking) nb else self.workers.len;
        const scan_len = scan_end - scan_start;
        if (scan_len == 0) return;

        const submitted = self.counters.submitted.load(.monotonic);
        const rel_hint: usize = @intCast(submitted % scan_len);
        var off: usize = 0;
        while (off < scan_len) : (off += 1) {
            const idx = scan_start + ((rel_hint + off) % scan_len);
            const w = &self.workers[idx];
            if (w.is_parked.load(.seq_cst) == 1) {
                w.park_mutex.lock();
                if (w.is_parked.load(.monotonic) == 1) {
                    w.park_cond.signal();
                }
                w.park_mutex.unlock();
                break;
            }
        }
    }

    /// Slice L4 — watchdog main loop. Wakes every `watchdog_interval_ns`,
    /// walks default-lane workers [nb..max_threads), and increments
    /// `counters.watchdog_stalls_detected` for each worker whose current task
    /// has been running longer than `blocking_promotion_timeout_ns`. When
    /// stalls are detected, spawns up to one overflow worker per tick via
    /// `maybeSpawnOverflow`. Exits when `watchdog_stop` is set by
    /// `joinAllWorkers`.
    fn watchdogMain(self: *Core) void {
        const interval_ns = self.config.watchdog_interval_ns;
        const timeout_ns = self.config.blocking_promotion_timeout_ns;
        const nb: usize = self.config.blocking_workers;
        while (!self.watchdog_stop.load(.acquire)) {
            std.Thread.sleep(interval_ns);
            if (self.watchdog_stop.load(.acquire)) break;

            self.reapRetiredOverflow();

            const now = nowNs();
            var stalls_this_tick: u32 = 0;
            var idx: usize = nb;
            while (idx < self.config.max_threads) : (idx += 1) {
                const started = self.workers[idx].current_task_started_ns.load(.acquire);
                if (started == 0) continue;
                if (now <= started) continue;
                if (now - started > timeout_ns) {
                    _ = self.counters.watchdog_stalls_detected.fetchAdd(1, .monotonic);
                    stalls_this_tick += 1;
                }
            }

            if (stalls_this_tick > 0) {
                self.maybeSpawnOverflow();
            }
        }
    }

    fn reapRetiredOverflow(self: *Core) void {
        const max_overflow = self.config.max_overflow_workers;
        if (max_overflow == 0) return;
        const overflow_start = self.config.max_threads;
        const overflow_end = overflow_start + max_overflow;
        var idx: usize = overflow_start;
        while (idx < overflow_end) : (idx += 1) {
            var worker = &self.workers[idx];
            if (worker.overflow_retired.load(.acquire) and worker.thread != null) {
                worker.thread.?.join();
                worker.thread = null;
                worker.overflow_retired.store(false, .release);
                _ = self.counters.overflow_retires.fetchAdd(1, .monotonic);
                _ = self.counters.overflow_active.fetchSub(1, .monotonic);
            }
        }
    }

    fn maybeSpawnOverflow(self: *Core) void {
        const max_overflow = self.config.max_overflow_workers;
        if (max_overflow == 0) return;
        const overflow_start = self.config.max_threads;
        const overflow_end = overflow_start + max_overflow;
        var idx: usize = overflow_start;
        while (idx < overflow_end) : (idx += 1) {
            var worker = &self.workers[idx];
            if (worker.thread == null) {
                worker.thread = std.Thread.spawn(.{}, overflowWorkerMain, .{ self, idx }) catch return;
                _ = self.counters.overflow_spawns.fetchAdd(1, .monotonic);
                _ = self.counters.overflow_active.fetchAdd(1, .monotonic);
                return;
            }
        }
    }

    fn overflowWorkerMain(self: *Core, worker_index: usize) void {
        tls_worker_index = worker_index;
        defer tls_worker_index = null;
        const idle_retire_ns: u64 = self.config.watchdog_interval_ns * 2;
        var idle_since: u64 = 0;

        while (true) {
            if (self.shouldExit()) break;

            const maybe_entry = self.nextTask(worker_index);
            if (maybe_entry == null) {
                const now = nowNs();
                if (idle_since == 0) {
                    idle_since = now;
                } else if (now - idle_since > idle_retire_ns) {
                    break;
                }
                self.idle(worker_index);
                continue;
            }

            idle_since = 0;
            self.runTask(worker_index, maybe_entry.?);
        }

        self.workers[worker_index].overflow_retired.store(true, .release);
    }

    fn workerMain(self: *Core, worker_index: usize) void {
        tls_worker_index = worker_index;
        defer tls_worker_index = null;

        while (true) {
            if (self.shouldExit()) break;

            const maybe_entry = self.nextTask(worker_index);
            if (maybe_entry == null) {
                self.idle(worker_index);
                continue;
            }

            self.runTask(worker_index, maybe_entry.?);
        }
    }

    inline fn markWorkerNonEmpty(self: *Core, worker_index: usize) void {
        const bit: u64 = @as(u64, 1) << @intCast(worker_index);
        _ = self.workers_nonempty.fetchOr(bit, .release);
    }

    inline fn markWorkerEmpty(self: *Core, worker_index: usize) void {
        const bit: u64 = @as(u64, 1) << @intCast(worker_index);
        _ = self.workers_nonempty.fetchAnd(~bit, .release);
    }

    fn nextTask(self: *Core, worker_index: usize) ?QueueEntry {
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
        //
        // Lane routing (Slice L1): the own-lane inject queue is drained first,
        // with steal victims restricted to same-lane workers via `laneMask`.
        // Slice L3 adds optional cross-lane fallback: an idle blocking worker
        // helps the default lane (always on — purely additive capacity with no
        // isolation concern), and a default worker can help the blocking lane
        // when `cpu_helps_blocking` is opted in.
        const uses_local = self.config.scheduler_variant == .work_stealing or
            self.config.scheduler_variant == .lane_extension;
        if (uses_local) {
            // LIFO slot first: owner-only swap-to-empty. Most-recently-submitted
            // task runs next. This is the hot path for "task spawns task".
            const cached = worker.lifo_slot.swap(LIFO_SLOT_EMPTY, .acquire);
            if (cached != LIFO_SLOT_EMPTY) {
                return cached;
            }

            if (lq.popBottom()) |entry| {
                if (worker.owned_queue_len > 0) worker.owned_queue_len -= 1;
                if (worker.owned_queue_len == 0) self.markWorkerEmpty(worker_index);
                return entry;
            }
            // popBottom returned null: real queue is empty regardless of
            // owned_queue_len (stealers may have drained). Reconcile.
            if (worker.owned_queue_len != 0) {
                worker.owned_queue_len = 0;
                self.markWorkerEmpty(worker_index);
            }
        }

        // Try the worker's own lane first (L1 behavior).
        if (self.tryDrainLaneForWorker(worker, worker_index, lq, worker.serves_lane, uses_local)) |entry| {
            return entry;
        }

        // L3: cross-lane fallback when own lane is empty. Always recomputed
        // per nextTask call — "returns to own lane as soon as new own-lane
        // work arrives" semantic falls out of the always-try-own-lane-first
        // ordering above. No sticky cross-lane affinity.
        if (self.rebalanceLane(worker.serves_lane)) |other_lane| {
            if (self.tryDrainLaneForWorker(worker, worker_index, lq, other_lane, uses_local)) |entry| {
                return entry;
            }
        }

        if (uses_local) {
            _ = worker.steal_failures.fetchAdd(1, .release);
        }
        return null;
    }

    /// Returns the lane a worker should try as a fallback when its own lane
    /// has no work, or null if cross-lane rebalancing is not allowed for
    /// this worker. Blocking workers always help the default lane (isolation
    /// is preserved because default-lane steal never targets blocking
    /// workers). Default workers help the blocking lane only under the
    /// explicit `cpu_helps_blocking` opt-in.
    inline fn rebalanceLane(self: *const Core, worker_lane: types.TaskLane) ?types.TaskLane {
        return switch (worker_lane) {
            .blocking => if (self.config.blocking_workers > 0) types.TaskLane.default else null,
            .default => if (self.config.cpu_helps_blocking) types.TaskLane.blocking else null,
        };
    }

    /// Drain one task for `worker` from `lane`'s queues: pop the lane's
    /// inject queue in a batch (spilling into the worker's local deque),
    /// then steal from `lane`'s workers via the non-empty bitmap. Returns
    /// the task to run, or null if `lane` is empty.
    ///
    /// Invariant: overflow from both pop paths goes back into `lane`'s
    /// inject queue, never the other lane's. This keeps cross-lane steal
    /// decisions lossless — a blocking worker rebalancing to the default
    /// lane never contaminates `blocking_inject` with default tasks.
    inline fn tryDrainLaneForWorker(
        self: *Core,
        worker: *Worker,
        worker_index: usize,
        lq: *LocalQueue,
        lane: types.TaskLane,
        uses_local: bool,
    ) ?QueueEntry {
        const lane_inject = self.laneInjectQueue(lane);
        const lane_bits = self.laneMask(lane);

        if (!uses_local) {
            // global_queue: no LIFO/local; straight pop.
            return lane_inject.pop();
        }

        {
            var buf: [32]QueueEntry = undefined;
            const cap = @min(self.config.inject_batch_size, buf.len);
            const n = lane_inject.popMany(buf[0..cap]);
            if (n > 0) {
                const first = buf[0];
                const was_empty = worker.owned_queue_len == 0;
                var pushed_count: usize = 0;
                var i: usize = 1;
                while (i < n) : (i += 1) {
                    if (!lq.tryPushBottom(buf[i])) {
                        while (i < n) : (i += 1) {
                            _ = lane_inject.tryPush(buf[i]);
                        }
                        break;
                    }
                    pushed_count += 1;
                }
                if (pushed_count > 0) {
                    worker.owned_queue_len += pushed_count;
                    if (was_empty) self.markWorkerNonEmpty(worker_index);
                }
                updatePeakU32(&worker.local_queue_peak, @intCast(worker.owned_queue_len));
                return first;
            }
        }

        {
            var sub_mask = self.submitter_nonempty.load(.acquire);
            while (sub_mask != 0) {
                const sub_idx: usize = @ctz(sub_mask);
                sub_mask &= sub_mask - 1;
                var stolen: [32]QueueEntry = undefined;
                const budget = @min(self.config.steal_batch_size, stolen.len);
                const n = self.submitter_queues[sub_idx].steal(stolen[0..budget]);
                if (n > 0) {
                    const first = stolen[0];
                    const was_empty = worker.owned_queue_len == 0;
                    var pushed_count: usize = 0;
                    for (stolen[1..n]) |entry| {
                        if (!lq.tryPushBottom(entry)) {
                            _ = lane_inject.tryPush(entry);
                        } else {
                            pushed_count += 1;
                        }
                    }
                    if (pushed_count > 0) {
                        worker.owned_queue_len += pushed_count;
                        if (was_empty) self.markWorkerNonEmpty(worker_index);
                    }
                    updatePeakU32(&worker.local_queue_peak, @intCast(worker.owned_queue_len));
                    return first;
                }
            }
        }

        // Steal-peek bitmap restricted to `lane`'s workers.
        const self_bit: u64 = @as(u64, 1) << @intCast(worker_index);
        var mask = self.workers_nonempty.load(.acquire) & lane_bits & ~self_bit;
        while (mask != 0) {
            const victim_index: usize = @ctz(mask);
            mask &= mask - 1;
            var stolen: [32]QueueEntry = undefined;
            const budget = @min(self.config.steal_batch_size, stolen.len);
            const n = self.local_queues[victim_index].steal(stolen[0..budget]);
            if (n > 0) {
                const first = stolen[0];
                const was_empty = worker.owned_queue_len == 0;
                var pushed_count: usize = 0;
                for (stolen[1..n]) |entry| {
                    if (!lq.tryPushBottom(entry)) {
                        _ = lane_inject.tryPush(entry);
                    } else {
                        pushed_count += 1;
                    }
                }
                if (pushed_count > 0) {
                    worker.owned_queue_len += pushed_count;
                    if (was_empty) self.markWorkerNonEmpty(worker_index);
                }
                _ = worker.steals.fetchAdd(n, .release);
                updatePeakU32(&worker.local_queue_peak, @intCast(worker.owned_queue_len));
                return first;
            }
        }

        return null;
    }

    /// Returns the inject queue this worker should drain based on its lane.
    /// When `blocking_workers == 0`, all workers are `.default` and this
    /// always returns `&inject_queue` — no change vs pre-L1.
    inline fn laneInjectQueue(self: *Core, lane: types.TaskLane) *BoundedRing(QueueEntry) {
        return switch (lane) {
            .default => &self.inject_queue,
            .blocking => if (self.blocking_inject) |*bi| bi else unreachable,
        };
    }

    fn runTask(self: *Core, worker_index: usize, entry: QueueEntry) void {
        var worker = &self.workers[worker_index];
        const descriptor_index = entryIndex(entry);
        const entry_gen = entryGen(entry);
        var descriptor = &self.descriptors[descriptor_index];

        // Stale-entry filter — see `QueueEntry` doc. Reject entries whose
        // generation tag predates the descriptor's current generation, so
        // a recycled slot cannot be double-dispatched through the state CAS.
        if (@as(u32, @truncate(descriptor.generation)) != entry_gen) {
            return;
        }

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
        self.decrementQueued(descriptor.options.lane);

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
        const watchdog_enabled = self.config.watchdog_interval_ns > 0;
        const start_ns = if (timestamps_enabled or watchdog_enabled) nowNs() else 0;
        descriptor.start_ns = start_ns;

        if (timestamps_enabled) {
            const wait_ns = start_ns - descriptor.submit_ns;
            worker.wait_histogram.observe(wait_ns);
        }

        if (watchdog_enabled) {
            worker.current_task_started_ns.store(start_ns, .release);
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
        if (watchdog_enabled) {
            worker.current_task_started_ns.store(0, .release);
        }

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
        const lane_counter = self.queuedTasksCounter(worker.serves_lane);
        if (lane_counter.load(.seq_cst) != 0 or self.state.load(.acquire) != .running) {
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
        return self.totalQueuedTasks() == 0 and self.counters.active_tasks.load(.acquire) == 0;
    }

    fn cancelQueuedTasks(self: *Core) !void {
        // Task 4b: no decrementQueued here — it moved into cancelDescriptor's
        // CAS-success path. Matches the nextTask/runTask split so a ghost
        // duplicate index popped during cancellation drains doesn't
        // double-decrement (which would underflow queued_tasks and
        // deadlock shouldExit).
        while (self.inject_queue.pop()) |entry| {
            self.cancelDescriptor(entry);
        }
        if (self.blocking_inject) |*bi| {
            while (bi.pop()) |entry| {
                self.cancelDescriptor(entry);
            }
        }
        const uses_local = self.config.scheduler_variant == .work_stealing or
            self.config.scheduler_variant == .lane_extension;
        if (uses_local) {
            // Drain LIFO slots too.
            for (self.workers) |*w| {
                const cached = w.lifo_slot.swap(LIFO_SLOT_EMPTY, .acquire);
                if (cached != LIFO_SLOT_EMPTY) {
                    self.cancelDescriptor(cached);
                }
            }
            for (self.local_queues) |*lq| {
                while (lq.stealOne()) |entry| {
                    self.cancelDescriptor(entry);
                }
            }
        }
    }

    fn cancelDescriptor(self: *Core, entry: QueueEntry) void {
        const descriptor_index = entryIndex(entry);
        const entry_gen = entryGen(entry);
        const descriptor = &self.descriptors[descriptor_index];
        // Stale-entry filter (matches runTask): entry predates current
        // generation → silently drop without decrementing.
        if (@as(u32, @truncate(descriptor.generation)) != entry_gen) {
            return;
        }
        // Gate with the same state CAS pattern runTask uses. A duplicate
        // index emitted by a queue path will find state != .queued (already
        // cancelled, running, completed, or free) and silently return.
        // Only the first valid cancellation decrements queued_tasks.
        if (descriptor.state.cmpxchgStrong(.queued, .cancelled, .acq_rel, .acquire)) |_| {
            return;
        }
        self.decrementQueued(descriptor.options.lane);
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

        // Wake one blocked submitter per lane (if any) now that a descriptor
        // is available. Fast-path: skip the mutex entirely when no submitter
        // is blocked on that lane — the common uncontended case. Descriptors
        // are pool-wide, so either lane's waiter can benefit from a release;
        // waking one per lane avoids missed-signal deadlocks without a
        // broadcast thundering-herd.
        if (self.sync.default_backpressure_waiters.load(.monotonic) > 0) {
            self.sync.default_backpressure_mutex.lock();
            self.sync.default_backpressure_cond.signal();
            self.sync.default_backpressure_mutex.unlock();
        }
        if (self.sync.blocking_backpressure_waiters.load(.monotonic) > 0) {
            self.sync.blocking_backpressure_mutex.lock();
            self.sync.blocking_backpressure_cond.signal();
            self.sync.blocking_backpressure_mutex.unlock();
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
        for (self.local_queues) |*lq| {
            self.recordOwnedFree(lq.capacity() * @sizeOf(u32));
            lq.deinit();
        }
        if (self.submitter_queues.len > 0) {
            for (self.submitter_queues) |*sq| {
                sq.deinit();
            }
            self.recordOwnedFree(self.submitter_queues.len * @sizeOf(LocalQueue));
            self.allocator.free(self.submitter_queues);
        }
        self.inject_queue.deinit();
        if (self.blocking_inject) |*bi| {
            self.recordOwnedFree(bi.capacity() * @sizeOf(u32));
            bi.deinit();
            self.blocking_inject = null;
        }
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

    fn decrementQueued(self: *Core, lane: types.TaskLane) void {
        const counter = self.queuedTasksCounter(lane);
        _ = counter.fetchSub(1, .release);
    }

    /// Returns a pointer to the `queued_tasks` counter for the given lane.
    /// Lane-specific counters exist to avoid a livelock in the park
    /// handshake: a default worker's SC load of its lane's counter must
    /// not see blocking-lane submits, else it unparks spuriously on
    /// cross-lane work and spin-loops.
    inline fn queuedTasksCounter(self: *Core, lane: types.TaskLane) *std.atomic.Value(u64) {
        return switch (lane) {
            .default => &self.counters.queued_tasks,
            .blocking => &self.counters.queued_tasks_blocking,
        };
    }

    /// Sum of queued tasks across both lanes — for shutdown drain, stats
    /// snapshots, and deinit timeout diagnostics. Not used by the park
    /// handshake (which is per-lane for the reason above).
    inline fn totalQueuedTasks(self: *const Core) u64 {
        return self.counters.queued_tasks.load(.acquire) +
            self.counters.queued_tasks_blocking.load(.acquire);
    }

    /// Bitmask of workers serving `lane`. Bits [0..blocking_workers) are
    /// blocking workers; bits [blocking_workers..max_threads) are default.
    /// When `blocking_workers == 0`, all valid worker bits are in `.default`.
    /// Used to restrict steal-scan and wake-scan to same-lane workers.
    inline fn laneMask(self: *const Core, lane: types.TaskLane) u64 {
        const nb = self.config.blocking_workers;
        if (nb == 0) return switch (lane) {
            .default => ~@as(u64, 0),
            .blocking => 0,
        };
        const blocking_mask: u64 = (@as(u64, 1) << @intCast(nb)) - 1;
        return switch (lane) {
            .blocking => blocking_mask,
            .default => ~blocking_mask,
        };
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

    pub fn registerSubmitter(self: *ThreadPool) !usize {
        return self.core.registerSubmitter();
    }

    pub fn releaseSubmitter(self: *ThreadPool, idx: usize) void {
        self.core.releaseSubmitter(idx);
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
    /// `error.PoolBusy` unless the pool is quiescent
    /// (`active_tasks == 0 && queued_tasks == 0`), since purging during
    /// execution or with queued work remaining would corrupt scratch
    /// allocator ownership.
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
