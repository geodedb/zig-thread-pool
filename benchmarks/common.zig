const std = @import("std");
const builtin = @import("builtin");
const thread_pool = @import("thread_pool");

pub const ScenarioSpec = struct {
    name: []const u8,
    task_count: usize,
    worker_count: usize,
    submitter_count: usize,
    queue_capacity: usize,
    local_queue_capacity: usize,
    inject_batch_size: usize = 16,
    scratch_bytes: usize = 0,
    sleep_ns: u64 = 0,
    idle_gap_ns: u64 = 0,
    nested_children: usize = 0,
    lane: thread_pool.TaskLane = .default,
};

pub const ResultRow = struct {
    git_sha: []const u8,
    run_timestamp_unix_s: i64,
    zig_version: []const u8,
    os: []const u8,
    arch: []const u8,
    cpu: []const u8,
    scenario_name: []const u8,
    scheduler_variant: []const u8,
    worker_count: usize,
    submitter_count: usize,
    queue_capacity: usize,
    local_queue_capacity: usize,
    task_count: usize,
    throughput_ops_per_sec: f64,
    submit_latency_p50_ns: u64,
    submit_latency_p95_ns: u64,
    submit_latency_p99_ns: u64,
    completion_latency_p50_ns: u64,
    completion_latency_p95_ns: u64,
    completion_latency_p99_ns: u64,
    cpu_time_ns: u64,
    wall_time_ns: u64,
    alloc_count: u64,
    alloc_bytes: u64,
    live_bytes: u64,
    peak_live_bytes: u64,
    rss_current_bytes: u64,
    rss_peak_bytes: u64,
    rss_delta_after_warmup_bytes: i64,
    steals: u64,
    parks: u64,
    wakeups: u64,
    queue_peak: u64,
};

pub const ResultDocument = struct {
    generated_at_unix_s: i64,
    rows: []ResultRow,
};

const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

const BenchTaskCtx = struct {
    pool: ?*thread_pool.ThreadPool = null,
    wait_group: ?*thread_pool.WaitGroup = null,
    counter: *Counter,
    submitted_at_ns: *u64,
    completed_at_ns: *u64,
    scratch_bytes: usize,
    sleep_ns: u64,
    nested_children: usize = 0,
};

const SubmitterCtx = struct {
    pool: *thread_pool.ThreadPool,
    tasks: []BenchTaskCtx,
    submit_latencies_ns: []u64,
    wait_group: *thread_pool.WaitGroup,
    lane: thread_pool.TaskLane,
};

pub fn runScenarios(allocator: std.mem.Allocator, specs: []const ScenarioSpec, variants: []const thread_pool.SchedulerVariant, output_path: ?[]const u8) !void {
    var rows = std.ArrayList(ResultRow){};
    defer {
        for (rows.items) |row| {
            allocator.free(row.git_sha);
            allocator.free(row.cpu);
        }
        rows.deinit(allocator);
    }

    for (specs) |spec| {
        for (variants) |variant| {
            try rows.append(allocator, try runScenario(allocator, spec, variant));
        }
    }

    const document = ResultDocument{
        .generated_at_unix_s = std.time.timestamp(),
        .rows = try rows.toOwnedSlice(allocator),
    };
    defer allocator.free(document.rows);

    if (output_path) |path| {
        var file = try std.fs.cwd().createFile(path, .{ .truncate = true });
        defer file.close();
        const json = try std.json.Stringify.valueAlloc(allocator, document, .{ .whitespace = .indent_2 });
        defer allocator.free(json);
        try file.writeAll(json);
        try file.writeAll("\n");
    } else {
        const json = try std.json.Stringify.valueAlloc(allocator, document, .{ .whitespace = .indent_2 });
        defer allocator.free(json);
        try std.fs.File.stdout().writeAll(json);
        try std.fs.File.stdout().writeAll("\n");
    }
}

