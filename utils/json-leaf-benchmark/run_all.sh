#!/usr/bin/env bash
# Runs the benchmark steps for one data set and writes one result file per step.
# Usage: run_all.sh <profile> <data.native> [out-dir]
# Env:   STEPS="functions tables check"   steps to run. Other step: sizeonly (tables C0 and D0), writeheavy.
#        FUNC_RUNS=5, REPEATS=3, WARM=10  repeat counts (see the step scripts)
#        CH, MAX_MEMORY, WORK              see the step scripts
# Run it on a quiet machine, one process at a time. Each result file starts and ends with a load-average line.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
PROFILE=${1:?usage: $0 <profile> <data.native> [out-dir]}
DATA=${2:?usage: $0 <profile> <data.native> [out-dir]}
OUT=${3:-./results_$(date -u +%Y-%m-%d_%H%M%S)}
STEPS=${STEPS:-functions tables check}
mkdir -p "$OUT"
for step in $STEPS; do
    echo "== $step"
    case $step in
        functions) bash "$HERE/bench_functions.sh" "$PROFILE" "$DATA" "${FUNC_RUNS:-5}" ;;
        tables) bash "$HERE/bench_tables.sh" "$PROFILE" "$DATA" ;;
        sizeonly) READ=0 TABLES="C0 D0" REPEATS=1 bash "$HERE/bench_tables.sh" "$PROFILE" "$DATA" ;;
        writeheavy) bash "$HERE/bench_writeheavy.sh" "$PROFILE" "$DATA" ;;
        check) bash "$HERE/check.sh" "$PROFILE" "$DATA" ;;
        *) echo "unknown step $step" >&2; exit 1 ;;
    esac > "$OUT/res_$step.txt" 2>&1 || { echo "step $step failed, see $OUT/res_$step.txt" >&2; exit 1; }
done
echo "results in $OUT"
