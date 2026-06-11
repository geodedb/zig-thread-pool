# AppSec Review — devnw/zig/thread-pool `src/` (commit `39528a3`)

## 1. Scope & Assumptions

**Reviewed (read in full at commit `39528a3e92212efab8ed5840bc20e619a419c0f5`):**
`src/clock.zig`, `src/memory/scratch.zig`, `src/observability.zig`, `src/pool.zig`, `src/pool/desc_cache.zig`, `src/queue/bounded_ring.zig`, `src/queue/ring_queue.zig`, `src/queue/work_deque.zig`, `src/root.zig`, `src/stats/latency.zig`, `src/stats/process_memory.zig`, `src/sync.zig`, `src/types.zig`. `build.zig`, `build.zig.zon`, and `.gitlab-ci.yml` were reviewed under the supply-chain / build-config lens only.

**Prior art consulted:** `docs/APPSEC_REVIEW_2026-04-15_src.md` (F-001…F-011), `docs/BUG_2026-04-25_submitter_free_mask_shift_ub.md`, and the `39528a3` commit diff.

**Calibration (carried from the prior review, adapted for a native in-process Zig library):**

- This is a concurrency-primitives library linked into a host process. There is **no network, auth, persistence, or untrusted-data parsing surface** other than `/proc/self/status` on Linux and the caller-supplied `fn`/`ctx` pointers. OWASP/CIS map loosely; the live threat classes are **memory safety (UAF/OOB/double-free), atomics/ordering data races, integer/shift UB, resource exhaustion, and unsafe comptime configuration**.
- **Critical** = memory corruption or UB reachable from *correct* documented public-API calls. **High** = plausible-use data race / panic-as-DoS without opt-in, or weak-memory correctness defect on the normal path. **Medium/Low/Info** scale down from there.
- Static read-through only; no execution, no TSan run. Where a race could not be empirically confirmed I flag confidence and the evidence needed to verify. The project reports TSan/fuzz clean on `main` as of 2026-04-15 (`.gitlab-ci.yml:320`), which I treat as supporting (not conclusive) evidence for the narrow-window races below.
- Primary target is Linux x86_64/aarch64 (tier-1, aligned `u64`/`u32` loads are hardware-atomic in practice). Findings that are benign on tier-1 but unsound on 32-bit / weak-memory are rated accordingly.

**Headline:** All 1 Critical + 2 High findings from the 2026-04-15 review, the `submitter_free_mask` shift-UB bug, and the F-004…F-011 set are **verified fixed and not regressed** (see §5). The `39528a3` WaitGroup broadcast guard is **correct and race-free**. This pass found **no new Critical or High** issues; it found one Medium (a non-monotonic-clock underflow that the prior review did not cover) and a small number of Low/Info items concentrated in the newer `DescCache` wiring and the latency code.

## 2. Executive Summary

- **No confirmed memory-corruption or auth-class vulnerabilities in the reviewed scope.** The descriptor freelist (ABA-tagged CAS + atomic `free_indices`), generation-tagged queue entries, per-pool TLS identity check, spawn-aware init errdefer ladder, and CAS-guarded descriptor release are all sound and remain correct at `39528a3`.
- **Highest-impact new finding (Medium, AP-01):** latency and idle-purge interval math subtracts two **wall-clock (`.real`) timestamps** without guarding for backward movement (`src/clock.zig:14`, `src/pool.zig:2019/2113/2229/1617`). A routine backward clock step (NTP correction, VM resume, admin time-set) during an in-flight task underflows a checked subtraction → **process-abort panic in Debug/ReleaseSafe builds** (incl. the CI test matrix), or histogram corruption in ReleaseFast. Reachable with zero malicious input.
- **The `39528a3` WaitGroup fix is correct.** Moving `self.mutex.lock()` to the top of `done()` (over the `pending.fetchSub`) closes the prior use-after-free where a waiter could observe `pending == 0`, return, and destroy a stack-owned `WaitGroup` before the broadcasting thread reacquired the mutex (`src/types.zig:586-609`).
- **No remaining shift/overflow UB of the `BUG_2026-04-25` class.** Every `1 << n` site is now either special-cased for the full-width value (`src/pool.zig:760`) or has its shift amount provably bounded `< 64` by `Config.validate` or by `@ctz` + nonzero-mask guards (verified site-by-site in §6/Q3).
- **`DescCache` (added since the prior review) is sound under correct single-owner use.** Two residual items: a formal data race on the non-atomic `descriptor.generation` field in the rare ghost-duplicate dispatch window (Low, tier-1-benign, AP-02), and a cross-thread `releaseSubmitter` that skips the cache drain and leaves stale owner TLS (Low, caller-misuse-gated, AP-03).
- **Supply chain is clean.** Zero external dependencies (`build.zig.zon`), version-pinned CI catalog components (`v1.25.1`), gitleaks/SAST/dependency-scan/SBOM jobs present. Minor: `thread_pool.version` (`0.2.1`) disagrees with `build.zig.zon` (`0.2.4`) (Info, AP-06).

