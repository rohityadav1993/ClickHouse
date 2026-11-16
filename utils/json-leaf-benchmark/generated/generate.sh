#!/usr/bin/env bash
# Generates the synthetic data set (one `String` column `s`, Native format).
# Usage: generate.sh <output.native> [rows=1000000]
# Env:   CH   clickhouse binary (default: clickhouse)
set -euo pipefail
OUT=${1:?usage: $0 <output.native> [rows]}
ROWS=${2:-1000000}
CH=${CH:-clickhouse}
HERE=$(cd "$(dirname "$0")" && pwd)
mkdir -p "$(dirname "$OUT")"
"$CH" local --param_rows="$ROWS" --queries-file "$HERE/gen_2k.sql" > "$OUT"
echo "wrote $OUT ($ROWS rows)"
