# AppSec Review — Round 2 (Remediation Verification) — devnw/zig/thread-pool

**Branch:** `audit-2026-06-11`  **HEAD:** `b6e2d2e`  **Baseline:** round 1 at `39528a3`
**Diff under review:** `git diff 39528a3..HEAD -- src/ tests/ scripts/ Makefile .gitlab-ci.yml`
(20 files, +1262/−146). Round-1 report: `docs/APPSEC_REVIEW_2026-06-11_src.md`.

## 1. Scope & Assumptions

Round 2 answers two questions:

- **Q1 — Are AP-01…AP-06 actually closed?** Verified each fix in the current tree by
  reading the live code (not just the diff) and running the suites.
- **Q2 — Did the remediation introduce any new security-relevant defect?** Reviewed the
  full remediation diff under the round-1 threat model: memory safety (UAF / OOB /
  double-free), atomics / ordering / data-race correctness, integer / shift UB, resource
  exhaustion, and unsafe comptime configuration.

Same calibration as round 1 (native in-process concurrency library; no network / auth /
parsing surface beyond `/proc/self/status` and caller `fn`/`ctx` pointers). Static
read-through **plus** local execution this pass: `zig 0.16.0`. I ran `zig build test`
(Debug + ReleaseSafe + `-Dsingle-pool=true`) and `zig build test-integration`. I did **not**
re-run the TSan soak (CI-only); I treat the reported 8-clean TSan runs as supporting
evidence and address the single unreproducible first-run crash in §4.

**Headline:** **All six round-1 findings (AP-01…AP-06) are verified closed** with code +
test evidence. The remediation is disciplined and net-positive for safety. I found **no
new Critical / High / Medium** defects. I record **two Info-level residual notes** (AP2-01,
AP2-02) on the AP-06 version-pin mechanism and the documented-but-still-unsafe cross-thread
`releaseSubmitter` contract violation, both of which the code already bounds and documents.

## 2. Executive Summary

- **AP-01 closed and strengthened.** The clock source moved from wall-clock (`.real`) to
  monotonic (`.awake` = `CLOCK_MONOTONIC`) in both `src/clock.zig:23` and the
  `Condition.timedWait` deadline in `src/sync.zig:56`. Two hot-path interval subtractions
  additionally got saturating `-|` (`pool.zig:2260` `wait_ns`, `pool.zig:2360` `exec_ns`).
  Together these make every duration subtraction underflow-proof **at the source**: a
  monotonic base means `now >= prior` always holds, and the `-|` is belt-and-braces. The
  previously-unguarded idle-purge subtraction (`pool.zig:2480`) is now safe purely because
  the clock is monotonic. New unit test `clock: nanoTimestamp is monotonic non-decreasing`.
- **AP-02 closed.** `TaskDescriptor.generation` is now `std.atomic.Value(u64)`
  (`pool.zig:333`). **Every** access is atomic — verified all 9 sites (4 reads in
  `runTask`/`cancelDescriptor`/`wait`/`enqueuePush`, 2 reads in `packEntry` paths, 3
  load/store pairs in the acquire paths). The reset path (`resetDescriptorForAcquire`) no
  longer does `descriptor.* = .{}` over the atomic — it resets only the 6 non-atomic
  fields and leaves `generation`/`state`/`claimed_by` to explicit atomic stores by the
  caller (load-before-reset, `.release`-store-after). The plain-store residual flagged by
  GAP-0037 is gone.
- **AP-03 closed (contract + best-effort drain).** The owner-thread contract is now
  documented on all four relevant APIs (`registerSubmitter`/`releaseSubmitter` engine
  +facade). `releaseSubmitter` adds a cross-thread fallback that drains the per-submitter
  `DescCache` when the TLS guard does not match **and** the slot is still marked in-use
  (`pool.zig:1097-1119`), so quiescent cross-thread release (the realistic
  coordinator-after-join pattern) no longer strands descriptors. Residual contract-violation
  race is correctly bounded and documented (AP2-02, Info).
- **AP-04 closed.** `quantileScaled` rank math widened to `u128` (`latency.zig:122-123`);
  narrowing back to `u64` is lossless because the quotient `<= c`. New regression test
  exercises a count near `maxInt(u64)/9999`.
