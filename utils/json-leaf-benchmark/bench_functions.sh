#!/usr/bin/env bash
# Function cost: runs each case several times with `clickhouse local` and prints the median, min and max
# wall time (s), the median peak RSS (MiB) and the result of the expression summed over all rows.
# Usage: bench_functions.sh <profile> <data.native> [runs=5]
# Env:   CH, MAX_MEMORY (see lib.sh)
# Cases that differ in result (the `JSON` cast and the nested expression) are for the time only.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
load_profile "${1:?usage: $0 <profile> <data.native> [runs]}"
DATA=${2:?usage: $0 <profile> <data.native> [runs]}
RUNS=${3:-5}
require_functions

NAMES=()
EXPRS=()
add() { NAMES+=("$1"); EXPRS+=("$2"); }

add "JSONLength(s) [parse floor]" "JSONLength(s)"
add "JSONExtractLeafValues" "length(JSONExtractLeafValues(s, '$RE'))"
add "JSONExtractLeafValues (sum of string lengths)" "arraySum(x -> length(x), JSONExtractLeafValues(s, '$RE'))"
add "JSONExtractLeafPathsAndValues" "length(JSONExtractLeafPathsAndValues(s, '$RE'))"
add "JSONExtractLeafPathsAndValues(...).2" "length(JSONExtractLeafPathsAndValues(s, '$RE').2)"
add "JSONAllValues(CAST(s AS JSON(max_dynamic_paths = 0, SKIP REGEXP)))" \
    "length(JSONAllValues(CAST(s AS JSON(max_dynamic_paths = 0, SKIP REGEXP '$RE'))))"
extra_function_cases

env_note "start"
printf '%-72s %9s %8s %8s %9s  %s\n' case median_s min_s max_s rss_MiB "result (sum over all rows)"
for i in "${!NAMES[@]}"; do
    query="SELECT sum(${EXPRS[$i]}) FROM file('$DATA', 'Native', 's String') $SET"
    times=()
    mems=()
    result=
    for _ in $(seq "$RUNS"); do
        out=$(mktemp)
        err=$(mktemp)
        /usr/bin/time -o "$err" -f '%e %M' "$CH" local -q "$query" > "$out"
        result=$(cat "$out")
        read -r t m < "$err"
        rm -f "$out" "$err"
        times+=("$t")
        mems+=("$((m / 1024))")
    done
    sorted=$(printf '%s\n' "${times[@]}" | sort -n)
    printf '%-72s %9s %8s %8s %9s  %s\n' "${NAMES[$i]}" \
        "$(printf '%s\n' "${times[@]}" | median)" "$(head -1 <<< "$sorted")" "$(tail -1 <<< "$sorted")" \
        "$(printf '%s\n' "${mems[@]}" | median)" "$result"
done
env_note "end"
