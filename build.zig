// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros

const std = @import("std");
const manifest = @import("build.zig.zon");

const Import = std.Build.Module.Import;

/// Bundle of shared modules that every consumer module (lib, tests,
/// examples, benchmarks, fuzz harness, observability seam tests) must
/// import by reference. Materialising these once and threading the same
/// pointer through every `addImport` call avoids Zig 0.16's
/// "file exists in modules X and X0" diagnostic, which fires when the
/// same source file is pulled into multiple module trees via duplicate
/// `addOptions` / `addModule` calls.
const Deps = struct {
    /// Shared `build_options` MODULE (not the `*Options` builder). Every
    /// consumer that does `@import("build_options")` resolves to the
    /// same instance.
    build_options_mod: *std.Build.Module,
    /// Shared `observability` named module. Imported by the public
    /// `thread_pool` module + every test root that exercises the seam.
    /// As of 2026-04-30 this is a permanent comptime no-op stub
    /// (see src/observability.zig); callers that need real telemetry
    /// wrap `ThreadPool.submit` directly at their layer.
    observability_mod: *std.Build.Module,
};

fn allocImports(b: *std.Build, imports: []const Import) []Import {
    return b.allocator.dupe(Import, imports) catch @panic("out of memory");
}

fn importedModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    module: *std.Build.Module,
    deps: Deps,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = allocImports(b, &.{
            .{ .name = "thread_pool", .module = module },
            .{ .name = "observability", .module = deps.observability_mod },
            .{ .name = "build_options", .module = deps.build_options_mod },
        }),
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const tsan = b.option(bool, "tsan", "Enable ThreadSanitizer on test artifacts") orelse false;
    const single_pool = b.option(
        bool,
        "single-pool",
        "Assume at most one ThreadPool per process. Elides the F-001 per-pool " ++
            "TLS-identity check on the hot submit path. UNSAFE when multiple " ++
            "pools coexist in one process (restores the pre-F-001 OOB hazard).",
    ) orelse false;

    // COMPTIME-ELISION / P-09: optional pin for Config.timestamp_mode at
    // build time. `any` (default) preserves runtime-configurable behavior;
    // `full` pins to the observability-rich default; `disabled` pins to the
    // low-overhead path and lets the hot path elide submit/start clock
    // reads + histogram observes at comptime.
    const TimestampModeFlag = enum { any, full, disabled };
    const timestamp_mode_flag = b.option(
        TimestampModeFlag,
        "timestamp-mode",
        "Pin Config.timestamp_mode at build time to elide the runtime check " ++
            "from Core.runTask. `any` (default) is runtime-configurable; " ++
            "`full` pins histograms on; `disabled` pins them off.",
    ) orelse .any;

    // COMPTIME-ELISION / P-09: optional pin for Config.scheduler_variant at
    // build time. `any` (default) keeps the runtime `uses_local` switches;
    // pinning to one variant lets `submit/enqueuePush/nextTask` elide the
    // dead-path branches for the other two variants at comptime.
    const SchedulerVariantFlag = enum { any, global_queue, work_stealing, lane_extension };
    const scheduler_variant_flag = b.option(
        SchedulerVariantFlag,
        "scheduler-variant",
        "Pin Config.scheduler_variant at build time. `any` (default) keeps " ++
            "all three variants runtime-selectable; pinning elides the " ++
            "dead-path branches for the other variants at comptime.",
    ) orelse .any;

    // -Dwith_otel and -Dotel_use_devnw_* options: ACCEPTED BUT IGNORED.
    // Removed 2026-04-30 from the dep graph because thread-pool ↔ otel
    // formed a hard cycle (otel pulls thread-pool back through
    // `-Dotel_use_devnw_pool=true`) that the cross-repo diamond-dep
    // detector could not converge — every commit on either side bumped
    // the other's hash. The observability seam is now a permanent
    // comptime no-op (`src/observability.zig`); callers that need real
    // telemetry wrap `ThreadPool.submit` directly.
    //
    // We still accept the flags so existing downstream `b.dependency(
    // "thread_pool", .{ .with_otel = true, ... })` calls don't error
    // with "unknown option" — they just have no effect here. Downstream
    // consumers should treat thread-pool as a pure leaf and stop
    // forwarding otel options once they've migrated.
    _ = b.option(bool, "with_otel", "DEPRECATED: accepted for compat, ignored. Telemetry seam is permanent no-op.") orelse false;
    _ = b.option(bool, "otel_use_devnw_tls", "DEPRECATED: accepted for compat, ignored.") orelse false;
    _ = b.option(bool, "otel_disabled", "DEPRECATED: accepted for compat, ignored.") orelse false;
    _ = b.option(bool, "otel_profiles", "DEPRECATED: accepted for compat, ignored.") orelse false;
    _ = b.option(bool, "otel_use_devnw_grpc", "DEPRECATED: accepted for compat, ignored.") orelse false;

    // Materialize ONE shared `build_options` MODULE. Every consumer
    // module imports the SAME module instance via `addImport` to avoid
    // Zig 0.16's "file exists in modules X and X0" error when two
    // independent `addOptions` modules share a transitive file path.
    const build_options = b.addOptions();
    build_options.addOption(bool, "single_pool", single_pool);
    build_options.addOption(TimestampModeFlag, "timestamp_mode", timestamp_mode_flag);
    build_options.addOption(SchedulerVariantFlag, "scheduler_variant", scheduler_variant_flag);
    build_options.addOption([]const u8, "package_name", "thread_pool");
    // `with_otel` always false: the seam is permanently disabled.
    build_options.addOption(bool, "with_otel", false);
    // Single source of truth for the library version: read from build.zig.zon
    // so a release bump requires only one edit (AP2-01).
    build_options.addOption([]const u8, "version", manifest.version);
    const build_options_mod = build_options.createModule();

    // Observability seam. Declared as a SHARED NAMED MODULE so every
    // consumer (lib, tests, examples, benchmarks, plus the seam tests)
    // resolves to the same source file via `@import("observability")`.
    // As of 2026-04-30 this is a permanent comptime no-op stub; it does
    // NOT import otel and does NOT participate in any external dep
    // graph. See `src/observability.zig` for the residual API
    // (`Span`, `startSubmitSpan`, `endSubmitSpan`).
    const observability_mod = b.addModule("observability", .{
        .root_source_file = b.path("src/observability.zig"),
        .target = target,
        .optimize = optimize,
    });

    const deps: Deps = .{
        .build_options_mod = build_options_mod,
        .observability_mod = observability_mod,
    };

    const module = b.addModule("thread_pool", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = allocImports(b, &.{
            .{ .name = "build_options", .module = build_options_mod },
            .{ .name = "observability", .module = observability_mod },
        }),
    });

    const static_lib = b.addLibrary(.{
        .name = "thread-pool",
        .linkage = .static,
        .root_module = module,
    });
    b.installArtifact(static_lib);

    const build_step = b.step("build", "Build the standalone library");
    build_step.dependOn(&static_lib.step);

    const check_step = b.step("check", "Compile the library and unit tests without running them");
    const check_tests = b.addTest(.{
        .root_module = module,
    });
    check_step.dependOn(&check_tests.step);

    const unit_step = b.step("test", "Run unit tests");
    const unit_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/unit.zig", target, optimize, module, deps),
    });
    if (tsan) unit_tests.root_module.sanitize_thread = true;
    unit_step.dependOn(&b.addRunArtifact(unit_tests).step);
    // Also RUN the in-file module tests (src/**). Previously they were only
    // compiled by `zig build check` and never executed, so regressions
    // guarded by tests like GAP-0039 (stats/latency.zig) were invisible to
    // CI. `check_tests` is the same artifact the check step compiles.
    unit_step.dependOn(&b.addRunArtifact(check_tests).step);

    // Observability seam tests. Two targets:
    //   - `observability_disabled_test.zig` runs under BOTH flag values.
    //     Each test inside it is skip-guarded via
    //     `if (thread_pool.observability.enabled) return error.SkipZigTest;`
    //     so the disabled-mode invariants only fire when the flag is off.
    //   - `observability_enabled_test.zig` is registered under both flag
    //     values too, but every test inside it skips when the flag is
    //     off. The `otel` import is wired only when `with_otel = true`;
    //     the stub branch in the test file (see Chunk C) ensures the
    //     file still compiles cleanly under the disabled build.
    const disabled_seam_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/observability_disabled_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = allocImports(b, &.{
                .{ .name = "thread_pool", .module = module },
                .{ .name = "build_options", .module = build_options_mod },
            }),
        }),
    });
    unit_step.dependOn(&b.addRunArtifact(disabled_seam_tests).step);

    // Enabled-mode smoke test removed 2026-04-30 along with the otel
    // dependency. The seam is now permanently disabled, so the test
    // file `tests/observability_enabled_test.zig` was deleted (it
    // imported `otel` and exercised the wired path that no longer
    // exists). The disabled_seam_tests above remain and are sufficient
    // to verify the comptime no-op invariants.

    const integration_step = b.step("test-integration", "Run integration tests");
    const integration_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/integration.zig", target, optimize, module, deps),
    });
    if (tsan) integration_tests.root_module.sanitize_thread = true;
    integration_step.dependOn(&b.addRunArtifact(integration_tests).step);

    // Under TSan, switch stress from ReleaseFast to Debug so races are not
    // optimised away; -Dtsan is always a Debug-instrumented build.
    const stress_optimize: std.builtin.OptimizeMode = if (tsan) .Debug else .ReleaseFast;
    const stress_step = b.step("test-stress", "Run stress and load tests");
    const stress_tests = b.addTest(.{
        .root_module = importedModule(b, "tests/stress.zig", target, stress_optimize, module, deps),
    });
    if (tsan) stress_tests.root_module.sanitize_thread = true;
    stress_step.dependOn(&b.addRunArtifact(stress_tests).step);

    // SONNY-2540: a focused, optimization-aware regression executable lets
    // the qualification harness run fresh pinned/unpinned processes.
    const recruitment_tests = b.addTest(.{
        .name = "parked-recruitment-test",
        .root_module = importedModule(b, "tests/parked_recruitment.zig", target, optimize, module, deps),
    });
    const recruitment_step = b.step("test-recruitment", "Run the parked-worker handshake regression");
    recruitment_step.dependOn(&b.addRunArtifact(recruitment_tests).step);
    const recruitment_build = b.step("build-recruitment", "Install the recruitment regression executable");
    recruitment_build.dependOn(&b.addInstallArtifact(recruitment_tests, .{}).step);

    const all_tests_step = b.step("test-all", "Run unit, integration, and stress suites");
    all_tests_step.dependOn(&b.addRunArtifact(unit_tests).step);
    all_tests_step.dependOn(&b.addRunArtifact(check_tests).step);
    all_tests_step.dependOn(&b.addRunArtifact(integration_tests).step);
    all_tests_step.dependOn(&b.addRunArtifact(stress_tests).step);

    const example_step = b.step("example", "Build and run the basic example");
    const example_exe = b.addExecutable(.{
        .name = "thread-pool-basic",
        .root_module = importedModule(b, "examples/basic.zig", target, optimize, module, deps),
    });
    example_step.dependOn(&b.addRunArtifact(example_exe).step);

    const bench_step = b.step("bench", "Run the CI-safe benchmark suite");
    const bench_exe = b.addExecutable(.{
        .name = "thread-pool-bench",
        .root_module = importedModule(b, "benchmarks/bench.zig", target, .ReleaseFast, module, deps),
    });
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    bench_step.dependOn(&run_bench.step);
    b.installArtifact(bench_exe);

    const scale_bench_step = b.step("scale-bench", "Run the larger benchmark grid");
    const scale_bench_exe = b.addExecutable(.{
        .name = "thread-pool-scale-bench",
        .root_module = importedModule(b, "benchmarks/scale_bench.zig", target, .ReleaseFast, module, deps),
    });
    const run_scale_bench = b.addRunArtifact(scale_bench_exe);
    if (b.args) |args| run_scale_bench.addArgs(args);
    scale_bench_step.dependOn(&run_scale_bench.step);
    b.installArtifact(scale_bench_exe);

    const compare_step = b.step("compare-bench", "Compare two benchmark result files");
    const compare_exe = b.addExecutable(.{
        .name = "thread-pool-compare-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("benchmarks/compare.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        }),
    });
    const run_compare = b.addRunArtifact(compare_exe);
    if (b.args) |args| run_compare.addArgs(args);
    compare_step.dependOn(&run_compare.step);
    b.installArtifact(compare_exe);

    const micro_submit = b.addExecutable(.{
        .name = "thread-pool-micro-submit",
        .root_module = importedModule(b, "benchmarks/micro/submit_latency.zig", target, .ReleaseFast, module, deps),
    });
    const run_micro_submit = b.addRunArtifact(micro_submit);
    const micro_submit_step = b.step("bench-micro-submit", "Micro-benchmark: submit latency");
    micro_submit_step.dependOn(&run_micro_submit.step);

    const micro_steal = b.addExecutable(.{
        .name = "thread-pool-micro-steal",
        .root_module = importedModule(b, "benchmarks/micro/steal_throughput.zig", target, .ReleaseFast, module, deps),
    });
    const run_micro_steal = b.addRunArtifact(micro_steal);
    if (b.args) |args| run_micro_steal.addArgs(args);
    const micro_steal_step = b.step("bench-micro-steal", "Micro-benchmark: steal throughput");
    micro_steal_step.dependOn(&run_micro_steal.step);

    const micro_wake = b.addExecutable(.{
        .name = "thread-pool-micro-wake",
        .root_module = importedModule(b, "benchmarks/micro/wake_latency.zig", target, .ReleaseFast, module, deps),
    });
    const run_micro_wake = b.addRunArtifact(micro_wake);
    const micro_wake_step = b.step("bench-micro-wake", "Micro-benchmark: wake latency");
    micro_wake_step.dependOn(&run_micro_wake.step);

    const tokio_bench = b.addExecutable(.{
        .name = "thread-pool-tokio-parity",
        .root_module = importedModule(b, "benchmarks/bench_tokio_parity.zig", target, .ReleaseFast, module, deps),
    });
    b.installArtifact(tokio_bench);
    const run_tokio_bench = b.addRunArtifact(tokio_bench);
    const tokio_bench_step = b.step("bench-tokio-parity", "Tokio rt_multi_threaded parity benchmarks");
    tokio_bench_step.dependOn(&run_tokio_bench.step);

    const runtime_compare_zig = b.addExecutable(.{
        .name = "thread-pool-runtime-compare-zig",
        .root_module = importedModule(b, "benchmarks/runtime_compare_zig.zig", target, .ReleaseFast, module, deps),
    });
    b.installArtifact(runtime_compare_zig);
    const run_runtime_compare_zig = b.addRunArtifact(runtime_compare_zig);
    if (b.args) |args| run_runtime_compare_zig.addArgs(args);
    const runtime_compare_zig_step = b.step("bench-runtime-zig", "Comparable runtime benchmark for this Zig thread pool");
    runtime_compare_zig_step.dependOn(&run_runtime_compare_zig.step);

    const runtime_compare = b.addSystemCommand(&.{ "bash", "scripts/run-runtime-comparison.sh" });
    runtime_compare.addArg("--zig-bin");
    runtime_compare.addFileArg(runtime_compare_zig.getEmittedBin());
    if (b.args) |args| runtime_compare.addArgs(args);
    const runtime_compare_step = b.step("bench-runtime-compare", "Run direct side-by-side benchmarks against vendored Tokio and Go runtimes");
    runtime_compare_step.dependOn(&runtime_compare.step);

    const realistic_bench_exe = b.addExecutable(.{
        .name = "thread-pool-bench-realistic",
        .root_module = importedModule(b, "benchmarks/bench_realistic.zig", target, .ReleaseFast, module, deps),
    });
    b.installArtifact(realistic_bench_exe);
    const run_realistic_bench = b.addRunArtifact(realistic_bench_exe);
    if (b.args) |args| run_realistic_bench.addArgs(args);
    const realistic_bench_step = b.step("bench-realistic", "Realistic workload benchmarks (latency, fairness, lanes)");
    realistic_bench_step.dependOn(&run_realistic_bench.step);

    // Aggregate "bench-micro" step
    const micro_all_step = b.step("bench-micro", "All micro-benchmarks");
    micro_all_step.dependOn(&run_micro_submit.step);
    micro_all_step.dependOn(&run_micro_steal.step);
    micro_all_step.dependOn(&run_micro_wake.step);

    const fuzz_exe = b.addExecutable(.{
        .name = "pool-fuzz",
        .root_module = importedModule(b, "tests/fuzz/pool_fuzz.zig", target, optimize, module, deps),
    });
    if (tsan) fuzz_exe.root_module.sanitize_thread = true;
    b.installArtifact(fuzz_exe);
    const run_fuzz = b.addRunArtifact(fuzz_exe);
    run_fuzz.has_side_effects = true;
    if (b.args) |args| run_fuzz.addArgs(args);
    const fuzz_step = b.step("fuzz", "Run the public-API fuzz harness (set FUZZ_SEED / FUZZ_ITERATIONS env vars)");
    fuzz_step.dependOn(&run_fuzz.step);

    const tools_step = b.step("tools", "Build benchmark tooling");
    tools_step.dependOn(&bench_exe.step);
    tools_step.dependOn(&scale_bench_exe.step);
    tools_step.dependOn(&compare_exe.step);
    tools_step.dependOn(&runtime_compare_zig.step);

    // NOTE: cross-check step removed. Previously created per-target
    // copies of the root module via a now-deleted helper, which
    // introduced multiple modules rooted at src/root.zig into the build
    // graph. When downstream consumers instantiated thread-pool, Zig's
    // build graph saw the duplicate roots and errored with "file exists
    // in modules 'build_options0' and 'build_optionsN'". Cross-target
    // builds can be invoked from CI by running `zig build -Dtarget=...`
    // explicitly.
}
