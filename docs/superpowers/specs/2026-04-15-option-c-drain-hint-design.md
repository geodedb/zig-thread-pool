# Option C — Drain-Hint Ordering (Design)

**Parent brainstorm:** `docs/superpowers/brainstorms/2026-04-15-inject-head-contention.md`
**Target hotspot:** `BoundedRing.popMany` at 16.64% worker self-time;
13.43% pure atomic loads on `inject_queue.head` and per-slot
`sequence` cachelines (v2 profile 2026-04-14).
**Status:** CLOSED 2026-04-15 — implementation passed unit tests
but SIGSEGV'd in `test-stress` `phase h: double-dequeue race
reproducer` at ~15% rate (2/13 ReleaseFast runs). Same failure
signature as Option D's blocked reorder. See "Failure mode" at
bottom of this doc.

## Intent

Replace today's "every worker tries `popMany` every `nextTask`
iteration" (→ 56-way head-CAS contention) with a *hint-based*
ordering:

1. Only the worker the submitter *just woke* is expected to drain
   the inject queue on its next `nextTask` pass.
2. Non-hinted workers bitmap-steal from peers first; they fall back
   to `popMany` only if bitmap-steal returns nothing.

Under saturation this makes inject-queue head contention 1-way
most of the time; it becomes N-way only when the pool has drained
all distributed work and multiple workers simultaneously fall
through to the `popMany` fallback — i.e. precisely the moments
where contention is cheap because there's nothing else to do.

## Non-goals

- Not modifying `BoundedRing` semantics or `popMany` API. The hint
  is external: everyone still calls the same unchanged `popMany`.
- Not touching shutdown synchronization. `cancelQueuedTasks`
  continues to drain `inject_queue` via `inject_queue.pop()` under
  `state != .running`; worker's hint logic becomes moot during
  shutdown because the hint is never set while shutdown is pending
  (the only hint writer is `notifySubmits`, gated by `enqueueTask`
  which runs only when `state == .running`).
- Not touching the wake-one-per-notify invariant or the park
  handshake (seq_cst `queued_tasks` + `is_parked` pair).

## Data

Add one field to `Core`:

```zig
/// Latest hint from `notifySubmits` — the index of the worker the
/// submitter just woke (or attempted to). Workers read this in
/// `nextTask` to decide whether to drain inject *before* bitmap-steal
/// (hinted) or only as a fallback (non-hinted). Monotonic store
/// suffices: the hint is advisory; wrong reads degrade to today's
/// behavior (redundant popMany calls), never to a lost item.
/// Initial -1 = "no hint" (pre-first-submit and post-drain).
drain_hint: std.atomic.Value(i32) align(std.atomic.cache_line) =
    std.atomic.Value(i32).init(-1),
