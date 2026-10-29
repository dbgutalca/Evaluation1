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
# Engine Ingestion Functions
# ------------------------------------------------------------------------------

ingest_rocksdb() {
    local engine="RocksDB"
    local log_file="${LOGS_DIR}/rocksdb_ingest.log"
    echo -e "\n${CYAN}>>> [${engine}] Starting Ingestion...${NC}"
    echo -e "    Log output: ${log_file}"

    cd "${ROOT_DIR}/methods/rocksstorage" || {
        record_status "$engine" "FAIL" "Directory methods/rocksstorage not found"
        return 1
    }

    mvn -q exec:java \
        -Dexec.mainClass="com.rocks.Main" \
        -Dexec.args="ingest \"${CONFIG_FILE}\"" 2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ [${engine}] Ingest completed successfully.${NC}"
        record_status "$engine" "PASS" "Saved to ingest.csv"
    elif [ $exit_code -eq 137 ]; then
        echo -e "${RED}✗ [${engine}] Ingest failed: Out of Memory (OOM / Killed).${NC}"
        record_status "$engine" "FAIL" "Killed by OOM (exit code 137)"
    else
        echo -e "${RED}✗ [${engine}] Ingest failed with exit code ${exit_code}.${NC}"
        record_status "$engine" "FAIL" "Exit code ${exit_code} (see log)"
    fi
}

ingest_mapdb() {
    local engine="MapDB"
    local log_file="${LOGS_DIR}/mapdb_ingest.log"
    echo -e "\n${CYAN}>>> [${engine}] Starting Ingestion...${NC}"
    echo -e "    Log output: ${log_file}"

    cd "${ROOT_DIR}/methods/mapdbstorage" || {
        record_status "$engine" "FAIL" "Directory methods/mapdbstorage not found"
        return 1
    }

    mvn -q exec:java \
        -Dexec.mainClass="com.map.Main" \
        -Dexec.args="ingest \"${CONFIG_FILE}\"" 2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ [${engine}] Ingest completed successfully.${NC}"
        record_status "$engine" "PASS" "Saved to ingest.csv"
    elif [ $exit_code -eq 137 ]; then
        echo -e "${RED}✗ [${engine}] Ingest failed: Out of Memory (OOM / Killed).${NC}"
        record_status "$engine" "FAIL" "Killed by OOM (exit code 137)"
    else
        echo -e "${RED}✗ [${engine}] Ingest failed with exit code ${exit_code}.${NC}"
        record_status "$engine" "FAIL" "Exit code ${exit_code} (see log)"
    fi
}

ingest_sparksee() {
    local engine="Sparksee"
    local log_file="${LOGS_DIR}/sparksee_ingest.log"
    echo -e "\n${CYAN}>>> [${engine}] Starting Ingestion...${NC}"
    echo -e "    Log output: ${log_file}"

    cd "${ROOT_DIR}/methods/sparksee" || {
        record_status "$engine" "FAIL" "Directory methods/sparksee not found"
        return 1
    }

    # Compile Sparksee implementation if needed
    if ! javac -cp "sparkseejava.jar:." SparkseeImplementation2.java 2>&1 | tee -a "$log_file"; then
        echo -e "${RED}✗ [${engine}] Compilation failed (javac).${NC}"
        record_status "$engine" "FAIL" "Compilation error (javac)"
        return 1
    fi

    java -cp "sparkseejava.jar:." SparkseeImplementation2 ingest "${CONFIG_FILE}" 2>&1 | tee -a "$log_file"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ [${engine}] Ingest completed successfully.${NC}"
        record_status "$engine" "PASS" "Saved to ingest.csv"
    elif [ $exit_code -eq 137 ]; then
        echo -e "${RED}✗ [${engine}] Ingest failed: Out of Memory (OOM / Killed).${NC}"
        record_status "$engine" "FAIL" "Killed by OOM (exit code 137)"
    else
        echo -e "${RED}✗ [${engine}] Ingest failed with exit code ${exit_code}.${NC}"
        record_status "$engine" "FAIL" "Exit code ${exit_code} (see log)"
    fi
}

ingest_postgres() {
    local engine="PostgreSQL"
    local log_file="${LOGS_DIR}/postgres_ingest.log"
    echo -e "\n${CYAN}>>> [${engine}] Starting Ingestion...${NC}"
    echo -e "    Log output: ${log_file}"

    cd "${ROOT_DIR}/methods/sql" || {
        record_status "$engine" "FAIL" "Directory methods/sql not found"
        return 1
    }

    # Compile Postgres implementation if needed
    if ! javac -cp "postgresql-42.7.8.jar:." PostgresColumns.java 2>&1 | tee -a "$log_file"; then
        echo -e "${RED}✗ [${engine}] Compilation failed (javac).${NC}"
        record_status "$engine" "FAIL" "Compilation error (javac)"
        return 1
    fi

    java -cp "postgresql-42.7.8.jar:." PostgresColumns ingest "${CONFIG_FILE}" 2>&1 | tee -a "$log_file"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ [${engine}] Ingest completed successfully.${NC}"
        record_status "$engine" "PASS" "Saved to ingest.csv"
    elif [ $exit_code -eq 137 ]; then
        echo -e "${RED}✗ [${engine}] Ingest failed: Out of Memory (OOM / Killed).${NC}"
        record_status "$engine" "FAIL" "Killed by OOM (exit code 137)"
    else
        echo -e "${RED}✗ [${engine}] Ingest failed with exit code ${exit_code}.${NC}"
        record_status "$engine" "FAIL" "Exit code ${exit_code} (see log)"
    fi
}

ingest_neo4j() {
    local engine="Neo4j"
    local log_file="${LOGS_DIR}/neo4j_ingest.log"
    echo -e "\n${CYAN}>>> [${engine}] Starting Ingestion...${NC}"
    echo -e "    Log output: ${log_file}"

    cd "${ROOT_DIR}/methods/neo4jc" || {
        record_status "$engine" "FAIL" "Directory methods/neo4jc not found"
        return 1
    }

    mvn -q exec:java \
        -Dexec.mainClass="com.neo4j.Main" \
        -Dexec.args="ingest \"${CONFIG_FILE}\"" 2>&1 | tee "$log_file"
    local exit_code=${PIPESTATUS[0]}

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ [${engine}] Ingest completed successfully.${NC}"
        record_status "$engine" "PASS" "Saved to ingest.csv"
    elif [ $exit_code -eq 137 ]; then
        echo -e "${RED}✗ [${engine}] Ingest failed: Out of Memory (OOM / Killed).${NC}"
        record_status "$engine" "FAIL" "Killed by OOM (exit code 137)"
    else
        echo -e "${RED}✗ [${engine}] Ingest failed with exit code ${exit_code}.${NC}"
        record_status "$engine" "FAIL" "Exit code ${exit_code} (see log)"
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
# Summary Table
# ------------------------------------------------------------------------------

echo -e "\n\n${BOLD}================================================================================${NC}"
echo -e "${BOLD}                     INGESTION EXECUTION SUMMARY REPORT                         ${NC}"
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
echo -e "CSV Results : ${CYAN}${RESULTS_DIR}/ingest.csv${NC}"
echo -e "Detailed Logs : ${CYAN}${LOGS_DIR}/${NC}"

if [ "$fail_count" -gt 0 ]; then
    echo -e "\n${RED}⚠ One or more engines failed during ingestion. Check logs above for details.${NC}"
    exit 1
else
    echo -e "\n${GREEN}✓ All requested engines completed ingestion successfully!${NC}"
    exit 0
fi