Severity counts: **Critical 0 / High 0 / Medium 1 / Low 2 / Info 3.** Overall confidence: **High** on the fixed-findings verification and the clock finding; **Medium** on the two narrow-window concurrency findings (static-only; would benefit from a targeted TSan harness).

## 3. Findings Table

| ID | Severity | Confidence | Title | Location | OWASP 2025 | Status |
|----|----------|-----------|-------|----------|-----------|--------|
| AP-01 | Medium | High | Wall-clock (`.real`) interval subtraction underflows on backward clock step → panic-DoS (safe builds) / latency-histogram corruption (fast builds) | `src/clock.zig:14`; `src/pool.zig:2019,2113,2229,1617` | A10 | Open |
| AP-02 | Low | Medium | Formal data race on non-atomic `descriptor.generation` in the ghost-duplicate dispatch window (tier-1-benign, 32-bit/weak-memory unsound) | `src/pool.zig:235,1940,2318-2321,2365-2368` | — (CWE-362) | Open |
| AP-03 | Low | Medium | Cross-thread `releaseSubmitter` skips `DescCache` drain and leaves owner TLS stale → SPSC double-use of descriptors under coordinator-release pattern | `src/pool.zig:904-974,936-947,1362-1373` | — (CWE-667/362) | Open |
| AP-04 | Info | High | `quantileScaled` checked multiply `c * numerator` overflows `u64` (~1.8e15 observations) → panic in safe builds during `statsSnapshot` | `src/stats/latency.zig:112` | A10 (CWE-190) | Open |
| AP-05 | Info | High | `deinit` does not drain per-submitter `DescCache`s → `task_desc_live` left non-zero if a submitter never releases (counter/assertion only; no leak/UAF) | `src/pool.zig:2479-2486,2504-2514` | — | Open |
| AP-06 | Info | High | Version-string drift: `thread_pool.version = "0.2.1"` vs `build.zig.zon` `version = "0.2.4"` (SBOM / runtime-report disagreement) | `src/root.zig:42`; `build.zig.zon:3` | A08 (CWE-1395) | Open |

## 4. Finding Details

---

### AP-01 — Wall-clock interval subtraction underflows on a backward clock step

- **Severity:** Medium  **Confidence:** High
- **Location:** `src/clock.zig:14-17`; `src/pool.zig:2019`, `:2113`, `:2229`, `:1617`
- **Evidence:**

  `nowNs()` (`pool.zig:2731`) reads the **real / wall** clock, not a monotonic one:

  ```zig
  // src/clock.zig:14-17
  pub fn nanoTimestamp() i96 {
      const io = std.Io.Threaded.global_single_threaded.io();
      return std.Io.Clock.Timestamp.now(io, .real).raw.nanoseconds; // <- .real, non-monotonic
  }
  ```

  Four interval computations subtract two such timestamps **without** a `>=` guard or saturating operator:

  ```zig
  // recordTaskStart  src/pool.zig:2019
  const wait_ns = start_ns - descriptor.submit_ns;     // submit on thread A, start on thread B
  // finalizeTask     src/pool.zig:2113
  const exec_ns = complete_ns - start_ns;              // clock may step back during the task
  // idle             src/pool.zig:2229
  if (now - worker.last_idle_started_ns.load(.acquire) >= self.config.idle_purge_after_ns)
  // overflowWorkerMain src/pool.zig:1617
  } else if (now - idle_since > idle_retire_ns) {
  ```

  (Contrast `recordTaskStart:2032`, `idle:2219`, and `watchdogMain:1555`, which *do* guard with `>=` / `now <= started`.)
