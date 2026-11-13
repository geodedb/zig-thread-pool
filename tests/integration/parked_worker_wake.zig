//! SONNY-6479 regression: work queued while a worker is parked must wake
//! that worker instead of waiting out its `idle_park_after_ns` timer.
//!
//! Three paths left a parked worker asleep:
//!   1. `enqueueTask` scanned for a parked worker only on every
//!      `wake_coalesce_batch`-th submit (default 32). The skipped submits
//!      relied on workers seeing queued work before they park, which a
//!      worker that is already parked cannot do.
//!   2. A default-lane submit scanned only default-lane workers, and a
//!      parking blocking worker checked only the blocking lane's queue,
//!      although an idle blocking worker helps the default lane.
//!   3. `submitBatch` woke one worker per batch.
//!
//! Waking the blocking worker for default-lane work exposed a fourth: a
//! worker helping another lane pulled a batch of that lane's tasks into its
//! own local queue, where the lane's workers cannot steal them
//! (`laneMask`), so they waited for the helper's current task to finish.
//!
//! Every test parks the pool's workers on a 500 ms timer and bounds task
//! start latency at 50 ms: a task that waited for a timer is unmistakable,
//! and a woken worker starts in well under a millisecond.

const std = @import("std");
const thread_pool = @import("thread_pool");
const common = @import("../common.zig");

const park_ns: u64 = 500 * std.time.ns_per_ms;
const start_bound_ns: u64 = 50 * std.time.ns_per_ms;
const wait_limit_ns: u64 = 10 * std.time.ns_per_s;

fn nowNs() u64 {
    return @intCast(thread_pool.clock.nanoTimestamp());
}

/// Tasks of one round. Each records when it started and, if `hold`,
/// keeps its worker busy until `release`.
const Round = struct {
    hold: bool,
    started: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    release: std.atomic.Value(bool) = .init(false),
    last_start_ns: std.atomic.Value(u64) = .init(0),
    /// Bit `i` set once a task of this round ran on worker `i`.
    ran_on: std.atomic.Value(u64) = .init(0),
};

fn roundTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    const r: *Round = @ptrCast(@alignCast(raw_ctx));
    _ = r.last_start_ns.fetchMax(nowNs(), .acq_rel);
    _ = r.ran_on.fetchOr(@as(u64, 1) << @intCast(runtime.worker_index), .acq_rel);
    _ = r.started.fetchAdd(1, .acq_rel);
    if (r.hold) {
        const deadline = nowNs() + wait_limit_ns;
        while (!r.release.load(.acquire) and nowNs() < deadline) {
            thread_pool.clock.sleep(100 * std.time.ns_per_us);
        }
    }
    _ = r.finished.fetchAdd(1, .acq_rel);
}

fn waitAtLeast(counter: *const std.atomic.Value(u32), want: u32) !void {
    if (!waitAtLeastFor(counter, want, wait_limit_ns)) return error.Timeout;
}

fn waitAtLeastFor(counter: *const std.atomic.Value(u32), want: u32, limit_ns: u64) bool {
    const deadline = nowNs() + limit_ns;
    while (counter.load(.acquire) < want) {
        if (nowNs() >= deadline) return false;
        thread_pool.clock.sleep(50 * std.time.ns_per_us);
    }
    return true;
}

/// Wait until every worker has entered its park section: `parks` counts
/// entries and `wakeups` exits, so `parks == wakeups + 1` means the worker
/// is inside `idle` and found no work. The short settle that follows lets
/// it reach `timedWait`; it only makes the unfixed failure deterministic,
/// the assertions hold whether or not a worker is fully asleep.
fn waitAllParked(pool: *thread_pool.ThreadPool, workers: usize) !void {
    const deadline = nowNs() + wait_limit_ns;
    while (true) {
        const stats = pool.statsSnapshot();
        var parked: usize = 0;
        for (stats.worker_stats[0..workers]) |ws| {
            if (ws.parks == ws.wakeups + 1) parked += 1;
        }
        if (parked == workers) break;
        if (nowNs() >= deadline) return error.Timeout;
        thread_pool.clock.sleep(100 * std.time.ns_per_us);
    }
    thread_pool.clock.sleep(2 * std.time.ns_per_ms);
}

const Submit = enum { one_by_one, batch };

