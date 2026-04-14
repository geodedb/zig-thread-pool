// SPDX-License-Identifier: Apache-2.0
//! Tokio rt_multi_threaded parity benchmarks.
//! Scenarios mirror Tokio's published benchmark suite so numbers here are
//! directly comparable to Tokio's output on the same hardware.
//!
//! Reference: https://github.com/tokio-rs/tokio/blob/master/benches/rt_multi_threaded.rs
//!
//! NOTE: We intentionally start with the two scenarios that map to the
//! biggest gaps identified in the audit (pure throughput, multi-producer
//! contention).  The yield-heavy and chained-spawn variants from Tokio's
//! suite require a continuation/callback feature this pool doesn't expose
//! today; they can be added when nested-submit gets a first-class API.
const std = @import("std");
const thread_pool = @import("thread_pool");

const flood_count: usize = 1_000_000;
const contended_count: usize = 100_000;
const contended_submitters: usize = 8;

const NoopCtx = struct {
    marker: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

fn noopTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *NoopCtx = @ptrCast(@alignCast(raw_ctx));
    _ = ctx.marker.fetchAdd(1, .monotonic);
}

// === Scenario: flood_1m ===
// Single submitter pushes 1M trivial tasks. Measures pure throughput.
fn benchFlood(out_writer: anytype) !void {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 0, // CPU count
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    const start = std.time.nanoTimestamp();
    for (0..flood_count) |_| {
        _ = try pool.submit(noopTask, @ptrCast(&ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
    wg.wait();
    const end = std.time.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const ops_per_sec = @as(f64, @floatFromInt(flood_count)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(buf[0..], "tokio_parity scenario=flood_1m tasks={d} elapsed_ns={d} ops_per_sec={d:.0}\n", .{ flood_count, elapsed_ns, ops_per_sec });
    try out_writer.writeAll(line);
}

// === Scenario: flood_1m_batched ===
// Single submitter pushes 1M trivial tasks through submitBatch with batch
// size 64. Amortizes per-task submitter atomics (counters.submitted,
// queued_tasks seq_cst fetchAdd, parked-worker wake scan) identified by
// the 2026-04-14 ceiling A/B as the flood_1m bottleneck.
const flood_batch_size: usize = 64;

fn benchFloodBatched(out_writer: anytype) !void {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 0,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    var batch: [flood_batch_size]thread_pool.BatchTask = undefined;
    for (&batch) |*b| {
        b.* = .{ .task_fn = noopTask, .ctx = @ptrCast(&ctx) };
    }

    const start = std.time.nanoTimestamp();
    var submitted_total: usize = 0;
    while (submitted_total < flood_count) {
        const remaining = flood_count - submitted_total;
        const this_batch = @min(remaining, flood_batch_size);
        const result = try pool.submitBatch(batch[0..this_batch], .{
            .wait_group = &wg,
            .backpressure = .block,
        });
        submitted_total += result.submitted;
    }
    wg.wait();
    const end = std.time.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const ops_per_sec = @as(f64, @floatFromInt(flood_count)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(buf[0..], "tokio_parity scenario=flood_1m_batched tasks={d} batch={d} elapsed_ns={d} ops_per_sec={d:.0}\n", .{ flood_count, flood_batch_size, elapsed_ns, ops_per_sec });
    try out_writer.writeAll(line);
}

// === Scenario: contended_spawn_8x ===
// 8 submitter threads each push 100k/8 tasks concurrently.  Targets the
// producer_contention bottleneck identified in the audit.
const ContendedSubmitterCtx = struct {
    pool: *thread_pool.ThreadPool,
    wg: *thread_pool.WaitGroup,
    marker: *NoopCtx,
    count: usize,
};

fn contendedSubmitterThread(ctx: *ContendedSubmitterCtx) void {
    for (0..ctx.count) |_| {
        _ = ctx.pool.submit(noopTask, @ptrCast(ctx.marker), .{
            .wait_group = ctx.wg,
            .backpressure = .block,
        }) catch return;
    }
}

fn benchContended(out_writer: anytype) !void {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .max_threads = 0,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    const per_submitter = contended_count / contended_submitters;

    var threads: [contended_submitters]std.Thread = undefined;
    var submitter_ctxs: [contended_submitters]ContendedSubmitterCtx = undefined;

    const start = std.time.nanoTimestamp();
    for (0..contended_submitters) |i| {
        submitter_ctxs[i] = .{
            .pool = &pool,
            .wg = &wg,
            .marker = &ctx,
            .count = per_submitter,
        };
        threads[i] = try std.Thread.spawn(.{}, contendedSubmitterThread, .{&submitter_ctxs[i]});
    }
    for (&threads) |*t| t.join();
    wg.wait();
    const end = std.time.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);
    const total_tasks = per_submitter * contended_submitters;
    const ops_per_sec = @as(f64, @floatFromInt(total_tasks)) / (@as(f64, @floatFromInt(elapsed_ns)) / 1e9);

    var buf: [256]u8 = undefined;
    const line = try std.fmt.bufPrint(buf[0..], "tokio_parity scenario=contended_spawn_8x tasks={d} submitters={d} elapsed_ns={d} ops_per_sec={d:.0}\n", .{ total_tasks, contended_submitters, elapsed_ns, ops_per_sec });
    try out_writer.writeAll(line);
}

pub fn main() !void {
    const stdout = std.fs.File.stdout();

    try benchFlood(stdout);
    try benchFloodBatched(stdout);
    try benchContended(stdout);
}
