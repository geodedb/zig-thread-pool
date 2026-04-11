# Quality Gap Analysis

Last updated: 2026-04-11

## Summary

| Severity | Count |
|----------|-------|
| Critical | 1 |
| High | 3 |
| Medium | 13 |
| Low | 7 |
| **Total** | **24** |

### Top 5 Risks

1. **Q-001** descriptor.state data race -- non-atomic writes read under mutex on non-TSO architectures (UB)
2. **Q-003** deinit() can hang forever if any task is stuck (no timeout on drain shutdown)
3. **Q-004** Zero test coverage on CancellationToken, trySubmit, backpressure, QueueFull, shutdown-timeout paths
4. **Q-002** Stats.active_workers reports task count not worker count -- API contract violation
5. **Q-005** Three dead Config fields silently accepted, nothing happens at runtime

## Stack-Ranked Findings

| Rank | ID | Severity | PriorityScore | Category | Finding | Component | Issue URL | Status |
|------|------|----------|---------------|----------|---------|-----------|-----------|--------|
| 1 | Q-001 | Critical | 100 | architecture | descriptor.state data race: written non-atomically, read under mutex | pool.zig:427,466-468,187 | -- | Open |
| 2 | Q-003 | High | 80 | architecture | deinit()->shutdown(.drain, null) hangs forever if task stuck | pool.zig:151,212 | -- | Open |
| 3 | Q-004 | High | 80 | tests | Zero coverage: CancellationToken, trySubmit, backpressure, QueueFull, shutdown timeout | tests/*.zig | -- | Open |
| 4 | Q-002 | High | 60 | api-contract | Stats.active_workers populated from active_tasks counter | pool.zig:261 | -- | Open |
| 5 | Q-005 | Medium | 48 | api-contract | 3 dead Config fields: idle_shrink_after_ns, stats_enabled, allocator_mode | types.zig:49,58,59 | -- | Open |
| 6 | Q-007 | Medium | 48 | architecture | parseOutputArg returns dangling pointer (use-after-free) | bench.zig:34, scale_bench.zig:73 | -- | Open |
| 7 | Q-006 | Medium | 36 | api-contract | TaskLane.keyed and SchedulerVariant.lane_extension non-functional | types.zig:6,17 | -- | Open |
| 8 | Q-009 | Medium | 36 | perf | nowNs() inconsistent: pool clamps negatives, benchmarks panic | pool.zig:674, common.zig:427 | -- | Open |
| 9 | Q-012 | Medium | 36 | docs | Zero doc comments on public ThreadPool methods | pool.zig:627-672 | -- | Open |
| 10 | Q-016 | Medium | 36 | maintainability | Core struct 35+ flat fields with no logical grouping | pool.zig:69-100 | -- | Open |
| 11 | Q-008 | Medium | 24 | maintainability | updatePeak CAS function duplicated verbatim | pool.zig:679, scratch.zig:22 | -- | Open |
| 12 | Q-010 | Medium | 24 | maintainability | parseOutputArg duplicated in bench.zig and scale_bench.zig | bench.zig:34, scale_bench.zig:73 | -- | Open |
| 13 | Q-011 | Medium | 24 | maintainability | Counter struct duplicated 3 times | basic.zig:4, tests/common.zig:4, benchmarks/common.zig:61 | -- | Open |
| 14 | Q-013 | Medium | 24 | docs | DESIGN.md submitBatch signature stale (shows !void, actually !SubmitBatchResult) | docs/DESIGN.md:18 | -- | Open |
| 15 | Q-014 | Medium | 20 | docs | No TaskState lifecycle diagram or doc in code | types.zig:31-38 | -- | Open |
| 16 | Q-015 | Medium | 20 | readability | Double-negation in cancellation check | pool.zig:449 | -- | Open |
| 17 | Q-017 | Medium | 16 | maintainability | recordOwnedAlloc/recordOwnedFree recreate Accounting each call | pool.zig:572-589 | -- | Open |
| 18 | Q-019 | Low | 16 | perf | private_peak_bytes misuses VmHWM (RSS peak, not private peak) | process_memory.zig:74 | -- | Open |
| 19 | Q-022 | Low | 16 | ci-cd | prepare-zig CI job produces no artifact, nothing depends on it | .gitlab-ci.yml:37-42 | -- | Open |
| 20 | Q-023 | Low | 16 | ci-cd | CI before_script apt-get + install-zig duplicated 14 times | .gitlab-ci.yml | -- | Open |
| 21 | Q-018 | Low | 12 | perf | compare.zig readDocument leaks raw bytes buffer | compare.zig:45 | -- | Open |
| 22 | Q-024 | Low | 12 | ci-cd | Pre-commit zig-fmt hook excludes benchmarks/ and examples/ | .pre-commit-config.yaml:69 | -- | Open |
| 23 | Q-020 | Low | 8 | maintainability | version constant in root.zig unreferenced and duplicates build.zig.zon | root.zig:16 | -- | Open |
| 24 | Q-021 | Low | 8 | cleanup | CODEOWNERS contains placeholder @your-username | CODEOWNERS:3 | -- | Open |

## Detailed Findings

---

### Q-001 -- descriptor.state data race (Critical, PriorityScore 100)

**Impact:** 5 | **Likelihood:** 5 | **PriorityScore:** 5 \* 5 \* 4 = 100

**Category:** architecture
**Confidence:** confidence::confirmed
**Severity:** Critical

**Summary:** `descriptor.state` is written with plain assignments in `runTask` (lines 427, 454, 467) and read under `completion_mutex` in `wait` (line 187). On architectures without Total Store Ordering (ARM, RISC-V), this is a data race and undefined behavior per the Zig/LLVM memory model.

**Evidence:**

```zig
// pool.zig:427  -- written without atomic/mutex
descriptor.state = .running;

// pool.zig:466-467  -- written without atomic/mutex
if (descriptor.state != .cancelled) {
    descriptor.state = .completed;

// pool.zig:187  -- read under completion_mutex, but writer never acquires it
switch (descriptor.state) {
```

**Root cause:** The descriptor.state field was likely correct initially when all access was under one lock but the completion path was optimized to avoid the lock on the write side without upgrading to atomic operations.

**Recommended change:** Make `descriptor.state` an `std.atomic.Value(TaskState)` and use `.store(..., .release)` in runTask, `.load(.acquire)` in wait. Alternatively, acquire completion_mutex before writing `.completed`/`.cancelled`.

**Acceptance criteria:** TaskState transitions use atomic ordering or are fully covered by the completion_mutex. ThreadSanitizer (or Zig's builtin TSAN via `-fsanitize=thread`) reports zero data-race warnings on the stress test suite.

**Verification:** `zig build test-stress -Doptimize=Debug` under TSAN (or manual ARM CI run) with no race reports.

**Affected paths:** `src/thread_pool/pool.zig`

**Effort:** S (< 1 day)
**Suggested owner:** @benji (primary contributor)

---

### Q-003 -- deinit() hangs forever on stuck task (High, PriorityScore 80)

**Impact:** 4 | **Likelihood:** 5 | **PriorityScore:** 4 \* 5 \* 4 = 80

**Category:** architecture
**Confidence:** confidence::confirmed
**Severity:** High

**Summary:** `deinit()` calls `shutdown(.drain, null)` which passes `null` timeout. The shutdown loop at line 212-218 spins indefinitely (`if (deadline != 0 ...`) when active_tasks never reaches zero. A single stuck task causes a permanent hang with no diagnostic output.

**Evidence:**

```zig
// pool.zig:151
pub fn deinit(self: *Core) void {
    self.shutdown(.drain, null) catch {};

// pool.zig:211-218
const deadline = if (timeout_ns) |ns| nowNs() + ns else 0;
while (true) {
    ...
    if (deadline != 0 and nowNs() >= deadline) return error.Timeout;
    std.Thread.sleep(100_000);
}
```

**Root cause:** The API exposes a timeout parameter in `shutdown()` but `deinit()` hardcodes null. No fallback watchdog or diagnostic panic exists.

**Recommended change:** Add a configurable `deinit_timeout_ns` to Config (default 30s) and use it in `deinit()`. On timeout, log diagnostic stats and force-join threads.

**Acceptance criteria:** `deinit()` returns or panics with diagnostic info within a bounded time even if a task is stuck.

**Verification:** Add a test that submits an infinitely-blocking task, calls deinit, and asserts it completes within the configured timeout.

**Affected paths:** `src/thread_pool/pool.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-004 -- Zero test coverage on critical paths (High, PriorityScore 80)

**Impact:** 4 | **Likelihood:** 5 | **PriorityScore:** 4 \* 5 \* 4 = 80

**Category:** tests
**Confidence:** confidence::confirmed
**Severity:** High

**Summary:** The following public-API paths have no test coverage: CancellationToken (cancel before and during execution), trySubmit (non-blocking path), backpressure (block and block_with_timeout policies), QueueFull error, shutdown with timeout, process memory sampling.

**Evidence:** Grepping `tests/*.zig` for `CancellationToken`, `trySubmit`, `block_with_timeout`, `QueueFull`, and `shutdown.*timeout` returns zero matches.

**Root cause:** Incremental development focused on happy-path first. Edge-case tests deferred.

**Recommended change:** Add dedicated test functions for each untested path. Minimum:

- `test "cancellation token prevents execution"`
- `test "trySubmit returns QueueFull when full"`
- `test "block backpressure eventually succeeds"`
- `test "shutdown with timeout returns Timeout on stuck task"`

**Acceptance criteria:** Each path exercised with assertion. `zig build test --summary all` passes green.

**Verification:** `zig build test --summary all` -- all new tests pass.

**Affected paths:** `tests/unit.zig`, `tests/integration.zig`

**Effort:** M (1-3 days)
**Suggested owner:** @benji

---

### Q-002 -- Stats.active_workers semantic mismatch (High, PriorityScore 60)

**Impact:** 4 | **Likelihood:** 3 | **PriorityScore:** 4 \* 3 \* 5 = 60

**Category:** api-contract
**Confidence:** confidence::confirmed
**Severity:** High

**Summary:** `Stats.active_workers` is populated from `self.active_tasks.load(.acquire)` (pool.zig:261). The field name implies worker count but reports active task count. Consumers relying on this for capacity planning will get incorrect values (one worker can run only one task, but the naming suggests workers not tasks).

**Evidence:**

```zig
// pool.zig:261
.active_workers = self.active_tasks.load(.acquire),
```

**Root cause:** Naming was likely a copy-paste from an early design where 1:1 worker-to-task was assumed.

**Recommended change:** Either rename the Stats field to `active_tasks` (breaking change) or introduce a distinct `active_workers` counter tracking actual thread execution state.

**Acceptance criteria:** Field name matches semantic meaning; doc-comment clarifies what is counted.

**Verification:** Update existing tests/benchmarks that reference `active_workers` to use the renamed field; compile clean.

**Affected paths:** `src/thread_pool/pool.zig`, `src/thread_pool/types.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-005 -- Dead Config fields silently ignored (Medium, PriorityScore 48)

**Impact:** 3 | **Likelihood:** 4 | **PriorityScore:** 3 \* 4 \* 4 = 48

**Category:** api-contract
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** Three Config fields are declared and can be set by users but have zero runtime effect:

- `idle_shrink_after_ns` (line 49) -- never read post-normalization
- `stats_enabled` (line 59) -- stats always collected regardless
- `allocator_mode` (line 58) -- worker scratch always allocated regardless

**Evidence:**

```zig
// types.zig:49,58,59
idle_shrink_after_ns: u64 = 60_000_000_000,
allocator_mode: AllocatorMode = .caller_supplied_with_worker_scratch,
stats_enabled: bool = true,
```

Grepping pool.zig for `idle_shrink_after_ns`, `stats_enabled`, and `allocator_mode` yields zero runtime reads.

**Root cause:** Planned features declared in the config struct ahead of implementation.

**Recommended change:** Either (a) mark with `// TODO: not yet implemented` doc-comments and add `@compileLog` deprecation notices, or (b) remove them until implemented (breaking change). At minimum, `validate()` should warn or error if a non-default value is set for an unimplemented field.

**Acceptance criteria:** Users cannot silently set a dead field expecting behavior. Either compile-time or runtime diagnostic fires.

**Verification:** Set `stats_enabled = false` and verify either a compile error or runtime warning appears.

**Affected paths:** `src/thread_pool/types.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-007 -- parseOutputArg returns dangling pointer (Medium, PriorityScore 48)

**Impact:** 4 | **Likelihood:** 3 | **PriorityScore:** 4 \* 3 \* 4 = 48

**Category:** architecture
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** `parseOutputArg` calls `std.process.argsAlloc(allocator)` then `defer std.process.argsFree(allocator, args)`. It returns a slice element (`args[idx + 1]`) which points into the freed buffer. The returned `[]const u8` is a use-after-free.

**Evidence:**

```zig
// bench.zig:34-41 and scale_bench.zig:73-80
fn parseOutputArg(allocator: std.mem.Allocator) !?[]const u8 {
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);  // <-- frees backing memory
    ...
    return args[idx + 1];  // <-- dangling pointer
}
```

**Root cause:** The `defer` frees the args buffer before the caller can use the returned slice.

**Recommended change:** Remove the `defer` and let the caller own the args lifetime, or duplicate the string with `allocator.dupe(u8, args[idx + 1])`.

**Acceptance criteria:** No use-after-free. Returned slice remains valid for the caller's lifetime.

**Verification:** Run benchmarks with `-Doptimize=Debug` (safety checks enabled). Previously would detect illegal memory access at runtime on some allocators.

**Affected paths:** `benchmarks/bench.zig`, `benchmarks/scale_bench.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-006 -- Non-functional public enum variants (Medium, PriorityScore 36)

**Impact:** 3 | **Likelihood:** 3 | **PriorityScore:** 3 \* 3 \* 4 = 36

**Category:** api-contract
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** `TaskLane.keyed` and `SchedulerVariant.lane_extension` are public enum variants but have no implementation. Users can select them but the pool ignores the distinction.

**Evidence:**

```zig
// types.zig:6  -- SchedulerVariant.lane_extension
// types.zig:17 -- TaskLane.keyed
```

**Root cause:** Placeholder variants for planned-but-unimplemented features.

**Recommended change:** Add doc-comments marking them `/// Not yet implemented -- selecting this has no effect.` or gate them behind a comptime flag so users cannot accidentally depend on them.

**Acceptance criteria:** Selecting an unimplemented variant either produces a compile-time diagnostic or a clear runtime error.

**Verification:** Attempt to create a pool with `.lane_extension` scheduler and assert compile error or explicit runtime error.

**Affected paths:** `src/thread_pool/types.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-009 -- nowNs() inconsistency across modules (Medium, PriorityScore 36)

**Impact:** 3 | **Likelihood:** 3 | **PriorityScore:** 3 \* 3 \* 4 = 36

**Category:** perf
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** `pool.zig:674` clamps negative `nanoTimestamp()` to 0. `benchmarks/common.zig:427` does an unchecked `@intCast` which panics on negative values. If a system clock goes backwards (NTP correction, VM migration), benchmarks crash.

**Evidence:**

```zig
// pool.zig:674-676 -- safe
fn nowNs() u64 {
    const ts = std.time.nanoTimestamp();
    return if (ts < 0) 0 else @as(u64, @intCast(ts));
}

// benchmarks/common.zig:427-429 -- panics
fn nowNs() u64 {
    return @as(u64, @intCast(std.time.nanoTimestamp()));
}
```

**Root cause:** Independent implementations of the same helper without a shared utility.

**Recommended change:** Extract a shared `nowNs()` to a common utility or inline the safe version everywhere.

**Acceptance criteria:** All `nowNs()` implementations handle negative timestamps without panic.

**Verification:** Compile and run with `std.time.nanoTimestamp` mocked or on a system with NTP slew; no crash.

**Affected paths:** `src/thread_pool/pool.zig`, `benchmarks/common.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-012 -- No doc comments on public API (Medium, PriorityScore 36)

**Impact:** 3 | **Likelihood:** 3 | **PriorityScore:** 3 \* 3 \* 4 = 36

**Category:** docs
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** None of the public ThreadPool methods (init, deinit, submit, trySubmit, submitBatch, wait, waitGroup, shutdown, statsSnapshot, purgeWorkerCaches) have `///` doc-comments. The types TaskContext, TaskFn, SubmitOptions also lack documentation.

**Evidence:** Lines 627-672 of pool.zig -- all `pub fn` declarations lack `///` comments.

**Root cause:** Rapid iteration without documentation pass.

**Recommended change:** Add `///` doc-comments to each public method describing parameters, return values, error conditions, and thread-safety guarantees.

**Acceptance criteria:** `zig build-lib src/root.zig -femit-docs` produces meaningful documentation for all public symbols.

**Verification:** Run `zig build-lib src/root.zig -femit-docs` and inspect generated docs.

**Affected paths:** `src/thread_pool/pool.zig`, `src/thread_pool/types.zig`

**Effort:** M
**Suggested owner:** @benji

---

### Q-016 -- Core struct overly flat (Medium, PriorityScore 36)

**Impact:** 3 | **Likelihood:** 3 | **PriorityScore:** 3 \* 3 \* 4 = 36

**Category:** maintainability
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** The `Core` struct has 35+ fields at the top level (lines 69-100) covering allocator, config, state machine, worker management, queues, stats counters, and memory accounting. No logical grouping makes it difficult to reason about field relationships and cache-line layout.

**Evidence:** See pool.zig lines 69-100 -- 32 fields in a flat struct.

**Root cause:** Organic growth without periodic refactoring.

**Recommended change:** Group related fields into nested structs: `CoreStats`, `CoreQueues`, `CoreConfig`. This improves cache locality for hot stats and clarifies ownership.

**Acceptance criteria:** Core struct reduced to fewer than 15 top-level fields via logical sub-structs.

**Verification:** All existing tests pass after refactor.

**Affected paths:** `src/thread_pool/pool.zig`

**Effort:** M
**Suggested owner:** @benji

---

### Q-008 -- updatePeak duplicated (Medium, PriorityScore 24)

**Impact:** 2 | **Likelihood:** 3 | **PriorityScore:** 2 \* 3 \* 4 = 24

**Category:** maintainability
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** The `updatePeak` CAS helper is duplicated verbatim in `pool.zig:679-686` and `scratch.zig:22-29`. Divergence risk if one is updated without the other.

**Evidence:**

```zig
// Both locations -- identical implementation
fn updatePeak(counter: *std.atomic.Value(u64), value: u64) void {
    var current = counter.load(.monotonic);
    while (value > current) {
        const previous = counter.cmpxchgWeak(current, value, .monotonic, .monotonic);
        if (previous == null) return;
        current = previous.?;
    }
}
```

**Recommended change:** Extract to a shared utility module (e.g., `src/thread_pool/atomic_util.zig`).

**Affected paths:** `src/thread_pool/pool.zig`, `src/thread_pool/memory/scratch.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-010 -- parseOutputArg duplicated (Medium, PriorityScore 24)

**Impact:** 2 | **Likelihood:** 3 | **PriorityScore:** 2 \* 3 \* 4 = 24

**Category:** maintainability
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** `parseOutputArg` is copy-pasted identically in `bench.zig:34` and `scale_bench.zig:73`. Both copies also contain the dangling-pointer bug (Q-007).

**Recommended change:** Move to `benchmarks/common.zig` as a single shared function.

**Affected paths:** `benchmarks/bench.zig`, `benchmarks/scale_bench.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-011 -- Counter struct duplicated 3 times (Medium, PriorityScore 24)

**Impact:** 2 | **Likelihood:** 3 | **PriorityScore:** 2 \* 3 \* 4 = 24

**Category:** maintainability
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** A trivial `Counter` struct wrapping `std.atomic.Value(u64)` is defined independently in `examples/basic.zig:4`, `tests/common.zig:4`, and `benchmarks/common.zig:61`.

**Recommended change:** Define once in `tests/common.zig` (already public) and import in examples/benchmarks, or add to a shared test-util module.

**Affected paths:** `examples/basic.zig`, `tests/common.zig`, `benchmarks/common.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-013 -- DESIGN.md submitBatch signature stale (Medium, PriorityScore 24)

**Impact:** 2 | **Likelihood:** 3 | **PriorityScore:** 2 \* 3 \* 4 = 24

**Category:** docs
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** `docs/DESIGN.md:18` shows `submitBatch(tasks, options) !void` but the actual return type is `!Core.SubmitBatchResult` (pool.zig:649).

**Evidence:**

```text
// DESIGN.md:18
- `ThreadPool.submitBatch(tasks, options) !void`

// pool.zig:649
pub fn submitBatch(...) !Core.SubmitBatchResult {
```

**Recommended change:** Update DESIGN.md line 18 to `!SubmitBatchResult`.

**Affected paths:** `docs/DESIGN.md`

**Effort:** S
**Suggested owner:** @benji

---

### Q-014 -- No TaskState lifecycle documentation (Medium, PriorityScore 20)

**Impact:** 2 | **Likelihood:** 2 | **PriorityScore:** 2 \* 2 \* 5 = 20

**Category:** docs
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** The `TaskState` enum (types.zig:31-38) has 6 states (free, reserved, queued, running, completed, cancelled) but no documentation describing valid transitions, who performs them, or invariants.

**Recommended change:** Add a doc-comment with a state-transition table or ASCII diagram.

**Affected paths:** `src/thread_pool/types.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-015 -- Double-negation obscures cancellation intent (Medium, PriorityScore 20)

**Impact:** 2 | **Likelihood:** 2 | **PriorityScore:** 2 \* 2 \* 5 = 20

**Category:** readability
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** Line 449: `if (!(descriptor.options.cancellation_token != null and descriptor.options.cancellation_token.?.isCancelled()))` uses double negation making the logic hard to parse at a glance.

**Evidence:**

```zig
// pool.zig:449
if (!(descriptor.options.cancellation_token != null and descriptor.options.cancellation_token.?.isCancelled())) {
```

**Recommended change:** Rewrite as:

```zig
const cancelled = if (descriptor.options.cancellation_token) |token| token.isCancelled() else false;
if (!cancelled) {
```

**Affected paths:** `src/thread_pool/pool.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-017 -- Accounting struct recreated per call (Medium, PriorityScore 16)

**Impact:** 2 | **Likelihood:** 2 | **PriorityScore:** 2 \* 2 \* 4 = 16

**Category:** maintainability
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** `recordOwnedAlloc` and `recordOwnedFree` (pool.zig:572-589) construct a fresh `Accounting` struct on every call with the same four pointer fields. This is verbose but not a correctness or performance issue (the struct is stack-allocated with no heap cost).

**Recommended change:** Store a single `Accounting` field on Core initialized once in `init()`, or convert to a method that takes `self` directly.

**Affected paths:** `src/thread_pool/pool.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-019 -- private_peak_bytes misuses VmHWM (Low, PriorityScore 16)

**Impact:** 2 | **Likelihood:** 2 | **PriorityScore:** 2 \* 2 \* 4 = 16

**Category:** perf
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** `process_memory.zig:74` uses `VmHWM` (RSS high-water mark, includes shared pages) for `private_peak_bytes`. The field name implies private-only memory but VmHWM includes shared mappings.

**Evidence:**

```zig
// process_memory.zig:74
.private_peak_bytes = parseProcStatusKiB(contents, "VmHWM:") * 1024,
```

**Recommended change:** There is no kernel-exported private-peak metric. Either rename the field to `rss_peak_bytes` (same as `rss_peak_bytes` above, and remove the duplicate), or track private peak manually by sampling `RssAnon` over time.

**Affected paths:** `src/thread_pool/stats/process_memory.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-022 -- Dead CI job prepare-zig (Low, PriorityScore 16)

**Impact:** 2 | **Likelihood:** 2 | **PriorityScore:** 2 \* 2 \* 4 = 16

**Category:** ci-cd
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** The `prepare-zig` job (lines 37-42) runs `apt-get` and installs zig but produces no artifacts and no downstream job declares `needs: ["prepare-zig"]`. It wastes CI minutes on every pipeline.

**Recommended change:** Remove the job or convert it to produce a cached zig binary artifact that downstream jobs consume.

**Affected paths:** `.gitlab-ci.yml`

**Effort:** S
**Suggested owner:** @benji

---

### Q-023 -- CI before_script duplicated 14 times (Low, PriorityScore 16)

**Impact:** 2 | **Likelihood:** 2 | **PriorityScore:** 2 \* 2 \* 4 = 16

**Category:** ci-cd
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** The `before_script` block (`apt-get update && apt-get install ... && *install-zig`) is repeated in nearly every job. While YAML anchors are used for the zig install, the apt-get preamble is not DRY.

**Recommended change:** Create a `.base-job` template with the common before_script and use `extends: .base-job` in each concrete job.

**Affected paths:** `.gitlab-ci.yml`

**Effort:** S
**Suggested owner:** @benji

---

### Q-018 -- compare.zig leaks bytes buffer (Low, PriorityScore 12)

**Impact:** 2 | **Likelihood:** 2 | **PriorityScore:** 2 \* 2 \* 3 = 12

**Category:** perf
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** `readDocument` (compare.zig:45) allocates `bytes` via `readFileAlloc` but never frees it. The parsed JSON document references slices into `bytes`, so freeing requires careful lifecycle management.

**Evidence:**

```zig
// compare.zig:45
const bytes = try std.fs.cwd().readFileAlloc(allocator, path, 8 * 1024 * 1024);
// bytes never freed -- parsed JSON references it
```

**Recommended change:** Use an ArenaAllocator scoped to the comparison operation so both the bytes and the parsed document are freed together.

**Affected paths:** `benchmarks/compare.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-024 -- Pre-commit zig-fmt excludes benchmarks/examples (Low, PriorityScore 12)

**Impact:** 2 | **Likelihood:** 2 | **PriorityScore:** 2 \* 2 \* 3 = 12

**Category:** ci-cd
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** The pre-commit `zig-fmt` hook (line 69) only checks `src/`, `tests/`, and `build.zig`. Files in `benchmarks/` and `examples/` can drift from formatting standards.

**Evidence:**

```yaml
# .pre-commit-config.yaml:69
args: [src/, tests/, build.zig]
```

**Recommended change:** Add `benchmarks/` and `examples/` to the args list.

**Affected paths:** `.pre-commit-config.yaml`

**Effort:** S
**Suggested owner:** @benji

---

### Q-020 -- Unreferenced version constant (Low, PriorityScore 8)

**Impact:** 1 | **Likelihood:** 2 | **PriorityScore:** 1 \* 2 \* 4 = 8

**Category:** maintainability
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** `root.zig:16` declares `pub const version = "0.2.0"` which duplicates `build.zig.zon` line 3. No code references `version`, creating drift risk when the zon version is bumped.

**Recommended change:** Either remove the constant and direct consumers to `build.zig.zon`, or generate it from build.zig at comptime using `@embedFile` on `build.zig.zon`.

**Affected paths:** `src/root.zig`, `build.zig.zon`

**Effort:** S
**Suggested owner:** @benji

---

### Q-021 -- CODEOWNERS placeholder (Low, PriorityScore 8)

**Impact:** 1 | **Likelihood:** 2 | **PriorityScore:** 1 \* 2 \* 4 = 8

**Category:** cleanup
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** `CODEOWNERS:3` contains `* @your-username` -- a scaffold placeholder that provides no actual ownership enforcement.

**Recommended change:** Replace `@your-username` with the actual GitLab username (e.g., `@benji`).

**Affected paths:** `CODEOWNERS`

**Effort:** S
**Suggested owner:** @benji

---

## Findings by Category

### architecture (3)

- Q-001 (Critical, 100) -- descriptor.state data race
- Q-003 (High, 80) -- deinit() hangs forever
- Q-007 (Medium, 48) -- parseOutputArg dangling pointer

### api-contract (3)

- Q-002 (High, 60) -- Stats.active_workers semantic mismatch
- Q-005 (Medium, 48) -- Dead Config fields
- Q-006 (Medium, 36) -- Non-functional enum variants

### tests (1)

- Q-004 (High, 80) -- Zero coverage on critical paths

### maintainability (6)

- Q-016 (Medium, 36) -- Core struct overly flat
- Q-008 (Medium, 24) -- updatePeak duplicated
- Q-010 (Medium, 24) -- parseOutputArg duplicated
- Q-011 (Medium, 24) -- Counter struct duplicated
- Q-017 (Medium, 16) -- Accounting struct recreated per call
- Q-020 (Low, 8) -- Unreferenced version constant

### docs (3)

- Q-012 (Medium, 36) -- No doc comments on public API
- Q-013 (Medium, 24) -- DESIGN.md submitBatch signature stale
- Q-014 (Medium, 20) -- No TaskState lifecycle documentation

### perf (3)

- Q-009 (Medium, 36) -- nowNs() inconsistent
- Q-019 (Low, 16) -- private_peak_bytes misuses VmHWM
- Q-018 (Low, 12) -- compare.zig leaks bytes buffer

### readability (1)

- Q-015 (Medium, 20) -- Double-negation in cancellation check

### ci-cd (3)

- Q-022 (Low, 16) -- Dead CI job
- Q-023 (Low, 16) -- CI before_script duplicated
- Q-024 (Low, 12) -- Pre-commit excludes directories

### cleanup (1)

- Q-021 (Low, 8) -- CODEOWNERS placeholder

## Remediation Roadmap

### Quick Wins (< 1 day each)

| ID | Fix | Effort |
|----|-----|--------|
| Q-001 | Make descriptor.state atomic or acquire completion_mutex on write | S |
| Q-002 | Rename Stats field to active_tasks | S |
| Q-007 | Dupe the string or remove defer in parseOutputArg | S |
| Q-010 | Move parseOutputArg to benchmarks/common.zig | S |
| Q-013 | Update DESIGN.md:18 return type | S |
| Q-015 | Simplify double-negation | S |
| Q-021 | Replace @your-username in CODEOWNERS | S |
| Q-024 | Add benchmarks/ and examples/ to pre-commit args | S |
| Q-020 | Remove root.zig version constant | S |
| Q-022 | Remove or repurpose prepare-zig CI job | S |
| Q-008 | Extract updatePeak to shared module | S |
| Q-011 | Deduplicate Counter to one location | S |

### Medium (1-5 days)

| ID | Fix | Effort |
|----|-----|--------|
| Q-003 | Add configurable deinit timeout + watchdog diagnostic | S-M |
| Q-004 | Write tests for CancellationToken, trySubmit, backpressure, shutdown timeout | M |
| Q-005 | Add validation/warnings for dead Config fields | S-M |
| Q-006 | Gate unimplemented enum variants | S |
| Q-009 | Unify nowNs() across all modules | S |
| Q-012 | Add doc-comments to all public API symbols | M |
| Q-014 | Document TaskState lifecycle | S |
| Q-016 | Refactor Core into logical sub-structs | M |
| Q-017 | Store Accounting as a Core field | S |
| Q-019 | Rename or fix private_peak_bytes metric | S |
| Q-023 | DRY CI before_script with extends | S |

### Strategic (> 5 days)

| ID | Fix | Effort |
|----|-----|--------|
| Q-018 | Introduce ArenaAllocator pattern in compare.zig and audit all benchmark memory | S-M |

---

## Scoring Methodology

```text
PriorityScore = Impact(1-5) * Likelihood(1-5) * 4
```

- **Impact**: 5=outage/UB, 4=frequent bugs/major dev drag, 3=moderate, 2=minor, 1=polish
- **Likelihood**: 5=ubiquitous/touched often, 4=often encountered, 3=sometimes, 2=rare, 1=edge-case
- All findings tagged `confidence::confirmed` -- verified via direct code inspection.
