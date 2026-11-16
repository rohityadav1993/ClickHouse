#!/usr/bin/env bash
# Write-heavy case. For each table A to D: NINS inserts of ROWS rows each into a new table, no `OPTIMIZE`.
# It prints the total insert time, then waits until the background merges stop and prints the time to settle,
# the final and the maximum number of active parts, and the bytes on disk.
# `clickhouse local` cannot be polled between statements, so the script starts its own temporary
# `clickhouse server` (127.0.0.1, free port, data under WORK) and stops it by its PID at the end.
# Usage: bench_writeheavy.sh <profile> <data.native>
# Env:   TABLES="A B C D"
#        NINS=100 ROWS=100000   number of inserts and rows per insert (the first NINS*ROWS rows of the file are used)
#        STABLE=30              seconds without a merge or a change of the part count that count as settled
#        CAP=900                maximum seconds to wait for the merges (the line says CAPPED if it is reached)
#        POLL=5                 seconds between two polls
#        WORK=./work_wh         scratch dir
#        CH, MAX_MEMORY         see lib.sh
# Settle time starts at the end of the last insert and ends at the last observed merge or part count change.
# One `clickhouse client` process starts per insert, which adds about 0.05 s to each.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/lib.sh"
load_profile "${1:?usage: $0 <profile> <data.native>}"
DATA=${2:?usage: $0 <profile> <data.native>}
TABLES=${TABLES:-A B C D}
NINS=${NINS:-100}
ROWS=${ROWS:-100000}
STABLE=${STABLE:-30}
CAP=${CAP:-900}
POLL=${POLL:-5}
WORK=${WORK:-./work_wh}
require_functions
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd)

# Split the first NINS*ROWS rows into NINS Native files, c_0.native to c_<NINS-1>.native.
CHUNKS="$WORK/chunks"
rm -rf "$CHUNKS"
mkdir -p "$CHUNKS"
"$CH" local --max_threads=1 -q "
    INSERT INTO FUNCTION file('$CHUNKS/c_{_partition_id}.native', 'Native', 's String, rn UInt64') PARTITION BY rn
    SELECT s, intDiv(rowNumberInAllBlocks(), $ROWS) AS rn FROM file('$DATA', 'Native', 's String') LIMIT $((NINS * ROWS))"

# Temporary server on a free port.
PORT=$(python3 -I -c "
import socket
s = socket.socket()
s.bind(('127.0.0.1', 0))
print(s.getsockname()[1])
s.close()")
SRV="$WORK/srv"
rm -rf "$SRV"
mkdir -p "$SRV/data" "$SRV/tmp" "$SRV/user_files" "$SRV/log"
cat > "$SRV/config.xml" <<XML
<clickhouse>
  <logger><level>warning</level><log>$SRV/log/server.log</log><errorlog>$SRV/log/error.log</errorlog></logger>
  <listen_host>127.0.0.1</listen_host>
  <tcp_port>$PORT</tcp_port>
  <path>$SRV/data/</path>
  <tmp_path>$SRV/tmp/</tmp_path>
  <user_files_path>$SRV/user_files/</user_files_path>
  <mlock_executable>false</mlock_executable>
  <users><default><password></password><networks><ip>127.0.0.1</ip></networks><profile>default</profile><quota>default</quota></default></users>
  <profiles><default><max_memory_usage>$MAX_MEMORY</max_memory_usage></default></profiles>
  <quotas><default/></quotas>
</clickhouse>
XML
"$CH" server --config-file "$SRV/config.xml" --pid-file "$SRV/pid" > "$SRV/stdout.log" 2>&1 &
SPID=$!
cleanup()
{
    kill "$SPID" 2>/dev/null || true
    wait "$SPID" 2>/dev/null || true
    rm -rf "$CHUNKS" "$SRV"
}
trap cleanup EXIT
C() { "$CH" client --port "$PORT" "$@"; }
for _ in $(seq 60); do
    C -q "SELECT 1" > /dev/null 2>&1 && break
    sleep 1
done
C -q "SELECT 1" > /dev/null || { echo "server did not start, see $SRV/log" >&2; exit 1; }

env_note "start"
echo "# temporary server port=$PORT background_pool_size=$(C -q "SELECT value FROM system.server_settings WHERE name = 'background_pool_size'") inserts=$NINS x $ROWS rows"
printf '%-3s %14s %9s %11s %9s %15s %s\n' tbl total_insert_s settle_s final_parts max_parts bytes_on_disk note
for T in $TABLES; do
    C -q "DROP TABLE IF EXISTS t SYNC"
    C -q "CREATE TABLE t ($(ddl "$T")) ENGINE = MergeTree ORDER BY tuple()"
    insert_sql=$(ins "$T" "input('s String, rn UInt64')")
    t0=$(now)
    for i in $(seq 0 $((NINS - 1))); do
        C -q "INSERT INTO t $insert_sql FORMAT Native" < "$CHUNKS/c_$i.native"
    done
    t1=$(now)
    last_change=$t1
    prev=-1
    max_parts=0
    note=settled
    while :; do
        merges=$(C -q "SELECT count() FROM system.merges WHERE database = 'default' AND table = 't'")
        parts=$(C -q "SELECT count() FROM system.parts WHERE database = 'default' AND table = 't' AND active")
        n=$(now)
        [ "$parts" -gt "$max_parts" ] && max_parts=$parts
        if [ "$merges" != 0 ] || [ "$parts" != "$prev" ]; then last_change=$n; fi
        prev=$parts
        if awk "BEGIN{exit !($n - $last_change >= $STABLE)}"; then break; fi
        if awk "BEGIN{exit !($n - $t1 >= $CAP)}"; then note=CAPPED; last_change=$n; break; fi
        sleep "$POLL"
    done
    disk=$(C -q "SELECT sum(bytes_on_disk) FROM system.parts WHERE database = 'default' AND table = 't' AND active")
    printf '%-3s %14.2f %9.2f %11s %9s %15s %s\n' "$T" "$(awk "BEGIN{print $t1 - $t0}")" "$(awk "BEGIN{print $last_change - $t1}")" "$prev" "$max_parts" "$disk" "$note"
    C -q "DROP TABLE t SYNC"
done
env_note "end"
