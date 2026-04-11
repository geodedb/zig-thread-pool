const std = @import("std");
const types = @import("types.zig");
const BoundedRing = @import("queue/bounded_ring.zig").BoundedRing;
const WorkDeque = @import("queue/work_deque.zig").WorkDeque;
const WorkerScratch = @import("memory/scratch.zig").WorkerScratch;
const Accounting = @import("memory/scratch.zig").Accounting;
const LatencyHistogram = @import("stats/latency.zig").LatencyHistogram;
const process_memory = @import("stats/process_memory.zig");

threadlocal var tls_worker_index: ?usize = null;

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

pub const TaskFn = *const fn (ctx: *anyopaque, runtime: *TaskContext) void;

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
    state: types.TaskState = .free,
    task_fn: ?TaskFn = null,
    ctx: ?*anyopaque = null,
    options: types.SubmitOptions = .{},
    submit_ns: u64 = 0,
    start_ns: u64 = 0,
    complete_ns: u64 = 0,
};

const Worker = struct {
    thread: ?std.Thread = null,
    local_queue: WorkDeque(u32),
    scratch: WorkerScratch,
    busy_ns: u64 = 0,
    idle_ns: u64 = 0,
    local_queue_peak: u32 = 0,
    parks: u64 = 0,
    wakeups: u64 = 0,
    steals: u64 = 0,
    steal_failures: u64 = 0,
    last_idle_started_ns: u64 = 0,
};

