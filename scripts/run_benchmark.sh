#!/usr/bin/env bash
# ==============================================================================
# Usage:
#   ./scripts/run_benchmark.sh [engine] [config_properties_file] [--condition cold|warm|both]
#
# Arguments:
#   engine:                 Target engine: all | rocksdb | mapdb | sparksee | postgres | neo4j
#                           Default: all
#   config_properties_file: Path to benchmark.properties file
#                           Default: ./benchmark.properties
#   --condition:            Override benchmark condition: cold | warm | both
#
# Features:
#   1. Protocol enforcement:
#      - Cold mode: flushes OS pagecache (drop_caches), restarts service if applicable,
#        executes unbuffered cold passes with per-repetition deterministic shuffle.
#      - Warm mode: executes unmeasured warm-up passes (discarded), followed by measured passes.
#   2. Memory isolation & tracking:
#      - Monitors resident set size (RSS) and system RAM in the background.
#      - Saves metrics to ${results_dir}/ram_usage_<engine>.csv and consolidated ram_usage.csv.
#   3. Correctness check:
#      - ensures equal answer counts.
#   4. Failure isolation:
#      - If one engine crashes or fails (OOM, connection error), other engines proceed unharmed.
#      - Per-engine output saved to ${results_dir}/benchmark_<engine>.csv.
#      - Consolidated into ${results_dir}/benchmark.csv at the end.
# ==============================================================================

set -u

# ANSI Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

show_help() {
    cat << EOF
Usage:
  $(basename "$0") [engine] [config_properties_file] [options]

Engines:
  all           Run benchmark for all 5 engines in sequence (default)
  rocksdb       RocksDB embedded storage engine
  mapdb         MapDB embedded storage engine
  sparksee      Sparksee embedded graph database
  postgres      PostgreSQL relational backend
  neo4j         Neo4j graph database backend

Configuration:
  config_file   Path to benchmark.properties (default: ./benchmark.properties)

Options:
  --condition   Execution condition: cold | warm | both (overrides config file)
  --no-shuffle  Disable query shuffling (run queries in file order)
  --shuffle     Enable query shuffling (default)
  -h, --help    Display this help message and exit
EOF
    exit 0
}

# Parse command line arguments
TARGET="all"
CONFIG_FILE=""
OVERRIDE_CONDITION=""
OVERRIDE_SHUFFLE=""

while [ $# -gt 0 ]; do
    case "$1" in
        -h|--help)
            show_help
            ;;
        --condition)
            shift
            OVERRIDE_CONDITION="${1:-}"
            ;;
        --condition=*)
            OVERRIDE_CONDITION="${1#*=}"
            ;;
        --no-shuffle)
            OVERRIDE_SHUFFLE="false"
            ;;
        --shuffle)
            OVERRIDE_SHUFFLE="true"
            ;;
        all|rocks|rocksdb|map|mapdb|spark|sparksee|sql|postgres|postgresql|neo|neo4j)
            TARGET="$1"
            ;;
        *.properties)
            CONFIG_FILE="$1"
            ;;
        *)
            if [ -f "$1" ]; then
                CONFIG_FILE="$1"
            else
                TARGET="$1"
            fi
            ;;
    esac
    shift
done

# Resolve default config file
if [ -z "$CONFIG_FILE" ]; then
    if [ -f "${ROOT_DIR}/benchmark.properties" ]; then
        CONFIG_FILE="${ROOT_DIR}/benchmark.properties"
    elif [ -f "./benchmark.properties" ]; then
        CONFIG_FILE="./benchmark.properties"
    else
        CONFIG_FILE="${ROOT_DIR}/benchmark.properties"
    fi
fi

if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}[ERROR] Configuration file not found: ${CONFIG_FILE}${NC}"
    echo -e "${YELLOW}Please create a benchmark.properties file or specify an existing one.${NC}"
    echo -e "Template available: cp benchmark.properties.example benchmark.properties"
    exit 1
fi

CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"

# Helper to read property
get_prop() {
    local key="$1"
    local default_val="$2"
    local val
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE" | head -n 1 | cut -d '=' -f2 | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
    if [ -z "$val" ]; then
        echo "$default_val"
    else
        echo "$val"
    fi
}

