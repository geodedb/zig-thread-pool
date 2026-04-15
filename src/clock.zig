//! Clock wrappers that preserve the zero-arg API of 0.15.2
//! (`std.time.nanoTimestamp`, `std.Thread.sleep`) on top of 0.16.0 primitives.
//!
//! `nanoTimestamp` uses `std.Io.Clock.Timestamp.now` on the static
//! `global_single_threaded` Io (the `now` vtable fn ignores `userdata`).
//!
//! `sleep` uses `std.posix.nanosleep` on POSIX and `kernel32.Sleep` on
//! Windows. Both are uncancelable and do not require any async state.

const std = @import("std");
const builtin = @import("builtin");

pub fn nanoTimestamp() i96 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds;
}

pub fn sleep(nanoseconds: u64) void {
    if (builtin.os.tag == .windows) {
        const ms: u32 = @intCast(@min(nanoseconds / std.time.ns_per_ms, @as(u64, std.math.maxInt(u32))));
        std.os.windows.kernel32.Sleep(ms);
        return;
    }

    const ns_per_s = std.time.ns_per_s;
    const sec: u64 = nanoseconds / ns_per_s;
    const nsec: u64 = nanoseconds % ns_per_s;
    var req: std.posix.timespec = .{
        .sec = @intCast(sec),
        .nsec = @intCast(nsec),
    };
    var rem: std.posix.timespec = undefined;
    while (true) {
        const rc = std.posix.system.nanosleep(&req, &rem);
        const err = std.posix.errno(rc);
        switch (err) {
            .SUCCESS => return,
            .INTR => {
                req = rem;
                continue;
            },
            else => return,
        }
    }
}
