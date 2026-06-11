# Audit Remediation 2026-06-11 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close all 45 NOW-actionable gaps from the 2026-06-11 full audit (issues #92–#125 plus older quick wins) with TDD, one commit per gap or coherent gap group.

**Architecture:** Surgical fixes to an existing Zig 0.16.0 thread-pool library. No structural refactors (those are deferred). Each task is independently testable and committable. Branch: `audit-2026-06-11`.

**Tech Stack:** Zig 0.16.0 (`zig` on PATH — do NOT use `./zig-0.15.2/zig`). Validation: `zig build test --summary all`, `zig build test-integration --summary all`, `zig fmt --check src tests benchmarks examples`, `zig build check`.

**Conventions:**
- Commit format: `fix: close GAP-XXXX - <title> (#issue)` or `docs: ...` for doc-only.
- Pre-commit hooks run automatically (markdownlint may auto-fix `.md` files — re-add and re-commit if the hook modifies files).
- After EVERY code change: `zig fmt src tests benchmarks examples` before committing (the repo gates on fmt).
- Line numbers cited below are from commit `39528a3` and may drift ±5 lines as earlier tasks land; verify context before editing.

---

### Task 1: GAP-0036 / AP-01 — Monotonic clock (#92)

**Files:**
- Modify: `src/clock.zig:14-17`
- Modify: `src/sync.zig:48-53`
- Modify: `src/pool.zig:2019` (recordTaskStart), `src/pool.zig:2113` (finalizeTask)
- Test: `tests/unit.zig` (append)

- [ ] **Step 1: Write the failing-ish regression test** (it passes already for monotonicity but pins the contract; the real fix is the clock source change)

```zig
test "clock: nanoTimestamp is monotonic non-decreasing" {
    const clock = @import("thread_pool").clock_for_testing; // see Step 3 if not exported
    var prev = clock.nanoTimestamp();
    var i: usize = 0;
    while (i < 1000) : (i += 1) {
        const now = clock.nanoTimestamp();
        try std.testing.expect(now >= prev);
        prev = now;
    }
}
```

If `clock` is not reachable from tests, add `pub const clock_for_testing = @import("clock.zig");` to `src/root.zig` (near the other re-exports) — or test via `src/clock.zig`'s own `test` block if tests/unit.zig cannot import it; an in-file `test` in `src/clock.zig` is acceptable (the unit test build includes src module tests at the file level only if referenced — verify with `zig build test --summary all` that the test runs; if not, put it in `tests/unit.zig` with the re-export).

- [ ] **Step 2: Change the clock source `.real` → `.awake`** in `src/clock.zig:16`:

```zig
pub fn nanoTimestamp() i96 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Clock.Timestamp.now(io, .awake).raw.nanoseconds;
}
```

Update the module doc comment to note the monotonic (`.awake` = CLOCK_MONOTONIC) source and why (AP-01: backward wall-clock steps must not underflow interval math).

- [ ] **Step 3: Change `src/sync.zig:51` deadline clock `.real` → `.awake`:**

```zig
    pub fn timedWait(self: *Condition, m: *Mutex, timeout_ns: u64) error{Timeout}!void {
        return self.waitInner(m, .{ .duration = .{
            .raw = .fromNanoseconds(@intCast(timeout_ns)),
            .clock = .awake,
        } });
    }
```

- [ ] **Step 4: Belt-and-braces saturating subtraction at the two histogram sites.** In `src/pool.zig` find (recordTaskStart, ~:2019) `const wait_ns = start_ns - descriptor.submit_ns;` → `const wait_ns = start_ns -| descriptor.submit_ns;` and (finalizeTask, ~:2113) `const exec_ns = complete_ns - start_ns;` → `const exec_ns = complete_ns -| start_ns;`

- [ ] **Step 5: Run** `zig build test --summary all` and `zig build test-integration --summary all` — expect all pass (68/69 + 26/26).

- [ ] **Step 6: Commit** `fix: close GAP-0036 - use monotonic clock for interval math (AP-01, #92)`

---

### Task 2: Q-NEW-02 — Reject waitable in submitBatch (#107)

**Files:**
- Modify: `src/pool.zig` `Core.submitBatch` (~:836, right after the `tasks.len == 0` check) and public wrapper doc (~:2637)
- Test: `tests/unit.zig` (append)

- [ ] **Step 1: Write the failing test:**