pub fn runScenario(allocator: std.mem.Allocator, spec: ScenarioSpec, variant: thread_pool.SchedulerVariant) !ResultRow {
    var pool = try thread_pool.ThreadPool.init(allocator, .{
        .min_threads = spec.worker_count,
        .max_threads = spec.worker_count,
        .queue_capacity = spec.queue_capacity,
        .local_queue_capacity = spec.local_queue_capacity,
        .inject_batch_size = spec.inject_batch_size,
        .worker_scratch_cap_bytes = @max(spec.scratch_bytes, 4096),
        .idle_park_after_ns = 100_000,
        .idle_purge_after_ns = 500_000,
        .scheduler_variant = variant,
        .allow_blocking_lane = spec.lane == .blocking,
    });
    defer pool.deinit();

    try warmup(&pool, @max(spec.task_count / 8, 32), spec.scratch_bytes);
    const warmup_memory = pool.statsSnapshot().memory;

    var counter = Counter{};
    var submitted_at_ns = try allocator.alloc(u64, spec.task_count);
    defer allocator.free(submitted_at_ns);
    var completed_at_ns = try allocator.alloc(u64, spec.task_count);
    defer allocator.free(completed_at_ns);
    @memset(completed_at_ns, 0);
    var submit_latencies_ns = try allocator.alloc(u64, spec.task_count);
    defer allocator.free(submit_latencies_ns);

    var tasks = try allocator.alloc(BenchTaskCtx, spec.task_count);
    defer allocator.free(tasks);
    for (tasks, 0..) |*task, idx| {
        task.* = .{
            .counter = &counter,
            .submitted_at_ns = &submitted_at_ns[idx],
            .completed_at_ns = &completed_at_ns[idx],
            .scratch_bytes = spec.scratch_bytes,
            .sleep_ns = spec.sleep_ns,
            .nested_children = spec.nested_children,
        };
    }

    const cpu_before = try processCpuTimeNs();
    const wall_start = nowNs();

    if (spec.idle_gap_ns != 0) {
        try submitRange(allocator, &pool, tasks[0 .. spec.task_count / 2], submit_latencies_ns[0 .. spec.task_count / 2], spec.submitter_count, spec.lane);
        std.Thread.sleep(spec.idle_gap_ns);
        try submitRange(allocator, &pool, tasks[spec.task_count / 2 ..], submit_latencies_ns[spec.task_count / 2 ..], spec.submitter_count, spec.lane);
        std.Thread.sleep(spec.idle_gap_ns);
    } else {
        try submitRange(allocator, &pool, tasks, submit_latencies_ns, spec.submitter_count, spec.lane);
    }

    const wall_end = nowNs();
    const cpu_after = try processCpuTimeNs();
    const stats = pool.statsSnapshot();

    const submit_latencies_copy = try allocator.dupe(u64, submit_latencies_ns);
    defer allocator.free(submit_latencies_copy);
    const completion_latencies = try allocator.alloc(u64, spec.task_count);
    defer allocator.free(completion_latencies);
    for (completion_latencies, 0..) |*latency, idx| {
        latency.* = completed_at_ns[idx] - submitted_at_ns[idx];
    }

    const submit_summary = summarizeLatencies(submit_latencies_copy);
    const completion_summary = summarizeLatencies(completion_latencies);

    const throughput = @as(f64, @floatFromInt(spec.task_count)) / (@as(f64, @floatFromInt(wall_end - wall_start)) / std.time.ns_per_s);
    const git_sha = try gitSha(allocator);
    const cpu_name = try allocator.dupe(u8, @tagName(builtin.cpu.arch));

    const cpu_time_ns = if (cpu_after > cpu_before) cpu_after - cpu_before else wall_end - wall_start;

    return .{
        .git_sha = git_sha,
        .run_timestamp_unix_s = std.time.timestamp(),
        .zig_version = builtin.zig_version_string,
        .os = @tagName(builtin.os.tag),
        .arch = @tagName(builtin.cpu.arch),
        .cpu = cpu_name,
        .scenario_name = spec.name,
        .scheduler_variant = @tagName(variant),
        .worker_count = spec.worker_count,
        .submitter_count = spec.submitter_count,
        .queue_capacity = spec.queue_capacity,
        .local_queue_capacity = spec.local_queue_capacity,
        .task_count = spec.task_count,
        .throughput_ops_per_sec = throughput,
        .submit_latency_p50_ns = submit_summary.p50_ns,
        .submit_latency_p95_ns = submit_summary.p95_ns,
        .submit_latency_p99_ns = submit_summary.p99_ns,
        .completion_latency_p50_ns = completion_summary.p50_ns,
        .completion_latency_p95_ns = completion_summary.p95_ns,
        .completion_latency_p99_ns = completion_summary.p99_ns,
        .cpu_time_ns = cpu_time_ns,
        .wall_time_ns = wall_end - wall_start,
        .alloc_count = 0,
        .alloc_bytes = stats.total_alloc_bytes,
        .live_bytes = stats.live_bytes,
        .peak_live_bytes = stats.peak_live_bytes,
        .rss_current_bytes = stats.memory.rss_current_bytes,
        .rss_peak_bytes = stats.memory.rss_peak_bytes,
        .rss_delta_after_warmup_bytes = @as(i64, @intCast(stats.memory.rss_current_bytes)) - @as(i64, @intCast(warmup_memory.rss_current_bytes)),
        .steals = stats.steals,
        .parks = stats.parks,
        .wakeups = stats.wakeups,
        .queue_peak = stats.queue_depth_peak,
    };
}

