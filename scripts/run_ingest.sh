#!/usr/bin/env bash
# ==============================================================================
# Usage:
#   ./scripts/run_ingest.sh [engine] [config_properties_file]
#
# Arguments:
#   engine:                 Target engine: all | rocksdb | mapdb | sparksee | postgres | neo4j
#                           Default: all
#   config_properties_file: Path to benchmark.properties file
#                           Default: ./benchmark.properties
#
# Examples:
#   ./scripts/run_ingest.sh
#   ./scripts/run_ingest.sh all benchmark.properties
#   ./scripts/run_ingest.sh rocksdb /path/to/benchmark.properties
#   ./scripts/run_ingest.sh postgres
#
# Robustness & Failure Isolation:
#   - Each engine runs independently. If an engine fails (e.g., OOM, crash,
#     or connection error), the failure is logged and the script proceeds
#     to execute the remaining engines without losing existing data or results.
#   - Ingestion metrics are appended to ${results_dir}/ingest.csv.
#   - Detailed per-engine logs are written to ${results_dir}/logs/<engine>_ingest.log.
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
  $(basename "$0") [engine] [config_properties_file]

Engines:
  all           Run ingestion for all 5 engines in sequence (default)
  rocksdb       RocksDB embedded storage engine
  mapdb         MapDB embedded storage engine
  sparksee      Sparksee embedded graph database
  postgres      PostgreSQL relational backend
  neo4j         Neo4j graph database backend

Configuration:
  config_file   Path to benchmark.properties (default: ./benchmark.properties)

Options:
  -h, --help    Display this help message and exit
EOF
    exit 0
}

# Parse flags
if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
    show_help
fi

# Detect arguments
TARGET="all"
CONFIG_FILE=""

if [ $# -ge 1 ]; then
    case "$1" in
        all|rocks|rocksdb|map|mapdb|spark|sparksee|sql|postgres|postgresql|neo|neo4j)
            TARGET="$1"
            if [ $# -ge 2 ]; then
                CONFIG_FILE="$2"
            fi
            ;;
        *.properties)
            TARGET="all"
            CONFIG_FILE="$1"
            ;;
        *)
            if [ -f "$1" ]; then
                TARGET="all"
                CONFIG_FILE="$1"
            else
                TARGET="$1"
                if [ $# -ge 2 ]; then
                    CONFIG_FILE="$2"
                fi
            fi
            ;;
    esac
fi

# Default config file if not specified
if [ -z "$CONFIG_FILE" ]; then
    if [ -f "${ROOT_DIR}/benchmark.properties" ]; then
        CONFIG_FILE="${ROOT_DIR}/benchmark.properties"
    elif [ -f "./benchmark.properties" ]; then
        CONFIG_FILE="./benchmark.properties"
    else
        CONFIG_FILE="${ROOT_DIR}/benchmark.properties"
    fi
fi

# Resolve configuration file to absolute path
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}[ERROR] Configuration file not found: ${CONFIG_FILE}${NC}"
    echo -e "${YELLOW}Please create a benchmark.properties file or specify an existing one.${NC}"
    echo -e "You can copy the template: cp benchmark.properties.example benchmark.properties"
    exit 1
fi

CONFIG_FILE="$(cd "$(dirname "$CONFIG_FILE")" && pwd)/$(basename "$CONFIG_FILE")"
CONFIG_DIR="$(dirname "$CONFIG_FILE")"

# Read results_dir from config file (default to results)
RAW_RESULTS_DIR=$(grep -E '^[[:space:]]*results_dir[[:space:]]*=' "$CONFIG_FILE" | head -n 1 | cut -d '=' -f2 | tr -d '[:space:]')
if [ -z "$RAW_RESULTS_DIR" ]; then
    RAW_RESULTS_DIR="results"
fi