```

Own cacheline to avoid false sharing with `workers_nonempty` and
`counters`. Hint is written by the submitter thread (at most one
writer per notify) and read by 56 consumers — low write traffic,
high read traffic: shared-state cacheline with rare invalidations.

## Producer side (`notifySubmits`)

After the existing wake-scan loop, store the last-targeted index.
Two variants considered; prefer V1 for simplicity:

### V1 (preferred)

```zig
var woke_idx: i32 = -1;
while (off < self.workers.len) : (off += 1) {
    const idx = (hint_idx + off) % self.workers.len;
    // ... existing park/signal logic ...
    if (/* signaled */) { woke_idx = @intCast(idx); break; }
}
if (woke_idx >= 0) {
    self.drain_hint.store(woke_idx, .monotonic);
}
```

- If no worker was parked (`woke_idx < 0`), leave the hint stale.
  Rationale: hint staleness only means "some worker other than the
  truly-hinted one will drain" — a mild efficiency loss, not a
  correctness issue. A parked-free pool is already saturated;
  whoever finishes their task first will fall through to the
  fallback `popMany`.
- `.monotonic` because the hint is advisory. If a worker reads a
  stale value, it either (a) is the stale target and drains
  (correct, just not optimal) or (b) is not the target and relies
  on fallback `popMany`. Neither outcome violates safety.

### V2 (rejected)

Clear-hint-on-no-wake (`drain_hint.store(-1)` when `woke_idx < 0`)
makes the hint "definitely fresh or -1." Complicates the reader
and buys nothing: a -1 hint means every worker falls through to
step 5 fallback, which is exactly today's all-workers-popMany
behavior. So clearing is strictly worse than leaving stale.

## Consumer side (`nextTask`)

Current `nextTask` order (work_stealing path):

1. LIFO slot
2. `popBottom` (own local)
3. `popMany` (inject drain)
4. bitmap-steal (peer locals)

Proposed:

1. LIFO slot
2. `popBottom`
3. **IF `drain_hint == worker_index`:** `popMany`. If n > 0, return.
4. bitmap-steal. If success, return.
5. **`popMany` (fallback for non-hinted workers, or hinted-but-empty).**
   If n > 0, return.
6. `steal_failures++`, return null.

Step 3 is the "hinted-first" path: the worker the submitter just
woke attempts inject drain before any peer-steal. Step 5 is the
"everyone else" fallback: after failing bitmap-steal (bitmap read
showed no peer has stealable work), the worker tries inject.

### Why this ordering works

Under `flood_1m_batched` (target scenario):

- Submitter pushes 64-item batch → wakes worker W via notify →
  `drain_hint := W`.
- W runs `nextTask`: step 3 fires (hint matches). `popMany(32)`
  succeeds. W distributes 31 items to its local queue via
  `tryPushBottom`, keeps 1 for itself. Returns.
- W's `markWorkerNonEmpty(W)` flips W's bit in `workers_nonempty`.
- Other workers run `nextTask`: steps 1-2 empty, step 3 skipped
  (hint ≠ their index), step 4 bitmap-steal succeeds (W is set).
  They each stealHalf from W. W's local drains quickly.
- Submitter pushes next 64-item batch → notifySubmits scans for
  parked workers. Most are busy (running tasks they stole from W).
  Woke a different parked worker W' → `drain_hint := W'`.
- Cycle repeats with W' as drainer.

Number of concurrent `popMany` calls per submit batch: 1 (hinted)
if W drains before peers expand — otherwise some fallback calls
once W's local drains. Far below today's 56.

Under `contended_spawn_8x`:

- 8 worker threads spawn tasks *from within* workers. These go to
  the owning worker's LIFO/local queue (step 1-2 of submit), not
  inject.
- Inject queue rarely has items.
- Hint is usually stale or -1. All workers read step 3 false.
- Bitmap-steal dominates (step 4). Fallback `popMany` (step 5) is
  rarely reached and when it is, inject is likely empty.
- Net behavior ≈ today. Expected: neutral.

Under `flood_1m` (unbatched):

- Single submitter, 1 item per push, hint cycles per-submit.
- Hinted worker drains 1 item via popMany. Distributes 0 to local
  (only 1 item, which it runs itself). Nothing to steal.
- Non-hinted workers: step 4 finds empty bitmap (hinted worker's
  local has nothing). Step 5 fallback popMany — may or may not
  find items depending on submitter rate.
- This is the weakest scenario for Option C — the drain-distribute
  pattern is broken (no distribution with batch=1), so non-hinted
  workers must popMany-fallback.
- Expected: neutral to slight win (fallback popMany still has
  contention, but the hinted worker gets a clean drain first).

## Correctness

### No lost wakeups

The park handshake is unchanged:

```text
submitter:  push → queued_tasks.fetchAdd(.seq_cst) → is_parked.load(.seq_cst) → signal
worker:     is_parked.store(.seq_cst) → queued_tasks.load(.seq_cst) → wait
```

The SC total order still guarantees the parking worker either
observes the submitter's `queued_tasks` increment (and bails out)
or the submitter observes `is_parked == 1` (and signals). The
hint is orthogonal — it only affects *which* consumer path the
woken worker takes in `nextTask`, never whether it wakes.

