#!/usr/bin/env bash
# Table cost and search cost for the variants A, B, C, D (and C0, D0, the size-only variants).
# Per build it prints insert time, `OPTIMIZE FINAL` time, bytes on disk and index bytes.
# Then, per token of the profile, it prints the granules the text index selects, the cold time, the warm
# median/min/max, the time without the index, the result and whether the result equals the result without the index.
# Usage: bench_tables.sh <profile> <data.native>
# Env:   TABLES="A B C D"   variants to run (add C0 D0 for the size-only variants, which have no read side)
#        REPEATS=3          builds per variant, run one after another
#        READ=1             0 skips the read side
#        WARM=10            warm runs per token
#        WORK=./work        scratch dir. One database per variant, deleted after the variant is measured.
#        CH, MAX_MEMORY     see lib.sh
# Cold: the first query of a new `clickhouse local` process after SYSTEM DROP MARK CACHE, UNCOMPRESSED CACHE and
#       TEXT INDEX CACHES. The operating system page cache stays, so cold still reads from page cache.
# Warm: the runs after the first one, in the same process.
# Read query: sum(cityHash64(s)). It reads the whole column s for each matching granule, so the table
# variants do the same work. (A query such as sum(length(s)) can be rewritten to the subcolumn s.size on
# some variants and not on others.)
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
load_profile "${1:?usage: $0 <profile> <data.native>}"
DATA=${2:?usage: $0 <profile> <data.native>}
TABLES=${TABLES:-A B C D}
REPEATS=${REPEATS:-3}
READ=${READ:-1}
WARM=${WARM:-10}
WORK=${WORK:-./work}
SRC="file('$DATA', 'Native', 's String')"
require_functions
mkdir -p "$WORK"

env_note "start"
printf '%-4s %-3s %9s %10s %15s %12s\n' run tbl insert_s optimize_s bytes_on_disk index_bytes
[ "$READ" = 1 ] && printf '  read: %-3s %-8s %-10s %8s %8s %8s %8s %9s %11s %20s %5s\n' tbl role granules cold_s warm_med warm_min warm_max noidx_s rows sum_cityhash match

for R in $(seq 1 "$REPEATS"); do
for T in $TABLES; do
    DB="$WORK/db_$T"
    rm -rf "$DB"
    q "$DB" "CREATE TABLE t ($(ddl "$T")) ENGINE = MergeTree ORDER BY tuple()"
    t0=$(now)
    q "$DB" "INSERT INTO t $(ins "$T" "$SRC") $SET"
    t1=$(now)
    q "$DB" "OPTIMIZE TABLE t FINAL $SET"
    t2=$(now)
    disk=$(q "$DB" "SELECT sum(bytes_on_disk) FROM system.parts WHERE database = 'default' AND table = 't' AND active")
    idxb=$(q "$DB" "SELECT sum(data_compressed_bytes) FROM system.data_skipping_indices WHERE database = 'default' AND table = 't'")
    printf '%-4s %-3s %9.2f %10.2f %15s %12s\n' "$R" "$T" "$(awk "BEGIN{print $t1 - $t0}")" "$(awk "BEGIN{print $t2 - $t1}")" "$disk" "$idxb"

    if [ "$READ" = 1 ] && [ "$T" != C0 ] && [ "$T" != D0 ]; then
        e=$(expr "$T")
        for entry in "${TOKENS[@]}"; do
            role=${entry%%=*}
            tok=${entry#*=}
            query="SELECT count(), sum(cityHash64(s)) FROM t WHERE hasAllTokens($e, '$tok')"
            gran=$(q "$DB" "SELECT extract(explain, 'Granules: (\\\\d+/\\\\d+)') FROM (EXPLAIN indexes = 1 SELECT sum(cityHash64(s)) FROM t WHERE hasAllTokens($e, '$tok') $SET) WHERE explain LIKE '%Granules:%'" | tail -1)
            sql=$(mktemp)
            out=$(mktemp)
            err=$(mktemp)
            {
                echo "SYSTEM DROP MARK CACHE;"
                echo "SYSTEM DROP UNCOMPRESSED CACHE;"
                echo "SYSTEM DROP TEXT INDEX CACHES;"
                echo "$query $SET FORMAT TSV;"
                for _ in $(seq "$WARM"); do echo "$query $SET FORMAT TSV;"; done
                echo "$query SETTINGS use_skip_indexes = 0, max_memory_usage = $MAX_MEMORY FORMAT TSV;"
            } > "$sql"
            "$CH" local --path "$DB" --multiquery --time < "$sql" > "$out" 2> "$err"
            # Elapsed-time lines on stderr: 3 SYSTEM statements, 1 cold, WARM warm, 1 without the index.
            grep -E '^[0-9]+(\.[0-9]+)?$' "$err" > "$err.t"
            cold=$(sed -n 4p "$err.t")
            warm=$(sed -n "5,$((4 + WARM))p" "$err.t")
            noidx=$(sed -n "$((5 + WARM))p" "$err.t")
            match=OK
            [ "$(wc -l < "$out")" = "$((WARM + 2))" ] || match=ERROR
            [ "$(sort -u "$out" | wc -l)" = 1 ] || match=DIFF
            sorted=$(sort -n <<< "$warm")
            printf '  read: %-3s %-8s %-10s %8s %8s %8s %8s %9s %11s %20s %5s\n' "$T" "$role" "$gran" "$cold" \
                "$(median <<< "$warm")" "$(head -1 <<< "$sorted")" "$(tail -1 <<< "$sorted")" "$noidx" \
                "$(sed -n 1p "$out" | cut -f1)" "$(sed -n 1p "$out" | cut -f2)" "$match"
            rm -f "$sql" "$out" "$err" "$err.t"
            [ "$match" = OK ] || { echo "result check failed for table $T, token $tok ($match)" >&2; exit 1; }
        done
    fi
    rm -rf "$DB"
done
done
env_note "end"
