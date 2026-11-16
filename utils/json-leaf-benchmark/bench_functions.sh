#!/usr/bin/env bash
# Function cost: runs each case several times with `clickhouse local` and prints the median, min and max
# wall time (s), the median peak RSS (MiB) and the result of the expression summed over all rows.
# Each round runs every case once, so a short burst of load on the machine falls on all cases.
# Usage: bench_functions.sh <profile> <data.native> [runs=5]
# Env:   CH, MAX_MEMORY (see lib.sh)
#        BINS="label=path ..."   binaries to compare, each round runs every case on each of them (default: CH)
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
add "JSONExtractLeafValues, no skip_regex" "length(JSONExtractLeafValues(s))"
add "JSONExtractLeafPathsAndValues, no skip_regex" "length(JSONExtractLeafPathsAndValues(s))"
add "JSONExtractLeafValues, arrays = 'string'" "length(JSONExtractLeafValues(s, '$RE', 'string'))"
add "JSONExtractLeafValues, arrays = 'skip'" "length(JSONExtractLeafValues(s, '$RE', 'skip'))"
add "JSONAllValues(CAST(s AS JSON(max_dynamic_paths = 0, SKIP REGEXP)))" \
    "length(JSONAllValues(CAST(s AS JSON(max_dynamic_paths = 0, SKIP REGEXP '$RE'))))"
extra_function_cases

read -r -a BIN_LIST <<< "${BINS:-default=$CH}"
for b in "${BIN_LIST[@]}"; do
    CH=${b#*=} require_functions
done

# TIMES[key], MEMS[key]: space-separated values per run. RESULT[key]: the result of the last run.
declare -A TIMES MEMS RESULT
env_note "start"
for r in $(seq "$RUNS"); do
    for i in "${!NAMES[@]}"; do
        query="SELECT sum(${EXPRS[$i]}) FROM file('$DATA', 'Native', 's String') $SET"
        for b in "${BIN_LIST[@]}"; do
            key="$i ${b%%=*}"
            out=$(mktemp)
            err=$(mktemp)
            /usr/bin/time -o "$err" -f '%e %M' "${b#*=}" local -q "$query" > "$out"
            RESULT[$key]=$(cat "$out")
            read -r t m < "$err"
            rm -f "$out" "$err"
            TIMES[$key]+="$t "
            MEMS[$key]+="$((m / 1024)) "
        done
    done
    env_note "round $r done"
done

printf '%-72s %-10s %9s %8s %8s %9s  %s\n' case bin median_s min_s max_s rss_MiB "result (sum over all rows)"
for i in "${!NAMES[@]}"; do
    for b in "${BIN_LIST[@]}"; do
        key="$i ${b%%=*}"
        sorted=$(tr ' ' '\n' <<< "${TIMES[$key]}" | grep . | sort -n)
        printf '%-72s %-10s %9s %8s %8s %9s  %s\n' "${NAMES[$i]}" "${b%%=*}" \
            "$(median <<< "$sorted")" "$(head -1 <<< "$sorted")" "$(tail -1 <<< "$sorted")" \
            "$(tr ' ' '\n' <<< "${MEMS[$key]}" | grep . | median)" "${RESULT[$key]}"
    done
done
env_note "end"
