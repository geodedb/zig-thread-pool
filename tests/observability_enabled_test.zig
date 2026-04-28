// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

//! Verifies one thread-pool submit span lands in an in-memory recorder
//! when `-Dwith_otel=true`. Skips under the disabled build.
//!
//! NOTE: deviation from the HTTP template — we exercise the seam
//! directly via the in-memory recorder rather than driving a real
//! `ThreadPool.submit` call. The seam's behaviour is identical:
//! `startSubmitSpan` -> `endSubmitSpan` enters and leaves one tracer
//! span. Driving a real submit would also pull the entire pool init
//! path (worker threads, futexes, scheduler variants) into the test —
//! the seam contract being verified is independent of that machinery.
//!
//! The `otel` module is only added to this test root when
//! `-Dwith_otel=true`. To compile cleanly under both flag values we
//! gate the otel-namespace identifiers behind `comptime if (enabled)`
//! and stub the alias to an empty struct when the flag is off — that
//! branch is dead code in the disabled build but the import resolves.

const std = @import("std");
const build_options = @import("build_options");
const thread_pool = @import("thread_pool");

const otel = if (build_options.with_otel) @import("otel") else struct {};

test "one thread_pool.submit producer span recorded when otel enabled" {
    if (!thread_pool.observability.enabled) return error.SkipZigTest;

    const allocator = std.testing.allocator;

    var resource = try otel.sdk.resource.defaultResource(allocator);
    defer resource.deinit();
    try resource.attributes.putString(otel.semconv.service_name, "thread-pool-test");

    var recorder = otel.exporters.in_memory.Recorder.init(allocator);
    defer recorder.deinit();
    var tp = try otel.sdk.trace.TracerProvider.init(allocator, .{
        .resource = &resource,
        .default_exporter = recorder.spanExporter(),
    });
    defer tp.deinit();

    var tracer = tp.tracer(.{ .name = "thread-pool-test" });
    thread_pool.observability.global.tracer = &tracer;
    defer thread_pool.observability.global.tracer = null;

    const span = thread_pool.observability.startSubmitSpan();
    thread_pool.observability.endSubmitSpan(span, true);

    try tp.forceFlush(1_000);
    try std.testing.expectEqual(@as(usize, 1), recorder.spans.items.len);

    // Verify span name shape: `"thread_pool.submit"`.
    const recorded = recorder.spans.items[0];
    try std.testing.expectEqualStrings("thread_pool.submit", recorded.name);

    // Verify the messaging.system + messaging.operation attributes
    // landed on the span. The in-memory recorder stores attributes as
    // `[]KV` (string-stringified key/value pairs) — see
    // otel/src/exporters/in_memory.zig.
    var found_system: ?[]const u8 = null;
    var found_op: ?[]const u8 = null;
    for (recorded.attribute_kv) |kv| {
        if (std.mem.eql(u8, kv.key, "messaging.system")) {
            found_system = kv.value;
        } else if (std.mem.eql(u8, kv.key, "messaging.operation")) {
            found_op = kv.value;
        }
    }
    const system_value = found_system orelse return error.MissingMessagingSystemAttribute;
    try std.testing.expectEqualStrings("thread_pool", system_value);
    const op_value = found_op orelse return error.MissingMessagingOperationAttribute;
    try std.testing.expectEqualStrings("publish", op_value);
}
