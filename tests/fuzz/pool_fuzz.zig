//! Random-interleave fuzz harness for the public ThreadPool API.
//!
//! Usage:
//!   zig build fuzz                          # default 100 iterations, seed 0xC0FFEE
//!   FUZZ_SEED=1 FUZZ_ITERATIONS=5000 zig build fuzz
//!   FUZZ_SCHEDULER=lane_extension zig build fuzz   # pin the scheduler variant
//!
//! Scheduler variant selection (GAP-0055, #104):
//!   - Derived from the seed: seed % 3 -> global_queue / work_stealing /
//!     lane_extension, so rotating FUZZ_SEED rotates variants.
//!   - FUZZ_SCHEDULER overrides the derivation ("global_queue",
//!     "work_stealing", or "lane_extension").
//!   - A -Dscheduler-variant comptime pin overrides both (the pool would
//!     reject any other variant with error.BuildOptionMismatch).
//!
//! Invariants checked after each iteration (post-shutdown):
//!   - stats.submitted == stats.completed + stats.cancelled
//!     (the pool accounts for every submitted task)
//!   - stats.task_desc_live == 0
//!     (no leaked task descriptors post-shutdown)
//!   - DebugAllocator reports no leaks
//!   - shutdown completes within 5 seconds (infinite-drain catch)
//!
//! Coverage gaps noted:
//!   - submitter_free_mask (fully-set = no leaked submitter slots) is
//!     private to Core and not exposed by statsSnapshot(). We verify
//!     releaseSubmitter is called for every registerSubmitter we issued,
//!     but cannot read the mask directly from the public API.
//!
//! Historical bug, now fixed (GAP-0056, #105):
//!   Early versions of this harness hard-coded work_stealing because the
//!   default global_queue scheduler stranded submitter-slot tasks in
//!   submitter_queues[] (tryDrainLaneForWorker never consumes them when
//!   !uses_local), hanging shutdown(.drain, null). Commit 141d979 gated
//!   the submit-side submitter-queue push on `uses_local`, making
//!   registerSubmitter a functional no-op under global_queue — submits
//!   fall through to the inject queue. global_queue therefore now runs
//!   with the full op table, submitter ops included; the drain behavior
//!   is pinned by "global_queue + registered submitter drains on
//!   shutdown" in tests/integration.zig. The 5-second shutdown timeout
//!   stays as the regression detector.

const std = @import("std");
const thread_pool = @import("thread_pool");

/// Shutdown timeout: 5 seconds. If a pool takes longer than this to drain,
/// the harness treats it as an invariant failure rather than hanging forever.
const shutdown_timeout_ns: u64 = 5_000_000_000;

const OpKind = enum(u8) {
    submit,
    try_submit,
    register,
    release,
    shutdown_drain,
    shutdown_cancel,
    // SEC-018 / F-008: concurrent double-wait on a waitable handle.  The
    // op spawns a pair of threads that each call `pool.wait(handle)` on
    // the same handle.  Pre-fix, this could double-release the descriptor
    // slot; post-fix, the release is CAS-guarded.  The invariant under
    // test here is simply "no crash, no allocator leak" — the per-iter
    // invariant block at the bottom of `runOne` catches both.
    double_wait,
    // GAP-0055 (#104): caller-side WaitGroup add/done/wait round-trip.
    // Acquires `pool.waitGroup()`, adds 1, submits a task whose body
    // calls `wg.done()` through ctx, then blocks in `wg.wait()` until
    // the worker's done() broadcast releases it.  Regression coverage
    // for 39528a3 (done() now holds the condition mutex before
    // publishing pending==0, closing the stack-lifetime race against
    // a returning waiter).
    wait_group,
};

fn noop(ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = ctx;
    _ = runtime;
}

/// Task body for the `wait_group` op: signals the caller-owned WaitGroup.
/// The caller blocks in `wg.wait()` inside the same op, so the WaitGroup
/// outlives the task (the wait does not return until this done() runs).
fn wgDoneTask(ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const wg: *thread_pool.WaitGroup = @ptrCast(@alignCast(ctx));
    wg.done();
}

fn envU64(init: std.process.Init.Minimal, gpa: std.mem.Allocator, key: []const u8, default: u64) u64 {
    const val = init.environ.getAlloc(gpa, key) catch return default;
    defer gpa.free(val);
    return std.fmt.parseInt(u64, val, 0) catch default;
}

fn envU32(init: std.process.Init.Minimal, gpa: std.mem.Allocator, key: []const u8, default: u32) u32 {
    const val = init.environ.getAlloc(gpa, key) catch return default;
    defer gpa.free(val);
    return std.fmt.parseInt(u32, val, 10) catch default;
}