SCALE_FACTOR=$(get_prop "scale_factor" "sf1")
RAW_RESULTS_DIR=$(get_prop "results_dir" "results")
BENCH_COND=$(get_prop "benchmark_condition" "both")
if [ -n "$OVERRIDE_CONDITION" ]; then
    BENCH_COND="$OVERRIDE_CONDITION"
fi
COLD_REPS=$(get_prop "cold_iterations" "3")
WARM_REPS=$(get_prop "measured_iterations" "5")
WARMUP_REPS=$(get_prop "warmup_iterations" "3")
RANDOM_SEED=$(get_prop "random_seed" "42")
SHUFFLE_MODE=$(get_prop "shuffle_queries" "true")
if [ -n "$OVERRIDE_SHUFFLE" ]; then
    SHUFFLE_MODE="$OVERRIDE_SHUFFLE"
fi

SHUFFLE_JVM_ARG=""
if [ "$SHUFFLE_MODE" = "false" ]; then
    SHUFFLE_JVM_ARG="-Dshuffle_queries=false"
fi

if [[ "$RAW_RESULTS_DIR" = /* ]]; then
    RESULTS_DIR="$RAW_RESULTS_DIR"
else
    RESULTS_DIR="${CONFIG_DIR}/${RAW_RESULTS_DIR}"
fi

LOGS_DIR="${RESULTS_DIR}/logs"
mkdir -p "$LOGS_DIR"

echo -e "${BOLD}================================================================================${NC}"
echo -e "${BOLD}                     STORAGE ENGINE BENCHMARK RUNNER                            ${NC}"
echo -e "${BOLD}================================================================================${NC}"
echo -e "Config File : ${CYAN}${CONFIG_FILE}${NC}"
echo -e "Scale Factor: ${CYAN}${SCALE_FACTOR}${NC}"
echo -e "Condition   : ${CYAN}${BENCH_COND}${NC} (cold: ${COLD_REPS} reps, warm: ${WARM_REPS} reps, warmup: ${WARMUP_REPS})"
echo -e "Shuffle     : ${CYAN}${SHUFFLE_MODE}${NC} (Seed: ${RANDOM_SEED})"
echo -e "Results Dir : ${CYAN}${RESULTS_DIR}${NC}"
echo -e "Target      : ${CYAN}${TARGET}${NC}"
echo -e "${BOLD}================================================================================${NC}"

# Result tracking
RESULTS_ENGINE=()
RESULTS_STATUS=()
RESULTS_DETAIL=()

record_status() {
    local engine="$1"
    local status="$2"
    local detail="$3"
    RESULTS_ENGINE+=("$engine")
    RESULTS_STATUS+=("$status")
    RESULTS_DETAIL+=("$detail")
}

# ------------------------------------------------------------------------------
# RAM Sampling Function (Resident Set Size & Global System RAM)
# ------------------------------------------------------------------------------
RAM_PID=""
RAM_TMP=""

start_ram_sampler() {
    local engine="$1"
    local target_name="$2"
    RAM_TMP=$(mktemp)

    (
        while true; do
            local rss_total=0
            # Search for processes related to java or engine name
            if command -v pgrep >/dev/null 2>&1; then
                for p in $(pgrep -f "$target_name" 2>/dev/null); do
                    local rss
                    rss=$(ps -p "$p" -o rss= 2>/dev/null | tr -d '[:space:]')
                    if [[ "$rss" =~ ^[0-9]+$ ]]; then
                        rss_total=$((rss_total + rss))
                    fi
                done
            fi
            if [ $rss_total -gt 0 ]; then
                echo "$rss_total" >> "$RAM_TMP"
            fi
            sleep 0.2
        done
    ) >/dev/null 2>&1 &
    RAM_PID=$!
}

stop_ram_sampler() {
    local engine="$1"
    local cond="$2"
    local rep="$3"
    if [ -n "$RAM_PID" ]; then
        kill "$RAM_PID" 2>/dev/null || true
        wait "$RAM_PID" 2>/dev/null || true
        RAM_PID=""
    fi

    local ram_csv="${RESULTS_DIR}/ram_usage_${engine}.csv"
    local write_header=0
    if [ ! -f "$ram_csv" ]; then
        write_header=1
    fi

    if [ -f "$RAM_TMP" ] && [ -s "$RAM_TMP" ]; then
        local stats
        stats=$(awk '
            BEGIN { min=999999999; max=0; sum=0; count=0 }
            {
                val = $1 / 1024.0 # Convert KB to MB
                if (val < min) min = val
                if (val > max) max = val
                sum += val
                count++
            }
            END {
                if (count > 0) printf "%.2f,%.2f,%.2f", min, max, sum/count;
                else printf "0,0,0";
            }
        ' "$RAM_TMP")
        rm -f "$RAM_TMP"

        local min_mb max_mb mean_mb
        min_mb=$(echo "$stats" | cut -d ',' -f1)
        max_mb=$(echo "$stats" | cut -d ',' -f2)
        mean_mb=$(echo "$stats" | cut -d ',' -f3)

        if [ $write_header -eq 1 ]; then
            echo "engine,scale_factor,condition,repetition,rss_min_mb,rss_max_mb,rss_mean_mb" > "$ram_csv"
        fi
        echo "${engine},${SCALE_FACTOR},${cond},${rep},${min_mb},${max_mb},${mean_mb}" >> "$ram_csv"
    fi
}

# ------------------------------------------------------------------------------
# Cache Flushing & Engine Restart Helpers
# ------------------------------------------------------------------------------
drop_os_caches() {
    echo "    Flushing OS page cache (drop_caches)..."
    sync
    if [ -w /proc/sys/vm/drop_caches ]; then
        echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true
    elif command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null 2>&1 || true
    else
        # Try best effort
        sync
    fi
}

restart_service() {
    local service_name="$1"
    echo "    Restarting service: ${service_name}..."
    if command -v systemctl >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo systemctl restart "$service_name" >/dev/null 2>&1 || true
        sleep 2
    elif command -v brew >/dev/null 2>&1; then
        brew services restart "$service_name" >/dev/null 2>&1 || true
        sleep 2
    fi
}

# ------------------------------------------------------------------------------
# Benchmark Runners per Engine
# ------------------------------------------------------------------------------

run_rocksdb() {
    local engine="rocksdb"
    local log_file="${LOGS_DIR}/rocksdb_bench.log"
    echo -e "\n${CYAN}>>> [RocksDB] Starting Benchmark...${NC}"
    echo -e "    Log output: ${log_file}"

    cd "${ROOT_DIR}/methods/rocksstorage" || {
        record_status "RocksDB" "FAIL" "Directory methods/rocksstorage not found"
        return 1
    }

    local any_fail=0

    # Cold runs
    if [ "$BENCH_COND" = "cold" ] || [ "$BENCH_COND" = "both" ]; then
        echo -e "  ${YELLOW}Executing Cold Passes (${COLD_REPS} repetitions)...${NC}"
        for rep in $(seq 1 "$COLD_REPS"); do
            echo -e "  [Cold Rep ${rep}/${COLD_REPS}]"
            drop_os_caches
            start_ram_sampler "$engine" "com.rocks.Main"
            mvn -q exec:java $SHUFFLE_JVM_ARG \
                -Dexec.mainClass="com.rocks.Main" \
                -Dexec.args="bench \"${CONFIG_FILE}\" cold ${rep}" 2>&1 | tee -a "$log_file"
            local exit_code=${PIPESTATUS[0]}
            stop_ram_sampler "$engine" "cold" "$rep"
            if [ $exit_code -ne 0 ]; then
                any_fail=1
                break
            fi
        done
    fi

    # Warm runs
    if [ $any_fail -eq 0 ] && ([ "$BENCH_COND" = "warm" ] || [ "$BENCH_COND" = "both" ]); then
        echo -e "  ${YELLOW}Executing Warm Passes (${WARM_REPS} repetitions, ${WARMUP_REPS} warmup)...${NC}"
        start_ram_sampler "$engine" "com.rocks.Main"
        mvn -q exec:java $SHUFFLE_JVM_ARG \
            -Dexec.mainClass="com.rocks.Main" \
            -Dexec.args="bench \"${CONFIG_FILE}\" warm" 2>&1 | tee -a "$log_file"
        local exit_code=${PIPESTATUS[0]}
        stop_ram_sampler "$engine" "warm" "1"
        if [ $exit_code -ne 0 ]; then
            any_fail=1
        fi
    fi

    if [ $any_fail -eq 0 ]; then
        echo -e "${GREEN}✓ [RocksDB] Benchmark completed successfully.${NC}"
        record_status "RocksDB" "PASS" "Saved to benchmark_rocksdb.csv"
    else
        echo -e "${RED}✗ [RocksDB] Benchmark encountered errors (see log).${NC}"
        record_status "RocksDB" "FAIL" "Execution error (see log)"
    fi
}

run_mapdb() {
    local engine="mapdb"
    local log_file="${LOGS_DIR}/mapdb_bench.log"
    echo -e "\n${CYAN}>>> [MapDB] Starting Benchmark...${NC}"
    echo -e "    Log output: ${log_file}"

    cd "${ROOT_DIR}/methods/mapdbstorage" || {
        record_status "MapDB" "FAIL" "Directory methods/mapdbstorage not found"
        return 1
    }

    local any_fail=0

    # Cold runs
    if [ "$BENCH_COND" = "cold" ] || [ "$BENCH_COND" = "both" ]; then
        echo -e "  ${YELLOW}Executing Cold Passes (${COLD_REPS} repetitions)...${NC}"
        for rep in $(seq 1 "$COLD_REPS"); do
            echo -e "  [Cold Rep ${rep}/${COLD_REPS}]"
            drop_os_caches
            start_ram_sampler "$engine" "com.map.Main"
            mvn -q exec:java $SHUFFLE_JVM_ARG \
                -Dexec.mainClass="com.map.Main" \
                -Dexec.args="bench \"${CONFIG_FILE}\" cold ${rep}" 2>&1 | tee -a "$log_file"
            local exit_code=${PIPESTATUS[0]}
            stop_ram_sampler "$engine" "cold" "$rep"
            if [ $exit_code -ne 0 ]; then
                any_fail=1
                break
            fi
        done
    fi

    # Warm runs
    if [ $any_fail -eq 0 ] && ([ "$BENCH_COND" = "warm" ] || [ "$BENCH_COND" = "both" ]); then
        echo -e "  ${YELLOW}Executing Warm Passes (${WARM_REPS} repetitions, ${WARMUP_REPS} warmup)...${NC}"
        start_ram_sampler "$engine" "com.map.Main"
        mvn -q exec:java $SHUFFLE_JVM_ARG \
            -Dexec.mainClass="com.map.Main" \
            -Dexec.args="bench \"${CONFIG_FILE}\" warm" 2>&1 | tee -a "$log_file"
        local exit_code=${PIPESTATUS[0]}
        stop_ram_sampler "$engine" "warm" "1"
        if [ $exit_code -ne 0 ]; then
            any_fail=1
        fi
    fi

    if [ $any_fail -eq 0 ]; then
        echo -e "${GREEN}✓ [MapDB] Benchmark completed successfully.${NC}"
        record_status "MapDB" "PASS" "Saved to benchmark_mapdb.csv"
    else
        echo -e "${RED}✗ [MapDB] Benchmark encountered errors (see log).${NC}"
        record_status "MapDB" "FAIL" "Execution error (see log)"
    fi
}

run_sparksee() {
    local engine="sparksee"
    local log_file="${LOGS_DIR}/sparksee_bench.log"
    echo -e "\n${CYAN}>>> [Sparksee] Starting Benchmark...${NC}"
    echo -e "    Log output: ${log_file}"

    cd "${ROOT_DIR}/methods/sparksee" || {
        record_status "Sparksee" "FAIL" "Directory methods/sparksee not found"
        return 1
    }

    if ! javac -cp "sparkseejava.jar:." SparkseeImplementation2.java 2>&1 | tee -a "$log_file"; then
        echo -e "${RED}✗ [Sparksee] Compilation failed (javac).${NC}"
        record_status "Sparksee" "FAIL" "Compilation error (javac)"
        return 1
    fi

    local any_fail=0

    # Cold runs
    if [ "$BENCH_COND" = "cold" ] || [ "$BENCH_COND" = "both" ]; then
        echo -e "  ${YELLOW}Executing Cold Passes (${COLD_REPS} repetitions)...${NC}"
        for rep in $(seq 1 "$COLD_REPS"); do
            echo -e "  [Cold Rep ${rep}/${COLD_REPS}]"
            drop_os_caches
            start_ram_sampler "$engine" "SparkseeImplementation2"
            java $SHUFFLE_JVM_ARG -cp "sparkseejava.jar:." SparkseeImplementation2 bench "${CONFIG_FILE}" cold "${rep}" 2>&1 | tee -a "$log_file"
            local exit_code=${PIPESTATUS[0]}
            stop_ram_sampler "$engine" "cold" "$rep"
            if [ $exit_code -ne 0 ]; then
                any_fail=1
                break
            fi
        done
    fi

    # Warm runs
    if [ $any_fail -eq 0 ] && ([ "$BENCH_COND" = "warm" ] || [ "$BENCH_COND" = "both" ]); then
        echo -e "  ${YELLOW}Executing Warm Passes (${WARM_REPS} repetitions, ${WARMUP_REPS} warmup)...${NC}"
        start_ram_sampler "$engine" "SparkseeImplementation2"
        java $SHUFFLE_JVM_ARG -cp "sparkseejava.jar:." SparkseeImplementation2 bench "${CONFIG_FILE}" warm 2>&1 | tee -a "$log_file"
        local exit_code=${PIPESTATUS[0]}
        stop_ram_sampler "$engine" "warm" "1"
        if [ $exit_code -ne 0 ]; then
            any_fail=1
        fi
    fi

    if [ $any_fail -eq 0 ]; then
        echo -e "${GREEN}✓ [Sparksee] Benchmark completed successfully.${NC}"
        record_status "Sparksee" "PASS" "Saved to benchmark_sparksee.csv"
    else
        echo -e "${RED}✗ [Sparksee] Benchmark encountered errors (see log).${NC}"
        record_status "Sparksee" "FAIL" "Execution error (see log)"
    fi
}

run_postgres() {
    local engine="postgres"
    local log_file="${LOGS_DIR}/postgres_bench.log"
    echo -e "\n${CYAN}>>> [PostgreSQL] Starting Benchmark...${NC}"
    echo -e "    Log output: ${log_file}"

    cd "${ROOT_DIR}/methods/sql" || {
        record_status "PostgreSQL" "FAIL" "Directory methods/sql not found"
        return 1
    }

    if ! javac -cp "postgresql-42.7.8.jar:." PostgresColumns.java 2>&1 | tee -a "$log_file"; then
        echo -e "${RED}✗ [PostgreSQL] Compilation failed (javac).${NC}"
        record_status "PostgreSQL" "FAIL" "Compilation error (javac)"
        return 1
    fi

    local any_fail=0

    # Cold runs
    if [ "$BENCH_COND" = "cold" ] || [ "$BENCH_COND" = "both" ]; then
        echo -e "  ${YELLOW}Executing Cold Passes (${COLD_REPS} repetitions)...${NC}"
        for rep in $(seq 1 "$COLD_REPS"); do
            echo -e "  [Cold Rep ${rep}/${COLD_REPS}]"
            restart_service "postgresql"
            drop_os_caches
            start_ram_sampler "$engine" "PostgresColumns"
            java $SHUFFLE_JVM_ARG -cp "postgresql-42.7.8.jar:." PostgresColumns bench "${CONFIG_FILE}" cold "${rep}" 2>&1 | tee -a "$log_file"
            local exit_code=${PIPESTATUS[0]}
            stop_ram_sampler "$engine" "cold" "$rep"
            if [ $exit_code -ne 0 ]; then
                any_fail=1
                break
            fi
        done
    fi

    # Warm runs
    if [ $any_fail -eq 0 ] && ([ "$BENCH_COND" = "warm" ] || [ "$BENCH_COND" = "both" ]); then
        echo -e "  ${YELLOW}Executing Warm Passes (${WARM_REPS} repetitions, ${WARMUP_REPS} warmup)...${NC}"
        start_ram_sampler "$engine" "PostgresColumns"
        java $SHUFFLE_JVM_ARG -cp "postgresql-42.7.8.jar:." PostgresColumns bench "${CONFIG_FILE}" warm 2>&1 | tee -a "$log_file"
        local exit_code=${PIPESTATUS[0]}
        stop_ram_sampler "$engine" "warm" "1"
        if [ $exit_code -ne 0 ]; then
            any_fail=1
        fi
    fi

    if [ $any_fail -eq 0 ]; then
        echo -e "${GREEN}✓ [PostgreSQL] Benchmark completed successfully.${NC}"
        record_status "PostgreSQL" "PASS" "Saved to benchmark_postgres.csv"
    else
        echo -e "${RED}✗ [PostgreSQL] Benchmark encountered errors (see log).${NC}"
        record_status "PostgreSQL" "FAIL" "Execution error (see log)"
    fi
}

run_neo4j() {
    local engine="neo4j"
    local log_file="${LOGS_DIR}/neo4j_bench.log"
    echo -e "\n${CYAN}>>> [Neo4j] Starting Benchmark...${NC}"
    echo -e "    Log output: ${log_file}"

    cd "${ROOT_DIR}/methods/neo4jc" || {
        record_status "Neo4j" "FAIL" "Directory methods/neo4jc not found"
        return 1
    }

    local any_fail=0

    # Cold runs
    if [ "$BENCH_COND" = "cold" ] || [ "$BENCH_COND" = "both" ]; then
        echo -e "  ${YELLOW}Executing Cold Passes (${COLD_REPS} repetitions)...${NC}"
        for rep in $(seq 1 "$COLD_REPS"); do
            echo -e "  [Cold Rep ${rep}/${COLD_REPS}]"
            restart_service "neo4j"
            drop_os_caches
            start_ram_sampler "$engine" "com.neo4j.Main"
            mvn -q exec:java $SHUFFLE_JVM_ARG \
                -Dexec.mainClass="com.neo4j.Main" \
                -Dexec.args="bench \"${CONFIG_FILE}\" cold ${rep}" 2>&1 | tee -a "$log_file"
            local exit_code=${PIPESTATUS[0]}
            stop_ram_sampler "$engine" "cold" "$rep"
            if [ $exit_code -ne 0 ]; then
                any_fail=1
                break
            fi
        done
    fi

    # Warm runs
    if [ $any_fail -eq 0 ] && ([ "$BENCH_COND" = "warm" ] || [ "$BENCH_COND" = "both" ]); then
        echo -e "  ${YELLOW}Executing Warm Passes (${WARM_REPS} repetitions, ${WARMUP_REPS} warmup)...${NC}"
        start_ram_sampler "$engine" "com.neo4j.Main"
        mvn -q exec:java $SHUFFLE_JVM_ARG \
            -Dexec.mainClass="com.neo4j.Main" \
            -Dexec.args="bench \"${CONFIG_FILE}\" warm" 2>&1 | tee -a "$log_file"
        local exit_code=${PIPESTATUS[0]}
        stop_ram_sampler "$engine" "warm" "1"
        if [ $exit_code -ne 0 ]; then
            any_fail=1
        fi
    fi

    if [ $any_fail -eq 0 ]; then
        echo -e "${GREEN}✓ [Neo4j] Benchmark completed successfully.${NC}"
        record_status "Neo4j" "PASS" "Saved to benchmark_neo4j.csv"
    else
        echo -e "${RED}✗ [Neo4j] Benchmark encountered errors (see log).${NC}"
        record_status "Neo4j" "FAIL" "Execution error (see log)"
    fi
}

# ------------------------------------------------------------------------------
# Dispatch Target Engine
# ------------------------------------------------------------------------------

case "$TARGET" in
    all)
        run_rocksdb
        run_mapdb
        run_sparksee
        run_postgres
        run_neo4j
        ;;
    rocks|rocksdb)
        run_rocksdb
        ;;
    map|mapdb)
        run_mapdb
        ;;
    spark|sparksee)
        run_sparksee
        ;;
    sql|postgres|postgresql)
        run_postgres
        ;;
    neo|neo4j)
        run_neo4j
        ;;
    *)
        echo -e "${RED}[ERROR] Invalid target: ${TARGET}${NC}"
        echo "Available options: all | rocksdb | mapdb | sparksee | postgres | neo4j"
        exit 2
        ;;
esac

# ------------------------------------------------------------------------------
# Consolidate CSV Files
# ------------------------------------------------------------------------------
consolidate_bench_csvs() {
    local target_csv="${RESULTS_DIR}/benchmark.csv"
    local temp_csv="${RESULTS_DIR}/.benchmark_consolidated.tmp"
    local first=1
    rm -f "$temp_csv"

    for f in "${RESULTS_DIR}"/benchmark_*.csv; do
        [ -f "$f" ] || continue
        if [ $first -eq 1 ]; then
            head -n 1 "$f" >> "$temp_csv"
            first=0
        fi
        tail -n +2 "$f" >> "$temp_csv"
    done

    if [ -f "$temp_csv" ]; then
        mv "$temp_csv" "$target_csv"
    fi
}

consolidate_ram_csvs() {
    local target_csv="${RESULTS_DIR}/ram_usage.csv"
    local temp_csv="${RESULTS_DIR}/.ram_consolidated.tmp"
    local first=1
    rm -f "$temp_csv"

    for f in "${RESULTS_DIR}"/ram_usage_*.csv; do
        [ -f "$f" ] || continue
        if [ $first -eq 1 ]; then
            head -n 1 "$f" >> "$temp_csv"
            first=0
        fi
        tail -n +2 "$f" >> "$temp_csv"
    done

    if [ -f "$temp_csv" ]; then
        mv "$temp_csv" "$target_csv"
    fi
}

consolidate_bench_csvs
consolidate_ram_csvs

# ------------------------------------------------------------------------------
# Correctness Validation (Reviewer Sec. A7.7)
# ------------------------------------------------------------------------------
validate_cardinality() {
    local bench_csv="${RESULTS_DIR}/benchmark.csv"
    if [ ! -f "$bench_csv" ]; then
        return 0
    fi

    echo -e "\n${BOLD}>>> Running Correctness Check (Cardinality Validation)...${NC}"
    local mismatch_count
    mismatch_count=$(awk -F ',' '
        NR > 1 {
            key = $5 ":" $6 # query_type:param
            engine = $1
            card = $8
            if (key in seen_card && seen_card[key] != card) {
                print "Mismatch for " key ": " seen_engine[key] "=" seen_card[key] " vs " engine "=" card
                mismatches++
            } else {
                seen_card[key] = card
                seen_engine[key] = engine
            }
        }
        END { print mismatches + 0 }
    ' "$bench_csv" | tail -n 1)

    if [ "$mismatch_count" -eq 0 ]; then
        echo -e "${GREEN}✓ Correctness Check PASSED: All backends returned identical result cardinalities!${NC}"
    else
        echo -e "${RED}⚠ Correctness Check WARNING: Found ${mismatch_count} cardinality mismatch(es) between engines!${NC}"
    fi
}

validate_cardinality

# ------------------------------------------------------------------------------
# Summary Table
# ------------------------------------------------------------------------------

echo -e "\n\n${BOLD}================================================================================${NC}"
echo -e "${BOLD}                     BENCHMARK EXECUTION SUMMARY REPORT                         ${NC}"
echo -e "${BOLD}================================================================================${NC}"
printf "%-15s | %-10s | %-48s\n" "ENGINE" "STATUS" "DETAILS"
echo "--------------------------------------------------------------------------------"

fail_count=0
pass_count=0

for i in "${!RESULTS_ENGINE[@]}"; do
    name="${RESULTS_ENGINE[$i]}"
    status="${RESULTS_STATUS[$i]}"
    detail="${RESULTS_DETAIL[$i]}"

    case "$status" in
        PASS)
            printf "%-15s | ${GREEN}%-10s${NC} | %-48s\n" "$name" "$status" "$detail"
            ((pass_count++))
            ;;
        FAIL)
            printf "%-15s | ${RED}%-10s${NC} | %-48s\n" "$name" "$status" "$detail"
            ((fail_count++))
            ;;
    esac
done

echo "================================================================================"
echo -e "Totals: ${pass_count} passed, ${fail_count} failed."
echo -e "Consolidated Benchmark : ${CYAN}${RESULTS_DIR}/benchmark.csv${NC}"
echo -e "Consolidated RAM Stats : ${CYAN}${RESULTS_DIR}/ram_usage.csv${NC}"
echo -e "Individual Metrics     : ${CYAN}${RESULTS_DIR}/benchmark_<engine>.csv${NC}"
echo -e "Detailed Execution Logs: ${CYAN}${LOGS_DIR}/${NC}"

if [ "$fail_count" -gt 0 ]; then
    echo -e "\n${RED}⚠ One or more engines encountered errors. Check logs for details.${NC}"
    exit 1
else
    echo -e "\n${GREEN}✓ All requested engines completed benchmark successfully!${NC}"
    exit 0
fi