fn submitRange(allocator: std.mem.Allocator, pool: *thread_pool.ThreadPool, tasks: []BenchTaskCtx, submit_latencies_ns: []u64, submitter_count: usize, lane: thread_pool.TaskLane) !void {
    var wg = pool.waitGroup();
    if (submitter_count <= 1) {
        var i: usize = 0;
        while (i < tasks.len) : (i += 1) {
            const submit_started = nowNs();
            tasks[i].submitted_at_ns.* = submit_started;
            tasks[i].pool = pool;
            tasks[i].wait_group = &wg;
            if (tasks[i].nested_children == 0) {
                _ = try pool.submit(benchTask, @ptrCast(&tasks[i]), .{
                    .wait_group = &wg,
                    .backpressure = .block,
                    .timeout_ns = 5 * std.time.ns_per_s,
                    .lane = lane,
                });
            } else {
                _ = try pool.submit(nestedTask, @ptrCast(&tasks[i]), .{
                    .wait_group = &wg,
                    .backpressure = .block,
                    .timeout_ns = 5 * std.time.ns_per_s,
                    .lane = lane,
                });
            }
            submit_latencies_ns[i] = nowNs() - submit_started;
        }
        wg.wait();
        return;
    }

    const submitter_len = @min(submitter_count, tasks.len);
    const threads = try allocator.alloc(std.Thread, submitter_len);
    defer allocator.free(threads);
    const ctxs = try allocator.alloc(SubmitterCtx, submitter_len);
    defer allocator.free(ctxs);

    const base = tasks.len / submitter_len;
    const remainder = tasks.len % submitter_len;
    var offset: usize = 0;
    for (ctxs, 0..) |*ctx, idx| {
        const extra: usize = if (idx < remainder) 1 else 0;
        const count = base + extra;
        ctx.* = .{
            .pool = pool,
            .tasks = tasks[offset .. offset + count],
            .submit_latencies_ns = submit_latencies_ns[offset .. offset + count],
            .wait_group = &wg,
            .lane = lane,
        };
        offset += count;
    }
    for (threads, ctxs) |*thread, ctx| {
        thread.* = try std.Thread.spawn(.{}, submitterMain, .{ctx});
    }
    for (threads) |thread| thread.join();
    wg.wait();
}

fn submitterMain(ctx: SubmitterCtx) void {
    for (ctx.tasks, 0..) |*task, idx| {
        const submit_started = nowNs();
        task.submitted_at_ns.* = submit_started;
        task.pool = ctx.pool;
        task.wait_group = ctx.wait_group;
        if (task.nested_children == 0) {
            _ = ctx.pool.submit(benchTask, @ptrCast(task), .{
                .wait_group = ctx.wait_group,
                .backpressure = .block,
                .timeout_ns = 5 * std.time.ns_per_s,
                .lane = ctx.lane,
            }) catch return;
        } else {
            _ = ctx.pool.submit(nestedTask, @ptrCast(task), .{
                .wait_group = ctx.wait_group,
                .backpressure = .block,
                .timeout_ns = 5 * std.time.ns_per_s,
                .lane = ctx.lane,
            }) catch return;
        }
        ctx.submit_latencies_ns[idx] = nowNs() - submit_started;
    }
}

