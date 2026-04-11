# Quality Gap Analysis

Last updated: 2026-04-11

## Summary

| Severity | Open | Resolved | Closed | Won't Do | Total |
|----------|------|----------|--------|----------|-------|
| Critical | 0 | 1 | 0 | 0 | 1 |
| High | 0 | 2 | 2 | 0 | 4 |
| Medium | 3 | 3 | 9 | 1 | 16 |
| Low | 9 | 0 | 4 | 0 | 13 |
| **Total** | **12** | **6** | **15** | **1** | **34** |

### Top 5 Remaining Risks

1. ~~**Q-022** Stats.wakeups permanently zero~~ -- Closed: commit da32fee
2. **Q-004** Remaining test coverage gap -- `.block` backpressure policy path still untested
3. **Q-023** deinitOwned missing recordOwnedFree for inject_queue buffer -- accounting asymmetry
4. **Q-024** process_memory.private_peak_bytes reports current not peak on Linux -- reads RssAnon instead of VmHWM
5. **Q-025** submitBatch doc comment says "atomically" but behavior is sequential with partial failure

## Stack-Ranked Findings (Open Items Only)

| Rank | ID | Severity | PriorityScore | Category | Finding | Component | Issue URL | Status |
|------|------|----------|---------------|----------|---------|-----------|-----------|--------|
| 1 | Q-022 | High | 60 | api-contract | Stats.wakeups permanently zero: counters.wakeups never incremented | pool.zig:93,316 | -- | Closed |
| 2 | Q-023 | Medium | 40 | maintainability | deinitOwned missing recordOwnedFree for inject_queue buffer | pool.zig:678 vs :149 | -- | Open |
| 3 | Q-024 | Medium | 40 | api-contract | process_memory.private_peak_bytes reports current not peak on Linux | process_memory.zig:73-74 | -- | Open |
| 4 | Q-004 | Medium | 28 | tests | Remaining gap: .block backpressure policy untested | tests/*.zig | -- | Partially Fixed |
| 5 | Q-025 | Medium | 24 | docs | submitBatch doc says "atomically" but behavior is sequential with partial failure | pool.zig:745-748 | -- | Open |
| 6 | Q-028 | Low | 18 | docs | DESIGN.md says inject queue is "Mutex-protected" but it is lock-free Vyukov MPMC | DESIGN.md:52, bounded_ring.zig:2 | -- | Open |
| 7 | Q-029 | Low | 18 | docs | DESIGN.md says work-stealing "is not currently lock-free" but it uses Chase-Lev deque | DESIGN.md:99 vs :60 | -- | Open |
| 8 | Q-006 | Low | 12 | api-contract | lane_extension still exists but validate() rejects it; stale variant | types.zig:6,99 | -- | Partially Fixed |
| 9 | Q-018 | Low | 12 | perf | compare.zig readDocument leak mitigated by ArenaAllocator but no explicit free | compare.zig:45 | -- | Open |
| 10 | Q-026 | Low | 12 | readability | Core.waitGroup() ignores self parameter -- static constructor disguised as method | pool.zig:244-247 | -- | Open |
| 11 | Q-030 | Low | 12 | maintainability | Code duplication: nowNs() in 2 files, Counter struct in 3 files, updatePeak in 2 files | pool.zig, common.zig, tests/common.zig, scratch.zig | -- | Open |
| 12 | Q-020 | Low | 8 | maintainability | version constant in root.zig unreferenced and duplicates build.zig.zon | root.zig:16 | -- | Open |
| 13 | Q-021 | Low | 8 | cleanup | CODEOWNERS contains placeholder @your-username | CODEOWNERS:3 | -- | Open |
| 14 | Q-027 | Low | 8 | readability | Magic sentinel 0xFFFFFFFF used as raw literal; free_sentinel constant exists | pool.zig:158 vs :613 | -- | Open |

> **Note:** 14 items closed and 1 won't-do have been moved to `docs/GAP_ANALYSIS_RESOLVED.md`.

## Recently Resolved Findings

The following findings were confirmed fixed during the 2026-04-11 audit:

| ID | Severity | PriorityScore | Finding | Resolution | Status |
|------|----------|---------------|---------|------------|--------|
| Q-001 | Critical | 100 | descriptor.state data race | Now `std.atomic.Value(TaskState)` with `.load(.acquire)` reads and atomic stores | Resolved |
| Q-002 | High | 60 | Stats.active_workers semantic mismatch | Field renamed to `active_tasks` throughout; correctly populated | Resolved |
| Q-005 | Medium | 48 | Dead Config fields silently ignored | `idle_shrink_after_ns`, `stats_enabled`, `allocator_mode` all removed | Resolved |
| Q-009 | Medium | 36 | nowNs() inconsistency across modules | Both implementations now use identical safe-cast pattern with negative clamping | Resolved |
| Q-004 | High | 80 -> 28 | Zero test coverage on critical paths | CancellationToken, trySubmit, block_with_timeout, shutdown timeout all tested; only `.block` backpressure untested (downgraded to Medium, rescored) | Partially Fixed |
| Q-006 | Medium | 36 -> 12 | Non-functional public enum variants | `TaskLane.keyed` removed; `lane_extension` still exists but `validate()` rejects it (downgraded to Low, rescored) | Partially Fixed |

## Detailed Findings

---

### Q-022 -- Stats.wakeups permanently zero (High, PriorityScore 60) [CLOSED]

**Status:** Closed
**Resolution:** `statsSnapshot()` now aggregates wakeups from per-worker counters by summing `worker.wakeups.load(.acquire)` across all workers, matching the pattern used for other per-worker stats. Commit da32fee.
**Evidence:** `src/thread_pool/pool.zig` -- statsSnapshot wakeups aggregation loop.
**Resolved date:** 2026-04-11

---

### Q-023 -- deinitOwned missing recordOwnedFree for inject_queue (Medium, PriorityScore 40)

**Impact:** 2 | **Likelihood:** 5 | **PriorityScore:** 2 \* 5 \* 4 = 40

**Category:** maintainability
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** In `init()`, pool.zig:149 calls `self.recordOwnedAlloc(self.inject_queue.capacity() * @sizeOf(u32))` to track the inject queue's buffer allocation. However, `deinitOwned()` (pool.zig:678) calls `self.inject_queue.deinit()` without a preceding `recordOwnedFree` for the same size. Every other allocation in `deinitOwned` has a matching `recordOwnedFree` call.

**Evidence:**

```zig
// pool.zig:149 -- allocation tracked
self.recordOwnedAlloc(self.inject_queue.capacity() * @sizeOf(u32));

// pool.zig:678 -- freed but NOT tracked (asymmetry)
self.inject_queue.deinit();
// compare with pool.zig:679-687 where every other free is tracked
self.recordOwnedFree(self.worker_stats_buffer.len * @sizeOf(types.WorkerStats));
```

**Root cause:** The inject_queue free was likely added later and the accounting call was missed.

**Recommended change:** Insert `self.recordOwnedFree(self.inject_queue.capacity() * @sizeOf(u32));` before `self.inject_queue.deinit();` on pool.zig:678.

**Acceptance criteria:** `live_bytes` reaches 0 after full pool teardown.

**Verification:** Add assertion in test that `stats.live_bytes == 0` after `pool.deinit()`.

**Affected paths:** `src/thread_pool/pool.zig`

**Effort:** S (< 1 day)
**Suggested owner:** @benji

---

### Q-024 -- process_memory.private_peak_bytes reports current not peak on Linux (Medium, PriorityScore 40)

**Impact:** 2 | **Likelihood:** 5 | **PriorityScore:** 2 \* 5 \* 4 = 40

**Category:** api-contract
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** On Linux, `private_peak_bytes` is populated by reading the `RssAnon:` field from `/proc/self/status` (process_memory.zig:74). This reports the *current* anonymous RSS, not the peak. The correct field for peak anonymous memory is not available in `/proc/self/status`, but at minimum the current and peak fields should not both read the same source.

**Evidence:**

```zig
// process_memory.zig:73-74 -- both read the same field
.private_current_bytes = parseProcStatusKiB(contents, "RssAnon:") * 1024,
.private_peak_bytes = parseProcStatusKiB(contents, "RssAnon:") * 1024,
```

On macOS, the correct distinction is made (`resident_size` vs `resident_size_max`). On Windows, `PeakPagefileUsage` is used. Only Linux is incorrect.

**Root cause:** Linux's `/proc/self/status` does not expose a peak-anonymous-RSS field, so the current value was used as a placeholder.

**Recommended change:** Either (a) track peak in-process using an atomic high-water mark updated each time private_current_bytes is sampled, or (b) document that `private_peak_bytes` is approximate on Linux. At minimum, add a code comment explaining the limitation.

**Acceptance criteria:** `private_peak_bytes >= private_current_bytes` is an invariant, enforced either by tracking or by documentation of the limitation.

**Verification:** Run a benchmark that allocates and frees memory, verify `private_peak_bytes` is at least as large as the maximum observed `private_current_bytes`.

**Affected paths:** `src/thread_pool/stats/process_memory.zig`

**Effort:** S (< 1 day)
**Suggested owner:** @benji

---

### Q-004 -- Remaining test coverage gap: .block backpressure (Medium, PriorityScore 28)

**Impact:** 2 | **Likelihood:** 3 | **PriorityScore:** 2 \* 3 \* 4 + 4 = 28

**Category:** tests
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** The original Q-004 finding (zero test coverage on critical paths) has been mostly addressed. CancellationToken, trySubmit, block_with_timeout, and shutdown timeout all have dedicated tests in `tests/unit.zig`. The remaining gap is the `.block` backpressure policy (blocking indefinitely until space is available), which has no dedicated test.

**Evidence:** Grepping `tests/*.zig` for `backpressure` and `.block` returns only `block_with_timeout` references. No test exercises the `.block` (infinite wait) path.

**Root cause:** The `.block` policy is the simplest variant and was likely considered implicitly tested through other paths.

**Recommended change:** Add a test that fills the queue, spawns a thread that submits with `.block` backpressure, drains one slot from another thread, and asserts the blocked submit eventually succeeds.

**Acceptance criteria:** `test "block backpressure eventually succeeds"` passes in `zig build test --summary all`.

**Verification:** `zig build test --summary all` -- new test passes.

**Affected paths:** `tests/unit.zig`

**Effort:** S (< 1 day)
**Suggested owner:** @benji

---

### Q-025 -- submitBatch doc says "atomically" but behavior is sequential (Medium, PriorityScore 24)

**Impact:** 2 | **Likelihood:** 3 | **PriorityScore:** 2 \* 3 \* 4 = 24

**Category:** docs
**Confidence:** confidence::confirmed
**Severity:** Medium

**Summary:** The doc comment at pool.zig:745 says `/// Submit multiple tasks atomically.` but the implementation (pool.zig:213-221) is a sequential loop that calls `self.submit()` for each task individually. If the first task succeeds but a later one fails, the function returns a partial `SubmitBatchResult` with the count of successfully submitted tasks. This is explicitly non-atomic behavior.

**Evidence:**

```zig
// pool.zig:745
/// Submit multiple tasks atomically. Returns the count of tasks

// pool.zig:213-221 -- sequential loop, partial failure possible
pub fn submitBatch(self: *Core, tasks: []const BatchTask, options: types.SubmitOptions) !SubmitBatchResult {
    for (tasks, 0..) |task, idx| {
        _ = self.submit(task.task_fn, task.ctx, options) catch |err| {
            if (idx == 0) return err;
            return .{ .submitted = idx };  // partial result
        };
    }
    return .{ .submitted = tasks.len };
}
```

**Root cause:** Doc comment was aspirational; the implementation prioritized simplicity.

**Recommended change:** Update the doc comment to say `/// Submit multiple tasks sequentially. Returns the count of tasks successfully enqueued. If the first task fails, the error propagates; subsequent failures return a partial result.` (This text already partially appears on lines 746-747.)

**Acceptance criteria:** Doc comment accurately describes non-atomic, partial-failure behavior.

**Verification:** Read the doc comment and confirm it matches implementation semantics.

**Affected paths:** `src/thread_pool/pool.zig`

**Effort:** S (< 1 day)
**Suggested owner:** @benji

---

### Q-028 -- DESIGN.md says inject queue is "Mutex-protected" (stale) (Low, PriorityScore 18)

**Impact:** 2 | **Likelihood:** 3 | **PriorityScore:** 2 \* 3 \* 3 = 18

**Category:** docs
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** DESIGN.md line 52 describes the inject queue as `Mutex-protected, no unbounded growth.` However, the inject queue is now implemented as a lock-free Vyukov MPMC bounded ring buffer (see `src/thread_pool/queue/bounded_ring.zig` line 2: `/// Lock-free bounded MPMC queue (Vyukov design).`). The documentation is stale.

**Evidence:**

```text
// DESIGN.md:52
- Mutex-protected, no unbounded growth.

// bounded_ring.zig:2
/// Lock-free bounded MPMC queue (Vyukov design).
```

**Recommended change:** Update DESIGN.md:52 to `Lock-free bounded MPMC ring (Vyukov design), no unbounded growth.`

**Affected paths:** `docs/DESIGN.md`

**Effort:** S (< 1 day)
**Suggested owner:** @benji

---

### Q-029 -- DESIGN.md says work-stealing "is not currently lock-free" (stale) (Low, PriorityScore 18)

**Impact:** 2 | **Likelihood:** 3 | **PriorityScore:** 2 \* 3 \* 3 = 18

**Category:** docs
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** DESIGN.md line 99 states `work_stealing reduces multi-producer contention and improves local handoff, but it is not currently lock-free.` This contradicts DESIGN.md line 60 which correctly states `The local deque uses a lock-free Chase-Lev design.` The implementation (`src/thread_pool/queue/work_deque.zig`) is indeed a lock-free Chase-Lev deque. The inject queue is also lock-free (Vyukov MPMC). The entire work-stealing path is now lock-free.

**Evidence:**

```text
// DESIGN.md:99 -- stale claim
- `work_stealing` reduces multi-producer contention and improves local handoff, but it is not currently lock-free.

// DESIGN.md:60 -- contradicts line 99
- The local deque uses a lock-free Chase-Lev design.
```

**Recommended change:** Update DESIGN.md:99 to `work_stealing reduces multi-producer contention and improves local handoff via lock-free Chase-Lev deques and a lock-free Vyukov inject queue.`

**Affected paths:** `docs/DESIGN.md`

**Effort:** S (< 1 day)
**Suggested owner:** @benji

---

### Q-006 -- lane_extension variant partially addressed (Low, PriorityScore 12)

**Impact:** 2 | **Likelihood:** 2 | **PriorityScore:** 2 \* 2 \* 3 = 12

**Category:** api-contract
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** The original Q-006 identified two non-functional enum variants: `TaskLane.keyed` and `SchedulerVariant.lane_extension`. `TaskLane.keyed` has been removed. `SchedulerVariant.lane_extension` still exists (types.zig:6) but `validate()` now returns `error.UnsupportedSchedulerVariant` if selected (types.zig:99), with a test covering this at types.zig:233-234. The variant remains as a placeholder for future work; it is no longer silently accepted.

**Evidence:**

```zig
// types.zig:99 -- validate() rejects it
if (self.scheduler_variant == .lane_extension) return error.UnsupportedSchedulerVariant;

// types.zig:233-234 -- test coverage
test "Config validation rejects lane_extension variant" {
    var cfg = Config{ .max_threads = 2, .min_threads = 1, .scheduler_variant = .lane_extension };
```

**Remaining concern:** The variant is public and could confuse users who discover it via autocomplete before reading docs.

**Recommended change:** Add a doc comment `/// Reserved for future use. Selecting this variant returns UnsupportedSchedulerVariant at validation.`

**Affected paths:** `src/thread_pool/types.zig`

**Effort:** S (< 1 day)
**Suggested owner:** @benji

---

### Q-018 -- compare.zig leaks bytes buffer (Low, PriorityScore 12)

**Impact:** 2 | **Likelihood:** 2 | **PriorityScore:** 2 \* 2 \* 3 = 12

**Category:** perf
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** `readDocument` (compare.zig:45) allocates `bytes` via `readFileAlloc` but never frees it. The parsed JSON document references slices into `bytes`, so freeing requires careful lifecycle management. Mitigated by ArenaAllocator in the caller but no explicit free.

**Recommended change:** Ensure the ArenaAllocator pattern covers the entire comparison operation lifecycle so both bytes and parsed document are freed together.

**Affected paths:** `benchmarks/compare.zig`

**Effort:** S
**Suggested owner:** @benji

---

### Q-026 -- Core.waitGroup() ignores self parameter (Low, PriorityScore 12)

**Impact:** 1 | **Likelihood:** 3 | **PriorityScore:** 1 \* 3 \* 4 = 12

**Category:** readability
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** `Core.waitGroup()` at pool.zig:244-247 takes `self: *Core` but immediately discards it with `_ = self;` and returns a default-initialized `WaitGroup`. This is a static constructor disguised as a method, which is misleading.

**Evidence:**

```zig
// pool.zig:244-247
pub fn waitGroup(self: *Core) types.WaitGroup {
    _ = self;
    return .{};
}
```

**Root cause:** Placeholder for future implementation that will likely need the Core reference.

**Recommended change:** Either (a) make this a static function `pub fn waitGroup() types.WaitGroup { return .{}; }` until it needs pool state, or (b) add a doc comment explaining why `self` is taken but unused (future use).

**Affected paths:** `src/thread_pool/pool.zig`

**Effort:** S (< 1 day)
**Suggested owner:** @benji

---

### Q-030 -- Code duplication across modules (Low, PriorityScore 12)

**Impact:** 1 | **Likelihood:** 3 | **PriorityScore:** 1 \* 3 \* 4 = 12

**Category:** maintainability
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** Several utility constructs are duplicated across multiple files:

1. **`nowNs()`** -- Identical implementation in `pool.zig:791` and `benchmarks/common.zig:459`.
2. **`Counter` struct** -- Semantically identical atomic counter in `benchmarks/common.zig:61`, `tests/common.zig:4`, and `examples/basic.zig:4`.
3. **`updatePeak` / `updatePeakU32`** -- CAS loop in `memory/scratch.zig:24` (`updatePeak` for u64) and `pool.zig:798` (`updatePeakU32` for u32). Pool.zig:796 aliases `Accounting.updatePeak` but keeps a separate u32 variant.

**Root cause:** Independent development of benchmark/test utilities without a shared utility module.

**Recommended change:** Extract shared utilities into a common module. For `nowNs()`, a single `pub fn nowNs()` in a shared file imported by both pool and benchmarks. For `Counter`, a shared test helper. For `updatePeak`, consider a generic version parameterized on the atomic value type.

**Affected paths:** `src/thread_pool/pool.zig`, `benchmarks/common.zig`, `tests/common.zig`, `examples/basic.zig`, `src/thread_pool/memory/scratch.zig`

**Effort:** S-M
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

### Q-027 -- Magic sentinel literal instead of named constant (Low, PriorityScore 8)

**Impact:** 1 | **Likelihood:** 2 | **PriorityScore:** 1 \* 2 \* 4 = 8

**Category:** readability
**Confidence:** confidence::confirmed
**Severity:** Low

**Summary:** The free-list initialization at pool.zig:158 uses the raw literal `0xFFFFFFFF` to mark the end of the list. A named constant `free_sentinel` with the same value already exists at pool.zig:613 and is used in `acquireDescriptor`. The initialization code should use the constant for consistency and readability.

**Evidence:**

```zig
// pool.zig:154-158 -- raw literal
// The last slot uses the sentinel 0xFFFFFFFF (empty).
self.free_indices[idx] = if (idx + 1 < normalized.queue_capacity)
    @as(u32, @intCast(idx + 1))
else
    0xFFFFFFFF;

// pool.zig:613 -- named constant exists
const free_sentinel: u32 = 0xFFFFFFFF;
```

**Recommended change:** Replace `0xFFFFFFFF` on pool.zig:158 with `free_sentinel`. May need to move the constant declaration above the `init` function or make it a module-level const.

**Affected paths:** `src/thread_pool/pool.zig`

**Effort:** S (< 1 day)
**Suggested owner:** @benji

---

## Findings by Category (Open Items Only)

### api-contract (2)

- ~~Q-022 (High, 60) -- Stats.wakeups permanently zero~~ -- Closed: commit da32fee
- Q-024 (Medium, 40) -- process_memory.private_peak_bytes incorrect on Linux
- Q-006 (Low, 12) -- lane_extension variant partially addressed

### maintainability (2)

- Q-023 (Medium, 40) -- deinitOwned accounting asymmetry
- Q-030 (Low, 12) -- Code duplication across modules
- Q-020 (Low, 8) -- Unreferenced version constant

### tests (1)

- Q-004 (Medium, 28) -- .block backpressure untested

### docs (3)

- Q-025 (Medium, 24) -- submitBatch doc-comment inaccuracy
- Q-028 (Low, 18) -- DESIGN.md inject queue description stale
- Q-029 (Low, 18) -- DESIGN.md work-stealing lock-free claim stale

### readability (2)

- Q-026 (Low, 12) -- waitGroup() ignores self
- Q-027 (Low, 8) -- Magic sentinel literal

### perf (1)

- Q-018 (Low, 12) -- compare.zig leaks bytes buffer

### cleanup (1)

- Q-021 (Low, 8) -- CODEOWNERS placeholder

## Remediation Roadmap (Open Items Only)

### Quick Wins (< 1 day each)

| ID | Fix | Effort |
|----|-----|--------|
| Q-022 | ~~Sum per-worker wakeups in statsSnapshot()~~ | Done -- commit da32fee |
| Q-023 | Add recordOwnedFree before inject_queue.deinit() | S |
| Q-024 | Track private peak via atomic high-water mark or document Linux limitation | S |
| Q-025 | Update submitBatch doc comment to say "sequentially" not "atomically" | S |
| Q-027 | Replace 0xFFFFFFFF literal with free_sentinel constant | S |
| Q-026 | Make waitGroup() static or add doc comment explaining future self usage | S |
| Q-028 | Update DESIGN.md inject queue description to "Lock-free Vyukov MPMC" | S |
| Q-029 | Remove "is not currently lock-free" claim from DESIGN.md | S |
| Q-021 | Replace @your-username in CODEOWNERS | S |
| Q-020 | Remove root.zig version constant or generate from build.zig.zon | S |
| Q-006 | Add doc comment to lane_extension variant | S |

### Medium (1-5 days)

| ID | Fix | Effort |
|----|-----|--------|
| Q-004 | Write test for .block backpressure policy | S |
| Q-030 | Extract shared nowNs(), Counter, updatePeak into common utility | S-M |
| Q-018 | Audit benchmark memory lifecycle, ensure ArenaAllocator pattern covers all paths | S-M |

### Strategic (> 5 days)

None currently. All remaining findings are quick wins or medium effort.

---

## Scoring Methodology

```text
PriorityScore = Impact(1-5) * Likelihood(1-5) * 4
```

- **Impact**: 5=outage/UB, 4=frequent bugs/major dev drag, 3=moderate, 2=minor, 1=polish
- **Likelihood**: 5=ubiquitous/touched often, 4=often encountered, 3=sometimes, 2=rare, 1=edge-case
- All findings tagged `confidence::confirmed` -- verified via direct code inspection.