### No stuck items

A stuck item would require all workers to indefinitely skip
`popMany`. That can't happen because:

- A worker only skips step 3's popMany if the hint doesn't match.
- A worker only skips step 5's popMany if step 4 bitmap-steal
  succeeded — i.e. it's making progress, will return, re-enter
  `nextTask`, try again.
- When a worker reaches step 5, it always calls popMany. So the
  fallback guarantees drain under quiescence.

### No races with `cancelQueuedTasks`

`cancelQueuedTasks` drains inject via `inject_queue.pop()` (not
`popMany`). This is already concurrent with worker popMany calls
on HEAD — the ring is MPMC-safe for concurrent consumers. Adding
a hint doesn't change that.

Shutdown path:

- `shutdown(.cancel_pending)` calls `cancelQueuedTasks` first,
  draining inject while `state == .shutdown_requested`.
- Workers still in `nextTask` may hit step 3 or step 5 popMany
  concurrent with shutdown's pop. Both paths call the same ring
  operations — already safe today.
- No worker uses the hint for correctness; the hint never
  transitions a worker into park or into a shutdown-specific
  state. Nothing to synchronize.

### Hint staleness

- Race: submitter stores hint W, worker W' (W' ≠ W) reads hint = W,
  skips step 3. Later reads hint = W' (after later notify)…
  Worker W runs nextTask, reads hint = W, popMany. Fine.
- Race: two submitters race, hint flickers. At most one worker is
  the current hint target at any instant (monotonic store is
  atomic). Worst case: both hint targets drain in parallel — 2-way
  contention. Still far below 56-way.
- Race: worker reads hint = self, commits to step 3, but by the
  time popMany runs, hint has moved. Worker still drains as if
  hinted. Correct behavior — just an extra drainer this cycle.

## Measurement plan

1. `zig build test` (unit) — must pass.
2. `zig build test-stress` 20× (ReleaseFast) — required per
   project measurement rules (submit-path change).
3. Paired n=10 BSSB A/B against `d9f509c` (current main):
    - `flood_1m_batched` — primary gate scenario.
    - `flood_1m` — secondary, check for unbatched regression.
    - `contended_spawn_8x` — regression guard, inject-light.
    - `contended_spawn_8x_batched` — regression guard.
4. Gate:
    - ≥+15% flood_1m_batched CLEAN → land.
    - +5..+15% flood_1m_batched with no CLEAN regression elsewhere
      → land.
    - <+5% or any CLEAN regression → revert and close Option C.

## Rejected variants

### C-sticky — single long-lived drainer

Maintain a `drainer_index` that persists across submits, only
rotating when the current drainer parks or CAS-claims release.
Rejected because it fails the "drainer busy" case: if the
designated drainer is mid-task when inject fills, nobody else
drains and inject backs up to backpressure. The hint-per-notify
design is self-healing because each notify targets a parked (not
busy) worker.

### C-cas-takeover — any worker can CAS-claim drainer role

After K bitmap-steal failures, worker attempts
`drainer_index.cmpxchgStrong(current, self)` and drains on
success. Rejected as redundant with the step-5 fallback — the
fallback already gives non-hinted workers a chance to popMany
under quiescence, with zero CAS overhead.

### C-queue-of-drainers — lock-free queue of candidate drainers

Submitters enqueue indices; drainers dequeue. Rejected as
massively overcomplicated for a contention reduction that the
simpler step-5 fallback already provides.

## Open questions

1. Does monotonic/release-acquire matter for `drain_hint`?
    - Monotonic store on submitter side is safe because the hint
      is a pure hint (no synchronizes-with obligations on the
      *pointed-at worker*). The worker's popMany has its own
      `.acquire` load on inject head/tail for the items themselves.
    - `.acquire` load on consumer side is cheap — single shared
      cacheline, no release paired with it beyond read-my-own-recent.
    - Decision: monotonic store + monotonic load. Revisit if a
      memory-model concern surfaces during implementation.

