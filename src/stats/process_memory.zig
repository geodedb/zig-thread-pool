const std = @import("std");
const builtin = @import("builtin");
const types = @import("../types.zig");

const mach_port_t = c_uint;
const mach_msg_type_number_t = c_uint;
const kern_return_t = c_int;
const task_flavor_t = c_int;
const integer_t = c_int;

const time_value_t = extern struct {
    seconds: integer_t,
    microseconds: integer_t,
};

const mach_task_basic_info = extern struct {
    virtual_size: usize,
    resident_size: usize,
    resident_size_max: usize,
    user_time: time_value_t,
    system_time: time_value_t,
    policy: integer_t,
    suspend_count: integer_t,
};

const MACH_TASK_BASIC_INFO: task_flavor_t = 20;

extern fn mach_task_self() mach_port_t;
extern fn task_info(target_task: mach_port_t, flavor: task_flavor_t, task_info_out: [*]integer_t, task_info_out_cnt: *mach_msg_type_number_t) kern_return_t;

/// GAP-0031 (#17): the kernel exposes no high-water mark for anonymous RSS
/// (`RssAnon:` has no `VmHWM:` counterpart), so track the peak observed
/// across samples taken by this process. Process-wide by design — the
/// metric itself is process-scoped.
var private_peak_observed = std.atomic.Value(u64).init(0);

pub fn sample() !types.ProcessMemoryStats {
    return switch (builtin.os.tag) {
        .linux => try sampleLinux(),
        .macos => try sampleMacos(),
        .windows => try sampleWindows(),
        else => .{},
    };
}

fn sampleLinux() !types.ProcessMemoryStats {
    const posix = std.posix;
    const fd = try posix.openat(posix.AT.FDCWD, "/proc/self/status", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, 0);
    defer _ = std.os.linux.close(fd);

    var buffer: [16 * 1024]u8 = undefined;
    var total: usize = 0;
    while (total < buffer.len) {
        const n = try posix.read(fd, buffer[total..]);
        if (n == 0) break;
        total += n;
    }
    const contents = buffer[0..total];

    const private_current = parseProcStatusKiB(contents, "RssAnon:") * 1024;
    // RssAnon has no kernel high-water counterpart; report the peak observed
    // across samples taken by this process (GAP-0031, #17). CAS loop: on
    // success cmpxchgWeak returns null and `orelse` installs our value as
    // the loop-exit witness; on failure it returns the actual value and the
    // loop re-checks whether our sample still exceeds it.
    var peak = private_peak_observed.load(.monotonic);
    while (private_current > peak) {
        peak = private_peak_observed.cmpxchgWeak(peak, private_current, .monotonic, .monotonic) orelse private_current;
    }
    return .{
        .rss_current_bytes = parseProcStatusKiB(contents, "VmRSS:") * 1024,
        .rss_peak_bytes = parseProcStatusKiB(contents, "VmHWM:") * 1024,
        .private_current_bytes = private_current,
        .private_peak_bytes = peak,
    };
}

fn parseProcStatusKiB(contents: []const u8, prefix: []const u8) u64 {
    var it = std.mem.tokenizeScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var field_it = std.mem.tokenizeAny(u8, line[prefix.len..], " \t");
        while (field_it.next()) |field| {
            const kib = std.fmt.parseInt(u64, field, 10) catch return 0;
            // Cap so caller *1024 cannot overflow u64 (F-007).
            return @min(kib, std.math.maxInt(u64) / 1024);
        }
    }
    return 0;
}

test "F-007: parseProcStatusKiB clamps so callers can *1024 without overflow" {
    const big = "VmRSS:\t18446744073709551615 kB\n";
    const v = parseProcStatusKiB(big, "VmRSS:");
    // Caller multiplies by 1024; this must not overflow u64.
    _ = v *% 1024; // wrapping mul would catch a regression via assertion below
    try std.testing.expect(v <= std.math.maxInt(u64) / 1024);
}

test "GAP-0031: private_peak_bytes tracks the observed peak monotonically" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Drive RssAnon up with a touched 64 MiB anonymous mapping, sample while
    // it is live, then free it and sample again: the peak must not follow
    // the current value back down. Pre-fix it did — both fields read the
    // same RssAnon line.
    const len = 64 * 1024 * 1024;
    const buf = try std.heap.page_allocator.alloc(u8, len);
    var i: usize = 0;
    while (i < len) : (i += 4096) buf[i] = 1;

    const s1 = try sample();
    std.heap.page_allocator.free(buf);
    const s2 = try sample();

    // The sample just taken is folded into the observed peak before return.
    try std.testing.expect(s1.private_peak_bytes >= s1.private_current_bytes);
    try std.testing.expect(s2.private_peak_bytes >= s2.private_current_bytes);
    // Peak is monotone non-decreasing across samples even though the
    // current value dropped with the freed mapping.
    try std.testing.expect(s2.private_peak_bytes >= s1.private_peak_bytes);
}

fn sampleMacos() !types.ProcessMemoryStats {
    var info = std.mem.zeroes(mach_task_basic_info);
    var count: mach_msg_type_number_t = @sizeOf(mach_task_basic_info) / @sizeOf(integer_t);
    if (task_info(mach_task_self(), MACH_TASK_BASIC_INFO, @ptrCast(&info), &count) != 0) {
        return error.ProcessMemoryUnavailable;
    }

    return .{
        .rss_current_bytes = @as(u64, @intCast(info.resident_size)),
        .rss_peak_bytes = @as(u64, @intCast(info.resident_size_max)),
        .private_current_bytes = @as(u64, @intCast(info.resident_size)),
        .private_peak_bytes = @as(u64, @intCast(info.resident_size_max)),
    };
}

fn sampleWindows() !types.ProcessMemoryStats {
    // Zig 0.16 removed the GetProcessMemoryInfo wrapper from std.os.windows.
    // Keep Windows memory sampling unavailable until a psapi.dll extern is
    // added; callers already handle ProcessMemoryUnavailable gracefully.
    return error.ProcessMemoryUnavailable;
}