if [[ "$RAW_RESULTS_DIR" = /* ]]; then
    RESULTS_DIR="$RAW_RESULTS_DIR"
else
    RESULTS_DIR="${CONFIG_DIR}/${RAW_RESULTS_DIR}"
fi

LOGS_DIR="${RESULTS_DIR}/logs"
mkdir -p "$LOGS_DIR"

echo -e "${BOLD}================================================================================${NC}"
echo -e "${BOLD}                     STORAGE ENGINE INGESTION RUNNER                            ${NC}"
echo -e "${BOLD}================================================================================${NC}"
echo -e "Config File : ${CYAN}${CONFIG_FILE}${NC}"
echo -e "Results Dir : ${CYAN}${RESULTS_DIR}${NC}"
echo -e "Logs Dir    : ${CYAN}${LOGS_DIR}${NC}"
echo -e "Target      : ${CYAN}${TARGET}${NC}"
echo -e "${BOLD}================================================================================${NC}"

# Result tracking
RESULTS_ENGINE=()
RESULTS_STATUS=()
RESULTS_SIZE=()
RESULTS_DETAIL=()

record_status() {
    local engine="$1"
    local status="$2"
    local size="${3:-N/A}"
    local detail="${4:-}"
    RESULTS_ENGINE+=("$engine")
    RESULTS_STATUS+=("$status")
    RESULTS_SIZE+=("$size")
    RESULTS_DETAIL+=("$detail")
}

# ------------------------------------------------------------------------------
# Configuration Helpers & Storage Measurement
# ------------------------------------------------------------------------------

get_config_value() {
    local key="$1"
    local default_val="$2"
    local val
    val=$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$CONFIG_FILE" 2>/dev/null | head -n 1 | cut -d '=' -f2- | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    if [ -z "$val" ]; then
        echo "$default_val"
    else
        echo "$val"
    fi
}

resolve_config_path() {
    local raw_path="$1"
    if [ -z "$raw_path" ]; then
        echo ""
    elif [[ "$raw_path" = /* ]]; then
        echo "$raw_path"
    else
        echo "${CONFIG_DIR}/${raw_path}"
    fi
}

format_bytes_human() {
    local b="$1"
    if [ -z "$b" ] || [ "$b" -eq 0 ] 2>/dev/null; then
        echo "0B"
        return
    fi
    awk -v b="$b" 'BEGIN {
        split("B KB MB GB TB PB", units);
        i = 1;
        while (b >= 1024 && i < 6) {
            b /= 1024;
            i++;
        }
        printf "%.2f%s", b, units[i];
    }'
}

append_db_size_to_csv() {
    local engine_lower="$1"
    local bytes="$2"
    local human="$3"
    local csv_file="${RESULTS_DIR}/ingest_${engine_lower}.csv"

    if [ -f "$csv_file" ]; then
        local header
        local data
        header=$(head -n 1 "$csv_file")
        data=$(tail -n +2 "$csv_file")

        if [[ "$header" != *"db_size_bytes"* ]]; then
            header="${header},db_size_bytes,db_size_human"
            data="${data},${bytes},${human}"
            printf "%s\n%s\n" "$header" "$data" > "$csv_file"
        fi
    fi

    # Also log to dedicated db_sizes.csv
    local sizes_csv="${RESULTS_DIR}/db_sizes.csv"
    local sf
    sf=$(get_config_value "scale_factor" "unknown")
    if [ ! -f "$sizes_csv" ]; then
        echo "engine,scale_factor,db_size_bytes,db_size_human" > "$sizes_csv"
    else
        # Remove previous entry for this engine if present to avoid duplicates on re-runs
        grep -v "^${engine_lower}," "$sizes_csv" > "${sizes_csv}.tmp" 2>/dev/null && mv "${sizes_csv}.tmp" "$sizes_csv"
    fi
    echo "${engine_lower},${sf},${bytes},${human}" >> "$sizes_csv"
}

measure_rocksdb_size() {
    local db_raw=$(get_config_value "rocksdb_dir" "dbs/rocks")
    local db_path=$(resolve_config_path "$db_raw")
    local size_bytes="0"
    if [ -d "$db_path" ]; then
        size_bytes=$(du -sk "$db_path" 2>/dev/null | awk '{print $1 * 1024}')
    fi
    echo "${size_bytes:-0}"
}

measure_mapdb_size() {
    local db_raw=$(get_config_value "mapdb_dir" "dbs/mapdb")
    local db_path=$(resolve_config_path "$db_raw")
    local size_bytes="0"
    if [ -e "$db_path" ]; then
        size_bytes=$(du -sk "$db_path" 2>/dev/null | awk '{print $1 * 1024}')
    fi
    echo "${size_bytes:-0}"
}

measure_sparksee_size() {
    local db_raw=$(get_config_value "sparksee_db" "dbs/sparksee.gdb")
    local db_path=$(resolve_config_path "$db_raw")
    local size_bytes="0"
    if [ -e "$db_path" ]; then
        size_bytes=$(du -sk "$db_path" 2>/dev/null | awk '{print $1 * 1024}')
    fi
    echo "${size_bytes:-0}"
}

measure_postgres_size() {
    local pg_url=$(get_config_value "postgres_url" "jdbc:postgresql://localhost:5432/postgres")
    local pg_user=$(get_config_value "postgres_user" "postgres")
    local pg_pass=$(get_config_value "postgres_pass" "postgres")

    local pg_db=$(echo "$pg_url" | sed -E 's/.*\///' | cut -d '?' -f1)
    [ -z "$pg_db" ] && pg_db="postgres"

    local pg_host_port=$(echo "$pg_url" | sed -E 's/jdbc:postgresql:\/\/([^/]+)\/.*/\1/')
    local pg_host=$(echo "$pg_host_port" | cut -d ':' -f1)
    local pg_port=$(echo "$pg_host_port" | cut -s -d ':' -f2)
    [ -z "$pg_port" ] && pg_port="5432"

    local size_bytes=""
    if command -v psql >/dev/null 2>&1; then
        size_bytes=$(PGPASSWORD="$pg_pass" psql -h "$pg_host" -p "$pg_port" -U "$pg_user" -d "$pg_db" -t -A -c "SELECT pg_database_size('$pg_db');" 2>/dev/null | tr -d '[:space:]')
    fi

    # Fallback to postgres_data_dir or default directory if psql query failed
    if [ -z "$size_bytes" ] || ! [[ "$size_bytes" =~ ^[0-9]+$ ]] || [ "$size_bytes" -eq 0 ] 2>/dev/null; then
        local pg_data_dir=$(get_config_value "postgres_data_dir" "")
        if [ -n "$pg_data_dir" ] && [ -d "$pg_data_dir" ]; then
            size_bytes=$(du -sk "$pg_data_dir" 2>/dev/null | awk '{print $1 * 1024}')
        fi
    fi

    echo "${size_bytes:-0}"
}

measure_neo4j_size() {
    local data_dir_raw=$(get_config_value "neo4j_data_dir" "/var/lib/neo4j/data")
    local data_dir=$(resolve_config_path "$data_dir_raw")
    local db_name=$(get_config_value "neo4j_database" "neo4j")

    local db_path="${data_dir}/databases/${db_name}"
    local tx_path="${data_dir}/transactions/${db_name}"

    local size_bytes
    size_bytes=$(du -sk "$db_path" "$tx_path" 2>/dev/null | awk '{sum += $1} END {print sum * 1024}')

    if [ -z "$size_bytes" ] || [ "$size_bytes" -eq 0 ] 2>/dev/null; then
        local home_raw=$(get_config_value "neo4j_home" "")
        if [ -n "$home_raw" ]; then
            local home_dir=$(resolve_config_path "$home_raw")
            size_bytes=$(du -sk "${home_dir}/data/databases/${db_name}" "${home_dir}/data/transactions/${db_name}" 2>/dev/null | awk '{sum += $1} END {print sum * 1024}')
        fi
    fi

    echo "${size_bytes:-0}"
}

# ------------------------------------------------------------------------------
# Engine Ingestion Functions
# ------------------------------------------------------------------------------

ingest_rocksdb() {
    local engine="RocksDB"
    local log_file="${LOGS_DIR}/rocksdb_ingest.log"
    echo -e "\n${CYAN}>>> [${engine}] Starting Ingestion...${NC}"
    echo -e "    Log output: ${log_file}"

    rm -f "${RESULTS_DIR}/ingest_rocksdb.csv" "${log_file}"

    cd "${ROOT_DIR}/methods/rocksstorage" || {
        record_status "$engine" "FAIL" "Directory methods/rocksstorage not found"
        return 1
    }

    mvn -q exec:java \
        -Dexec.mainClass="com.rocks.Main" \
        -Dexec.args="ingest \"${CONFIG_FILE}\"" 2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        local size_bytes
        local size_human
        size_bytes=$(measure_rocksdb_size)
        size_human=$(format_bytes_human "$size_bytes")
        append_db_size_to_csv "rocksdb" "$size_bytes" "$size_human"
        echo -e "${GREEN}✓ [${engine}] Ingest completed successfully. DB Size: ${size_human} (${size_bytes} bytes)${NC}"
        record_status "$engine" "PASS" "$size_human" "Saved to ingest_rocksdb.csv"
    elif [ $exit_code -eq 137 ]; then
        echo -e "${RED}✗ [${engine}] Ingest failed: Out of Memory (OOM / Killed).${NC}"
        record_status "$engine" "FAIL" "N/A" "Killed by OOM (exit code 137)"
    else
        echo -e "${RED}✗ [${engine}] Ingest failed with exit code ${exit_code}.${NC}"
        record_status "$engine" "FAIL" "N/A" "Exit code ${exit_code} (see log)"
    fi
}

ingest_mapdb() {
    local engine="MapDB"
    local log_file="${LOGS_DIR}/mapdb_ingest.log"
    echo -e "\n${CYAN}>>> [${engine}] Starting Ingestion...${NC}"
    echo -e "    Log output: ${log_file}"

    rm -f "${RESULTS_DIR}/ingest_mapdb.csv" "${log_file}"

    cd "${ROOT_DIR}/methods/mapdbstorage" || {
        record_status "$engine" "FAIL" "N/A" "Directory methods/mapdbstorage not found"
        return 1
    }

    mvn -q exec:java \
        -Dexec.mainClass="com.map.Main" \
        -Dexec.args="ingest \"${CONFIG_FILE}\"" 2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        local size_bytes
        local size_human
        size_bytes=$(measure_mapdb_size)
        size_human=$(format_bytes_human "$size_bytes")
        append_db_size_to_csv "mapdb" "$size_bytes" "$size_human"
        echo -e "${GREEN}✓ [${engine}] Ingest completed successfully. DB Size: ${size_human} (${size_bytes} bytes)${NC}"
        record_status "$engine" "PASS" "$size_human" "Saved to ingest_mapdb.csv"
    elif [ $exit_code -eq 137 ]; then
        echo -e "${RED}✗ [${engine}] Ingest failed: Out of Memory (OOM / Killed).${NC}"
        record_status "$engine" "FAIL" "N/A" "Killed by OOM (exit code 137)"
    else
        echo -e "${RED}✗ [${engine}] Ingest failed with exit code ${exit_code}.${NC}"
        record_status "$engine" "FAIL" "N/A" "Exit code ${exit_code} (see log)"
    fi
}

ingest_sparksee() {
    local engine="Sparksee"
    local log_file="${LOGS_DIR}/sparksee_ingest.log"
    echo -e "\n${CYAN}>>> [${engine}] Starting Ingestion...${NC}"
    echo -e "    Log output: ${log_file}"

    rm -f "${RESULTS_DIR}/ingest_sparksee.csv" "${log_file}"

    cd "${ROOT_DIR}/methods/sparksee" || {
        record_status "$engine" "FAIL" "N/A" "Directory methods/sparksee not found"
        return 1
    }

    # Compile Sparksee implementation if needed
    if ! javac -cp "sparkseejava.jar:." SparkseeImplementation2.java 2>&1 | tee -a "$log_file"; then
        echo -e "${RED}✗ [${engine}] Compilation failed (javac).${NC}"
        record_status "$engine" "FAIL" "N/A" "Compilation error (javac)"
        return 1
    fi

    java -cp "sparkseejava.jar:." SparkseeImplementation2 ingest "${CONFIG_FILE}" 2>&1 | tee -a "$log_file"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        local size_bytes
        local size_human
        size_bytes=$(measure_sparksee_size)
        size_human=$(format_bytes_human "$size_bytes")
        append_db_size_to_csv "sparksee" "$size_bytes" "$size_human"
        echo -e "${GREEN}✓ [${engine}] Ingest completed successfully. DB Size: ${size_human} (${size_bytes} bytes)${NC}"
        record_status "$engine" "PASS" "$size_human" "Saved to ingest_sparksee.csv"
    elif [ $exit_code -eq 137 ]; then
        echo -e "${RED}✗ [${engine}] Ingest failed: Out of Memory (OOM / Killed).${NC}"
        record_status "$engine" "FAIL" "N/A" "Killed by OOM (exit code 137)"
    else
        echo -e "${RED}✗ [${engine}] Ingest failed with exit code ${exit_code}.${NC}"
        record_status "$engine" "FAIL" "N/A" "Exit code ${exit_code} (see log)"
    fi
}

ingest_postgres() {
    local engine="PostgreSQL"
    local log_file="${LOGS_DIR}/postgres_ingest.log"
    echo -e "\n${CYAN}>>> [${engine}] Starting Ingestion...${NC}"
    echo -e "    Log output: ${log_file}"

    rm -f "${RESULTS_DIR}/ingest_postgres.csv" "${log_file}"

    cd "${ROOT_DIR}/methods/sql" || {
        record_status "$engine" "FAIL" "N/A" "Directory methods/sql not found"
        return 1
    }

    # Compile Postgres implementation if needed
    if ! javac -cp "postgresql-42.7.8.jar:." PostgresColumns.java 2>&1 | tee -a "$log_file"; then
        echo -e "${RED}✗ [${engine}] Compilation failed (javac).${NC}"
        record_status "$engine" "FAIL" "N/A" "Compilation error (javac)"
        return 1
    fi

    java -cp "postgresql-42.7.8.jar:." PostgresColumns ingest "${CONFIG_FILE}" 2>&1 | tee -a "$log_file"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        local size_bytes
        local size_human
        size_bytes=$(measure_postgres_size)
        size_human=$(format_bytes_human "$size_bytes")
        append_db_size_to_csv "postgres" "$size_bytes" "$size_human"
        echo -e "${GREEN}✓ [${engine}] Ingest completed successfully. DB Size: ${size_human} (${size_bytes} bytes)${NC}"
        record_status "$engine" "PASS" "$size_human" "Saved to ingest_postgres.csv"
    elif [ $exit_code -eq 137 ]; then
        echo -e "${RED}✗ [${engine}] Ingest failed: Out of Memory (OOM / Killed).${NC}"
        record_status "$engine" "FAIL" "N/A" "Killed by OOM (exit code 137)"
    else
        echo -e "${RED}✗ [${engine}] Ingest failed with exit code ${exit_code}.${NC}"
        record_status "$engine" "FAIL" "N/A" "Exit code ${exit_code} (see log)"
    fi
}

ingest_neo4j() {
    local engine="Neo4j"
    local log_file="${LOGS_DIR}/neo4j_ingest.log"
    echo -e "\n${CYAN}>>> [${engine}] Starting Ingestion...${NC}"
    echo -e "    Log output: ${log_file}"

    rm -f "${RESULTS_DIR}/ingest_neo4j.csv" "${log_file}"

    cd "${ROOT_DIR}/methods/neo4jc" || {
        record_status "$engine" "FAIL" "N/A" "Directory methods/neo4jc not found"
        return 1
    }

    mvn -q exec:java \
        -Dexec.mainClass="com.neo4j.Main" \
        -Dexec.args="ingest \"${CONFIG_FILE}\"" 2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        local size_bytes
        local size_human
        size_bytes=$(measure_neo4j_size)
        size_human=$(format_bytes_human "$size_bytes")
        append_db_size_to_csv "neo4j" "$size_bytes" "$size_human"
        echo -e "${GREEN}✓ [${engine}] Ingest completed successfully. DB Size: ${size_human} (${size_bytes} bytes)${NC}"
        record_status "$engine" "PASS" "$size_human" "Saved to ingest_neo4j.csv"
    elif [ $exit_code -eq 137 ]; then
        echo -e "${RED}✗ [${engine}] Ingest failed: Out of Memory (OOM / Killed).${NC}"
        record_status "$engine" "FAIL" "N/A" "Killed by OOM (exit code 137)"
    else
        echo -e "${RED}✗ [${engine}] Ingest failed with exit code ${exit_code}.${NC}"
        record_status "$engine" "FAIL" "N/A" "Exit code ${exit_code} (see log)"
    fi
}

# ------------------------------------------------------------------------------
# Dispatch Execution
# ------------------------------------------------------------------------------

case "$TARGET" in
    all)
        ingest_rocksdb
        ingest_mapdb
        ingest_sparksee
        ingest_postgres
        ingest_neo4j
        ;;
    rocks|rocksdb)
        ingest_rocksdb
        ;;
    map|mapdb)
        ingest_mapdb
        ;;
    spark|sparksee)
        ingest_sparksee
        ;;
    sql|postgres|postgresql)
        ingest_postgres
        ;;
    neo|neo4j)
        ingest_neo4j
        ;;
    *)
        echo -e "${RED}[ERROR] Invalid target: ${TARGET}${NC}"
        echo "Available options: all | rocksdb | mapdb | sparksee | postgres | neo4j"
        exit 2
        ;;
