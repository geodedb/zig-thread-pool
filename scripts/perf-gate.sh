#!/usr/bin/env bash
# scripts/perf-gate.sh
# Usage: ./scripts/perf-gate.sh <step-name> <before|after>
# Captures bench + bench-realistic JSON, and when called with "after"
# emits a markdown diff vs the matching "before" file.

set -euo pipefail

STEP="${1:?step name required (e.g. step-1-f001)}"
PHASE="${2:?phase required: before | after}"
ART_DIR="docs/performance/appsec-fixes-2026-04-15"

if [[ "$PHASE" != "before" && "$PHASE" != "after" ]]; then
    echo "phase must be 'before' or 'after'" >&2
    exit 2
fi

mkdir -p "$ART_DIR"

BENCH_OUT="$ART_DIR/${STEP}-${PHASE}-bench.json"
REAL_OUT="$ART_DIR/${STEP}-${PHASE}-realistic.json"

echo "[perf-gate] $STEP $PHASE: running zig build bench ..."
zig build bench -- --output "$BENCH_OUT"

echo "[perf-gate] $STEP $PHASE: running zig build bench-realistic ..."
zig build bench-realistic -Doptimize=ReleaseFast -- --output "$REAL_OUT"

if [[ "$PHASE" == "after" ]]; then
    DIFF_OUT="$ART_DIR/${STEP}-diff.md"
    BEFORE_BENCH="$ART_DIR/${STEP}-before-bench.json"
    BEFORE_REAL="$ART_DIR/${STEP}-before-realistic.json"

    if [[ ! -f "$BEFORE_BENCH" || ! -f "$BEFORE_REAL" ]]; then
        echo "[perf-gate] ERROR: missing before-files. Run '$STEP before' first." >&2
        exit 3
    fi

    {
        echo "# Perf diff — $STEP"
        echo
        echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "## bench (zig build bench)"
        echo
        echo "| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |"
        echo "|---|---|---:|---:|---:|---:|---:|---:|"
        jq -r --slurpfile bef "$BEFORE_BENCH" '
          .rows as $aft
          | $bef[0].rows as $bfr
          | $aft
          | map({
              scenario_name, scheduler_variant,
              ops_after: .throughput_ops_per_sec,
              p95_after: .submit_latency_p95_ns,
              key: (.scenario_name + "|" + .scheduler_variant)
            })
          | .[] as $a
          | $bfr
          | map(select((.scenario_name + "|" + .scheduler_variant) == $a.key))
          | if length == 0 then
              [$a.scenario_name, $a.scheduler_variant, "n/a", $a.ops_after, "n/a", "n/a", $a.p95_after, "n/a"]
            else
              . [0] as $b
              | [
                  $a.scenario_name, $a.scheduler_variant,
                  ($b.throughput_ops_per_sec | tostring),
                  ($a.ops_after | tostring),
                  ((($a.ops_after - $b.throughput_ops_per_sec) / $b.throughput_ops_per_sec * 100) | tostring + "%"),
                  ($b.submit_latency_p95_ns | tostring),
                  ($a.p95_after | tostring),
                  ((($a.p95_after - $b.submit_latency_p95_ns) / $b.submit_latency_p95_ns * 100) | tostring + "%")
                ]
            end
          | "| " + join(" | ") + " |"
        ' "$BENCH_OUT"
        echo
        echo "## bench-realistic (zig_thread_pool rows)"
        echo
        echo "| scenario | variant | ops/s before | ops/s after | Δ % | p95 submit before (ns) | p95 submit after (ns) | Δ p95 % |"
        echo "|---|---|---:|---:|---:|---:|---:|---:|"
        jq -r --slurpfile bef "$BEFORE_REAL" '
          .rows as $aft
          | $bef[0].rows as $bfr
          | $aft
          | map({
              scenario_name, scheduler_variant,
              ops_after: .throughput_ops_per_sec,
              p95_after: .submit_latency_p95_ns,
              key: (.scenario_name + "|" + .scheduler_variant)
            })
          | .[] as $a
          | $bfr
          | map(select((.scenario_name + "|" + .scheduler_variant) == $a.key))
          | if length == 0 then
              [$a.scenario_name, $a.scheduler_variant, "n/a", ($a.ops_after | tostring), "n/a", "n/a", ($a.p95_after | tostring), "n/a"]
            else
              .[0] as $b
              | [
                  $a.scenario_name, $a.scheduler_variant,
                  ($b.throughput_ops_per_sec | tostring),
                  ($a.ops_after | tostring),
                  ((($a.ops_after - $b.throughput_ops_per_sec) / $b.throughput_ops_per_sec * 100) | tostring + "%"),
                  ($b.submit_latency_p95_ns | tostring),
                  ($a.p95_after | tostring),
                  ((($a.p95_after - $b.submit_latency_p95_ns) / $b.submit_latency_p95_ns * 100) | tostring + "%")
                ]
            end
          | "| " + join(" | ") + " |"
        ' "$REAL_OUT"
        echo
        echo "## Review checklist"
        echo
        echo "Apply the Performance-Regression Review Rule from the plan:"
        echo "- Throughput regression ≥ 5% on any scenario → BLOCK, escalate to user."
        echo "- p95 latency regression ≥ 10% on any scenario → BLOCK, escalate to user."
        echo "- 3–5% throughput / 7–10% p95 → WARN, note in commit body."
    } > "$DIFF_OUT"

    echo "[perf-gate] diff written to $DIFF_OUT"
fi

echo "[perf-gate] done."