const Core = struct {
    allocator: std.mem.Allocator,
    config: types.Config,
    state: std.atomic.Value(PoolState) = std.atomic.Value(PoolState).init(.running),
    workers: []Worker,
    descriptors: []TaskDescriptor,
    free_indices: []u32,
    free_top: usize,
    free_mutex: std.Thread.Mutex = .{},
    inject_queue: BoundedRing(u32),
    completion_mutex: std.Thread.Mutex = .{},
    completion_cond: std.Thread.Condition = .{},
    wait_histogram: LatencyHistogram = .{},
    exec_histogram: LatencyHistogram = .{},
    latency_mutex: std.Thread.Mutex = .{},
    worker_stats_buffer: []types.WorkerStats,
    submit_round_robin: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queued_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    active_tasks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    parked_workers: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    submitted: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    started: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    completed: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    cancelled: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    steals: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    steal_failures: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    wakeups: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    parks: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    queue_depth_peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    task_desc_live: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    task_desc_peak: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_alloc_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_free_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    live_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    peak_live_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn init(self: *Core, allocator: std.mem.Allocator, config: types.Config) !void {
        var normalized = config.normalized();
        try normalized.validate();

        self.* = .{
            .allocator = allocator,
            .config = normalized,
            .workers = try allocator.alloc(Worker, normalized.max_threads),
            .descriptors = try allocator.alloc(TaskDescriptor, normalized.queue_capacity),
            .free_indices = try allocator.alloc(u32, normalized.queue_capacity),
            .free_top = normalized.queue_capacity,
            .inject_queue = try BoundedRing(u32).init(allocator, normalized.queue_capacity),
            .worker_stats_buffer = try allocator.alloc(types.WorkerStats, normalized.max_threads),
        };
        errdefer self.deinitOwned();

        self.recordOwnedAlloc(self.workers.len * @sizeOf(Worker));
        self.recordOwnedAlloc(self.descriptors.len * @sizeOf(TaskDescriptor));
        self.recordOwnedAlloc(self.free_indices.len * @sizeOf(u32));
        self.recordOwnedAlloc(self.worker_stats_buffer.len * @sizeOf(types.WorkerStats));
        self.recordOwnedAlloc(self.inject_queue.capacity() * @sizeOf(u32));

        for (self.descriptors, 0..) |*descriptor, idx| {
            descriptor.* = .{};
            self.free_indices[idx] = @as(u32, @intCast(idx));
        }

        const accounting = Accounting{
            .total_alloc_bytes = &self.total_alloc_bytes,
            .total_free_bytes = &self.total_free_bytes,
            .live_bytes = &self.live_bytes,
            .peak_live_bytes = &self.peak_live_bytes,
        };

        for (self.workers) |*worker| {
            worker.* = .{
                .local_queue = try WorkDeque(u32).init(allocator, normalized.local_queue_capacity),
                .scratch = WorkerScratch.init(allocator, accounting, normalized.worker_scratch_cap_bytes),
                .last_idle_started_ns = nowNs(),
            };
            self.recordOwnedAlloc(worker.local_queue.capacity() * @sizeOf(u32));
        }

        for (self.workers, 0..) |*worker, idx| {
            worker.thread = try std.Thread.spawn(.{}, workerMain, .{ self, idx });
        }
    }

    pub fn deinit(self: *Core) void {
        self.shutdown(.drain, null) catch {};
        self.deinitOwned();
    }

    pub fn trySubmit(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.submitInternal(task_fn, ctx, options, false);
    }

    pub fn submit(self: *Core, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.submitInternal(task_fn, ctx, options, true);
    }

    pub fn submitBatch(self: *Core, tasks: []const BatchTask, options: types.SubmitOptions) !void {
        for (tasks) |task| {
            _ = try self.submit(task.task_fn, task.ctx, options);
        }
    }

    pub fn wait(self: *Core, handle: types.TaskHandle) !void {
        if (!handle.isValid()) return error.InvalidHandle;
        if (handle.index >= self.descriptors.len) return error.InvalidHandle;

        self.completion_mutex.lock();
        defer self.completion_mutex.unlock();

        while (true) {
            const descriptor = &self.descriptors[handle.index];
            if (descriptor.generation != handle.generation) return error.InvalidHandle;
            switch (descriptor.state) {
                .completed, .cancelled => {
                    self.releaseDescriptor(handle.index);
                    return;
                },
                .free => return error.InvalidHandle,
                else => self.completion_cond.wait(&self.completion_mutex),
            }
        }
    }

    pub fn waitGroup(self: *Core) types.WaitGroup {
        _ = self;
        return .{};
    }

    pub fn shutdown(self: *Core, mode: types.ShutdownMode, timeout_ns: ?u64) !void {
        const old_state = self.state.swap(.shutdown_requested, .acq_rel);
        if (old_state == .stopped) return;

        if (mode == .cancel_pending) {
            try self.cancelQueuedTasks();
        }

        const deadline = if (timeout_ns) |ns| nowNs() + ns else 0;
        while (true) {
            const queued = self.queued_tasks.load(.acquire);
            const active = self.active_tasks.load(.acquire);
            if (queued == 0 and active == 0) break;
            if (deadline != 0 and nowNs() >= deadline) return error.Timeout;
            std.Thread.sleep(100_000);
        }

        self.state.store(.stopping, .release);
        for (self.workers) |*worker| {
            if (worker.thread) |thread| {
                thread.join();
                worker.thread = null;
            }
        }
        self.state.store(.stopped, .release);
    }

    pub fn statsSnapshot(self: *Core) types.Stats {
        for (self.workers, 0..) |*worker, idx| {
            self.worker_stats_buffer[idx] = .{
                .worker_index = idx,
                .busy_ns = worker.busy_ns,
                .idle_ns = worker.idle_ns,
                .local_queue_depth = @as(u32, @intCast(worker.local_queue.len())),
                .local_queue_peak = worker.local_queue_peak,
                .parks = worker.parks,
                .wakeups = worker.wakeups,
                .steals = worker.steals,
                .steal_failures = worker.steal_failures,
                .scratch_current_bytes = @as(u64, @intCast(worker.scratch.bytesCurrent())),
                .scratch_peak_bytes = @as(u64, @intCast(worker.scratch.bytesPeak())),
            };
        }

        const memory = process_memory.sample() catch types.ProcessMemoryStats{};

        self.latency_mutex.lock();
        defer self.latency_mutex.unlock();

        return .{
            .submitted = self.submitted.load(.acquire),
            .started = self.started.load(.acquire),
            .completed = self.completed.load(.acquire),
            .cancelled = self.cancelled.load(.acquire),
            .active_workers = self.active_tasks.load(.acquire),
            .parked_workers = self.parked_workers.load(.acquire),
            .retired_workers = 0,
            .queue_depth_current = self.queued_tasks.load(.acquire),
            .queue_depth_peak = self.queue_depth_peak.load(.acquire),
            .steals = self.steals.load(.acquire),
            .steal_failures = self.steal_failures.load(.acquire),
            .wakeups = self.wakeups.load(.acquire),
            .parks = self.parks.load(.acquire),
            .task_desc_live = self.task_desc_live.load(.acquire),
            .task_desc_peak = self.task_desc_peak.load(.acquire),
            .total_alloc_bytes = self.total_alloc_bytes.load(.acquire),
            .total_free_bytes = self.total_free_bytes.load(.acquire),
            .live_bytes = self.live_bytes.load(.acquire),
            .peak_live_bytes = self.peak_live_bytes.load(.acquire),
            .task_wait_ns = self.wait_histogram.summary(),
            .task_exec_ns = self.exec_histogram.summary(),
            .memory = memory,
            .worker_stats = self.worker_stats_buffer,
        };
    }

    pub fn purgeWorkerCaches(self: *Core) !void {
        if (self.active_tasks.load(.acquire) != 0) return error.PoolBusy;
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
        descriptor.submit_ns = nowNs();
        descriptor.start_ns = 0;
        descriptor.complete_ns = 0;
        descriptor.state = .queued;

        var queued = false;
        if (self.config.scheduler_variant == .work_stealing and tls_worker_index != null) {
            const worker = &self.workers[tls_worker_index.?];
            queued = worker.local_queue.tryPushBottom(descriptor_index);
            if (queued) {
                worker.local_queue_peak = @max(worker.local_queue_peak, @as(u32, @intCast(worker.local_queue.len())));
            }
        }
        if (!queued) {
            queued = self.inject_queue.tryPush(descriptor_index);
        }
        if (!queued) {
            if (options.wait_group) |wait_group| wait_group.done();
            return error.QueueFull;
        }

        _ = self.submitted.fetchAdd(1, .monotonic);
        self.incrementQueued();
        _ = self.wakeups.fetchAdd(1, .monotonic);

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

        if (self.config.scheduler_variant == .work_stealing) {
            if (worker.local_queue.popBottom()) |descriptor_index| {
                self.decrementQueued();
                return descriptor_index;
            }

            if (self.inject_queue.pop()) |descriptor_index| {
                var moved: usize = 1;
                while (moved < self.config.inject_batch_size) : (moved += 1) {
                    if (worker.local_queue.len() >= worker.local_queue.capacity()) break;
                    const extra = self.inject_queue.pop() orelse break;
                    if (!worker.local_queue.tryPushBottom(extra)) {
                        _ = self.inject_queue.tryPush(extra);
                        break;
                    }
                    worker.local_queue_peak = @max(worker.local_queue_peak, @as(u32, @intCast(worker.local_queue.len())));
                }
                self.decrementQueued();
                return descriptor_index;
            }

            const start = @as(usize, @intCast(self.submit_round_robin.fetchAdd(1, .monotonic) % self.workers.len));
            var offset: usize = 0;
            while (offset < self.workers.len) : (offset += 1) {
                const victim_index = (start + offset) % self.workers.len;
                if (victim_index == worker_index) continue;
                if (self.workers[victim_index].local_queue.stealTop()) |descriptor_index| {
                    self.decrementQueued();
                    _ = self.steals.fetchAdd(1, .monotonic);
                    worker.steals += 1;
                    return descriptor_index;
                }
            }

            _ = self.steal_failures.fetchAdd(1, .monotonic);
            worker.steal_failures += 1;
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
        descriptor.state = .running;
        descriptor.start_ns = nowNs();

        const wait_ns = descriptor.start_ns - descriptor.submit_ns;
        self.latency_mutex.lock();
        self.wait_histogram.observe(wait_ns);
        self.latency_mutex.unlock();

        _ = self.started.fetchAdd(1, .monotonic);
        _ = self.active_tasks.fetchAdd(1, .monotonic);

        const run_started_ns = descriptor.start_ns;
        const idle_started_ns = worker.last_idle_started_ns;
        if (idle_started_ns != 0 and run_started_ns >= idle_started_ns) {
            worker.idle_ns += run_started_ns - idle_started_ns;
        }

        var runtime = TaskContext{
            .worker_index = worker_index,
            .cancellation_token = descriptor.options.cancellation_token,
            .scratch = &worker.scratch,
            .lane = descriptor.options.lane,
        };

        if (!(descriptor.options.cancellation_token != null and descriptor.options.cancellation_token.?.isCancelled())) {
            worker.scratch.beginTask() catch {};
            descriptor.task_fn.?(descriptor.ctx.?, &runtime);
            worker.scratch.finishTask();
        } else {
            descriptor.state = .cancelled;
            _ = self.cancelled.fetchAdd(1, .monotonic);
        }

        descriptor.complete_ns = nowNs();
        const exec_ns = descriptor.complete_ns - run_started_ns;
        worker.busy_ns += exec_ns;
        worker.last_idle_started_ns = descriptor.complete_ns;

        self.latency_mutex.lock();
        self.exec_histogram.observe(exec_ns);
        self.latency_mutex.unlock();

        _ = self.active_tasks.fetchSub(1, .monotonic);
        if (descriptor.state != .cancelled) {
            descriptor.state = .completed;
            _ = self.completed.fetchAdd(1, .monotonic);
        }

        if (descriptor.options.wait_group) |wait_group| {
            wait_group.done();
        }

        self.completion_mutex.lock();
        self.completion_cond.broadcast();
        self.completion_mutex.unlock();

        if (!descriptor.options.waitable) {
            self.releaseDescriptor(descriptor_index);
        }
    }

    fn idle(self: *Core, worker_index: usize) void {
        var worker = &self.workers[worker_index];
        var spins: usize = 0;
        while (spins < self.config.spin_before_park_iters) : (spins += 1) {
            if (self.queued_tasks.load(.acquire) != 0) return;
            std.atomic.spinLoopHint();
        }

        _ = self.parks.fetchAdd(1, .monotonic);
        _ = self.parked_workers.fetchAdd(1, .monotonic);
        worker.parks += 1;
        std.Thread.sleep(self.config.idle_park_after_ns);
        _ = self.parked_workers.fetchSub(1, .monotonic);
        worker.wakeups += 1;

        if (self.config.worker_scratch_cap_bytes != 0 and self.config.idle_purge_after_ns != 0) {
            const now = nowNs();
            if (now - worker.last_idle_started_ns >= self.config.idle_purge_after_ns) {
                worker.scratch.purge();
            }
        }
    }

    fn shouldExit(self: *Core) bool {
        const state = self.state.load(.acquire);
        if (state == .running) return false;
        return self.queued_tasks.load(.acquire) == 0 and self.active_tasks.load(.acquire) == 0;
    }

    fn cancelQueuedTasks(self: *Core) !void {
        while (self.inject_queue.pop()) |descriptor_index| {
            self.decrementQueued();
            self.cancelDescriptor(descriptor_index);
        }
        if (self.config.scheduler_variant == .work_stealing) {
            for (self.workers) |*worker| {
                while (worker.local_queue.popBottom()) |descriptor_index| {
                    self.decrementQueued();
                    self.cancelDescriptor(descriptor_index);
                }
            }
        }
    }

    fn cancelDescriptor(self: *Core, descriptor_index: u32) void {
        const descriptor = &self.descriptors[descriptor_index];
        descriptor.state = .cancelled;
        _ = self.cancelled.fetchAdd(1, .monotonic);
        if (descriptor.options.wait_group) |wait_group| wait_group.done();
        self.completion_mutex.lock();
        self.completion_cond.broadcast();
        self.completion_mutex.unlock();
        if (!descriptor.options.waitable) self.releaseDescriptor(descriptor_index);
    }

    fn acquireDescriptor(self: *Core) ?u32 {
        self.free_mutex.lock();
        defer self.free_mutex.unlock();
        if (self.free_top == 0) return null;
        self.free_top -= 1;
        const descriptor_index = self.free_indices[self.free_top];
        var descriptor = &self.descriptors[descriptor_index];
        const prev_generation = descriptor.generation;
        descriptor.* = .{};
        descriptor.generation = prev_generation +% 1;
        if (descriptor.generation == 0) descriptor.generation = 1;
        descriptor.state = .reserved;
        const live = self.task_desc_live.fetchAdd(1, .monotonic) + 1;
        updatePeak(&self.task_desc_peak, live);
        return descriptor_index;
    }

    fn releaseDescriptor(self: *Core, descriptor_index: u32) void {
        self.free_mutex.lock();
        defer self.free_mutex.unlock();
        var descriptor = &self.descriptors[descriptor_index];
        descriptor.task_fn = null;
        descriptor.ctx = null;
        descriptor.options = .{};
        descriptor.submit_ns = 0;
        descriptor.start_ns = 0;
        descriptor.complete_ns = 0;
        descriptor.state = .free;
        self.free_indices[self.free_top] = descriptor_index;
        self.free_top += 1;
        _ = self.task_desc_live.fetchSub(1, .monotonic);
    }

    fn recordOwnedAlloc(self: *Core, bytes: usize) void {
        const accounting = Accounting{
            .total_alloc_bytes = &self.total_alloc_bytes,
            .total_free_bytes = &self.total_free_bytes,
            .live_bytes = &self.live_bytes,
            .peak_live_bytes = &self.peak_live_bytes,
        };
        accounting.recordAlloc(bytes);
    }

    fn recordOwnedFree(self: *Core, bytes: usize) void {
        const accounting = Accounting{
            .total_alloc_bytes = &self.total_alloc_bytes,
            .total_free_bytes = &self.total_free_bytes,
            .live_bytes = &self.live_bytes,
            .peak_live_bytes = &self.peak_live_bytes,
        };
        accounting.recordFree(bytes);
    }

    fn deinitOwned(self: *Core) void {
        for (self.workers) |*worker| {
            worker.scratch.purge();
            self.recordOwnedFree(worker.local_queue.capacity() * @sizeOf(u32));
            worker.local_queue.deinit();
        }
        self.inject_queue.deinit();
        self.recordOwnedFree(self.worker_stats_buffer.len * @sizeOf(types.WorkerStats));
        self.allocator.free(self.worker_stats_buffer);
        self.recordOwnedFree(self.free_indices.len * @sizeOf(u32));
        self.allocator.free(self.free_indices);
        self.recordOwnedFree(self.descriptors.len * @sizeOf(TaskDescriptor));
        self.allocator.free(self.descriptors);
        self.recordOwnedFree(self.workers.len * @sizeOf(Worker));
        self.allocator.free(self.workers);
    }

    fn incrementQueued(self: *Core) void {
        const queue_depth = self.queued_tasks.fetchAdd(1, .monotonic) + 1;
        updatePeak(&self.queue_depth_peak, queue_depth);
    }

    fn decrementQueued(self: *Core) void {
        var current = self.queued_tasks.load(.monotonic);
        while (current != 0) {
            const previous = self.queued_tasks.cmpxchgWeak(current, current - 1, .monotonic, .monotonic);
            if (previous == null) return;
            current = previous.?;
        }
    }
};

pub const ThreadPool = struct {
    core: *Core,

    pub fn init(allocator: std.mem.Allocator, config: types.Config) !ThreadPool {
        const core = try allocator.create(Core);
        errdefer allocator.destroy(core);
        try core.init(allocator, config);
        return .{ .core = core };
    }

    pub fn deinit(self: *ThreadPool) void {
        const allocator = self.core.allocator;
        self.core.deinit();
        allocator.destroy(self.core);
        self.* = undefined;
    }

    pub fn trySubmit(self: *ThreadPool, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.core.trySubmit(task_fn, ctx, options);
    }

    pub fn submit(self: *ThreadPool, task_fn: TaskFn, ctx: *anyopaque, options: types.SubmitOptions) !types.TaskHandle {
        return self.core.submit(task_fn, ctx, options);
    }

    pub fn submitBatch(self: *ThreadPool, tasks: []const BatchTask, options: types.SubmitOptions) !void {
        return self.core.submitBatch(tasks, options);
    }

    pub fn wait(self: *ThreadPool, handle: types.TaskHandle) !void {
        return self.core.wait(handle);
    }

    pub fn waitGroup(self: *ThreadPool) types.WaitGroup {
        return self.core.waitGroup();
    }

    pub fn shutdown(self: *ThreadPool, mode: types.ShutdownMode, timeout_ns: ?u64) !void {
        return self.core.shutdown(mode, timeout_ns);
    }

    pub fn statsSnapshot(self: *ThreadPool) types.Stats {
        return self.core.statsSnapshot();
    }

    pub fn purgeWorkerCaches(self: *ThreadPool) !void {
        return self.core.purgeWorkerCaches();
    }
};

fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}

fn updatePeak(counter: *std.atomic.Value(u64), value: u64) void {
    var current = counter.load(.monotonic);
    while (value > current) {
        const previous = counter.cmpxchgWeak(current, value, .monotonic, .monotonic);
        if (previous == null) return;
        current = previous.?;
    }
}