```zig
test "submitBatch rejects waitable options (Q-NEW-02 descriptor leak guard)" {
    const tp = @import("thread_pool");
    var pool = try tp.ThreadPool.init(std.testing.allocator, .{ .max_threads = 1, .queue_capacity = 8 });
    defer pool.deinit();
    const noop = struct {
        fn run(_: ?*anyopaque, _: *tp.TaskContext) void {}
    };
    const batch = [_]tp.BatchTask{.{ .task_fn = noop.run, .ctx = null }} ** 2;
    try std.testing.expectError(error.WaitableUnsupported, pool.submitBatch(&batch, .{ .waitable = true }));
}
```

Match the existing test-file style for pool construction (copy a neighboring submitBatch test's init pattern — there are existing `submitBatch` tests in tests/unit.zig; mirror their exact `ThreadPool.init` signature and `BatchTask` field names).

- [ ] **Step 2: Run** `zig build test --summary all` — expect FAIL (error.WaitableUnsupported not returned / not a member yet).

- [ ] **Step 3: Implement.** In `Core.submitBatch` immediately after `if (tasks.len == 0) return .{ .submitted = 0 };` add:

```zig
        // Q-NEW-02 (#107): waitable handles are discarded by the batch path
        // (no handle is returned per task), so a waitable batch would leak
        // one descriptor per task until pool exhaustion. Reject explicitly.
        if (options.waitable) return error.WaitableUnsupported;
```

- [ ] **Step 4: Fix the public wrapper doc** (~`src/pool.zig:2637`): replace the sentence "Submit multiple tasks atomically." with "Submit multiple tasks sequentially in batch order; returns the count actually enqueued — always check `result.submitted`. `options.waitable` is unsupported (returns `error.WaitableUnsupported`); per-task handles are not returned by the batch path." (This also closes the live residual of Q-025 #59 / Q-NEW-01.)

- [ ] **Step 5: Run** `zig build test --summary all` — expect PASS. Run `zig fmt src tests`.

- [ ] **Step 6: Commit** `fix: close Q-NEW-02 - reject waitable in submitBatch (#107); docs: close Q-025 residual (#59)`

---

### Task 3: PERF-NEW-03 — releaseSubmitter drain: backoff escalation + no silent task loss (#117)

**Files:**
- Modify: `src/pool.zig:962-974` (the drain loop in `releaseSubmitter`)
- Test: `tests/integration/submitter_lifecycle.zig` (append)

Current code drops the entry after 2^20 spins — which strands the descriptor in `.queued` and leaves `queued_tasks` non-zero (shutdown drain hang risk). Fix: escalate backoff (spin → yield → sleep), and on final cap **cancel the task properly** instead of silently dropping.

- [ ] **Step 1: Implement.** Replace the inner drain loop body:

```zig
        // Drain: push each pending entry to the inject queue with escalating
        // backoff (spin -> yield -> sleep). If the inject queue stays full
        // past the cap (pathological: consumers stalled during teardown),
        // cancel the task properly instead of silently dropping it, so the
        // descriptor is released and queued_tasks stays balanced (#117).
        const max_push_retries: u32 = 1 << 14;
        while (self.submitter_queues[idx].stealOne()) |entry| {
            var retries: u32 = 0;
            var pushed = false;
            while (retries < max_push_retries) : (retries += 1) {
                if (self.inject_queue.tryPush(entry)) {
                    pushed = true;
                    break;
                }
                if (retries < 64) {
                    std.atomic.spinLoopHint();
                } else if (retries < 1024) {
                    std.Thread.yield() catch {};
                } else {
                    clock.sleep(10 * std.time.ns_per_us);
                }
            }
            if (!pushed) {
                // Cancel: claim the descriptor away from any future dispatch,
                // then release it back to the freelist.
                const didx = entryIndex(entry);
                const descriptor = &self.descriptors[didx];
                if (@as(u32, @truncate(descriptor.generation)) == entryGen(entry)) {
                    if (descriptor.state.cmpxchgStrong(.queued, .cancelled, .acq_rel, .acquire) == null) {
                        self.decrementQueued(descriptor.options.lane);
                        self.releaseDescriptor(didx);
                    }
                }
            }
        }
```

Notes for the implementer: `entryIndex`/`entryGen` are at `src/pool.zig:147-152`; `decrementQueued` and `releaseDescriptor` are existing Core methods (releaseDescriptor accepts `.cancelled` as a terminal state — see ~:2401). If Task 5 (GAP-0037) has already landed, `descriptor.generation` is an atomic — use `.load(.acquire)`. Check whether a cancellation counter exists (`grep -n "cancell" src/pool.zig src/types.zig`); if `counters.cancelled`/similar is incremented elsewhere on the cancel path, increment it here identically so `submitted == completed + cancelled` invariants hold (the fuzz harness asserts this).

- [ ] **Step 2: Write a regression test** in `tests/integration/submitter_lifecycle.zig`: register a submitter, submit several tasks through it, release the submitter, then `shutdown(.drain, 5s timeout)` must not hang and stats must satisfy `submitted == completed + cancelled`. Mirror the file's existing test structure.

- [ ] **Step 3: Run** `zig build test --summary all && zig build test-integration --summary all` — expect PASS. `zig fmt src tests`.

- [ ] **Step 4: Commit** `fix: close PERF-NEW-03 - escalating backoff + proper cancel in releaseSubmitter drain (#117)`

---

### Task 4: GAP-0037 / AP-02 — Atomic descriptor.generation (#93)

**Files:**
- Modify: `src/pool.zig:235` (field), `~:1940` (runTask read), `~:2318-2321` and `~:2365-2368` (acquire writes), plus every other `descriptor.generation` / `.generation` access (`grep -n "\.generation" src/pool.zig`)

- [ ] **Step 1: Change the field:** `generation: u64 = 0,` → `generation: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),`

- [ ] **Step 2: Update all accesses.** Reads (e.g. runTask `:1940`, Task 3's cancel path): `descriptor.generation` → `descriptor.generation.load(.acquire)`. Writes in acquireDescriptor/acquireDescriptorBatch:

```zig
            const prev_generation = descriptor.generation.load(.monotonic);
            descriptor.* = .{};
            var next_gen = prev_generation +% 1;
            if (next_gen == 0) next_gen = 1;
            descriptor.generation.store(next_gen, .release);
```

CAUTION: `descriptor.* = .{};` resets generation to the init value — keep the load-before-reset / store-after-reset order exactly as above. Find ALL sites with `grep -n "generation" src/pool.zig` and convert each.

- [ ] **Step 3: Run** `zig build test --summary all && zig build test-integration --summary all` — expect PASS. If TSan is cheap on this host, optionally `zig build test -Dtsan --summary all`.

- [ ] **Step 4: Commit** `fix: close GAP-0037 - make descriptor.generation atomic (AP-02, #93)`

---

### Task 5: GAP-0038 / AP-03 — releaseSubmitter owner contract + defensive drain (#94)

**Files:**
- Modify: `src/pool.zig` `Core.releaseSubmitter` (~:904-974) and public wrapper docs `ThreadPool.registerSubmitter`/`releaseSubmitter` (~:2652-2660)
- Test: `tests/integration/submitter_lifecycle.zig` (append)

- [ ] **Step 1: Document the contract.** On BOTH the Core method and public wrappers add: registering and releasing MUST happen on the same thread, with the slot quiescent (no in-flight submit). Cross-thread release is unsupported.

- [ ] **Step 2: Defense-in-depth.** In `Core.releaseSubmitter`, the DescCache drain currently only runs when the caller's TLS matches (~:936-947). After that block, add a fallback: if TLS did NOT match (cross-thread release), still drain `self.desc_caches[idx]` before publishing the slot free — the slot is being retired, so a best-effort drain prevents the descriptor leak (the stale-TLS hazard on the original owner remains documented-unsupported):

```zig
        } else {
            // Cross-thread release (unsupported per contract, see doc above):
            // best-effort drain so cached descriptors are not stranded (#94).
            const cache = &self.desc_caches[idx];
            var buf: [DescCache.capacity]u32 = undefined;
            const n = cache.drainAll(&buf);
            for (buf[0..n]) |didx| self.releaseDescriptor(didx);
        }
```

(Adapt to the actual surrounding code; the matching `if` is the TLS-guard block.)

- [ ] **Step 3: Test:** thread A registers + submits via the slot; main thread releases the slot (cross-thread); assert no descriptor leak: after `shutdown(.drain)`, `task_desc_live == 0` (use the existing test helper if one exposes it — `grep -n "task_desc_live" tests/ src/pool.zig` for the accessor; `drainWorkerDescCachesForTesting` exists at ~:2716).

- [ ] **Step 4: Run** suites, fmt, **commit** `fix: close GAP-0038 - releaseSubmitter owner contract + cross-thread drain fallback (AP-03, #94)`

---

### Task 6: Numeric/lifecycle batch — GAP-0039, GAP-0040, GAP-0041+Q-020, GAP-0031, Q-026, Q-NEW-10 (#95 #96 #97 #56 #17 #60 #115)

**Files:**
- Modify: `src/stats/latency.zig:112`, `src/pool.zig` (deinitOwned ~:2504, joinAllWorkers ~:1080, waitGroup ~:741), `src/root.zig:42`, `src/stats/process_memory.zig:55-60`
- Test: `tests/unit.zig` (append)

- [ ] **Step 1: GAP-0039 (#95):** widen quantileScaled rank math to u128:

```zig
        const target_wide = (@as(u128, c) * numerator + (denominator - 1)) / denominator;
        const target: u64 = @intCast(@max(target_wide, 1));
```

(`numerator`/`denominator` are u64; result ≤ c so the cast is safe.)

- [ ] **Step 2: GAP-0040 (#96):** in `deinitOwned`, before freeing `self.desc_caches`, drain each per-submitter cache exactly like `drainWorkerDescCaches` does for workers (release each index via `releaseDescriptor`). Match the existing worker-drain code style (~:2479-2486).

- [ ] **Step 3: GAP-0041 + Q-020 (#97, #56):** `src/root.zig:42` → `pub const version = "0.2.4";` and add a unit test that references it so it's no longer dead:

```zig
test "version constant matches build manifest" {
    // Keep in sync with build.zig.zon .version — CI asserts via this test.
    try std.testing.expectEqualStrings("0.2.4", @import("thread_pool").version);
}
```

(If the test module cannot see build.zig.zon, the hardcoded pair is acceptable; the test makes drift a one-line conscious change.)

- [ ] **Step 4: GAP-0031 (#17):** real private peak on Linux. `/proc/self/status` has no RssAnon high-water; track an observed peak:

```zig
var private_peak_observed = std.atomic.Value(u64).init(0);
```

(file scope), then in the Linux sampler:

```zig
    const private_current = parseProcStatusKiB(contents, "RssAnon:") * 1024;
    // RssAnon has no kernel HWM counterpart; report the peak observed
    // across samples taken by this process (GAP-0031, #17).
    var peak = private_peak_observed.load(.monotonic);
    while (private_current > peak) {
        peak = private_peak_observed.cmpxchgWeak(peak, private_current, .monotonic, .monotonic) orelse private_current;
    }
    return .{
        .rss_current_bytes = parseProcStatusKiB(contents, "VmRSS:") * 1024,
        .rss_peak_bytes = parseProcStatusKiB(contents, "VmHWM:") * 1024,
        .private_current_bytes = private_current,
        .private_peak_bytes = peak,
    };
```

Add/extend the existing process_memory unit test: two consecutive samples ⇒ `private_peak_bytes >= private_current_bytes` is NOT guaranteed (peak is max of currents), but `sample2.private_peak_bytes >= sample1.private_peak_bytes` (monotone) and `peak >= current` at each sample IS guaranteed — assert both.

- [ ] **Step 5: Q-026 (#60):** inspect `Core.waitGroup` (~:741). If `self` is genuinely unused, make the dependency real or explicit: preferred minimal fix is to keep the method but document why it's instance-scoped (API symmetry) and silence with `_ = self;` only if already present — otherwise have it assert the pool is running: `std.debug.assert(self.state.load(.acquire) == .running);` which both uses self and tightens the contract. Verify no caller breaks.

- [ ] **Step 6: Q-NEW-10 (#115):** in `joinAllWorkers` (~:1080-1085), when joining a worker with `worker.is_overflow == true` and a live thread, update the overflow accounting the same way `reapRetiredOverflow` (~:1580) does (increment retires counter, decrement active). Copy the exact counter-update lines from reapRetiredOverflow.

- [ ] **Step 7: Run** both suites; fmt; **commit** `fix: close GAP-0039/0040/0041, GAP-0031, Q-026, Q-NEW-10 - numeric and lifecycle correctness batch (#95 #96 #97 #56 #17 #60 #115)`

---

### Task 7: SEC-020 + Q-027 — spinLoopHint + free_sentinel (#32 #62)

**Files:**
- Modify: `src/pool.zig:~1816,~1852` (CAS retry loops missing `spinLoopHint` — locate via issue #32: `glab issue view 32`; they are the `markWorkerNonEmpty`/`submitter_nonempty` style fetchOr/CAS retry loops in tryDrainLaneForWorker), `src/pool.zig:699`

- [ ] **Step 1: SEC-020:** add `std.atomic.spinLoopHint();` inside the two unbounded CAS retry loops cited by issue #32 (check `glab issue view 32` for exact current lines; verify each is a genuine retry loop).
- [ ] **Step 2: Q-027:** `src/pool.zig:699` — the raw `0xFFFFFFFF` in `initDescriptorFreelist`. The named constant `free_sentinel` is declared at function scope ~:2304; hoist it to `Core` struct scope (`const free_sentinel: u32 = 0xFFFFFFFF;` as a container-level decl) and use it at BOTH :699 and the acquire sites.
- [ ] **Step 3: Run** suites; fmt; **commit** `fix: close SEC-020 and Q-027 - spinLoopHint in CAS loops, free_sentinel everywhere (#32 #62)`

---

### Task 8: Doc/metadata hygiene — SECURITY.md, CODEOWNERS, CHANGELOG (GAP-0045 GAP-0046 GAP-0029 SEC-002 GAP-0034 GAP-0030 / #100 #101 #37 #40 #39 #38)

**Files:**
- Modify: `SECURITY.md`, `CODEOWNERS`, `CHANGELOG.md`

- [ ] **Step 1: SECURITY.md:** (a) versions table → `| 0.2.x | :white_check_mark: |` and `| < 0.2 | :x: |`; (b) line ~11 "public GitHub issues" → "public GitLab issues" (project: gitlab.com/devnw/zig/thread-pool); (c) line ~43 "No Undefined Behavior: Strict adherence to defined semantics" → "Memory-safe on tier-1 targets (x86_64/aarch64 Linux): TSan- and fuzz-clean on `main`; remaining portability caveats for 32-bit/weak-memory targets are tracked in docs/GAP_ANALYSIS.md". (d) Replace any `@your-username` with `@benjiv`.
- [ ] **Step 2: CODEOWNERS:** replace `* @your-username` with `* @benjiv`.
- [ ] **Step 3: CHANGELOG.md:** find the placeholder date (`grep -n "XXXX\|YYYY\|TBD" CHANGELOG.md`) and replace with the real date — use `git log --tags --simplify-by-decoration --format='%ai %d' | head` to find the matching tag date.
- [ ] **Step 4: Commit** `docs: close GAP-0045/0046/0029, SEC-002, GAP-0034, GAP-0030 - SECURITY.md/CODEOWNERS/CHANGELOG hygiene (#100 #101 #37 #40 #39 #38)` (markdownlint hook may rewrite — re-add and retry).

---

### Task 9: DESIGN.md / types.zig doc-accuracy — Q-NEW-03/04/05/06/07/09, RISK-06 note, QR-005 (#108 #109 #110 #111 #112 #114 #85 #49)

**Files:**
- Modify: `docs/DESIGN.md`, `docs/ALGORITHMS.md:~518`, `docs/PERFORMANCE_TARGETS.md:~69`, `src/types.zig:~178-181,~240-243,~675-677`, `src/pool.zig` submit wrapper doc ~:2625

- [ ] **Step 1: Q-NEW-03 (#108):** delete the "Runtime Presets" section (DESIGN.md ~:153-162) and rewrite "Worker wake selection" (~:65-68) to describe only the rotating-probe `scanAndWake`. Verify: `grep -n "RuntimePreset\|wake_strategy\|scan_parked_workers\|idle_queue" docs/DESIGN.md` → empty.
- [ ] **Step 2: Q-NEW-04 (#109):** DESIGN.md ~:295 `steal_batch_size` "(16 default)" → "(8 default)".
- [ ] **Step 3: Q-NEW-05 (#110):** remove `completion_only` from DESIGN.md ~:320 and ALGORITHMS.md ~:518; valid modes are `full`/`disabled`.
- [ ] **Step 4: Q-NEW-06 (#111):** types.zig ~:178-181 — correct: exactly `queue_capacity` descriptors are allocated; this is the hard cap on in-flight tasks; waitable tasks hold descriptors until `wait()`.
- [ ] **Step 5: Q-NEW-07 (#112):** types.zig ~:240-243 — `idle_park_after_ns` is the parked `timedWait` timeout before recheck/purge; spinning is governed by `spin_before_park_iters`.
- [ ] **Step 6: Q-NEW-09 (#114):** types.zig ~:675-677 — reword `parks`/`wakeups` as "park-loop entries (including no-wait bails)" and "park-loop exits (signals AND timeouts)".
- [ ] **Step 7: RISK-06 note (#85):** PERFORMANCE_TARGETS.md ~:69 — delete/replace the stale "alloc_count is currently emitted as 0" sentence: `total_alloc_count` counts scratch allocation events; per-size histograms remain future work (RISK-06).
- [ ] **Step 8: QR-005 (#49):** `ThreadPool.submit` wrapper doc (~src/pool.zig:2625-2627): add one sentence — "With `.backpressure = .block` a submit from a worker thread of the same pool can deadlock when the queue is full; see `BackpressurePolicy` docs."
- [ ] **Step 9:** `zig build check` (doc comments compile), fmt, **commit** `docs: close Q-NEW-03/04/05/06/07/09, QR-005 residual, RISK-06 staleness (#108 #109 #110 #111 #112 #114 #49 #85)`

---

### Task 10: QR-003 + QR-004 — explicit error sets (#41 #43)

**Files:**
- Modify: `src/types.zig` (`Config.validate` and new `ConfigError`), `src/pool.zig` (public facade returns), `src/root.zig` (re-export error sets)

- [ ] **Step 1: QR-003:** enumerate every `return error.X` in `Config.validate`/`normalized` (`grep -n "error\." src/types.zig`). Declare:

```zig
pub const ConfigError = error{ /* every variant found, e.g. TooManyWorkers, ZeroQueueCapacity, ... */ };
```

Change `validate`'s return type from inferred to `ConfigError!<current payload>` (keep the payload type exactly as-is). Build will fail if a variant is missed — fix until `zig build check` is clean.

- [ ] **Step 2: QR-004:** same procedure for the public facade: define `SubmitError`, `WaitError`, `ShutdownError`, `RegisterSubmitterError` near the facade in pool.zig by enumerating the errors each method can actually return (follow each call chain; include `WaitableUnsupported` from Task 2 in the batch path's set). Apply to `ThreadPool.submit/trySubmit/submitBatch/wait/shutdown/registerSubmitter` AND the Core methods if straightforward. Re-export the sets from root.zig.
- [ ] **Step 3:** Run both suites (callers in tests must still compile — error sets only narrow). fmt. **Commit** `feat: close QR-003/QR-004 - explicit public error sets (#41 #43)`

---

### Task 11: Q-NEW-08 — interruptible watchdog sleep (#113)

**Files:**
- Modify: `src/pool.zig` (Core fields ~watchdog state, `watchdogMain` ~:1539-1545, `joinAllWorkers` ~:1057-1061)
- Test: `tests/unit.zig` (append)

- [ ] **Step 1: Write the failing test:**

```zig
test "deinit is not blocked by a long watchdog interval (Q-NEW-08)" {
    const tp = @import("thread_pool");
    var pool = try tp.ThreadPool.init(std.testing.allocator, .{
        .max_threads = 1,
        .scheduler_variant = .lane_extension, // or whatever config enables the watchdog — check Config docs; watchdog runs when max_overflow_workers > 0
        .blocking_workers = 0,
        .max_overflow_workers = 1,
        .watchdog_interval_ns = 5 * std.time.ns_per_s,
    });
    const t0 = std.time.nanoTimestamp();
    pool.deinit();
    const elapsed = std.time.nanoTimestamp() - t0;
    try std.testing.expect(elapsed < 2 * std.time.ns_per_s);
}
```

Verify the exact Config that spawns the watchdog (`grep -n "watchdogMain\|watchdog_thread" src/pool.zig` and check the spawn condition); adapt the config so the watchdog actually runs. Run: expect FAIL (deinit takes ≥5s).

- [ ] **Step 2: Implement.** Add to Core (near other sync fields): `watchdog_mutex: sync.Mutex = .{}, watchdog_cond: sync.Condition = .{},`. In `watchdogMain` replace `clock.sleep(interval_ns)` with:

```zig
            self.watchdog_mutex.lock();
            if (!self.watchdog_stop.load(.acquire)) {
                self.watchdog_cond.timedWait(&self.watchdog_mutex, interval_ns) catch {};
            }
            self.watchdog_mutex.unlock();
```

In `joinAllWorkers` (and any other place that sets `watchdog_stop`), after the store add:

```zig
        self.watchdog_mutex.lock();
        self.watchdog_cond.broadcast();
        self.watchdog_mutex.unlock();
```

(Lock-around-broadcast is required to not race the stop-check-then-wait window.)

- [ ] **Step 3: Run** the new test (expect PASS, deinit returns quickly), then both suites. fmt. **Commit** `fix: close Q-NEW-08 - interruptible watchdog sleep (#113)`

---

### Task 12: Module headers + facade docs — QR-009, GAP-0044/NEW-002, QS-009 (#34 #28)

**Files:**
- Modify: `src/pool.zig` (top + Core method docs), `src/types.zig` (top), `src/memory/scratch.zig`, `src/pool/desc_cache.zig`, `src/stats/latency.zig`, `src/stats/process_memory.zig`, `src/queue/bounded_ring.zig`, `src/queue/ring_queue.zig`, `src/queue/work_deque.zig` (tops)

- [ ] **Step 1:** Add a `//!` header (3–6 lines: purpose, threading model, key invariants) to each file lacking one. pool.zig's should name the descriptor lifecycle (`free→reserved→queued→running→completed/cancelled→free`), the gen-tag dedup, and the SC park handshake. types.zig's should say "public API types; validation invariants in `Config.validate`".
- [ ] **Step 2: QS-009:** add `///` docs to the undocumented public Core methods (`deinit`, `submit`, `trySubmit`, `wait`, `shutdown`, `submitBatch`, `registerSubmitter`, `releaseSubmitter`, `waitGroup`, `statsSnapshot`, `purgeWorkerCaches`) — one to three lines each; reference the wrapper docs rather than duplicating detail where the wrapper is already thorough. Also add `///` to `sync.zig` and `clock.zig` public fns.
- [ ] **Step 3:** `zig build check`, fmt, **commit** `docs: close QR-009/GAP-0044/QS-009 - module headers and facade doc comments (#34 #28)`

---

### Task 13: Perf internals — PERF-NEW-02, PERF-NEW-09, PERF-NEW-04, NEW-003 (#99 #124 #119 #120)

**Files:**
- Modify: `src/pool.zig` (8 counter sites + finalizeTask ~:2103-2106), `benchmarks/common.zig` (~:262,:471-488), `tests/unit.zig:309-360`

- [ ] **Step 1: PERF-NEW-02 (#99):** at `src/pool.zig` lines ~1758, 1883, 2033, 2065, 2114, 2179, 2198, 2210 change `.fetchAdd(X, .release)` → `.fetchAdd(X, .monotonic)` for these worker-local observability counters ONLY: `steals`, `steal_failures`, `idle_ns`, `busy_ns`, `parks`, `wakeups`, `scratch_init_failures`. Do NOT touch any other atomic. Verify each site is one of those counters before editing.
- [ ] **Step 2: PERF-NEW-09 (#124):** in `finalizeTask` (~:2103-2106), guard the trailing `nowNs()` + `last_idle_started_ns.store` so it folds away when nothing consumes it:

```zig
        const idle_purge_active = self.config.worker_scratch_cap_bytes != 0 and self.config.idle_purge_after_ns != 0;
        if (timestamps_enabled or idle_purge_active) {
            // existing complete_ns read + last_idle_started_ns store
        }
```

Check how `timestamps_enabled` is spelled at this scope (`grep -n "timestamps_enabled" src/pool.zig`) and whether `complete_ns` is used unconditionally later in the function — if so, restructure so the non-instrumented path doesn't need it (the exec_ns computation at ~:2113 is already inside a timestamps-gated block; verify).
- [ ] **Step 3: PERF-NEW-04 (#119):** `benchmarks/common.zig` — compute `gitSha()` once in the harness entry (find the caller chain: `grep -n "gitSha" benchmarks/`) and thread it through instead of per-scenario. Verify with `zig build check`.
- [ ] **Step 4: NEW-003 (#120):** `tests/unit.zig:309-360` — reduce the `2_000_000_000` sleeps to `100 * std.time.ns_per_ms` and proportionally reduce the timeout assertions in those two tests (keep the same ordering relationships: timeout < task duration where the test requires a timeout to fire).
- [ ] **Step 5:** Run both suites (note total `zig build test` wall time — should drop several seconds). fmt. **Commit** `perf: close PERF-NEW-02/09/04, test: close NEW-003 (#99 #124 #119 #120)`

---

### Task 14: Infra/CI — GAP-0054, GAP-0042, GAP-0047, GAP-0057, QR-002 (#103 #98 #102 #106 #24)

**Files:**
- Modify: `Makefile:4`, `scripts/run-runtime-comparison.sh:~39,~60`, `.gitlab-ci.yml:~238`, `.gitmodules` + `docs/RUNTIME_COMPARISON.md`, `scripts/detect_diamond_deps.py:~91,~163,~174-177,~256-257`

- [ ] **Step 1: GAP-0054 (#103):** `Makefile:4` → `ZIG ?= zig`. In `scripts/run-runtime-comparison.sh` remove both `zig-0.15.2` fallback branches (keep plain `zig` / existing env override). Verify `make check` works.
- [ ] **Step 2: GAP-0042 (#98):** pin the CI base image by digest. Get the digest: `skopeo inspect --format '{{.Digest}}' docker://docker.io/library/ubuntu:24.04` (or `docker manifest inspect`). If neither tool exists on this host, SKIP this step and report it as blocked (do not guess a digest). On success: `.gitlab-ci.yml` `image: "ubuntu:24.04"` → `image: "ubuntu:24.04@sha256:<digest>"`.
- [ ] **Step 3: GAP-0047 (#102):** check whether `third_party/go` is initialized locally (`git submodule status`). If the checkout has the tags fetched, `cd third_party/go && git describe --tags --contains a1e7a41` to find a containing release; if you can identify the nearest go release tag and the submodule is cloned, re-pin: `git -C third_party/go fetch --tags --depth 1 origin tag <tag> && git -C third_party/go checkout <tag>` then `git add third_party/go`. If the network/tag fetch fails, FALLBACK: add `branch = master` removal note + record the pinned SHA and its date in `docs/RUNTIME_COMPARISON.md` ("go submodule pinned at a1e7a41 (master, fetched 2026-04); re-pin to a release tag when refreshing") and report partially-blocked.
- [ ] **Step 4: GAP-0057 (#106):** `scripts/detect_diamond_deps.py` — tighten `HASH_RE` to `r'\.hash\s*=\s*"(?P<hash>[A-Za-z0-9._-]+)"'`, add a guard before path use (`if "/" in pkg_hash or ".." in pkg_hash: continue`), and sanitize printed url/hash: `''.join(ch for ch in s if ch.isprintable())`. Run `python3 scripts/detect_diamond_deps.py` (or the pre-commit hook) to confirm it still works.
- [ ] **Step 5: QR-002 (#24):** verify locally first: `zig build test -Dsingle-pool=true --summary all` (expect pass — single-pool tests use one pool; if multi-pool tests fail under the flag, exclude via a skip guard reading build option, and note it). Then add a CI job to `.gitlab-ci.yml` mirroring the existing Debug unit-test job, named `zig-test-single-pool`, running `zig build test -Dsingle-pool=true --summary all` — copy the structure/tags/rules of the existing unit test job. NOTE: tests that create TWO pools (two_pool_cross_submit) are integration tests — only wire the unit suite unless integration also passes under the flag.
- [ ] **Step 6:** Commit `fix: close GAP-0054/0042/0047/0057, QR-002 - toolchain fallback, image pin, submodule pin, script hardening, single-pool CI gate (#103 #98 #102 #106 #24)`

---

### Task 15: Test coverage — GAP-0056 integration test, GAP-0055 fuzz extension (#105 #104)

**Files:**
- Modify: `tests/integration.zig` (append), `tests/fuzz/pool_fuzz.zig`

- [ ] **Step 1: GAP-0056 (#105):** write the foot-gun test FIRST:

```zig
test "global_queue + registered submitter drains on shutdown (GAP-0056)" {
    // The fuzz harness historically documented this combination as a
    // drain-hang foot-gun (pool_fuzz.zig:21-30). Pin the actual behavior.
    ...register submitter on a spawned thread, submit 100 tasks through it,
    release the submitter (same thread), then shutdown(.drain, 5s timeout)
    from main; assert completed+cancelled == 100 and no timeout...
}
```

Use `.scheduler_variant = .global_queue` explicitly. If this test FAILS (drain hang → timeout), that confirms the documented bug — in that case keep the test but assert the CURRENT contract (`error.Timeout` surfaced deterministically) and file the behavior in the test comment; if it PASSES (Task 3's drain fix may have fixed the underlying leak), assert full completion. Either way the path gains regression coverage.
- [ ] **Step 2: GAP-0055 (#104):** parameterize `tests/fuzz/pool_fuzz.zig` over scheduler variants: read variant from `FUZZ_SCHEDULER` env or derive from the seed (`seed % 3`), with the documented global_queue+submitter combination EXERCISED (not avoided) now that drain behavior is pinned; add a WaitGroup op to the op table (acquire `pool.waitGroup()`-equivalent, add/done around a submitted task) and keep the existing invariants. Make sure `zig build fuzz` still runs a bounded iteration locally (use FUZZ_ITERATIONS=500 for the smoke check).
- [ ] **Step 3:** Run `zig build test-integration --summary all` and `FUZZ_SEED=1 FUZZ_ITERATIONS=500 zig build fuzz`. fmt. **Commit** `test: close GAP-0056/GAP-0055 - global_queue submitter drain coverage + multi-variant fuzz (#105 #104)`

---

### Task 16: Final verification sweep

- [ ] **Step 1:** `zig build test --summary all && zig build test-integration --summary all && zig build test-stress --summary all` — ALL pass.
- [ ] **Step 2:** `zig fmt --check src tests benchmarks examples && zig build check` — clean.
- [ ] **Step 3:** `zig build test -Dtsan --summary all` (if host supports TSan) — clean.
- [ ] **Step 4:** `git status` — working tree clean, every change committed.

---

## Deferred (NOT in this plan — tracked in GitLab)

A/B-gated perf items (#116 #122 #123 #125 #55 #64 #79 #88-91 #36 #44 #47 #48 #52 #54 #121 #42), infra-dependent (#10 #11 #80-83 #74 #76 #78 #71 #72 #7 #86 #87 #19 #20 #22 #25 #27 #29 #30), large refactors (#14 QS-001, #118 GAP-0043, #21 QR-001, #31/#45 QS-004/005, #61 #66 #69 #70 #77 QS-15/16/18/Q-030/HYG). Won't-do: PERF-010/012/017, RISK-04, APPSEC-F008.