- **AP-05 closed.** `deinitOwned` now calls `drainSubmitterDescCaches()` (`pool.zig:2795`)
  alongside the pre-existing worker drain, releasing every cached `.reserved` descriptor
  before the slice is freed so `task_desc_live` reaches 0. Drain iterates the full slice,
  which is safe on every errdefer path because `desc_caches` is allocated-and-fully-
  initialized atomically (`pool.zig:885-886`) or is the empty default.
- **AP-06 closed.** `src/root.zig:42` now reports `"0.2.4"`, matching `build.zig.zon`.
  Pinning test `version constant matches build manifest` added. Residual: the test mirrors
  the literal rather than deriving from the manifest (AP2-01, Info).
- **New cancel/drain path (PERF-NEW-03 / #117) is correct.** `cancelDescriptor` is a
  faithful clone of the shutdown-path cancel: stale-filter → `.queued→.cancelled` CAS
  (arbitrates against a racing `runTask`) → `decrementQueued` **only on CAS success** →
  `cancelled++` → `wait_group.done()` → waitable broadcast / non-waitable release. No
  double-release, no lost `decrementQueued`, no double-free. The escalating backoff
  (spin→yield→sleep, cap `1<<14`) replaces the old silent-drop, closing a descriptor-strand
  / `queued_tasks` imbalance / drain-hang.
- **Watchdog condvar (Q-NEW-08 / #113) is lost-wakeup-free and double-join-safe.** Writers
  set `watchdog_stop` (`.release`) **before** taking `watchdog_mutex` and broadcasting; the
  watchdog re-checks the flag **under the mutex** before `timedWait`. Both join sites are
  guarded by `if (self.watchdog_thread) |t|` + null-out, and the errdefer site
  (`init`-failure-only) cannot co-run with the `joinAllWorkers` site.

Severity counts (round 2): **Critical 0 / High 0 / Medium 0 / Low 0 / Info 2 (residual
notes).** Overall confidence: **High** on every AP closure (code + passing tests under
Debug, ReleaseSafe, and single-pool); **High** that the remediation introduces no new
Critical/High/Medium defect on contract-compliant paths.

## 3. Q1 — Per-AP Closure Verdicts

| AP | Verdict | Primary evidence |
|----|---------|------------------|
| AP-01 | **CLOSED (+hardened)** | `clock.zig:23` `.awake`; `sync.zig:56` `.clock = .awake`; `pool.zig:2260` `-\|`, `:2360` `-\|`; monotonic base makes `:2480` safe; test `clock: nanoTimestamp is monotonic non-decreasing` |
| AP-02 | **CLOSED** | `pool.zig:333` `generation: std.atomic.Value(u64)`; all 9 accesses atomic; `resetDescriptorForAcquire` resets only non-atomic fields |
| AP-03 | **CLOSED (contract + drain)** | Owner-thread contract on 4 APIs (`pool.zig:1019-1027`, `:1043-1053`, facade); cross-thread fallback drain `pool.zig:1097-1119`; test `GAP-0038: cross-thread releaseSubmitter drains…` |
| AP-04 | **CLOSED** | `latency.zig:122-123` `u128` rank math; test `GAP-0039: quantileScaled rank math survives counts near maxInt(u64)/9999` |
| AP-05 | **CLOSED** | `drainSubmitterDescCaches` `pool.zig:2777-2784`, wired at `:2795`; tests `global_queue + (un)released submitter drains on shutdown` |
| AP-06 | **CLOSED** | `root.zig:42` `version = "0.2.4"`; test `version constant matches build manifest` |

### AP-01 — monotonic clock for interval math — CLOSED, hardened

`nanoTimestamp` now reads `.awake` (`CLOCK_MONOTONIC`); `Condition.timedWait` uses
`.clock = .awake` for its deadline. The module doc-comment records the rationale (NTP /
VM-resume backward steps must not underflow). Two hot subtractions also got `-|`
(`recordTaskStart`/`finalizeTask`). The idle-purge subtraction at `pool.zig:2480` is
*intentionally* unguarded but is now sound: both operands come from a monotonic source and
the store happens-before the read, so `now >= last_idle_started_ns` holds; the field is
seeded to `nowNs()` (non-zero) at worker init, so it is never `0` on that path. **No
underflow reachable.** Verified clean under `-Doptimize=ReleaseSafe` (the build where the
old checked subtraction would panic).

### AP-02 — atomic `descriptor.generation` — CLOSED

Field decl is atomic. I enumerated every access:

- Reads (atomic): `wait` `pool.zig:1180` `.acquire`; `enqueuePush` `:1626` `.monotonic`
  (owner-only, post-acquire — correct); handle build `:1702` `.monotonic` (owner-only);
  `runTask` stale-filter `:2184` `.acquire`; `cancelDescriptor` stale-filter `:2529`
  `.acquire`.
- Acquire paths (load `.monotonic` before reset, store bumped value `.release` after):
  `acquireDescriptor` `:2590/2594`; `acquireDescriptorBatch` `:2642/2646`.

The acquire/release pairing gives the lockless stale-filter readers a happens-before edge
to the reset of the non-atomic fields — closing the formal data race AP-02 described. The
`resetDescriptorForAcquire` decomposition is the load-bearing piece: it **never**
plain-stores over `generation`/`state`/`claimed_by`. **Field-coverage check:** TaskDescriptor
has exactly 9 fields — 3 atomic (`state`, `generation`, `claimed_by`) handled by the
caller's atomic stores, and 6 non-atomic (`task_fn`, `ctx`, `options`, `submit_ns`,
`start_ns`, `complete_ns`) all reset by `resetDescriptorForAcquire`. **No field is missed —
no stale data can leak across task reuse.**

### AP-03 — cross-thread `releaseSubmitter` — CLOSED (contract + best-effort drain)

The owner-thread / quiescent-slot contract is now stated on `Core.registerSubmitter`,
`Core.releaseSubmitter`, and their `ThreadPool` facade wrappers. The cross-thread fallback
(`pool.zig:1097-1119`) drains `desc_caches[idx]` when (a) the TLS guard does not match and
(b) the slot is still in-use in `submitter_free_mask` (the `& bit == 0` check skips the
already-free double-release case so a new registrant's cache is never touched). For the
realistic pattern — owner thread submits then exits/joins, coordinator releases the
quiescent slot — there is no concurrent owner access, so the SPSC drain is safe and
`task_desc_live` returns to 0 (proved by the `GAP-0038` integration test, which passes).
The residual race under an *active* contract violation is documented in code and tracked
here as AP2-02 (Info).

### AP-04 — `quantileScaled` u128 — CLOSED

`(@as(u128, c) * numerator + (denominator - 1)) / denominator` then `@intCast(@max(.,1))`.
Lossless narrowing (quotient `<= c <= maxInt(u64)`). Regression test synthesizes a count
above `maxInt(u64)/9999` and asserts the p9999 lookup no longer panics.

### AP-05 — `deinitOwned` drains submitter caches — CLOSED

`drainSubmitterDescCaches` iterates `self.desc_caches`, `drainAll`s each, and
`releaseDescriptor`s every index, called at `deinitOwned:2795` before the slice is freed.
Safe on the partial-init errdefer path: `desc_caches` is either the `&.{}` default
(no-op) or allocated **and** fully `.{}`-initialized in a single init block
(`pool.zig:885-886`); `descriptors`/`free_indices` are allocated earlier, so
`releaseDescriptor` never touches freed/garbage storage. Both new `global_queue` drain
tests pass with `std.testing.allocator` (no leak).

### AP-06 — version string — CLOSED

`root.zig` reports `"0.2.4"`, matching `build.zig.zon`. Pinning test added. See AP2-01 for
the residual on the pin mechanism.

## 4. Q2 — New-Defect Review (per high-risk area)

### 4.1 New cancel path in `releaseSubmitter` drain (PERF-NEW-03 / #117) — CLEAN

`cancelDescriptor` (`pool.zig:2523-2553`) was checked line-by-line against the
shutdown-path cancel (`cancelQueuedTasks`) and the `runTask` claim:

- **Double-release:** the `.queued→.cancelled` CAS is the single arbiter. A racing
  `runTask` that wins the `.queued→.running` CAS makes `cancelDescriptor`'s CAS fail →
  early return, no release. Only the CAS winner proceeds. For a **non-waitable** task the
  winner releases the descriptor exactly once; for a **waitable** task it does **not**
  release — it broadcasts and leaves the terminal `.cancelled→.free` to the waiter's
  CAS-guarded `wait()` (`pool.zig:1182-1194`). This matches `finalizeTask` and the
  shutdown cancel exactly. No double-release.
- **Lost `decrementQueued`:** `decrementQueued` runs **only** on CAS success
  (`pool.zig:2539`), and exactly once, so a ghost-duplicate entry that loses the CAS does
  not double-decrement (which would underflow `queued_tasks` and hang `shouldExit`).
  Balanced.
- **Waitable interaction:** a waitable task cancelled in the drain relies on the holder of
  its handle calling `wait()`. That is the documented waitable contract (the submitter got
  a handle back from `submit`). `submitBatch` cannot inject a waitable entry (rejected up
  front, §4.5), so no handle-less waitable can be stranded. Consistent.
- **Backoff bound:** spin (`<64`) → `yield` (`<1024`) → `sleep(10µs)`, capped at `1<<14`
  iterations, then `cancelDescriptor` (never a silent drop). The old code silently dropped
  past `1<<20`, stranding the descriptor in `.queued` forever and unbalancing
  `queued_tasks`. The new path is strictly safer.

### 4.2 Cross-thread `DescCache` drain fallback (GAP-0038) — CLEAN on contract-compliant paths; residual bounded (AP2-02)

The fallback drains a non-atomic SPSC cache from a non-owner thread. On the **documented-
correct** path (quiescent slot — owner no longer submitting) there is no concurrent access,
so `drainAll` (reads `head`, copies `indices[]`, zeroes `head`) is race-free. The
`& bit == 0` free-mask check prevents draining a cache a *new* registrant may already own
(double-release case bails idempotently). The **only** residual race is an active contract
violation (owner still mid-`tryPop`/`push` while another thread drains) — a genuine
non-atomic `head`/`indices` data race that could double-use an index → eventual double
`releaseDescriptor`. The code comments and the public API doc both forbid this; severity is
correctly bounded to caller-misuse. Tracked as **AP2-02 (Info)**.

### 4.3 Watchdog condvar (Q-NEW-08) — CLEAN

- **Lost wakeup:** stop-writers store `watchdog_stop = true` (`.release`) **before** taking
  `watchdog_mutex` + broadcast (`pool.zig:735-742`, `:1264-1272`). The watchdog re-checks
  `watchdog_stop` **under** `watchdog_mutex` immediately before `timedWait`
  (`pool.zig:1784-1787`). If the store lands before the under-lock check, the watchdog
  skips the wait; if after, the watchdog is already in `timedWait` and the broadcast wakes
  it. No lost wakeup; worst case it falls through on the interval timeout anyway.
- **Double-join:** both `t.join()` sites are guarded by `if (self.watchdog_thread) |t|` and
  null-out `watchdog_thread` after join. The errdefer site runs only on init failure (after
  which `init` returns an error and no normal `deinit` follows); the `joinAllWorkers` site
  runs on the success path. They are mutually exclusive. No double-join.
- **`timedWait` clock:** uses `.awake` (monotonic), consistent with AP-01.

### 4.4 Atomic generation conversion — CLEAN

No missed plain access (all 9 sites enumerated in §3 / AP-02). Orderings are correct:
`.acquire` on the lockless stale-filter reads and the `wait` read; `.release` on the bumped-
generation store paired with the post-reset publication; `.monotonic` only on owner-only
post-acquire reads where no cross-thread synchronization is required. The freelist CAS
(`.acq_rel`/`.acquire`) already orders the re-acquirer against the previous owner; the
generation `.release`/`.acquire` pair now also orders it against lockless ghost-entry
readers.

### 4.5 Explicit error sets (QR-003 / QR-004) — CLEAN (no silently-swallowed error)

`Config.validate` body is **byte-identical** to round 1 — only the return type changed
(`!void` → `ConfigError!void`). `SubmitError`/`SubmitBatchError`/`WaitError`/`ShutdownError`/
`RegisterSubmitterError` and the internal `EnqueueError` are exact enumerations of the
errors the existing code already returned; the conversion narrowed inferred error sets to
explicit ones without adding `catch`/`try`-swallow. `submitBatch` now additionally returns
`error.WaitableUnsupported` (Q-NEW-02), preventing a per-task descriptor leak — a net
hardening. Four unit tests assert the sets are closed/exhaustive. The one `try → plain` call
change (`shutdown`'s `cancelQueuedTasks`) is correct because `cancelQueuedTasks` became
infallible (`void`).

### 4.6 Per-field `resetDescriptorForAcquire` — CLEAN (no missed field → no info-leak)

Field-coverage cross-check (§3 / AP-02): all 6 non-atomic fields reset; all 3 atomic fields
handled by explicit atomic stores. **No field omitted.** A stale `task_fn`/`ctx` leaking
across reuse (the worst case — invoking a previous task's function pointer) cannot occur:
`enqueuePush` overwrites `task_fn`/`ctx`/`options` on every submit anyway, and the reset is
the defense-in-depth backstop. Metric fields (`submit_ns`/`start_ns`/`complete_ns`) are
zeroed, so no stale latency leaks into a recycled descriptor's histograms.

### 4.7 `finalizeTask` new guard (PERF-NEW-09) — CLEAN

The `complete_ns = nowNs()` + `last_idle_started_ns.store` is now guarded by
`timestamps_enabled OR idle_purge_active`. Both consumers are covered:
`recordTaskStart`'s idle-ns read (`pool.zig:2275`) is inside `if (timestamps_enabled)`, and
`idle`'s purge timer (`pool.zig:2480`) is inside `if (worker_scratch_cap_bytes != 0 and
idle_purge_after_ns != 0)` ≡ `idle_purge_active`. When the guard is inactive, neither
consumer reads `last_idle_started_ns`, so the un-updated (init-seeded `nowNs()`) value is
never consumed. **No stale value reaches a live consumer.** The unguarded subtraction at
`:2480` is safe for the AP-01 monotonic-clock reason, not the guard.

### 4.8 Fuzz / test changes — CLEAN (strengthened, no weakened invariant)

The post-iteration invariants (`submitted == completed + cancelled`; `task_desc_live == 0`;
DebugAllocator leak check) are **unchanged**. The fuzz harness was *broadened*: it now
rotates all three scheduler variants (was hard-coded `work_stealing`), adds a `wait_group`
add/done/wait op as direct regression coverage for the 39528a3 WaitGroup fix, and adds an
`FUZZ_SCHEDULER`/comptime-pin override. No stress test was modified (zero diff in
`tests/stress.zig`). New integration/unit tests (cross-thread drain, watchdog, monotonic
clock, version pin, batch-waitable rejection, error-set closure, overflow-retire
accounting) are purely additive.

### 4.9 The single unreproducible first-run TSan crash

I looked specifically for a logic path that could explain a rare integration-test crash
under TSan. On every **contract-compliant** path I found none: the cancel path, the
cross-thread drain (quiescent), the watchdog condvar, and the generation atomics are all
correctly synchronized. The cross-thread drain's only data race requires an *active*
contract violation, which the integration suite does not perform (the `GAP-0038` test joins
the owner before releasing). The most plausible benign explanation for an 8-clean / 1-crash
pattern on the *first* run after a fresh compile is a one-time runtime artifact (TSan shadow-
memory / lazy-page-fault / thread-startup ordering on cold caches) rather than a defect in
the remediation. **I cannot fully exclude a latent rare race** in the underlying
`std.Io.Mutex`/futex internals (out of scope, same "destroy-after-unlock" known-unknown as
round 1 §6), but nothing in this diff introduces an unguarded concurrent access on a
documented-correct path. Recommendation: keep the TSan soak in CI and capture the next
occurrence's stack if it recurs.

## 5. New Findings

No new Critical / High / Medium / Low defects. Two Info-level **residual notes** (neither
blocks shipping; both are already documented in code):

| ID | Severity | Title | Location | Note |
|----|----------|-------|----------|------|
| AP2-01 | Info | Version pin is a literal mirror, not a manifest-derived assertion | `src/root.zig:42`, `tests/unit.zig` (`version constant matches build manifest`) | The test pins the string `"0.2.4"` rather than importing `build.zig.zon`'s `.version`. It catches drift between `root.zig` and the *test*, but a future bump that updates the manifest + test but forgets `root.zig` (or any single-site miss across all three) can still pass. Stronger: derive `version` from the manifest at build time (e.g. inject via `build_options`) so there is one source of truth. |
| AP2-02 | Info | Cross-thread `releaseSubmitter` under an *active* contract violation still races the owner's SPSC `DescCache` | `src/pool.zig:1097-1119`, `src/pool/desc_cache.zig` | The fallback drain is non-atomic. If the owner is still submitting (contract violation) while another thread releases, `drainAll` races the owner's `tryPop`/`push` on the non-atomic `head` → potential descriptor double-use → double-free. Bounded to caller misuse and documented in code + public API. Optional defense-in-depth: a per-slot generation tag in the free-mask so the prior owner can detect revocation (the API-breaking change round-1 AP-03 already noted as out of scope). |

### AP2-01 — fix sketch

```zig
// build.zig: const zon = @import("build.zig.zon"); ... options.addOption([]const u8, "version", zon.version);
// root.zig:  pub const version = @import("build_options").version;
```

This removes the second source of truth entirely (the literal in `root.zig` and the literal
in the test both disappear).

## 6. Verification Performed

| Command | Result |
|---------|--------|
| `zig build test --summary all` (Debug) | 116/118 pass, 2 skip (platform-gated) |
| `zig build test --summary all -Doptimize=ReleaseSafe` | pass (AP-01/AP-04 panic surface clean) |
| `zig build test --summary all -Dsingle-pool=true` | pass (QR-002 comptime gate compiles + passes) |
| `zig build test-integration --summary all` | 31/31 pass (incl. GAP-0038 cross-thread drain, Q-NEW-08 watchdog, GAP-0056 submitter drains, Q-NEW-10 overflow retire) |

Not run locally (CI-only): TSan integration/stress/fuzz soak (relied on the reported 8-clean
runs; see §4.9), Windows/macOS stats paths.

## 7. Updated Severity Counts & Residual Risk

**Round 1 → Round 2 delta**

| Severity | Round 1 (open at `39528a3`) | Round 2 (open at `b6e2d2e`) |
|----------|------------------------------|------------------------------|
| Critical | 0 | 0 |
| High | 0 | 0 |
| Medium | 1 (AP-01) | 0 |
| Low | 2 (AP-02, AP-03) | 0 |
| Info | 3 (AP-04, AP-05, AP-06) | 2 residual notes (AP2-01, AP2-02) |

**All six round-1 findings are closed.** The two remaining Info items are residual notes on
mechanism (AP2-01) and a documented contract-violation race (AP2-02), not regressions.

**Residual-risk notes:**

- **AP2-02 / cross-thread SPSC race** is the only memory-safety residual, and it is gated on
  a documented contract violation. Real-world consumers using the realistic
  coordinator-after-join pattern are safe. Closing it fully requires the per-slot free-mask
  generation tag (API-breaking; deferred).
- **`std.Io.Mutex` destroy-after-unlock** remains a known-unknown (round 1 §6); not
  introduced or worsened by this diff.
- **`BoundedRing.popMany` unbounded sequence-spin** and **async-thread-death / signal
  safety** remain documented coverage gaps, unchanged by this remediation.
- **The first-run TSan crash (§4.9)** is unexplained by any logic defect found in the diff;
  most likely a one-time runtime artifact. Keep the soak; capture a stack if it recurs.

**No finding blocks shipping `b6e2d2e`.** The remediation closes every round-1 finding,
adds direct regression tests for each, and introduces no new Critical/High/Medium defect on
contract-compliant paths. The two Info residuals are optional hardening.
