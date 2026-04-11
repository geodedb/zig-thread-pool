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

const HANDLE = ?*anyopaque;
const BOOL = i32;
const DWORD = u32;
const SIZE_T = usize;

const PROCESS_MEMORY_COUNTERS_EX = extern struct {
    cb: DWORD,
    PageFaultCount: DWORD,
    PeakWorkingSetSize: SIZE_T,
    WorkingSetSize: SIZE_T,
    QuotaPeakPagedPoolUsage: SIZE_T,
    QuotaPagedPoolUsage: SIZE_T,
    QuotaPeakNonPagedPoolUsage: SIZE_T,
    QuotaNonPagedPoolUsage: SIZE_T,
    PagefileUsage: SIZE_T,
    PeakPagefileUsage: SIZE_T,
    PrivateUsage: SIZE_T,
};

extern fn GetCurrentProcess() HANDLE;
extern fn GetProcessMemoryInfo(process: HANDLE, counters: *PROCESS_MEMORY_COUNTERS_EX, cb: DWORD) BOOL;

pub fn sample() !types.ProcessMemoryStats {
    return switch (builtin.os.tag) {
        .linux => try sampleLinux(),
        .macos => try sampleMacos(),
        .windows => try sampleWindows(),
        else => .{},
    };
}

fn sampleLinux() !types.ProcessMemoryStats {
    var file = try std.fs.openFileAbsolute("/proc/self/status", .{});
    defer file.close();

    var buffer: [16 * 1024]u8 = undefined;
    const len = try file.readAll(&buffer);
    const contents = buffer[0..len];

    return .{
        .rss_current_bytes = parseProcStatusKiB(contents, "VmRSS:") * 1024,
        .rss_peak_bytes = parseProcStatusKiB(contents, "VmHWM:") * 1024,
        .private_current_bytes = parseProcStatusKiB(contents, "RssAnon:") * 1024,
        .private_peak_bytes = parseProcStatusKiB(contents, "RssAnon:") * 1024,
    };
}

fn parseProcStatusKiB(contents: []const u8, prefix: []const u8) u64 {
    var it = std.mem.tokenizeScalar(u8, contents, '\n');
    while (it.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        var field_it = std.mem.tokenizeAny(u8, line[prefix.len..], " \t");
        while (field_it.next()) |field| {
            return std.fmt.parseInt(u64, field, 10) catch 0;
        }
    }
    return 0;
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
    var counters = std.mem.zeroes(PROCESS_MEMORY_COUNTERS_EX);
    counters.cb = @sizeOf(PROCESS_MEMORY_COUNTERS_EX);
    if (GetProcessMemoryInfo(GetCurrentProcess(), &counters, counters.cb) == 0) {
        return error.ProcessMemoryUnavailable;
    }

    return .{
        .rss_current_bytes = @as(u64, @intCast(counters.WorkingSetSize)),
        .rss_peak_bytes = @as(u64, @intCast(counters.PeakWorkingSetSize)),
        .private_current_bytes = @as(u64, @intCast(counters.PrivateUsage)),
        .private_peak_bytes = @as(u64, @intCast(counters.PeakPagefileUsage)),
    };
}
