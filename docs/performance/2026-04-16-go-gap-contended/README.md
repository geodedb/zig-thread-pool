# 2026-04-16 Go-gap contended scenarios plan

Plan: [`docs/superpowers/plans/2026-04-16-go-gap-contended.md`](../../superpowers/plans/2026-04-16-go-gap-contended.md)

## Target scenarios and baseline gaps vs Go

| Scenario | Zig baseline (ops/sec) | Go baseline (ops/sec) | Gap vs Go |
|----------|-----------------------:|----------------------:|:---------:|
| `contended_spawn_8x` | 955,725 | 3,240,636 | 3.39x behind |
| `contended_cpu_10us` | 1,064,456 | 2,587,678 | 2.43x behind |
| `nested_fanout_4x`   | 597,869 | 3,979,197 | 6.66x behind |
| `mixed_fast_slow`    | 225,795 | 245,545 | 1.09x behind (sentinel) |

Source: `baseline.json` — 10 samples, 2 warmup discarded (8 retained), ReleaseFast, 56 workers.

## Host state at baseline capture

```text
 20:16:13 up  7:16,  2 users,  load average: 1.08, 1.65, 1.83
1.08 1.65 1.83 3/1114 1650416
%CPU     PID CMD
26.7   27995 /home/benji/.local/bin/claude --dangerously-skip-permissions
25.0  870622 /home/benji/.local/bin/claude --dangerously-skip-permissions
 2.1 3488926 gopls
 2.0    3629 /usr/bin/tmux
 2.0    1499 /usr/sbin/tailscaled --state=/var/lib/tailscale/tailscaled.state --socket=/run/tailscale/tailscaled.sock --port=41641
 0.8    1469 /usr/bin/dbus-daemon --system --address=systemd: --nofork --nopidfile --systemd-activation --syslog-only
 0.3    3895 /usr/libexec/upowerd
 0.2    2153 sshd-session: benji@pts/0
 0.1 3202921 sshd-session: benji@pts/8
```

Load average 1.08 (1m) on a 56-core host = ~2% utilization. The two Claude processes combined account for ~1 core. The bench harness saturates dozens of cores; 1 core of ambient noise is within tolerance. No co-tenant process exceeds 10% CPU. Proceeding per the decision in the task dispatch.

## Phase status

- [x] Phase 0 — Baseline
- [ ] Phase 1 — `submitBatch` harness adoption
- [ ] Phase 2 — Per-submitter descriptor cache
- [ ] Phase 3 — Per-worker descriptor cache
- [ ] Phase 4 — Final snapshot + docs
