#!/usr/bin/env bash
# Converts the raw JSONBench files into Native files with one `String` column `s` (one document per row).
# Lines that are not valid JSON are dropped. Three upstream files (5 to 7) hold one document cut at 65,535
# bytes, each followed by a fragment line, so 6 lines are dropped from the 10 files.
# Usage: convert.sh <raw-dir> <out-dir> [files=10]
# Output: <out-dir>/bluesky_1m.native (file 1) and <out-dir>/bluesky_10m.native (all files, in file order)
# Env:   CH   clickhouse binary (default: clickhouse)
set -euo pipefail
RAW=$(cd "${1:?usage: $0 <raw-dir> <out-dir> [files]}" && pwd)
OUT=${2:?usage: $0 <raw-dir> <out-dir> [files]}
FILES=${3:-10}
CH=${CH:-clickhouse}
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)
LAST=$(printf '%04d' "$FILES")
"$CH" local --engine_file_truncate_on_insert=1 -q "
    INSERT INTO FUNCTION file('$OUT/bluesky_1m.native', 'Native', 's String')
    SELECT s FROM file('$RAW/file_0001.json.gz', 'LineAsString', 's String') WHERE isValidJSON(s)"
if [ "$FILES" -gt 1 ]; then
    "$CH" local --engine_file_truncate_on_insert=1 -q "
        INSERT INTO FUNCTION file('$OUT/bluesky_10m.native', 'Native', 's String')
        SELECT s FROM file('$RAW/file_{0001..$LAST}.json.gz', 'LineAsString', 's String') WHERE isValidJSON(s) ORDER BY _path"
fi
echo "wrote $OUT/bluesky_1m.native$([ "$FILES" -gt 1 ] && echo " and $OUT/bluesky_10m.native")"