2. Should the hint be the *woken* worker or the *wake-scan start*?
    - Woken worker (V1 above) is simpler: we know exactly who
      got the signal.
    - Wake-scan start (`hint_idx` from line 711 before the loop)
      would give a prediction even when no worker was parked.
    - Decision: start with V1. If the "no worker parked" case
      matters, revisit later.

3. Should multiple hints coexist (a small bitmap of hinted workers
   rather than a single index)?
    - Not needed for the primary gate. Single-drainer is
      sufficient to cut 56-way contention to 1-way.
    - Deferred.

## Implementation sketch (for next iteration)

No code changes in this iteration. The expected diff when
implementing:

1. Add `drain_hint` field to `Core` struct.
2. Add `drain_hint.store(...)` to the tail of `notifySubmits`'s
   wake-scan loop (inside the `break` branch).
3. Refactor `nextTask`'s work-stealing block: extract inject
   drain to a helper or duplicate the popMany block once (step 3
   and step 5), gated by the hint check.
4. No changes to `BoundedRing`, `cancelQueuedTasks`,
   `workers_nonempty`, park/unpark, or the submit path.

Estimated diff: ~30 lines of code + struct field.

## Rollback plan

If stress/A-B fails: revert the nextTask + notifySubmits changes
(single commit), leave the struct field in place for a follow-up
iteration. Update this doc with the failure mode.

## Failure mode (2026-04-15)

Implemented per the spec. `zig build test` PASS. `zig build
test-stress -Doptimize=ReleaseFast` crashed with **signal 11
(SIGSEGV)** in `stress.double_dequeue_race.test.phase h:
double-dequeue race reproducer` at a ~15% rate across 13 runs
(2 failures, both in that single test; pre-change control was
5/5 PASS). Failing seed example: `0x186b1479`.

### Why the correctness proof missed it

The spec's "No races with `cancelQueuedTasks`" section argued
that ring operations already tolerate concurrent consumers and
that shutdown is safe. That is true of the ring, but the SIGSEGV
target is `double_dequeue_race` — a test that exercises the
phase-H ghost-duplicate path where a descriptor can be emitted
by multiple queue paths concurrently and must be filtered via
the atomic `.queued → .running` transition in `runTask`. The
design didn't reason about whether changing the *order* of inject
drain vs bitmap-steal for non-hinted workers changes the duplicate
emission rate or visibility window, and evidently it does.

### Why the same symptom as Option D

Option D was "popMany-after-bitmap-steal only" — the exact
pattern this implementation applies to non-hinted workers (step
4 before step 5). Any change that moves inject drain *after*
bitmap-steal re-creates Option D's SIGSEGV signature. The design
doc's brainstorm noted D was "blocked on understanding the
SIGSEGV root cause" — Option C inherited that block the moment
it made non-hinted workers drain-last.

### Remaining paths forward

1. **Hint-only, no fallback** — step 5 removed. Non-hinted
   workers never touch inject. Loses forward-progress guarantee
   under stale-hint quiescence; would need a replacement
   quiescence safety net (e.g., hinted worker re-hints before
   parking, or a periodic "any-worker-can-drain" tick). Not yet
   designed.
2. **Hint-only with pre-park drain** — non-hinted workers skip
   inject in nextTask but drain it once before calling `park`.
   Keeps quiescence safety, avoids bitmap-steal-then-drain
   reorder. Would need new design doc.
3. **Post-mortem on the SIGSEGV** — before any Option D / C
   variant, instrument or `rr`-record the crash to learn whether
   duplicates leak through `.queued → .running` or whether this
   is a distinct use-after-free in the stealing/shutdown path.
   Capturing a core dump + backtrace from the failing seed is
   the prerequisite for all reorder-based attacks.

### Reverted changes

`src/pool.zig` working-tree changes discarded (never committed).
The `drain_hint` field from the spec was NOT retained in-tree;
the closed-out design doc stands on its own. A future iteration
that re-opens this attack should re-derive from the design.