- **Attack scenario (non-destructive, no attacker needed):** Default `Config.timestamp_mode == .full` (`types.zig:343`), so every task records `wait_ns` and `exec_ns`. An operator's NTP daemon applies a backward step correction (or the host is a VM that resumes with a rewound wall clock) at the moment a task is in flight: `submit_ns` was captured at wall-time *T*, the clock steps back, `start_ns`/`complete_ns` are captured at *T − Δ < submit_ns*. The subtraction underflows.
  - **Debug / ReleaseSafe (incl. the CI matrix, `.gitlab-ci.yml:74-96`):** Zig's checked subtraction panics (`integer overflow`) → the entire host process aborts. For an in-process library this is a full denial-of-service of the embedding application.
  - **ReleaseFast / ReleaseSmall:** wraps to a near-`u64::MAX` value; the latency histogram (`latency.zig:observe`) records a garbage bucket (corrupts p95/p99/p999 — operator-facing SLO signals) and `idle:2229` purges scratch one tick early (benign).
- **Impact:** Panic-as-DoS in safety builds from a routine, non-malicious operational event; observability/SLO corruption in fast builds. The library cannot recover (Zig panics are non-catchable).
- **Root cause:** A non-monotonic clock is used to measure durations. Duration math must use a monotonic source; wall-clock is only appropriate for absolute timestamps.
- **Remediation (smallest safe fix):** Either (preferred) measure intervals from a monotonic source, or guard every duration subtraction. Minimal, behavior-preserving patch with saturating subtraction:

  ```zig
  const wait_ns = start_ns -| descriptor.submit_ns;   // pool.zig:2019
  const exec_ns = complete_ns -| start_ns;            // pool.zig:2113
  ```

  For the idle/retire timers, add the same `>=`/`>` guard already used at `:2219`:

  ```zig
  const last = worker.last_idle_started_ns.load(.acquire);   // pool.zig:2229
  if (now > last and now - last >= self.config.idle_purge_after_ns) worker.scratch.purge();
  ```

  Strategic fix: switch `clock.nanoTimestamp` interval consumers to a monotonic clock (`std.Io.Clock` monotonic source), keeping `.real` only for any absolute-timestamp need. `complete_ns` is also reused for purge timing, so monotonic is the more correct base there too.
- **Regression tests:** Unit test that calls `recordTaskStart`/`finalizeTask`-equivalent paths with `submit_ns > start_ns` (inject a fake clock or call the histogram path with a descriptor whose `submit_ns` is set to `nowNs() + 1_000_000`) and asserts no panic and a `0`/saturated observation. Run under `-O Debug` and `-O ReleaseSafe`.
- **References:** OWASP A10 (Mishandling of Exceptional Conditions); CWE-191 (Integer Underflow), CWE-754 (Improper Check for Unusual Conditions). CIS Controls v8.1.2 — secure-application-development (error-handling paths), application testing.

---

### AP-02 — Formal data race on non-atomic `descriptor.generation` in the ghost-duplicate dispatch window

- **Severity:** Low  **Confidence:** Medium
- **Location:** `src/pool.zig:235` (field decl), `:1940` (read), `:2318-2321` / `:2365-2368` (writes)
- **Evidence:** `descriptor.generation` is a **plain `u64`**, not `std.atomic.Value(u64)`:

  ```zig
  // TaskDescriptor, src/pool.zig:235
  generation: u64 = 0,
  ```

  `runTask` reads it locklessly as the stale-entry filter, *before* the claiming state-CAS:

  ```zig
  // src/pool.zig:1940
  if (@as(u32, @truncate(descriptor.generation)) != entry_gen) return;
  ```

  `acquireDescriptor` / `acquireDescriptorBatch` write it locklessly during re-acquisition:

  ```zig
  // src/pool.zig:2318-2321
  const prev_generation = descriptor.generation;
  descriptor.* = .{};
  descriptor.generation = prev_generation +% 1;
  if (descriptor.generation == 0) descriptor.generation = 1;
  ```