/// GAP-0055 (#104): parse FUZZ_SCHEDULER. Unknown values are reported and
/// ignored (fall back to seed-derived selection) rather than failing the
/// run, matching the lenient envU64/envU32 parsers above.
fn envVariant(init: std.process.Init.Minimal, gpa: std.mem.Allocator, key: []const u8) ?thread_pool.SchedulerVariant {
    const val = init.environ.getAlloc(gpa, key) catch return null;
    defer gpa.free(val);
    if (std.mem.eql(u8, val, "global_queue")) return .global_queue;
    if (std.mem.eql(u8, val, "work_stealing")) return .work_stealing;
    if (std.mem.eql(u8, val, "lane_extension")) return .lane_extension;
    std.debug.print(
        "fuzz: ignoring unknown {s}='{s}' (expected global_queue|work_stealing|lane_extension)\n",
        .{ key, val },
    );
    return null;
}

/// Pick the scheduler variant for this run: comptime pin > FUZZ_SCHEDULER >
/// seed % 3. A -Dscheduler-variant build pin must win, otherwise
/// ThreadPool.init rejects the config with error.BuildOptionMismatch.
fn pickVariant(init: std.process.Init.Minimal, seed: u64) thread_pool.SchedulerVariant {
    switch (thread_pool.build_options.scheduler_variant) {
        .global_queue => return .global_queue,
        .work_stealing => return .work_stealing,
        .lane_extension => return .lane_extension,
        .any => {},
    }
    if (envVariant(init, std.heap.page_allocator, "FUZZ_SCHEDULER")) |v| return v;
    return switch (seed % 3) {
        0 => .global_queue,
        1 => .work_stealing,
        else => .lane_extension,
    };
}

pub fn main(init: std.process.Init.Minimal) !u8 {
    const seed = envU64(init, std.heap.page_allocator, "FUZZ_SEED", 0xC0FFEE);
    const iterations = envU32(init, std.heap.page_allocator, "FUZZ_ITERATIONS", 100);
    const variant = pickVariant(init, seed);

    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();

    var i: u32 = 0;
    while (i < iterations) : (i += 1) {
        runOne(rng, variant) catch |err| {
            std.debug.print(
                "fuzz FAIL at iteration {d}, seed={d}, variant={s}: {s}\n",
                .{ i, seed, @tagName(variant), @errorName(err) },
            );
            return 1;
        };
    }

    std.debug.print(
        "fuzz ok: {d} iterations seed={d} variant={s}\n",
        .{ iterations, seed, @tagName(variant) },
    );
    return 0;
}

