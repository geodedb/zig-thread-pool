// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! `thread-pool` provides a bounded, reusable thread-pool for devnw/zig codebases.
//! The public surface intentionally stays small while the implementation offers
//! multiple scheduler variants behind the same API.

const std = @import("std");

pub const types = @import("thread_pool/types.zig");
pub const ThreadPool = @import("thread_pool/pool.zig").ThreadPool;
pub const TaskContext = @import("thread_pool/pool.zig").TaskContext;
pub const TaskFn = @import("thread_pool/pool.zig").TaskFn;
pub const BatchTask = @import("thread_pool/pool.zig").BatchTask;

pub const version = "0.2.0";

pub const Config = types.Config;
pub const SchedulerVariant = types.SchedulerVariant;
pub const AllocatorMode = types.AllocatorMode;
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

test {
    std.testing.refAllDecls(@This());
}