- **Failure scenario:** The code comments at `runTask` (`:1937-1960`) acknowledge that "ghost duplicate" queue entries are an unresolved upstream residual race. When a descriptor slot `I` is released to the freelist (`finalizeTask` → `releaseDescriptor`) while a duplicate entry for `(I, gen_old)` is still sitting in a queue, a second worker can pop that ghost entry and read `descriptor.generation` **at the same instant** another thread re-acquires slot `I` and writes the bumped generation. The freelist CAS chain orders the re-acquirer against the *previous owner*, but the ghost reader synchronizes only through the *queue* — there is no happens-before edge between the ghost read at `:1940` and the re-acquire write at `:2320`. This is a textbook data race on a non-atomic field (UB under the Zig/LLVM memory model, and TSan-reportable in principle).
- **Impact:** **Benign on tier-1 targets** (x86_64/aarch64): aligned `u64` accesses are hardware-atomic, so the reader observes a coherent `gen_old` or `gen_new`, and the subsequent `.queued → .running` state-CAS (`:1961`) backstops any double-dispatch (a stale `gen` read implies the re-enqueue to `.queued` has not yet happened, so the CAS fails). **On 32-bit / weak-memory targets** (the same portability class the prior F-003 finding was raised for), the `u64` read can tear, yielding a generation value that is neither `gen_old` nor `gen_new`; the state-CAS still backstops double-dispatch, but the memory model is violated and behavior is undefined.
- **Root cause:** Same class as the now-fixed F-003 (`free_indices` was promoted to `std.atomic.Value(u32)` for exactly this reason); `descriptor.generation` was not given the same treatment, and it is read on a path that can concurrently re-acquire the slot.
- **Remediation:** Make `generation` an `std.atomic.Value(u64)`; read with `.acquire`/`.monotonic` at `:1940` and store with `.release`/`.monotonic` at `:2320-2321`/`:2367-2368`. Zero runtime cost on tier-1 (compiles to the same `mov`), and it makes the memory model valid for future ports and removes a latent TSan finding. Mirror the F-003 fix rationale verbatim.
- **Verification:** Add a two-pool/recycle stress scenario that forces high descriptor-recycle churn and run `zig build test-stress -Dtsan` (and `tsan-fuzz`); confirm `descriptor.generation` is not reported. The existing soak (`.gitlab-ci.yml:337`) likely does not hit the precise ghost+re-acquire interleaving frequently enough to surface it.
- **References:** CWE-362 (Concurrent Execution / Data Race), CWE-366. Not an OWASP web category. CIS Controls v8.1.2 — application testing (ThreadSanitizer).

---

### AP-03 — Cross-thread `releaseSubmitter` skips the `DescCache` drain and leaves the owner's TLS stale

- **Severity:** Low  **Confidence:** Medium
- **Location:** `src/pool.zig:904-974` (esp. the TLS-guarded drain `:936-947`), `:1362-1373` (per-submitter cache use), `:1672-1680` (`tlsSubmitterIndexFor`)
- **Evidence:** The per-submitter descriptor-cache drain in `releaseSubmitter` runs **only when the calling thread is the registrant**:

  ```zig
  // src/pool.zig:936-947
  if (tls_submitter_slot.pool == @as(*anyopaque, @ptrCast(self)) and
      tls_submitter_slot.index == idx)
  {
      const cache = &self.desc_caches[idx];
      var buf: [DescCache.capacity]u32 = undefined;
      const n = cache.drainAll(&buf);
      // ... releaseDescriptor(buf[i]) ...
      tls_submitter_slot = .{};   // clears only THIS thread's TLS
  }
  // ... then unconditionally publishes the slot free via free_mask CAS (:949-955)
  ```

  TLS is per-thread. If thread B calls `releaseSubmitter(idx)` for a slot that thread A registered, the `if` is false: the cache is **not** drained, **A's** `tls_submitter_slot` is **not** cleared, yet the slot is published free and re-registrable.