fn runOne(rng: std.Random, variant: thread_pool.SchedulerVariant) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    // DebugAllocator.deinit() returns CheckResult (.ok or .leak).
    // Defer the check; on leak we panic loudly after deinit.
    defer {
        const result = gpa_state.deinit();
        if (result == .leak) {
            std.debug.panic("fuzz: allocator reported a leak after pool.deinit()\n", .{});
        }
    }
    const gpa = gpa_state.allocator();

    // All three variants run the full op table, submitter ops included.
    // global_queue routes submitter-slot submits to the inject queue
    // (141d979; see the module-level comment), so nothing is stranded in
    // submitter_queues[] and shutdown(.drain) terminates on every variant.
    // lane_extension requires a valid blocking-lane config:
    // allow_blocking_lane = true and 0 < blocking_workers < max_threads
    // (types.zig Config.validate).
    const max_threads = rng.intRangeAtMost(usize, 2, 6);
    const want_submitter_queues: bool = rng.boolean();
    const max_submitter_queues: u32 = if (want_submitter_queues) rng.intRangeAtMost(u32, 1, 4) else 0;
    const lane_ext = variant == .lane_extension;

    var pool = try thread_pool.ThreadPool.init(gpa, .{
        .max_threads = max_threads,
        .queue_capacity = 128,
        .scheduler_variant = variant,
        .max_submitter_queues = max_submitter_queues,
        .submitter_queue_capacity = if (max_submitter_queues > 0) 64 else 0,
        .allow_blocking_lane = lane_ext,
        .blocking_workers = if (lane_ext) 1 else 0,
    });

    // Track whether we have an active registered submitter slot.
    // We only allow one at a time to keep state simple.
    var my_submitter: ?usize = null;
    var shut_down = false;

    const n_ops: u32 = rng.intRangeAtMost(u32, 32, 256);
    var op_i: u32 = 0;
    while (op_i < n_ops) : (op_i += 1) {
        if (shut_down) break;
        const kind = rng.enumValue(OpKind);
        switch (kind) {
            .submit => {
                _ = pool.submit(noop, @ptrCast(&pool), .{}) catch continue;
            },
            .try_submit => {
                _ = pool.trySubmit(noop, @ptrCast(&pool), .{}) catch continue;
            },
            .register => {
                // Only register if we don't already hold a slot and there
                // are submitter queue slots configured.
                if (my_submitter == null and max_submitter_queues > 0) {
                    my_submitter = pool.registerSubmitter() catch null;
                }
            },
            .release => {
                if (my_submitter) |idx| {
                    pool.releaseSubmitter(idx);
                    my_submitter = null;
                }
            },
            .shutdown_drain => {
                pool.shutdown(.drain, shutdown_timeout_ns) catch |e| {
                    if (e == error.Timeout) return error.FuzzShutdownDrainTimeout;
                };
                shut_down = true;
            },
            .shutdown_cancel => {
                pool.shutdown(.cancel_pending, shutdown_timeout_ns) catch |e| {
                    if (e == error.Timeout) return error.FuzzShutdownCancelTimeout;
                };
                shut_down = true;
            },
            .double_wait => {
                // SEC-018: submit a waitable handle then fire two threads
                // that race to wait on it.  Ignore submit errors (queue
                // full, shutdown in progress) — the op is best-effort.
                const handle = pool.submit(noop, @ptrCast(&pool), .{ .waitable = true }) catch continue;
                const DoubleWait = struct {
                    fn run(p: *thread_pool.ThreadPool, h: thread_pool.types.TaskHandle) void {
                        // Success and InvalidHandle are both acceptable;
                        // the invariant we care about is "no crash".
                        p.wait(h) catch {};
                    }
                };
                const t0 = std.Thread.spawn(.{}, DoubleWait.run, .{ &pool, handle }) catch continue;
                const t1 = std.Thread.spawn(.{}, DoubleWait.run, .{ &pool, handle }) catch {
                    t0.join();
                    continue;
                };
                t0.join();
                t1.join();
            },
            .wait_group => {
                // Caller-side add/done/wait round-trip (39528a3 regression
                // coverage). The wait is bounded in practice: the op runs
                // only while the pool is live (shutdown ops set shut_down
                // and break this loop), submit succeeded, and a queued task
                // on a live pool always executes; done() is then guaranteed.
                // The harness-level safety net is the 5s shutdown timeout
                // plus the CI job timeout. On submit failure we balance the
                // add ourselves so the WaitGroup returns to zero.
                var wg = pool.waitGroup();
                wg.add(1);
                if (pool.submit(wgDoneTask, @ptrCast(&wg), .{})) |_| {
                    wg.wait();
                } else |_| {
                    wg.done();
                }
            },
        }
    }

    // Always shut down before reading stats so the counts are stable.
    if (!shut_down) {
        pool.shutdown(.drain, shutdown_timeout_ns) catch |e| {
            if (e == error.Timeout) return error.FuzzShutdownDrainTimeout;
        };
    }

    // Release any held submitter slot before deinit.
    // Coverage gap: we verify our own bookkeeping is balanced, but
    // submitter_free_mask is private to Core and cannot be read via
    // statsSnapshot(). The DebugAllocator leak check below catches any
    // memory that the pool failed to free, which would also signal a
    // mask leak indirectly.
    if (my_submitter) |idx| {
        pool.releaseSubmitter(idx);
        my_submitter = null;
    }

    // --- Invariant checks ---
    const s = pool.statsSnapshot();

    // Invariant 1: every submitted task must be accounted for.
    // submitted == completed + cancelled (started tasks that were cancelled
    // mid-flight are counted in cancelled, not completed).
    if (s.submitted != s.completed + s.cancelled) {
        std.debug.print(
            "fuzz invariant FAIL: submitted={d} completed={d} cancelled={d} (completed+cancelled={d})\n",
            .{ s.submitted, s.completed, s.cancelled, s.completed + s.cancelled },
        );
        pool.deinit();
        return error.FuzzInvariantTaskAccountingFailed;
    }

    // Invariant 2: no task descriptors may be live after shutdown.
    if (s.task_desc_live != 0) {
        std.debug.print(
            "fuzz invariant FAIL: task_desc_live={d} after shutdown\n",
            .{s.task_desc_live},
        );
        pool.deinit();
        return error.FuzzInvariantLeakedDescriptors;
    }

    // Clean up.  DebugAllocator.deinit() in the defer above will catch
    // any allocator-level leaks from pool.deinit().
    pool.deinit();
}
