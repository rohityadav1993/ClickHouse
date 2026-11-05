#!/usr/bin/env bash
# Cross-checks of the functions against each other and against the `JSON` type.
# Usage: check.sh <profile> <data.native>
# Env:   CH, MAX_MEMORY (see lib.sh)
# The script fails when a result that must be 0 is not 0. The other lines are for reading.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
load_profile "${1:?usage: $0 <profile> <data.native>}"
S="file('${2:?usage: $0 <profile> <data.native>}', 'Native', 's String')"
require_functions
Q() { "$CH" local --max_memory_usage="$MAX_MEMORY" "$@"; }
JAV="length(JSONAllValues(CAST(s AS JSON(max_dynamic_paths = 0, SKIP REGEXP '$RE'))))"

expect_zero()
{
    echo "$1: $2"
    [ "$2" = 0 ] || { echo "FAILED: expected 0" >&2; exit 1; }
}

echo "== rows where JSONExtractLeafValues differs from JSONExtractLeafPathsAndValues(...).2 (expect 0)"
expect_zero "rows" "$(Q -q "SELECT countIf(JSONExtractLeafValues(s, '$RE') != JSONExtractLeafPathsAndValues(s, '$RE').2) FROM $S")"

echo "== value counts: no skip, 'elements' mode, 'string' mode, 'skip' mode, JSONAllValues with SKIP REGEXP, JSONAllValues without skip"
Q -q "SELECT
    sum(length(JSONExtractLeafValues(s))) AS elements_no_skip,
    sum(length(JSONExtractLeafValues(s, '$RE'))) AS elements,
    sum(length(JSONExtractLeafValues(s, '$RE', 'string'))) AS string_mode,
    sum(length(JSONExtractLeafValues(s, '$RE', 'skip'))) AS skip_mode,
    sum($JAV) AS json_all_values,
    sum(length(JSONAllValues(CAST(s AS JSON(max_dynamic_paths = 0))))) AS json_all_values_no_skip,
    countIf(length(JSONExtractLeafValues(s, '$RE', 'string')) != length(JSONExtractLeafValues(s, '$RE', 'skip'))) AS rows_with_arrays
FROM $S FORMAT TSVWithNames"

echo "== rows where the value count differs from JSONAllValues: 'string' mode (expect 0), 'elements' mode (arrays only)"
expect_zero "string mode" "$(Q -q "SELECT countIf(length(JSONExtractLeafValues(s, '$RE', 'string')) != $JAV) FROM $S")"
echo "elements mode: $(Q -q "SELECT countIf(length(JSONExtractLeafValues(s, '$RE')) != $JAV) FROM $S")"

echo "== rows where the sorted values differ from JSONAllValues in 'string' mode"
echo "(can be above 0: the JSON type infers DateTime64 from ISO date strings and renders arrays as ['x'])"
Q -q "SELECT countIf(arraySort(JSONExtractLeafValues(s, '$RE', 'string')) != arraySort(JSONAllValues(CAST(s AS JSON(max_dynamic_paths = 0, SKIP REGEXP '$RE'))))) FROM $S"

echo "== type_json_use_partial_match_to_skip_paths_by_regexp 0 and 1: value counts (JSONExtractLeafValues, JSONAllValues)"
for pm in 0 1; do
    Q --type_json_use_partial_match_to_skip_paths_by_regexp="$pm" \
        -q "SELECT $pm AS partial_match, sum(length(JSONExtractLeafValues(s, '$RE'))), sum($JAV) FROM $S"
done

echo "== JSON(SKIP REGEXP) with the default max_dynamic_paths: value count (equals json_all_values above)"
Q -q "SELECT sum(length(JSONAllValues(CAST(s AS JSON(SKIP REGEXP '$RE'))))) FROM $S"

echo "== documents that hold each token: with the skip regex and without it"
for entry in "${TOKENS[@]}"; do
    tok=${entry#*=}
    echo "${entry%%=*} ($tok): $(Q -q "SELECT
        countIf(hasAllTokens(arrayStringConcat(JSONExtractLeafValues(s, '$RE'), ' '), '$tok')) AS with_skip,
        countIf(hasAllTokens(arrayStringConcat(JSONExtractLeafValues(s), ' '), '$tok')) AS without_skip
    FROM $S FORMAT TSV")"
done
