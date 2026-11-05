# Shared helpers. Sourced by the benchmark scripts, not run on its own.
#
# Env:
#   CH           clickhouse binary (default: clickhouse)
#   MAX_MEMORY   max_memory_usage for the heavy queries, in bytes (default: 0, no limit)
#
# A profile (profiles/<name>.sh) describes a data set: the skip regex, the JSON column types of
# tables C and D, and the search tokens. See load_profile.

CH=${CH:-clickhouse}
MAX_MEMORY=${MAX_MEMORY:-0}
LIB_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
IDX='TYPE text(tokenizer = splitByNonAlpha)'

# load_profile <name|path>: sets RE, JT_C, JT_D, TOKENS (array of role=token) and SET.
load_profile()
{
    local p=$1
    [ -f "$p" ] || p="$LIB_DIR/profiles/$1.sh"
    [ -f "$p" ] || { echo "unknown profile: $1" >&2; exit 1; }
    # shellcheck disable=SC1090
    . "$p"
    SET="SETTINGS max_memory_usage = $MAX_MEMORY"
}

require_functions()
{
    "$CH" local -q "SELECT JSONExtractLeafValues('{}')" > /dev/null \
        || { echo "$CH does not provide JSONExtractLeafValues" >&2; exit 1; }
}

now() { date +%s.%N; }

median() { sort -n | awk '{a[NR]=$1} END{print (NR%2)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'; }

# q <database dir> <query>: runs a query against a persistent `clickhouse local` database.
q() { "$CH" local --path "$1" --query "$2"; }

# env_note <label>: prints a comment line with the time and the load average.
env_note()
{
    echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ) $1 load_avg=$(cut -d' ' -f1-3 /proc/loadavg) cpus=$(getconf _NPROCESSORS_ONLN)"
}

# Table variants:
#   A  s String, text index on JSONExtractLeafValues(s, RE)
#   B  s String and a stored Array(String) column filled with JSONAllValues of a JSON cast
#   C  s String and a JSON column (default max_dynamic_paths), text index on JSONAllValues(j)
#   D  s String and a JSON(max_dynamic_paths = 0) column, text index on JSONAllValues(j)
#   C0, D0  like C and D without the column s (size only)
ddl()
{
    case $1 in
        A) echo "s String, INDEX idx JSONExtractLeafValues(s, '$RE') $IDX";;
        B) echo "s String, vals Array(String), INDEX idx vals $IDX";;
        C) echo "s String, j $JT_C, INDEX idx JSONAllValues(j) $IDX";;
        D) echo "s String, j $JT_D, INDEX idx JSONAllValues(j) $IDX";;
        C0) echo "j $JT_C, INDEX idx JSONAllValues(j) $IDX";;
        D0) echo "j $JT_D, INDEX idx JSONAllValues(j) $IDX";;
        *) echo "unknown table $1" >&2; return 1;;
    esac
}

# ins <table> <source>: SELECT that fills the table from <source> (a table expression with column s).
ins()
{
    local src=$2
    case $1 in
        A) echo "SELECT s FROM $src";;
        B) echo "SELECT s, JSONAllValues(CAST(s AS JSON(max_dynamic_paths = 0, SKIP REGEXP '$RE'))) FROM $src";;
        C) echo "SELECT s, CAST(s AS $JT_C) FROM $src";;
        D) echo "SELECT s, CAST(s AS $JT_D) FROM $src";;
        C0) echo "SELECT CAST(s AS $JT_C) FROM $src";;
        D0) echo "SELECT CAST(s AS $JT_D) FROM $src";;
        *) echo "unknown table $1" >&2; return 1;;
    esac
}

# expr <table>: the expression that the text index covers.
expr()
{
    case $1 in
        A) echo "JSONExtractLeafValues(s, '$RE')";;
        B) echo "vals";;
        C|D|C0|D0) echo "JSONAllValues(j)";;
        *) echo "unknown table $1" >&2; return 1;;
    esac
}
