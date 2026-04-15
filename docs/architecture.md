# Architecture

## High-Level Model

`thread-pool` is built around bounded task descriptors and a fixed worker cap.
The implementation exposes one public API while swapping scheduler behavior
behind the scenes.

The important pieces are:

- a bounded descriptor pool for tasks
- a global inject queue for externally submitted work
- optional per-worker local queues for work-stealing variants
- optional blocking-lane routing for isolating long-running work
- per-worker scratch allocators and runtime stats

## Scheduler Layout

- `global_queue`: all work is pushed into the shared inject queue
- `work_stealing`: workers prefer local work and steal from peers
- `lane_extension`: extends work stealing with dedicated blocking-lane workers

## Queue Strategy

- `BoundedRing` is used for the global inject queue
- `RingQueue` is the default per-worker queue
- `WorkDeque` remains exported for experimentation and testing

## Resource Model

- task descriptors are bounded by `queue_capacity`
- worker-local queue capacity is bounded independently
- scratch allocation is bounded by `worker_scratch_cap_bytes`
- `purgeWorkerCaches()` is allowed only when the pool is quiescent

## Observability

`statsSnapshot()` exposes:

- task lifecycle counters
- queue depth and wake/park behavior
- latency histograms
- allocation and process-memory counters
- per-worker scratch and queue information

## Further Reading

- [DESIGN.md](DESIGN.md)
- [SCHEDULER_DECISION.md](SCHEDULER_DECISION.md)
- [PERFORMANCE_TRACKING.md](PERFORMANCE_TRACKING.md)
