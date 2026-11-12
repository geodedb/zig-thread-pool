//! ThreadSanitizer regression suite. `zig build test-tsan` always builds this
//! file with `sanitize_thread` and the LLVM backend, so a data race fails the
//! step even when `-Dtsan` is not passed.

comptime {
    _ = @import("tsan/local_queue_dispatch.zig");
    _ = @import("tsan/scratch_stats.zig");
    _ = @import("tsan/waitable_release.zig");
}
