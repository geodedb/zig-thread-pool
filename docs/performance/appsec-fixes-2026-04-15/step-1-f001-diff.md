# Perf diff — step-1-f001

Generated: 2026-04-15T21:42:57Z

## bench (zig build bench)

| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |
|---|---|---:|---:|---:|---:|---:|---:|
| conn_churn_seq | global_queue | 1754329.6092376418 | 811641.5072991262 | -53.7349479239633% | 771 | 2076 | 169.26070038910507% |
| conn_churn_seq | work_stealing | 1029570.2323495693 | 876839.3878993167 | -14.834426992096251% | 1824 | 1920 | 5.263157894736842% |
| producer_contention | global_queue | 933101.030056059 | 828285.9657296682 | -11.232981311797904% | 5670 | 6004 | 5.890652557319224% |
| producer_contention | work_stealing | 917707.0408473734 | 924368.5531443086 | 0.7258865847628481% | 5959 | 5932 | -0.45309615707333445% |

## bench-realistic (zig_thread_pool rows)

| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |
|---|---|---:|---:|---:|---:|---:|---:|
| cpu_work_10us | work_stealing | 222712.11463705217 | 221840.91712407122 | -0.3911765259832069% | 18322 | 16890 | -7.815740639668159% |
| cpu_work_100us | work_stealing | 99182.98020059758 | 99983.48772700189 | 0.8071017071530672% | 25543 | 27710 | 8.48373331245351% |
| contended_cpu_10us | work_stealing | 209989.62210288606 | 211726.60057423217 | 0.8271734831234022% | 69420 | 68452 | -1.3944108326130797% |
| nested_fanout_4x | work_stealing | 171674.17340602248 | 189616.30760922658 | 10.451271642805343% | 25451 | 25199 | -0.9901379120663235% |
| burst_drain_burst | work_stealing | 82942.70601946943 | 83147.53669810072 | 0.24695442005859924% | 22419 | 18448 | -17.712654444890493% |

## Review checklist

Apply the Performance-Regression Review Rule from the plan:

- Throughput regression ≥ 5% on any scenario → BLOCK, escalate to user.
- p95 latency regression ≥ 10% on any scenario → BLOCK, escalate to user.
- 3–5% throughput / 7–10% p95 → WARN, note in commit body.