fn benchTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    const ctx: *BenchTaskCtx = @ptrCast(@alignCast(raw_ctx));
    if (ctx.scratch_bytes != 0) {
        _ = runtime.allocScratch(u8, ctx.scratch_bytes) catch {};
    }
    if (ctx.sleep_ns != 0) {
        std.Thread.sleep(ctx.sleep_ns);
    }
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
    ctx.completed_at_ns.* = nowNs();
}

fn nestedTask(raw_ctx: *anyopaque, runtime: *thread_pool.TaskContext) void {
    _ = runtime;
    const ctx: *BenchTaskCtx = @ptrCast(@alignCast(raw_ctx));
    _ = ctx.counter.value.fetchAdd(1, .monotonic);
    for (0..ctx.nested_children) |_| {
        _ = ctx.pool.?.submit(benchTask, @ptrCast(ctx), .{
            .wait_group = ctx.wait_group.?,
            .backpressure = .block,
            .timeout_ns = 5 * std.time.ns_per_s,
        }) catch return;
    }
    ctx.completed_at_ns.* = nowNs();
}

fn warmup(pool: *thread_pool.ThreadPool, task_count: usize, scratch_bytes: usize) !void {
    var counter = Counter{};
    var wg = pool.waitGroup();
    var submitted: u64 = 0;
    var completed: u64 = 0;
    var task = BenchTaskCtx{
        .counter = &counter,
        .submitted_at_ns = &submitted,
        .completed_at_ns = &completed,
        .scratch_bytes = scratch_bytes,
        .sleep_ns = 0,
    };
    for (0..task_count) |_| {
        submitted = nowNs();
        _ = try pool.submit(benchTask, @ptrCast(&task), .{
            .wait_group = &wg,
            .backpressure = .block,
            .timeout_ns = 5 * std.time.ns_per_s,
        });
    }
    wg.wait();
}

fn summarizeLatencies(values: []u64) thread_pool.LatencySummary {
    std.sort.heap(u64, values, {}, comptime std.sort.asc(u64));
    return .{
        .count = values.len,
        .min_ns = if (values.len == 0) 0 else values[0],
        .mean_ns = mean(values),
        .p50_ns = percentile(values, 50),
        .p95_ns = percentile(values, 95),
        .p99_ns = percentile(values, 99),
        .max_ns = if (values.len == 0) 0 else values[values.len - 1],
    };
}

fn mean(values: []const u64) u64 {
    if (values.len == 0) return 0;
    var total: u128 = 0;
    for (values) |value| total += value;
    return @as(u64, @intCast(total / values.len));
}

fn percentile(values: []const u64, pct: u8) u64 {
    if (values.len == 0) return 0;
    const idx = @min((values.len - 1) * pct / 100, values.len - 1);
    return values[idx];
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

fn processCpuTimeNs() !u64 {
    if (builtin.os.tag == .linux) {
        var file = try std.fs.openFileAbsolute("/proc/self/stat", .{});
        defer file.close();
        var buffer: [4096]u8 = undefined;
        const len = try file.readAll(&buffer);
        const contents = buffer[0..len];
        var it = std.mem.tokenizeScalar(u8, contents, ' ');
        var field_index: usize = 1;
        var utime_ticks: u64 = 0;
        var stime_ticks: u64 = 0;
        while (it.next()) |field| : (field_index += 1) {
            if (field_index == 14) utime_ticks = std.fmt.parseInt(u64, field, 10) catch 0;
            if (field_index == 15) {
                stime_ticks = std.fmt.parseInt(u64, field, 10) catch 0;
                break;
            }
        }
        return (utime_ticks + stime_ticks) * (std.time.ns_per_s / 100);
    }
    return nowNs();
}

fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}
