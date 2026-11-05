# Benchmark of `JSONExtractLeafValues`

These scripts compare a text index on a `String` column that holds JSON,
using `JSONExtractLeafValues` in the index expression, with three table layouts
that use the `JSON` type. They also measure the cost of the functions alone.

## Requirements

- A `clickhouse` binary with `JSONExtractLeafValues`. Set it with `CH=/path/to/clickhouse` (default: `clickhouse` from `PATH`).
- `bash`, `python3`, `curl` (Bluesky download only), GNU `time` at `/usr/bin/time`, a Linux `/proc/loadavg`.
- Disk space: the generated set is about 3.8 GB, the 10 Bluesky files are about 10 GB (gzip) and 5 GB (Native). A table build needs about 3 GB more.
- Run on a quiet machine, one process at a time. Every result file starts and ends with a line that has the load average.

## Table variants

All tables use `ENGINE = MergeTree ORDER BY tuple()` and a text index with `tokenizer = splitByNonAlpha`. Queries use `hasAllTokens`.

| Table | Stores | Index expression |
|---|---|---|
| A | `s String` | `JSONExtractLeafValues(s, <regex>)` |
| B | `s String` and `vals Array(String)` from `JSONAllValues(CAST(s AS JSON(max_dynamic_paths = 0, SKIP REGEXP ...)))` | `vals` |
| C | `s String` and `j JSON` (default `max_dynamic_paths`) | `JSONAllValues(j)` |
| D | `s String` and `j JSON(max_dynamic_paths = 0)` | `JSONAllValues(j)` |
| C0, D0 | Like C and D without `s` (size only) | `JSONAllValues(j)` |

## Data sets and profiles

A profile in `profiles/` sets the skip regex, the `JSON` types of C and D, and the search tokens. Pass its name as the first argument of every script.

- `generated`: synthetic documents with about 2,000 distinct paths. Skip regex `.*_noindex$`. Tokens `zxneedle` (indexed, 50 rows) and `zxskipped` (only inside a `_noindex` subtree, 50 rows).
- `bluesky`: the public JSONBench Bluesky data. Skip regex `^commit[.]record[.](subject|embed|reply|facets)([.].*|[[].*)?$`, also used as `SKIP REGEXP` in C and D. Tokens: a rare one, a common one and one that occurs only in a skipped subtree.

Make the data:

```bash
# Generated set, 1,000,000 rows. The second argument is optional.
bash generated/generate.sh data/gen_2k.native 1000000

# Bluesky. 10 files, about 1,000,000 documents each.
bash bluesky/download.sh data/raw 10
bash bluesky/convert.sh data/raw data 10      # writes data/bluesky_1m.native and data/bluesky_10m.native
```

`convert.sh` drops lines that are not valid JSON (6 lines in the 10 files).

## Steps

Each script takes `<profile> <data.native>` and prints a table to the standard output.

| Script | What it measures |
|---|---|
| `bench_functions.sh [runs=5]` | Wall time (median, min, max), peak memory and result of each expression over all rows: `JSONLength` (parse floor), the two new functions, `.2` of `JSONExtractLeafPathsAndValues`, and `JSONAllValues` of a `JSON` cast. The `generated` profile adds a nested `JSONExtractKeysAndValuesRaw` expression. The results of the cast and nested cases are not equal to the new functions, so compare their time only. |
| `bench_tables.sh` | Per table and build: insert time, `OPTIMIZE FINAL` time, bytes on disk, index bytes. Per token: granules read (`EXPLAIN indexes = 1`), cold time, warm median/min/max, time without the index, row count, `sum(cityHash64(s))` and `match`. `match` is `OK` when all runs and the run with `use_skip_indexes = 0` agree. The script stops on any other value. |
| `bench_writeheavy.sh` | `NINS` inserts of `ROWS` rows into one table on a temporary server, then the wait for merges: total insert time, settle time, final and maximum number of active parts, bytes on disk. `CAPPED` in the last column means the wait hit `CAP`. |
| `check.sh` | Cross-checks of the functions against each other and against `JSONAllValues`. The script fails if a value that must be 0 is not 0. |
| `run_all.sh [out-dir]` | Runs `STEPS` (default `functions tables check`; also `sizeonly` and `writeheavy`) and writes `res_<step>.txt` into `out-dir`. |

Example:

```bash
export CH=/path/to/clickhouse
bash run_all.sh generated data/gen_2k.native out-gen
STEPS="functions tables sizeonly writeheavy check" bash run_all.sh bluesky data/bluesky_10m.native out-bsky
```

For a quick test, use a small file (for example `generate.sh x.native 20000`) and `REPEATS=1 WARM=3 FUNC_RUNS=2`. For `bench_writeheavy.sh` use `NINS=5 ROWS=1000 STABLE=4 POLL=1`.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `CH` | `clickhouse` | Binary |
| `MAX_MEMORY` | `0` | `max_memory_usage` of the heavy queries, in bytes (0 is no limit) |
| `TABLES` | `A B C D` | Table variants for `bench_tables.sh` and `bench_writeheavy.sh` |
| `REPEATS` | `3` | Builds per table in `bench_tables.sh` |
| `WARM` | `10` | Warm runs per token in `bench_tables.sh` |
| `READ` | `1` | `0` skips the read side of `bench_tables.sh` |
| `WORK` | `./work`, `./work_wh` | Scratch directory. Databases are deleted after each table. |
| `NINS`, `ROWS`, `STABLE`, `CAP`, `POLL` | `100`, `100000`, `30`, `900`, `5` | `bench_writeheavy.sh` |

## Notes on the method

- Cold means the first query of a new `clickhouse local` process after `SYSTEM DROP MARK CACHE`, `SYSTEM DROP UNCOMPRESSED CACHE` and `SYSTEM DROP TEXT INDEX CACHES`. The operating system page cache stays. Warm means the runs after that, in the same process.
- The read query is `SELECT count(), sum(cityHash64(s)) ... WHERE hasAllTokens(<index expression>, <token>)`. It reads the whole `s` for each matching granule on every table. A query such as `sum(length(s))` can be rewritten to the subcolumn `s.size` on some tables only, and then it does not compare the tables.
- `OPTIMIZE FINAL` time is not the cost of background merges. Use `bench_writeheavy.sh` for that.
- Granule totals differ between tables, because the table layouts give different mark counts. Compare the granules read for the same token only as a sign of index selectivity.
- The `JSON` type infers `DateTime64` for ISO date strings, so the indexes of B, C and D hold a different text for these values than the index of A. The number of values is the same.