- **Failure scenario (caller-misuse-gated):** A reasonable consumer uses a coordinator thread to release submitter slots (the public `ThreadPool.releaseSubmitter` doc at `:2656` does **not** state that release must come from the registering thread). After B releases A's slot: (1) the descriptors A had cached in `desc_caches[idx]` are leaked (still `.reserved`, counted in `task_desc_live`); (2) A's TLS still points at `idx`, so A's next `submit` re-enters the per-submitter fast path (`:1362`) and pops `desc_caches[idx]`; (3) thread C re-registers and is handed the same `idx`, and now A and C both push/pop the same `DescCache` and `submitter_queues[idx]` — violating the documented SPSC single-owner invariant (`desc_cache.zig:3-10`). Concurrent `tryPop`/`push` on the non-atomic `head` can hand the same descriptor index to two callers → **descriptor double-use → eventual double-`releaseDescriptor` / double-free of a freelist slot**.
- **Impact:** Potential memory corruption (descriptor double-use / freelist double-push), but only under a usage pattern the library's internal comments treat as forbidden (`:919-925`: "Callers MUST ensure a given idx is released at most once per registration") while the *public* API documentation is silent on the owner-thread requirement. Under correct owner-thread release the path is clean (verified: TLS-guarded drain → clear TLS → publish free).
- **Root cause:** The SPSC ownership of `DescCache`/`submitter_queues[idx]` is enforced only via per-thread TLS, but slot ownership is released globally via the free-mask CAS, and the owner-thread requirement is not surfaced in the public contract.
- **Remediation:** (1) **Document** on `ThreadPool.registerSubmitter`/`releaseSubmitter` that a slot must be registered *and* released by the same thread, and that the slot must be quiescent (owner not mid-submit) at release. (2) Defense-in-depth: in `releaseSubmitter`, if `tls_submitter_slot` does not match the released `idx`, either refuse with an error or drain `desc_caches[idx]` under a one-time exclusive claim before publishing the slot free, and ensure the prior owner can detect the revocation (e.g., a per-slot generation in the free-mask, noted as out-of-scope in `:920-925`).
- **Verification:** Add a misuse test (thread A registers + caches, thread B releases, thread A submits once more) and assert it is rejected or safe; run under `-Dtsan`.
- **References:** CWE-667 (Improper Locking), CWE-362, CWE-415 (Double Free, worst case). CIS Controls v8.1.2 — secure design principles.

---

### AP-04 — `quantileScaled` checked multiply can overflow `u64`

- **Severity:** Info  **Confidence:** High
- **Location:** `src/stats/latency.zig:112`
- **Evidence:**

  ```zig
  const target = @max((c * numerator + (denominator - 1)) / denominator, 1);
  ```

  For the `p9999_ns` summary field (`numerator = 9999`, `denominator = 10000`, called from `latency.zig:82`), `c * 9999` overflows `u64` when the merged observation count `c` exceeds ~`1.845e15`.
- **Failure scenario:** A long-running daemon accumulates ≳1.8 quadrillion task observations in a single merged histogram; the next `statsSnapshot()` (`pool.zig:1258` → `summary()` → `quantileScaled`) performs the checked multiply. In Debug/ReleaseSafe this panics (DoS); in ReleaseFast it wraps and returns a meaningless percentile. The threshold is astronomically large (≈58 years at 1M tasks/s), hence Info, but it is a real checked-arithmetic overflow with a trivial fix.
- **Remediation:** Compute the rank in `u128`, or reorder to avoid the large product, e.g. `const target = @max(@as(u64, @intCast((@as(u128, c) * numerator + (denominator - 1)) / denominator)), 1);`. Apply the same to `quantile`/`summary` call sites.
- **References:** CWE-190 (Integer Overflow). OWASP A10.

---

### AP-05 — `deinit` does not drain per-submitter `DescCache`s