/// One round: park every worker, submit `tasks` tasks, and return how long
/// after the submit started the last of them began running.
fn runRound(pool: *thread_pool.ThreadPool, workers: usize, tasks: u32, hold: bool, how: Submit) !u64 {
    try waitAllParked(pool, workers);
    var round: Round = .{ .hold = hold };
    var submitted: u32 = 0;
    // `round` lives on this stack frame: never return while a task of it
    // can still run.
    defer {
        round.release.store(true, .release);
        waitAtLeast(&round.finished, submitted) catch @panic("SONNY-6479 test: tasks did not finish");
    }
    var batch: [16]thread_pool.BatchTask = undefined;
    std.debug.assert(tasks <= batch.len);
    const submitted_at = nowNs();
    switch (how) {
        .one_by_one => for (0..tasks) |_| {
            _ = try pool.submit(roundTask, @ptrCast(&round), .{});
            submitted += 1;
        },
        .batch => {
            for (batch[0..tasks]) |*t| t.* = .{ .task_fn = roundTask, .ctx = @ptrCast(&round) };
            const result = try pool.submitBatch(batch[0..tasks], .{});
            submitted = @intCast(result.submitted);
            try std.testing.expectEqual(@as(usize, tasks), result.submitted);
        },
    }
    try waitAtLeast(&round.started, tasks);
    return round.last_start_ns.load(.acquire) -| submitted_at;
}

fn expectPrompt(name: []const u8, worst_ns: u64) !void {
    if (worst_ns >= start_bound_ns) {
        std.debug.print("{s}: a task started {d} ms late (bound {d} ms, park {d} ms)\n", .{
            name,
            worst_ns / std.time.ns_per_ms,
            start_bound_ns / std.time.ns_per_ms,
            park_ns / std.time.ns_per_ms,
        });
        return error.TaskWaitedForParkTimer;
    }
}

// Path 1: one task at a time into an idle pool with the default
// `wake_coalesce_batch`. Before the fix only the submits that landed on a
// multiple of 32 woke a worker.
fn idleSubmitStartsPromptly(variant: thread_pool.SchedulerVariant) !void {
    try common.skipIfSchedulerVariantIncompatible(variant);
    const workers: usize = 2;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = workers,
        .max_threads = workers,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = variant,
        .idle_park_after_ns = park_ns,
        .timestamp_mode = common.default_timestamp_mode,
    });
    defer pool.deinit();

    var worst: u64 = 0;
    for (0..16) |_| worst = @max(worst, try runRound(&pool, workers, 1, false, .one_by_one));
    try expectPrompt("idle submit", worst);
}

test "SONNY-6479: a task submitted to an idle pool wakes a parked worker (global_queue)" {
    try idleSubmitStartsPromptly(.global_queue);
}

test "SONNY-6479: a task submitted to an idle pool wakes a parked worker (work_stealing)" {
    try idleSubmitStartsPromptly(.work_stealing);
}

// Path 2: as many long tasks as workers, on the default lane, with one
// worker reserved for the blocking lane. The last task can only run on the
// blocking worker (`rebalanceLane`). `wake_coalesce_batch = 1` takes path 1
// out of the picture, as geode configures its pools.
fn blockingWorkerHelpsPromptly(variant: thread_pool.SchedulerVariant) !void {
    try common.skipIfSchedulerVariantIncompatible(variant);
    const workers: usize = 8;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = workers,
        .max_threads = workers,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = variant,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .wake_coalesce_batch = 1,
        .idle_park_after_ns = park_ns,
        .timestamp_mode = common.default_timestamp_mode,
    });
    defer pool.deinit();

    var worst: u64 = 0;
    for (0..4) |_| worst = @max(worst, try runRound(&pool, workers, workers, true, .one_by_one));
    try expectPrompt("default lane with blocking helper", worst);
}

test "SONNY-6479: default-lane work wakes the parked blocking worker when no default worker is parked (global_queue)" {
    try blockingWorkerHelpsPromptly(.global_queue);
}

test "SONNY-6479: default-lane work wakes the parked blocking worker when no default worker is parked (work_stealing)" {
    try blockingWorkerHelpsPromptly(.work_stealing);
}

