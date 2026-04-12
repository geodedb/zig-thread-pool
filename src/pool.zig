const std = @import("std");
const types = @import("types.zig");
const BoundedRing = @import("queue/bounded_ring.zig").BoundedRing;
const WorkDeque = @import("queue/work_deque.zig").WorkDeque;
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

const TaskDescriptor = struct {
    generation: u64 = 0,
    state: std.atomic.Value(types.TaskState) = std.atomic.Value(types.TaskState).init(.free),
    task_fn: ?TaskFn = null,
    ctx: ?*anyopaque = null,
    options: types.SubmitOptions = .{},
    submit_ns: u64 = 0,
    start_ns: u64 = 0,
    complete_ns: u64 = 0,
};

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
    last_idle_started_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    scratch_init_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

/// Synchronization primitives for task completion and worker parking.
const Sync = struct {
    completion_mutex: std.Thread.Mutex = .{},
    completion_cond: std.Thread.Condition = .{},
    park_mutex: std.Thread.Mutex = .{},
    park_cond: std.Thread.Condition = .{},
};

/// Atomic counters tracking pool-wide task and worker events.
/// Fields are grouped by access pattern with cache-line padding
/// between groups to reduce false sharing between submit and worker paths.
const Counters = struct {
    const cache_line_size = std.atomic.cache_line;
    const field_size = @sizeOf(std.atomic.Value(u64));

    // === Hot write group (submit path) ===
    queued_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    submitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad0: [cache_line_size - 2 * field_size]u8 = undefined,

    // === Hot write group (worker path) ===
    active_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    started: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cancelled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    _pad1: [cache_line_size - 4 * field_size]u8 = undefined,

    // === Diagnostic/cold counters ===
    parked_workers: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    steals: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    steal_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    wakeups: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    parks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queue_depth_peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    task_desc_live: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    task_desc_peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_alloc_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_free_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_alloc_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    live_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak_live_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const Core = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    accounting: Accounting = undefined,
    state: std.atomic.Value(PoolState) = std.atomic.Value(PoolState).init(.running),
    workers: []Worker,
    local_queues: []WorkDeque(u32),
    descriptors: []TaskDescriptor,
    free_indices: []u32,
    free_top_tagged: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    inject_queue: BoundedRing(u32),
    sync: Sync = .{},
    counters: Counters = .{},
    worker_stats_buffer: []types.WorkerStats,

    pub fn init(self: *Core, allocator: std.mem.Allocator, config: types.Config) !void {
        var normalized = config.normalized();
        try normalized.validate();

        self.* = .{
            .allocator = allocator,
            .config = normalized,
            .workers = try allocator.alloc(Worker, normalized.max_threads),
            .local_queues = try allocator.alloc(WorkDeque(u32), normalized.max_threads),
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
        self.recordOwnedAlloc(self.local_queues.len * @sizeOf(WorkDeque(u32)));
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

        for (self.workers, self.local_queues) |*worker, *lq| {
            lq.* = try WorkDeque(u32).init(allocator, normalized.local_queue_capacity);
            worker.* = .{
                .scratch = WorkerScratch.init(allocator, self.accounting, normalized.worker_scratch_cap_bytes),
                .last_idle_started_ns = std.atomic.Value(u64).init(nowNs()),
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
            std.Thread.sleep(100_000);
        }

        self.joinAllWorkers();
    }

    fn joinAllWorkers(self: *Core) void {
        // Signal all workers to exit
        self.state.store(.stopping, .release);
        self.sync.park_mutex.lock();
        self.sync.park_cond.broadcast();
        self.sync.park_mutex.unlock();

        // Join all threads
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
        }
        self.state.store(.stopped, .release);
    }

    pub fn statsSnapshot(self: *Core) types.Stats {
        var aggregate_wakeups: u64 = 0;
        for (self.workers, 0..) |*worker, idx| {
            const w_wakeups = worker.wakeups.load(.acquire);
            aggregate_wakeups += w_wakeups;
            self.worker_stats_buffer[idx] = .{
                .worker_index = idx,
                .busy_ns = worker.busy_ns.load(.acquire),
                .idle_ns = worker.idle_ns.load(.acquire),
                .local_queue_depth = @as(u32, @intCast(self.local_queues[idx].len())),
                .local_queue_peak = worker.local_queue_peak.load(.acquire),
                .parks = worker.parks.load(.acquire),
                .wakeups = w_wakeups,
                .steals = worker.steals.load(.acquire),
                .steal_failures = worker.steal_failures.load(.acquire),
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
            .started = self.counters.started.load(.acquire),
            .completed = self.counters.completed.load(.acquire),
            .cancelled = self.counters.cancelled.load(.acquire),
            .active_tasks = self.counters.active_tasks.load(.acquire),
            .parked_workers = self.counters.parked_workers.load(.acquire),
            .queue_depth_current = self.counters.queued_tasks.load(.acquire),
            .queue_depth_peak = self.counters.queue_depth_peak.load(.acquire),
            .steals = self.counters.steals.load(.acquire),
            .steal_failures = self.counters.steal_failures.load(.acquire),
            .wakeups = aggregate_wakeups,
            .parks = self.counters.parks.load(.acquire),
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
                    std.Thread.sleep(50_000);
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
            queued = self.local_queues[wi].tryPushBottom(descriptor_index);
            if (queued) {
                const local_len = @as(u32, @intCast(self.local_queues[wi].len()));
                updatePeakU32(&self.workers[wi].local_queue_peak, local_len);
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

        if (self.counters.parked_workers.load(.monotonic) > 0) {
            self.sync.park_mutex.lock();
            self.sync.park_cond.signal();
            self.sync.park_mutex.unlock();
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

        if (self.config.scheduler_variant == .work_stealing) {
            if (lq.popBottom()) |descriptor_index| {
                self.decrementQueued();
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
                self.decrementQueued();
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
                if (self.local_queues[victim_index].stealTop()) |descriptor_index| {
                    self.decrementQueued();
                    _ = self.counters.steals.fetchAdd(1, .monotonic);
                    _ = worker.steals.fetchAdd(1, .release);
                    return descriptor_index;
                }
            }

            _ = self.counters.steal_failures.fetchAdd(1, .monotonic);
            _ = worker.steal_failures.fetchAdd(1, .release);
            return null;
        }

        if (self.inject_queue.pop()) |descriptor_index| {
            self.decrementQueued();
            return descriptor_index;
        }
        return null;
    }

    fn runTask(self: *Core, worker_index: usize, descriptor_index: u32) void {
        var worker = &self.workers[worker_index];
        var descriptor = &self.descriptors[descriptor_index];
        descriptor.state.store(.running, .release);
        const timestamps_enabled = self.config.timestamp_mode == .full;
        const start_ns = if (timestamps_enabled) nowNs() else 0;
        descriptor.start_ns = start_ns;

        if (timestamps_enabled) {
            const wait_ns = start_ns - descriptor.submit_ns;
            worker.wait_histogram.observe(wait_ns);
        }

        _ = self.counters.started.fetchAdd(1, .monotonic);
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
            _ = self.counters.completed.fetchAdd(1, .monotonic);
        }

        if (descriptor.options.wait_group) |wait_group| {
            wait_group.done();
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
        var spins: usize = 0;
        while (spins < self.config.spin_before_park_iters) : (spins += 1) {
            if (self.counters.queued_tasks.load(.acquire) != 0) return;
            if (self.state.load(.acquire) != .running) return;
            std.atomic.spinLoopHint();
        }

        if (self.state.load(.acquire) != .running) return;

        _ = self.counters.parks.fetchAdd(1, .monotonic);
        _ = worker.parks.fetchAdd(1, .release);

        self.sync.park_mutex.lock();
        _ = self.counters.parked_workers.fetchAdd(1, .monotonic);
        if (self.counters.queued_tasks.load(.acquire) != 0 or self.state.load(.acquire) != .running) {
            _ = self.counters.parked_workers.fetchSub(1, .monotonic);
            self.sync.park_mutex.unlock();
            _ = worker.wakeups.fetchAdd(1, .release);
            return;
        }
        self.sync.park_cond.timedWait(&self.sync.park_mutex, self.config.idle_park_after_ns) catch {};
        _ = self.counters.parked_workers.fetchSub(1, .monotonic);
        self.sync.park_mutex.unlock();
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
        while (self.inject_queue.pop()) |descriptor_index| {
            self.decrementQueued();
            self.cancelDescriptor(descriptor_index);
        }
        if (self.config.scheduler_variant == .work_stealing) {
            for (self.local_queues) |*lq| {
                while (lq.stealTop()) |descriptor_index| {
                    self.decrementQueued();
                    self.cancelDescriptor(descriptor_index);
                }
            }
        }
    }

    fn cancelDescriptor(self: *Core, descriptor_index: u32) void {
        const descriptor = &self.descriptors[descriptor_index];
        descriptor.state.store(.cancelled, .release);
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
            return;
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
        self.inject_queue.deinit();
        self.recordOwnedFree(self.worker_stats_buffer.len * @sizeOf(types.WorkerStats));
        self.allocator.free(self.worker_stats_buffer);
        self.recordOwnedFree(self.free_indices.len * @sizeOf(u32));
        self.allocator.free(self.free_indices);
        self.recordOwnedFree(self.descriptors.len * @sizeOf(TaskDescriptor));
        self.allocator.free(self.descriptors);
        self.recordOwnedFree(self.local_queues.len * @sizeOf(WorkDeque(u32)));
        self.allocator.free(self.local_queues);
        self.recordOwnedFree(self.workers.len * @sizeOf(Worker));
        self.allocator.free(self.workers);
    }

    fn incrementQueued(self: *Core) void {
        const queue_depth = self.counters.queued_tasks.fetchAdd(1, .release) +% 1;
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