esac

# ------------------------------------------------------------------------------
# Consolidate per-engine CSVs into a single ingest.csv
# ------------------------------------------------------------------------------
consolidate_ingest_csvs() {
    local target_csv="${RESULTS_DIR}/ingest.csv"
    local temp_csv="${RESULTS_DIR}/.ingest_consolidated.tmp"
    local first=1
    rm -f "$temp_csv"

    for f in "${RESULTS_DIR}"/ingest_*.csv; do
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

consolidate_ingest_csvs

# ------------------------------------------------------------------------------
# Summary Table
# ------------------------------------------------------------------------------

echo -e "\n\n${BOLD}================================================================================${NC}"
echo -e "${BOLD}                     INGESTION EXECUTION SUMMARY REPORT                         ${NC}"
echo -e "${BOLD}================================================================================${NC}"
printf "%-12s | %-8s | %-12s | %-40s\n" "ENGINE" "STATUS" "DB SIZE" "DETAILS"
echo "--------------------------------------------------------------------------------"

fail_count=0
pass_count=0

for i in "${!RESULTS_ENGINE[@]}"; do
    name="${RESULTS_ENGINE[$i]}"
    status="${RESULTS_STATUS[$i]}"
    size="${RESULTS_SIZE[$i]}"
    detail="${RESULTS_DETAIL[$i]}"

    case "$status" in
        PASS)
            printf "%-12s | ${GREEN}%-8s${NC} | %-12s | %-40s\n" "$name" "$status" "$size" "$detail"
            ((pass_count++))
            ;;
        FAIL)
            printf "%-12s | ${RED}%-8s${NC} | %-12s | %-40s\n" "$name" "$status" "$size" "$detail"
            ((fail_count++))
            ;;
    esac
done

echo "================================================================================"
echo -e "Totals: ${pass_count} passed, ${fail_count} failed."
echo -e "CSV Ingest   : ${CYAN}${RESULTS_DIR}/ingest.csv${NC}"
echo -e "CSV Sizes    : ${CYAN}${RESULTS_DIR}/db_sizes.csv${NC}"
echo -e "Detailed Logs: ${CYAN}${LOGS_DIR}/${NC}"

if [ "$fail_count" -gt 0 ]; then
    echo -e "\n${RED}⚠ One or more engines failed during ingestion. Check logs above for details.${NC}"
    exit 1
else
    echo -e "\n${GREEN}✓ All requested engines completed ingestion successfully!${NC}"
    exit 0
fi