// Path 3: one `submitBatch` of as many long tasks as workers into an idle
// pool. Before the fix the batch woke one worker.
fn batchWakesEnoughWorkers(variant: thread_pool.SchedulerVariant) !void {
    try common.skipIfSchedulerVariantIncompatible(variant);
    const workers: usize = 4;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = workers,
        .max_threads = workers,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = variant,
        .idle_park_after_ns = park_ns,
        .timestamp_mode = common.default_timestamp_mode,
    });
    defer pool.deinit();

    var worst: u64 = 0;
    for (0..4) |_| worst = @max(worst, try runRound(&pool, workers, workers, true, .batch));
    try expectPrompt("submitBatch", worst);
}

test "SONNY-6479: submitBatch wakes one parked worker per task (global_queue)" {
    try batchWakesEnoughWorkers(.global_queue);
}

test "SONNY-6479: submitBatch wakes one parked worker per task (work_stealing)" {
    try batchWakesEnoughWorkers(.work_stealing);
}

// Path 2, second half. Every default worker is busy and the blocking worker
// is free, so a batch of default-lane tasks is picked up by the blocking
// worker. When the default workers become free they must find the rest of
// the batch. Before the fix the blocking worker pulled the whole batch into
// its own local queue, which default workers never steal from, so the rest
// waited for the blocking worker's current task.
fn helperLeavesWorkStealable(variant: thread_pool.SchedulerVariant) !void {
    try common.skipIfSchedulerVariantIncompatible(variant);
    const workers: usize = 8;
    const default_workers: u32 = workers - 1;
    const default_mask: u64 = ((@as(u64, 1) << workers) - 1) & ~@as(u64, 1);
    const later_tasks: u32 = 4;
    var pool = try thread_pool.ThreadPool.init(std.testing.allocator, .{
        .min_threads = workers,
        .max_threads = workers,
        .queue_capacity = 64,
        .local_queue_capacity = 32,
        .scheduler_variant = variant,
        .allow_blocking_lane = true,
        .blocking_workers = 1,
        .wake_coalesce_batch = 1,
        .idle_park_after_ns = park_ns,
        .timestamp_mode = common.default_timestamp_mode,
    });
    defer pool.deinit();

    var rounds: usize = 0;
    var attempts: usize = 0;
    while (rounds < 3) : (attempts += 1) {
        if (attempts >= 20) return error.CouldNotOccupyDefaultWorkers;
        try waitAllParked(&pool, workers);
        var busy: Round = .{ .hold = true };
        var later: Round = .{ .hold = true };
        var busy_n: u32 = 0;
        var later_n: u32 = 0;
        defer {
            busy.release.store(true, .release);
            later.release.store(true, .release);
            waitAtLeast(&busy.finished, busy_n) catch @panic("SONNY-6479 test: tasks did not finish");
            waitAtLeast(&later.finished, later_n) catch @panic("SONNY-6479 test: tasks did not finish");
        }

        for (0..default_workers) |_| {
            _ = try pool.submit(roundTask, @ptrCast(&busy), .{});
            busy_n += 1;
        }
        try waitAtLeast(&busy.started, default_workers);
        // The scenario needs the blocking worker free. If it took one of the
        // busy tasks instead of a default worker, set the round up again.
        if (busy.ran_on.load(.acquire) != default_mask) continue;

        var batch: [later_tasks]thread_pool.BatchTask = undefined;
        for (&batch) |*t| t.* = .{ .task_fn = roundTask, .ctx = @ptrCast(&later) };
        later_n = @intCast((try pool.submitBatch(&batch, .{})).submitted);
        try std.testing.expectEqual(later_tasks, later_n);
        try waitAtLeast(&later.started, 1);
        try std.testing.expectEqual(@as(u64, 1), later.ran_on.load(.acquire));

        const freed_at = nowNs();
        busy.release.store(true, .release);
        const all_started = waitAtLeastFor(&later.started, later_tasks, 4 * park_ns);
        const waited = if (all_started) later.last_start_ns.load(.acquire) -| freed_at else 4 * park_ns;
        try expectPrompt("tasks left behind by the blocking worker", waited);
        rounds += 1;
    }
}

test "SONNY-6479: default-lane tasks the blocking worker picked up stay stealable by default workers (global_queue)" {
    try helperLeavesWorkStealable(.global_queue);
}

test "SONNY-6479: default-lane tasks the blocking worker picked up stay stealable by default workers (work_stealing)" {
    try helperLeavesWorkStealable(.work_stealing);
}
