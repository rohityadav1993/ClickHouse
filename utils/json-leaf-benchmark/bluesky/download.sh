#!/usr/bin/env bash
# Downloads files of the public JSONBench Bluesky data set (about 1,000,000 documents per file).
# Usage: download.sh <raw-dir> [files=10]
# Interrupted downloads resume. The 10 files are about 10 GB in total (gzip).
set -euo pipefail
DIR=${1:?usage: $0 <raw-dir> [files]}
FILES=${2:-10}
mkdir -p "$DIR"
cd "$DIR"
for i in $(seq "$FILES"); do
    f=$(printf 'file_%04d.json.gz' "$i")
    curl -sSf -C - -O "https://clickhouse-public-datasets.s3.amazonaws.com/bluesky/$f"
done
echo "downloaded $FILES file(s) to $DIR"
