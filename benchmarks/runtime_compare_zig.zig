const std = @import("std");
const builtin = @import("builtin");
const thread_pool = @import("thread_pool");

const flood_task_count: usize = 1_000_000;
const contended_task_count: usize = 100_000;
const contended_submitters: usize = 8;

const Sample = struct {
    elapsed_ns: u64,
    ops_per_sec: f64,
};

const ScenarioRow = struct {
    scenario_name: []const u8,
    task_count: usize,
    submitter_count: usize,
    worker_count: usize,
    median_elapsed_ns: u64,
    median_ops_per_sec: f64,
    stddev_ops_per_sec: f64,
    sample_count: usize,
    warmup_discarded: usize,
    samples: []Sample,
};

const RuntimeDocument = struct {
    runtime_name: []const u8,
    runtime_version: []const u8,
    source_commit: []const u8,
    generated_at_unix_s: i64,
    host_os: []const u8,
    host_arch: []const u8,
    rows: []ScenarioRow,
};

const Args = struct {
    output_path: ?[]const u8 = null,
    runtime_version: []const u8 = builtin.zig_version_string,
    source_commit: ?[]const u8 = null,
    samples: usize = 7,
    warmup_discard: usize = 1,
};

const NoopCtx = struct {
    marker: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const ContendedSubmitterCtx = struct {
    pool: *thread_pool.ThreadPool,
    wg: *thread_pool.WaitGroup,
    marker: *NoopCtx,
    count: usize,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try parseArgs(allocator);
    if (args.warmup_discard >= args.samples) return error.InvalidArguments;

    const worker_count = @max(std.Thread.getCpuCount() catch 1, 1);
    const source_commit = args.source_commit orelse try gitSha(allocator);

    var rows = std.ArrayList(ScenarioRow){};
    defer rows.deinit(allocator);

    try rows.append(allocator, try measureScenario(
        allocator,
        "flood_1m",
        flood_task_count,
        1,
        worker_count,
        args.samples,
        args.warmup_discard,
        runFloodSample,
    ));
    try rows.append(allocator, try measureScenario(
        allocator,
        "contended_spawn_8x",
        contended_task_count,
        contended_submitters,
        worker_count,
        args.samples,
        args.warmup_discard,
        runContendedSample,
    ));

    const document = RuntimeDocument{
        .runtime_name = "zig_thread_pool",
        .runtime_version = args.runtime_version,
        .source_commit = source_commit,
        .generated_at_unix_s = std.time.timestamp(),
        .host_os = @tagName(builtin.os.tag),
        .host_arch = @tagName(builtin.cpu.arch),
        .rows = try rows.toOwnedSlice(allocator),
    };

    const json = try std.json.Stringify.valueAlloc(allocator, document, .{ .whitespace = .indent_2 });
    defer allocator.free(json);

    if (args.output_path) |path| {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        try file.writeAll(json);
        try file.writeAll("\n");
    } else {
        try std.fs.File.stdout().writeAll(json);
        try std.fs.File.stdout().writeAll("\n");
    }
}

fn parseArgs(allocator: std.mem.Allocator) !Args {
    var parsed = Args{};
    const argv = try std.process.argsAlloc(allocator);

    var idx: usize = 1;
    while (idx < argv.len) : (idx += 1) {
        const arg = argv[idx];
        if (std.mem.eql(u8, arg, "--output")) {
            idx += 1;
            if (idx >= argv.len) return error.InvalidArguments;
            parsed.output_path = argv[idx];
        } else if (std.mem.eql(u8, arg, "--samples")) {
            idx += 1;
            if (idx >= argv.len) return error.InvalidArguments;
            parsed.samples = try std.fmt.parseInt(usize, argv[idx], 10);
        } else if (std.mem.eql(u8, arg, "--warmup-discard")) {
            idx += 1;
            if (idx >= argv.len) return error.InvalidArguments;
            parsed.warmup_discard = try std.fmt.parseInt(usize, argv[idx], 10);
        } else if (std.mem.eql(u8, arg, "--runtime-version")) {
            idx += 1;
            if (idx >= argv.len) return error.InvalidArguments;
            parsed.runtime_version = argv[idx];
        } else if (std.mem.eql(u8, arg, "--source-commit")) {
            idx += 1;
            if (idx >= argv.len) return error.InvalidArguments;
            parsed.source_commit = argv[idx];
        } else {
            std.debug.print(
                "usage: runtime_compare_zig [--output <path>] [--samples <n>] [--warmup-discard <n>] [--runtime-version <s>] [--source-commit <sha>]\n",
                .{},
            );
            return error.InvalidArguments;
        }
    }

    return parsed;
}

fn measureScenario(
    allocator: std.mem.Allocator,
    scenario_name: []const u8,
    task_count: usize,
    submitter_count: usize,
    worker_count: usize,
    run_count: usize,
    warmup_discard: usize,
    run_once: *const fn (usize) anyerror!u64,
) !ScenarioRow {
    const retained_count = run_count - warmup_discard;
    var all_samples = try allocator.alloc(Sample, run_count);
    defer allocator.free(all_samples);

    for (all_samples) |*sample| {
        sample.* = try sampleOnce(task_count, worker_count, run_once);
    }

    const retained = try allocator.alloc(Sample, retained_count);
    errdefer allocator.free(retained);
    @memcpy(retained, all_samples[warmup_discard..]);

    std.sort.heap(Sample, retained, {}, struct {
        fn lessThan(_: void, lhs: Sample, rhs: Sample) bool {
            return lhs.ops_per_sec < rhs.ops_per_sec;
        }
    }.lessThan);

    const median = retained[retained_count / 2];
    var sum_sq: f64 = 0;
    for (retained) |sample| {
        const delta = sample.ops_per_sec - median.ops_per_sec;
        sum_sq += delta * delta;
    }
    const stddev = std.math.sqrt(sum_sq / @as(f64, @floatFromInt(retained_count)));

    std.debug.print(
        "zig_thread_pool {s} median_ops_per_sec={d:.0} stddev_ops_per_sec={d:.0} workers={d}\n",
        .{ scenario_name, median.ops_per_sec, stddev, worker_count },
    );

    return .{
        .scenario_name = scenario_name,
        .task_count = task_count,
        .submitter_count = submitter_count,
        .worker_count = worker_count,
        .median_elapsed_ns = median.elapsed_ns,
        .median_ops_per_sec = median.ops_per_sec,
        .stddev_ops_per_sec = stddev,
        .sample_count = retained_count,
        .warmup_discarded = warmup_discard,
        .samples = retained,
    };
}

fn sampleOnce(task_count: usize, worker_count: usize, run_once: *const fn (usize) anyerror!u64) !Sample {
    const elapsed_ns = try run_once(worker_count);
    const elapsed_s = @as(f64, @floatFromInt(elapsed_ns)) / 1e9;
    return .{
        .elapsed_ns = elapsed_ns,
        .ops_per_sec = @as(f64, @floatFromInt(task_count)) / elapsed_s,
    };
}

fn runFloodSample(worker_count: usize) !u64 {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    const start_ns = std.time.nanoTimestamp();
    for (0..flood_task_count) |_| {
        _ = try pool.submit(noopTask, @ptrCast(&ctx), .{
            .wait_group = &wg,
            .backpressure = .block,
        });
    }
    wg.wait();
    return elapsedNsSince(start_ns);
}

fn runContendedSample(worker_count: usize) !u64 {
    var pool = try thread_pool.ThreadPool.init(std.heap.smp_allocator, .{
        .min_threads = worker_count,
        .max_threads = worker_count,
        .queue_capacity = 4096,
        .local_queue_capacity = 256,
        .scheduler_variant = .work_stealing,
    });
    defer pool.deinit();

    var ctx = NoopCtx{};
    var wg = pool.waitGroup();
    const per_submitter = contended_task_count / contended_submitters;
    var threads: [contended_submitters]std.Thread = undefined;
    var submitters: [contended_submitters]ContendedSubmitterCtx = undefined;

    const start_ns = std.time.nanoTimestamp();
    for (0..contended_submitters) |idx| {
        submitters[idx] = .{
            .pool = &pool,
            .wg = &wg,
            .marker = &ctx,
            .count = per_submitter,
        };
        threads[idx] = try std.Thread.spawn(.{}, contendedSubmitterThread, .{&submitters[idx]});
    }
    for (&threads) |*thread| thread.join();
    wg.wait();
    return elapsedNsSince(start_ns);
}

fn contendedSubmitterThread(ctx: *ContendedSubmitterCtx) void {
    for (0..ctx.count) |_| {
        _ = ctx.pool.submit(noopTask, @ptrCast(ctx.marker), .{
            .wait_group = ctx.wg,
            .backpressure = .block,
        }) catch @panic("submit failed during contended benchmark");
    }
}

fn noopTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *NoopCtx = @ptrCast(@alignCast(raw_ctx));
    _ = ctx.marker.fetchAdd(1, .monotonic);
}

fn elapsedNsSince(start_ns: i128) u64 {
    const end_ns = std.time.nanoTimestamp();
    const delta = end_ns - start_ns;
    return if (delta <= 0) 0 else @as(u64, @intCast(delta));
}

fn gitSha(allocator: std.mem.Allocator) ![]const u8 {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "rev-parse", "HEAD" },
        .max_output_bytes = 128,
    }) catch return allocator.dupe(u8, "unknown");
    defer allocator.free(result.stderr);
    if (result.term.Exited != 0) {
        allocator.free(result.stdout);
        return allocator.dupe(u8, "unknown");
    }
    defer allocator.free(result.stdout);
    return allocator.dupe(u8, std.mem.trim(u8, result.stdout, " \r\n\t"));
}