- **Severity:** Info  **Confidence:** High
- **Location:** `src/pool.zig:2479-2486` (`drainWorkerDescCaches` covers only `self.workers[*].desc_cache`); `:2504-2514` (`deinitOwned` frees `submitter_queues`/`desc_caches` without draining)
- **Evidence:** `drainWorkerDescCaches` iterates only worker caches; `deinitOwned` frees the per-submitter `desc_caches` slice (`:2511-2514`) without releasing any indices still held in them.
- **Failure scenario:** A submitter registers, caches descriptors via `acquireDescriptorBatch` (which increments `task_desc_live`), and the pool is torn down before that submitter calls `releaseSubmitter`. Those cached indices are never released, so `task_desc_live` is left non-zero. **No memory leak or UAF** — the entire `descriptors`/`free_indices` slab is freed wholesale at `:2523-2526` — but any leak-assertion harness that checks `task_desc_live == 0` pre-`deinit` has no safety net for the submitter-cache path (unlike the worker path, which `drainWorkerDescCachesForTesting` exposes at `:2716`).
- **Remediation:** Have `deinitOwned` (or `drainWorkerDescCaches`) also iterate `self.desc_caches[0..init_submitter_count]` and `releaseDescriptor` each before freeing the slice; or document that `task_desc_live` is only guaranteed zero when all submitters have released. Either is a few lines and makes the leak-assertion invariant total.
- **References:** CWE-401 (counter accounting only). CIS Controls v8.1.2 — application testing.

---

### AP-06 — Version-string drift between `thread_pool.version` and `build.zig.zon`

- **Severity:** Info  **Confidence:** High
- **Location:** `src/root.zig:42` (`pub const version = "0.2.1";`) vs `build.zig.zon:3` (`.version = "0.2.4"`)
- **Evidence:** The package manifest declares `0.2.4` (consistent with recent commit "bump to v0.2.4"), but the embedded runtime constant reports `0.2.1`.
- **Impact:** SBOM/dependency-scan tooling (`sbom-generate@v1.25.1`, `.gitlab-ci.yml:48`) keys off the manifest (`0.2.4`), while any consumer logging `thread_pool.version` reports `0.2.1`. This disagreement can mislead vulnerability triage and version-pinning decisions (which fix landed in which build).
- **Remediation:** Make `src/root.zig:version` derive from `build.zig.zon` (or add a CI check that asserts they match). Treat the manifest as the single source of truth.
- **References:** CWE-1395 / OWASP A03 (supply-chain hygiene / accurate component inventory). CIS Controls v8.1.2 — software component inventory.

---

## 5. Secure Design Notes (and prior-finding verification)

**Prior findings — verified fixed and not regressed at `39528a3`:**

| Prior ID | Status at `39528a3` | Evidence |
|----------|---------------------|----------|
| F-001 (cross-pool TLS OOB, Critical) | **Fixed** | `TlsSlot{pool,index}` with identity + bounds check in `tlsWorkerIndexFor`/`tlsSubmitterIndexFor` (`pool.zig:88-93`, `:1657-1680`). Bounds check (`slot.index >= len → null`) runs even under `-Dsingle-pool`; only the identity compare is comptime-elided. |
| F-002 (init errdefer frees live workers, High) | **Fixed** | Spawn-aware errdefer ladder (`pool.zig:594-630`) plus `init_worker_count`/`init_queue_count`/`init_submitter_count` bounding `deinitOwned` (`:2488-2531`). |
| F-003 (`free_indices` non-atomic, High) | **Fixed** | `free_indices: []std.atomic.Value(u32)` (`pool.zig:500`); `.monotonic` load/store at `:2312`, `:2352`, `:2358`, `:2439`. |
| F-004 (`WaitGroup.done` panic-DoS) | **Fixed** | `std.debug.runtime_safety` gate + saturate-and-return (`types.zig:594-605`); now also under the mutex. |
| F-005 (submitter slot leak / double-release) | **Hardened** | Bounds check (`pool.zig:908`) + atomic claim CAS (`:949-955`); residual cross-thread case is AP-03. |
| F-006 (`unreachable` on `blocking_inject == null`) | **Fixed** | Falls back to default inject / returns `null` (`pool.zig:1398-1413`, `:1897-1905`). |
| F-007 (`/proc` KiB `*1024` overflow) | **Fixed** | `@min(kib, maxInt/1024)` clamp + regression test (`process_memory.zig:68-82`). |
| F-008 (double-`wait` double-release) | **Fixed** | CAS-guarded terminal transition in `releaseDescriptor` (`pool.zig:2414-2425`) + `.free` success path in `wait` (`:1001-1009`). |
| `BUG_2026-04-25` (shift-UB `1<<64`) | **Fixed** | `if (max_submitter_queues == 64) maxInt(u64) else (1<<n)-1` (`pool.zig:760-764`) plus `validate` ceiling (`types.zig:430-431`). |

