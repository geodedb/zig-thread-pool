# Quality Gap Analysis

Last updated: 2026-04-11

## Summary

| Severity | Open | Closed | Won't Do | Total |
|----------|------|--------|----------|-------|
| Critical | 1 | 0 | 0 | 1 |
| High | 2 | 1 | 0 | 3 |
| Medium | 3 | 9 | 1 | 13 |
| Low | 3 | 4 | 0 | 7 |
| **Total** | **9** | **14** | **1** | **24** |

### Top 5 Remaining Risks

1. **Q-001** descriptor.state data race -- non-atomic writes read under mutex on non-TSO architectures (UB)
2. **Q-004** Zero test coverage on CancellationToken, trySubmit, backpressure, QueueFull, shutdown-timeout paths
3. **Q-002** Stats.active_workers reports task count not worker count -- API contract violation
4. **Q-005** Three dead Config fields silently accepted, nothing happens at runtime
5. **Q-006** TaskLane.keyed and SchedulerVariant.lane_extension non-functional enum variants

## Stack-Ranked Findings (Open Items Only)

| Rank | ID | Severity | PriorityScore | Category | Finding | Component | Issue URL | Status |
|------|------|----------|---------------|----------|---------|-----------|-----------|--------|
| 1 | Q-001 | Critical | 100 | architecture | descriptor.state data race: written non-atomically, read under mutex | pool.zig:427,466-468,187 | -- | Open |
| 2 | Q-004 | High | 80 | tests | Zero coverage: CancellationToken, trySubmit, backpressure, QueueFull, shutdown timeout | tests/*.zig | -- | Open |
| 3 | Q-002 | High | 60 | api-contract | Stats.active_workers populated from active_tasks counter | pool.zig:261 | -- | Open |
| 4 | Q-005 | Medium | 48 | api-contract | 3 dead Config fields: idle_shrink_after_ns, stats_enabled, allocator_mode | types.zig:49,58,59 | -- | Open |
| 5 | Q-006 | Medium | 36 | api-contract | TaskLane.keyed and SchedulerVariant.lane_extension non-functional | types.zig:6,17 | -- | Open |
| 6 | Q-009 | Medium | 36 | perf | nowNs() inconsistent: pool clamps negatives, benchmarks panic | pool.zig:674, common.zig:427 | -- | Open |
| 7 | Q-018 | Low | 12 | perf | compare.zig readDocument leaks raw bytes buffer | compare.zig:45 | -- | Open |
| 8 | Q-020 | Low | 8 | maintainability | version constant in root.zig unreferenced and duplicates build.zig.zon | root.zig:16 | -- | Open |
| 9 | Q-021 | Low | 8 | cleanup | CODEOWNERS contains placeholder @your-username | CODEOWNERS:3 | -- | Open |

> **Note:** 15 items closed and 1 won't-do have been moved to `docs/GAP_ANALYSIS_RESOLVED.md`.

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

## Findings by Category (Open Items Only)

### architecture (1)

- Q-001 (Critical, 100) -- descriptor.state data race

### api-contract (3)

- Q-002 (High, 60) -- Stats.active_workers semantic mismatch
- Q-005 (Medium, 48) -- Dead Config fields
- Q-006 (Medium, 36) -- Non-functional enum variants

### tests (1)

- Q-004 (High, 80) -- Zero coverage on critical paths

### maintainability (1)

- Q-020 (Low, 8) -- Unreferenced version constant

### perf (2)

- Q-009 (Medium, 36) -- nowNs() inconsistent
- Q-018 (Low, 12) -- compare.zig leaks bytes buffer

### cleanup (1)

- Q-021 (Low, 8) -- CODEOWNERS placeholder

## Remediation Roadmap (Open Items Only)

### Quick Wins (< 1 day each)

| ID | Fix | Effort |
|----|-----|--------|
| Q-001 | Make descriptor.state atomic or acquire completion_mutex on write | S |
| Q-002 | Rename Stats field to active_tasks | S |
| Q-021 | Replace @your-username in CODEOWNERS | S |
| Q-020 | Remove root.zig version constant | S |

### Medium (1-5 days)

| ID | Fix | Effort |
|----|-----|--------|
| Q-004 | Write tests for CancellationToken, trySubmit, backpressure, shutdown timeout | M |
| Q-005 | Add validation/warnings for dead Config fields | S-M |
| Q-006 | Gate unimplemented enum variants | S |
| Q-009 | Unify nowNs() across all modules | S |

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
