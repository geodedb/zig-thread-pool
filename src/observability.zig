// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! observability.zig — single-file otel seam for thread-pool.
//!
//! When `build_options.with_otel == false`, every public function in this
//! file collapses to a comptime-known no-op so the optimizer eliminates
//! the call site entirely. When true, calls forward to the appropriate
//! `otel.api.trace` helper.
//!
//! INVARIANT: every emit is `catch {}`-discarded. A failing exporter
//! never reaches the caller — telemetry must never break a task submit.
//!
//! NOTE: deviation from the HTTP template — thread-pool submit operations
//! do not fit the `instrumentation.http.startClientSpan` shape (HTTP
//! method/url is meaningless for a producer-side enqueue). We expose a
//! domain-specific `startSubmitSpan()` helper that constructs a span via
//! `otel.api.trace.Tracer.startSpan` directly with a messaging-shaped
//! span name (`"thread_pool.submit"`), `.producer` kind, and the
//! `messaging.system="thread_pool"` / `messaging.operation="publish"`
//! semantic conventions (matching otel messaging conventions for
//! producer-side enqueue spans).

const std = @import("std");
const build_options = @import("build_options");

pub const enabled: bool = build_options.with_otel;

const otel = if (enabled) @import("otel") else struct {};

/// Opaque handle for an in-flight submit operation. When disabled, this
/// is a zero-sized struct the optimizer drops entirely. The no-op
/// fallback's `end` signature MUST match `otel.api.trace.Span.end(?u64) void`
/// so callers can write `span.end(null)` regardless of `enabled` state.
pub const Span = if (enabled) otel.api.trace.Span else struct {
    pub fn end(self: @This(), _: ?u64) void {
        _ = self;
    }
};

/// Start a span for a thread-pool submit operation.
///
/// Span shape:
///   - name: `"thread_pool.submit"`
///   - kind: `.producer` (otel messaging conventions: producer = the
///     side that enqueues messages onto the queue/broker; the worker
///     thread that pops a task is the consumer).
///   - attributes:
///       * `messaging.system    = "thread_pool"`
///       * `messaging.operation = "publish"`
///
/// Wired at the public `ThreadPool.submit` / `ThreadPool.trySubmit` /
/// `ThreadPool.submitBatch` entry points. Worker-side task pickup is
/// intentionally NOT instrumented — that path runs at very high
/// frequency and a per-pop span would distort latency budgets.
pub fn startSubmitSpan() Span {
    if (!enabled) return Span{};
    const tracer = global.tracer orelse return Span{};
    const span = tracer.startSpan(
        .empty(),
        "thread_pool.submit",
        .{ .kind = .producer },
    ) catch return Span{};
    // Best-effort attribute attachment. Failures (OOM in the attribute
    // set) cannot block the submit — telemetry is non-fatal.
    span.setStringAttribute("messaging.system", "thread_pool") catch {};
    span.setStringAttribute("messaging.operation", "publish") catch {};
    return span;
}

/// Close a submit span, recording success/failure status.
///
/// On `ok = true` we set status `.ok`; on `ok = false` we set status
/// `.error_` with an empty description (callers who have an error
/// message can attach it via `span.setStatus` before calling this
/// helper). Callers typically pair this with `defer span.end(null)` at
/// the call site so the span is always ended regardless of which path
/// is taken; `setStatus` + `end` are idempotent for status reporting
/// (only the first status write wins; the deferred `end(null)` is a
/// redundant no-op when this helper has already ended the span).
pub fn endSubmitSpan(span: Span, ok: bool) void {
    if (!enabled) return;
    if (ok) {
        span.setStatus(.ok, "");
    } else {
        // `StatusCode` uses `@"error"` (escaped keyword) for the
        // failure variant — see otel/src/api/trace.zig:35.
        span.setStatus(.@"error", "");
    }
    span.end(null);
}

/// Set once at process start by `observability_init.Otel.installGlobals`.
/// Only referenced when `enabled == true`; otherwise the optimizer drops
/// the whole struct.
pub const global = if (enabled) struct {
    pub var tracer: ?*otel.api.trace.Tracer = null;
    pub var meter: ?*otel.api.metrics.Meter = null;
} else struct {};