**The `39528a3` WaitGroup broadcast guard is correct (answers Q2).** The diff moves `self.mutex.lock()` from inside the `if (previous == 1)` branch to the top of `done()`, so the `pending.fetchSub` and the conditional `cond.broadcast()` are both under the mutex (`types.zig:591-608`). `WaitGroup.wait` checks `pending` and sleeps in `cond.wait` under the same mutex (`:613-619`). This serializes "subtract-and-broadcast" against "check-and-wait": a waiter cannot return from `wait()` until `done()` releases the mutex, and after that point `done()` touches the `WaitGroup` no further — closing the prior use-after-free of a stack-owned `WaitGroup`. The underlying `sync.Condition` is a futex/epoch counting condvar that only ever produces spurious wakeups (never lost wakeups for the no-timeout path), which all callers tolerate via predicate re-check loops.

**Controls worth preserving:**

- **Generation-tagged queue entries + single-point state-CAS** (`pool.zig:142-152`, `:1940`, `:1961`, `:2285`) remain the primary defense against double-dispatch and back-stop the AP-02 data race.
- **ABA-tagged freelist with a *global* counter bumped on every acquire and release** (`pool.zig:2313`, `:2359`, `:2440`) makes the speculative multi-link traversal in `acquireDescriptorBatch` (`:2351-2358`) sound: a successful head-CAS provably implies zero intervening freelist mutations, so the chain read is consistent. `free_indices` slots are atomic, so the chain reads are non-tearing. This is a subtle pattern done correctly.
- **DescCache SPSC discipline** (`desc_cache.zig`) is correct under single-owner use; the refill (`pool.zig:1352-1359`/`:1365-1372`) only pushes ≤31 entries into a freshly-emptied 32-slot cache, so `push` never silently drops, and `drainAll` panics loudly on undersized buffers.
- **Init/teardown ordering** — worker struct written before fallible queue init (`pool.zig:721-735`), watchdog stopped before worker join (`:1057-1061`), backpressure waiters broadcast on shutdown (`:1072-1077`) — is disciplined.
- **Config validation** (`types.zig:399-432`) enforces all cross-field invariants and the `≤ 64` bitmap caps, which is what bounds the shift sites in Q3.
- **Supply chain:** zero external dependencies (`build.zig.zon`), version-pinned CI catalog (`v1.25.1`), gitleaks/SAST/secrets/SBOM/dependency-scan jobs (`.gitlab-ci.yml:44-49`), and a scheduled TSan+fuzz soak (`:337-356`). The otel dependency was deliberately collapsed to a comptime no-op (`observability.zig`), eliminating a dep cycle — a net supply-chain simplification.
- **`-Dsingle-pool`** is a documented, default-off, explicitly-UNSAFE build flag (`build.zig:56-62`, `pool.zig:21-24`); the bounds check it retains limits the residual hazard to in-bounds-wrong-worker corruption only when the "one pool per process" contract is violated. Acceptable as an opt-in.

## 6. Coverage Gaps & Questions

**Answers to the input questions:**

- **Q1 — New memory-safety/atomics issues since 2026-04-15?** Yes, but none Critical/High. The newest issues are concentrated where the code changed: AP-01 (clock underflow — pre-existing but uncovered by the prior review), AP-02 (`descriptor.generation` non-atomic — same class as fixed F-003, now in the ghost-duplicate path), AP-03 (cross-thread `releaseSubmitter` vs the new `DescCache`), and AP-05 (submitter-cache drain on `deinit`). The `DescCache` itself, `acquireDescriptorBatch`, and the `39528a3` change are otherwise sound.
- **Q2 — Is the `sync`/`WaitGroup` broadcast guard correct and race-free?** Yes — see §5. Correct for the documented use; the only residual is the standard "mutex-unlock-touches-its-own-memory-after-handoff" property of any futex mutex (see gaps below), which this code does not introduce incorrectly.
- **Q3 — Remaining shift/overflow UB of the `BUG_2026-04-25` class?** None found. Every `1 << n` was checked: `submitter_free_mask` init special-cases `n == 64` (`pool.zig:760-764`); `registerSubmitter` (`:895`) and `releaseSubmitter` (`:910`) bound `idx ∈ [0,63]` via `@ctz` on a nonzero mask / the `idx >= len` early-return; `markWorkerNonEmpty`/`markWorkerEmpty`/`self_bit` (`:1683`,`:1688`,`:1860`) bound `worker_index ≤ 63` via the validated `max_threads + max_overflow_workers ≤ 64`; `laneMask` (`:2568`) bounds `nb ≤ 63` via `blocking_workers < max_threads ≤ 64` and an `nb == 0` early-return; `latency.bucketUpperBound` (`:100`) bounds `index ≤ 62`. All packed-entry shifts use the constant `32`.

