// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! `thread-pool` provides a bounded, reusable thread-pool for devnw/zig codebases.
//! The public surface intentionally stays small while the implementation offers
//! multiple scheduler variants behind the same API.

const std = @import("std");

/// Re-export the `build_options` module so downstream test harnesses can
/// inspect compile-time-pinned flags (`-Dtimestamp-mode`,
/// `-Dscheduler-variant`, `-Dsingle-pool`) and adapt their configs
/// accordingly.  See `tests/common.zig::default_timestamp_mode`.
///
/// `build_options.with_otel` still exists as a const `false` for
/// backwards source-compat; see `src/observability.zig` for the
/// 2026-04-30 cycle-break rationale.
pub const build_options = @import("build_options");

/// Observability seam. As of 2026-04-30 this is a permanent comptime
/// no-op stub — `observability.enabled` is hardcoded `false` and every
/// helper compiles away. Callers that need real telemetry should wrap
/// `ThreadPool.submit` directly at their layer (where they already have
/// otel + caller context). See `src/observability.zig` for the
/// rationale (otel ↔ thread-pool dep cycle).
pub const observability = @import("observability");

/// Placeholder for backwards source-compat with callers that referenced
/// `thread_pool.observability_init.Otel`. The bootstrap helper module
/// was removed when the otel dep was dropped; this empty struct keeps
/// `@hasDecl(thread_pool, "observability_init")` callers compiling.
pub const observability_init = struct {};

pub const sync = @import("sync.zig");
pub const clock = @import("clock.zig");
pub const types = @import("types.zig");
pub const ThreadPool = @import("pool.zig").ThreadPool;
pub const TaskContext = @import("pool.zig").TaskContext;
pub const TaskFn = @import("pool.zig").TaskFn;
pub const BatchTask = @import("pool.zig").BatchTask;

pub const version = "0.2.4";

pub const Config = types.Config;
pub const SchedulerVariant = types.SchedulerVariant;
pub const QueueKind = types.QueueKind;
pub const TaskLane = types.TaskLane;
pub const BackpressurePolicy = types.BackpressurePolicy;
pub const SubmitOptions = types.SubmitOptions;
pub const ShutdownMode = types.ShutdownMode;
pub const TaskHandle = types.TaskHandle;
pub const WaitGroup = types.WaitGroup;
pub const CancellationToken = types.CancellationToken;
pub const LatencySummary = types.LatencySummary;
pub const WorkerStats = types.WorkerStats;
pub const ProcessMemoryStats = types.ProcessMemoryStats;
pub const Stats = types.Stats;
pub const WorkDeque = @import("queue/work_deque.zig").WorkDeque;
pub const BoundedRing = @import("queue/bounded_ring.zig").BoundedRing;
pub const RingQueue = @import("queue/ring_queue.zig").RingQueue;
pub const DescCache = @import("pool/desc_cache.zig").DescCache;

test {
    std.testing.refAllDecls(@This());
    // Files not re-exported above must be referenced explicitly or their
    // in-file tests are never collected (refAllDecls only reaches files
    // whose top-level decls appear in this module's public surface).
    _ = @import("stats/latency.zig");
    _ = @import("stats/process_memory.zig");
    _ = @import("memory/scratch.zig");
}
