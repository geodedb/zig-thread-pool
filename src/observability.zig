// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! observability.zig — permanent comptime no-op observability seam for
//! thread-pool.
//!
//! HISTORY: this file used to forward to `otel.api.trace` when
//! `-Dwith_otel=true` was passed to `zig build`.  As of 2026-04-30
//! the otel dependency is removed from `build.zig.zon` because
//! thread-pool ↔ otel formed a hard dep cycle that the cross-repo
//! diamond-dep detector (`geode/scripts/detect_diamond_deps.py`)
//! could not converge: every commit on either side bumped the
//! other's hash.  Even with `lazy = true` on the thread-pool side,
//! the manifest entry still made transitive consumers diamond.
//!
//! The seam is preserved as a permanent stub so callers
//! (pool.zig::submit, etc.) keep compiling unchanged.  Every public
//! symbol is a zero-sized struct or a `void`-returning no-op the
//! optimizer drops at every call site.  Callers that need real
//! telemetry should wrap `ThreadPool.submit` directly at their layer
//! (which has access to its own otel + caller context).
//!
//! INVARIANT preserved from the otel-wired version: telemetry is
//! never on the success-or-failure path of `submit`.  In the no-op
//! build, this is trivially true.

pub const enabled: bool = false;

/// Opaque handle for an in-flight submit operation.  Zero-sized; the
/// optimizer drops it.  `end` matches the previous wired-up
/// `otel.api.trace.Span.end(?u64) void` signature so caller code that
/// does `span.end(null)` keeps compiling without changes.
pub const Span = struct {
    pub fn end(self: @This(), _: ?u64) void {
        _ = self;
    }
};

/// Start a span for a thread-pool submit operation.  No-op stub.
pub fn startSubmitSpan() Span {
    return Span{};
}

/// Close a submit span, recording success/failure status.  No-op stub.
pub fn endSubmitSpan(span: Span, ok: bool) void {
    _ = span;
    _ = ok;
}

/// Globals struct preserved as an empty namespace so older code paths
/// that referenced `observability.global.tracer` (now unreachable
/// because `enabled = false`) still type-check at the access site.
pub const global = struct {};
