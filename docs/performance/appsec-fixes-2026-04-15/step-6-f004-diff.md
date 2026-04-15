# Perf diff — step-6-f004

Generated: 2026-04-15T23:17:41Z

## bench (zig build bench)

| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |
|---|---|---:|---:|---:|---:|---:|---:|
| conn_churn_seq | global_queue | 849306.7347162628 | 1218521.7688795014 | 43.47251929970699% | 1928 | 1181 | -38.7448132780083% |
| conn_churn_seq | work_stealing | 999420.2581705535 | 856564.7237536941 | -14.293840178740977% | 1608 | 2004 | 24.62686567164179% |
| producer_contention | global_queue | 838184.7161846388 | 730113.3244255706 | -12.893505413818811% | 5116 | 5280 | 3.205629397967162% |
| producer_contention | work_stealing | 915306.0353438632 | 874577.1773790271 | -4.449753021625712% | 5888 | 5589 | -5.078125% |

## bench-realistic (zig_thread_pool rows)

| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |
|---|---|---:|---:|---:|---:|---:|---:|
| cpu_work_10us | work_stealing | 225910.1450982457 | 219292.08523769322 | -2.9295098091652187% | 16606 | 18181 | 9.484523666144767% |
| cpu_work_100us | work_stealing | 99244.14172996335 | 99185.68552186548 | -0.05890141934716942% | 27015 | 28389 | 5.0860632981676845% |
| contended_cpu_10us | work_stealing | 211163.01451082673 | 213962.76500144295 | 1.3258716243950346% | 67884 | 68283 | 0.5877673678628248% |
| nested_fanout_4x | work_stealing | 164288.40040106085 | 172898.74427100012 | 5.240993185714695% | 26728 | 27965 | 4.6281053576773425% |
| burst_drain_burst | work_stealing | 82808.1313858655 | 85026.69848960912 | 2.679165761398038% | 19937 | 17257 | -13.442343381652206% |

## Review checklist

Apply the Performance-Regression Review Rule from the plan:

- Throughput regression ≥ 5% on any scenario → BLOCK, escalate to user.
- p95 latency regression ≥ 10% on any scenario → BLOCK, escalate to user.
- 3–5% throughput / 7–10% p95 → WARN, note in commit body.
