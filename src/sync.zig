//! Internal sync primitives that preserve the zero-arg API of 0.15.2
//! (`Mutex.lock/unlock`, `Condition.wait/signal/broadcast`, `Semaphore.wait/post`)
//! on top of 0.16.0's `std.Io`-based primitives.
//!
//! Implementation: call the `*Uncancelable` variants on a static
//! `std.Io.Threaded.global_single_threaded` instance. The futex vtable
//! functions in `std.Io.Threaded` ignore their `userdata` parameter for the
//! uncancelable path, so this is safe to call from any thread regardless of
//! whether it is registered with a `Threaded` runtime.

const std = @import("std");

inline fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub const Mutex = struct {
    inner: std.Io.Mutex = .init,

    pub fn lock(self: *Mutex) void {
        self.inner.lockUncancelable(io());
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock(io());
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};

pub const Condition = struct {
    inner: std.Io.Condition = .init,

    pub fn wait(self: *Condition, m: *Mutex) void {
        self.inner.waitUncancelable(io(), &m.inner);
    }

    pub fn signal(self: *Condition) void {
        self.inner.signal(io());
    }

    pub fn broadcast(self: *Condition) void {
        self.inner.broadcast(io());
    }
};

pub const Semaphore = struct {
    inner: std.Io.Semaphore = .{},

    pub fn wait(self: *Semaphore) void {
        self.inner.waitUncancelable(io());
    }

    pub fn post(self: *Semaphore) void {
        self.inner.post(io());
    }
};