**What could not be verified statically / out of scope:**

- **Empirical race confirmation.** AP-02 and AP-03 are static findings in narrow interleavings; a targeted `-Dtsan` harness (high descriptor-recycle churn for AP-02; cross-thread release for AP-03) is needed to confirm/refute. The general TSan/fuzz soak is reported clean but likely under-samples these windows.
- **`std.Io.Mutex.unlock` destruction-safety.** The `WaitGroup` fix is correct at the algorithm level, but whether the underlying futex mutex reads its own memory after the ownership-handoff store (the classic "destroy-after-unlock" question) depends on `std.Io.Mutex` internals, which are outside this scope. This is the same property as Go's `sync.WaitGroup` and is generally considered safe; flagged only as a known unknown.
- **`BoundedRing.popMany` unbounded sequence-spin (`bounded_ring.zig:116-118`)** has no retry cap (unlike `RingQueue.stealHalf`'s 256-cap). A producer thread killed between reserving `tail` and committing `sequence` (async signal, `pthread_cancel`, FFI longjmp) would spin a consumer forever → shutdown stall. This is the same "signal safety / async thread death" class the prior review noted as a coverage gap, not a finding — the pool installs no signal handlers and documents no async-cancellation safety.
- **macOS/Windows stats paths** (`process_memory.zig:84-104`) were read for bounds/error handling only; the `task_info` FFI signature and `count` sizing could not be validated against the live SDK without running on those platforms. Windows is correctly stubbed to `error.ProcessMemoryUnavailable`.
- **`build.zig` `runtime_compare`** invokes `bash scripts/run-runtime-comparison.sh` (`build.zig:312`); `scripts/` was not in scope. It only runs on the explicit `bench-runtime-compare` dev step, not in any consumer build path.

## 7. Prioritized Next Actions

1. **AP-01 (Medium):** Switch the four interval subtractions to a monotonic clock, or apply saturating subtraction (`-|`) at `pool.zig:2019`/`:2113` and `now > last` guards at `:2229`/`:1617`. Add a `submit_ns > start_ns` regression test exercised under `-O Debug` and `-O ReleaseSafe`. **Highest priority** because it is a non-malicious panic-DoS reachable in the safety builds the CI already runs.
2. **AP-02 (Low):** Promote `TaskDescriptor.generation` to `std.atomic.Value(u64)` (`.acquire`/`.release` or `.monotonic`), mirroring the F-003 fix. Zero tier-1 cost; closes a memory-model data race and a latent TSan finding.
3. **AP-03 (Low):** Document the owner-thread / quiescent-slot requirement on the public `registerSubmitter`/`releaseSubmitter` API, and add defense-in-depth (refuse or safely drain on a non-owner release). Add a misuse stress test under `-Dtsan`.
4. **AP-05 (Info):** Drain per-submitter `DescCache`s in `deinitOwned` (or document the `task_desc_live` caveat) so the leak-assertion invariant is total.
5. **AP-04 (Info):** Widen the `quantileScaled` product to `u128`.
6. **AP-06 (Info):** Reconcile `src/root.zig:version` with `build.zig.zon`, or add a CI assertion that they match.
7. **Targeted TSan harnesses** for the AP-02 ghost-duplicate + recycle interleaving and the AP-03 cross-thread release, added to the existing `tsan-stress-soak` / `tsan-fuzz` jobs, to convert the two Medium-confidence static findings into confirmed/refuted.

No confirmed vulnerabilities block shipping `39528a3`; AP-01 is the only finding with real-world DoS impact and should be fixed before the next release tag.
