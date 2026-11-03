#!/usr/bin/env bash
# ==============================================================================
# Usage:
#   ./scripts/reset_storage.sh [engine] [config_properties_file] [--force]
#
# Arguments:
#   engine:                 Target engine: all | rocksdb | mapdb | sparksee | postgres | neo4j
#                           Default: all
#   config_properties_file: Path to benchmark.properties file
#                           Default: ./benchmark.properties
#   --force / -f / -y:      Skip interactive confirmation prompt
#
# Examples:
#   ./scripts/reset_storage.sh
#   ./scripts/reset_storage.sh all benchmark.properties
#   ./scripts/reset_storage.sh rocksdb
#   ./scripts/reset_storage.sh postgres -f
#   ./scripts/reset_storage.sh neo4j
#
# Purpose:
#   Safely cleans storage state for secondary-memory graph backends:
#   - RocksDB  : Deletes directory at rocksdb_dir
#   - MapDB    : Deletes files/directories at mapdb_dir*
#   - Sparksee : Deletes database file/directory at sparksee_db*
#   - Postgres : Connects to database and drops all LDBC tables/indexes (keeps DB intact)
#   - Neo4j    : Stops neo4j service, deletes data/databases/neo4j and data/transactions/neo4j,
#                and restarts service (preventing heap OOMs from large Cypher deletes)
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
  all           Reset storage for all 5 engines (default)
  rocksdb       Delete RocksDB directory
  mapdb         Delete MapDB files/directory
  sparksee      Delete Sparksee database files (.gdb)
  postgres      Drop all LDBC tables and indexes in PostgreSQL
  neo4j         Stop service, wipe database/transaction folders, and restart

Configuration:
  config_file   Path to benchmark.properties (default: ./benchmark.properties)

Options:
  -f, --force, -y   Skip confirmation prompt and execute immediately
  -h, --help        Display this help message and exit
EOF
    exit 0
}

# Parse CLI arguments
TARGET="all"
CONFIG_FILE=""
FORCE=0

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            ;;
        -f|--force|-y)
            FORCE=1
            ;;
        all|rocks|rocksdb|map|mapdb|spark|sparksee|sql|postgres|postgresql|neo|neo4j)
            TARGET="$arg"
            ;;
        *.properties)
            CONFIG_FILE="$arg"
            ;;
        *)
            if [ -f "$arg" ]; then
                CONFIG_FILE="$arg"
            fi
            ;;
    esac
done

# Default config file if not specified
if [ -z "$CONFIG_FILE" ]; then
    if [ -f "${ROOT_DIR}/benchmark.properties" ]; then
        CONFIG_FILE="${ROOT_DIR}/benchmark.properties"
    elif [ -f "./benchmark.properties" ]; then
        CONFIG_FILE="./benchmark.properties"
    fi
fi

if [ -z "$CONFIG_FILE" ] || [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}[ERROR] Configuration file not found: ${CONFIG_FILE:-benchmark.properties}${NC}"
    echo -e "${YELLOW}Please create a benchmark.properties file or specify an existing one.${NC}"
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

# Path resolution helper
resolve_path() {
    local p="$1"
    if [ -z "$p" ]; then
        echo ""
    elif [[ "$p" = /* ]]; then
        echo "$p"
    else
        echo "${CONFIG_DIR}/${p}"
    fi
}

# Read engine settings from benchmark.properties
ROCKSDB_DIR=$(resolve_path "$(get_prop "rocksdb_dir" "dbs/rocks_sf1")")
MAPDB_DIR=$(resolve_path "$(get_prop "mapdb_dir" "dbs/mapdb_sf1")")
SPARKSEE_DB=$(resolve_path "$(get_prop "sparksee_db" "dbs/sparksee_sf1.gdb")")

POSTGRES_URL=$(get_prop "postgres_url" "jdbc:postgresql://localhost:5432/postgres")
POSTGRES_USER=$(get_prop "postgres_user" "postgres")

NEO4J_SERVICE=$(get_prop "neo4j_service" "neo4j")
NEO4J_HOME_PROP=$(get_prop "neo4j_home" "")
NEO4J_DATA_DIR_PROP=$(get_prop "neo4j_data_dir" "")

# Locate Neo4j data directory
find_neo4j_data_dir() {
    if [ -n "$NEO4J_DATA_DIR_PROP" ] && [ -d "$NEO4J_DATA_DIR_PROP" ]; then
        echo "$NEO4J_DATA_DIR_PROP"
        return
    fi
    if [ -n "$NEO4J_HOME_PROP" ] && [ -d "${NEO4J_HOME_PROP}/data" ]; then
        echo "${NEO4J_HOME_PROP}/data"
        return
    fi
    if [ -n "${NEO4J_HOME:-}" ] && [ -d "${NEO4J_HOME}/data" ]; then
        echo "${NEO4J_HOME}/data"
        return
    fi
    for candidate in "/var/lib/neo4j/data" "/usr/local/var/neo4j/data" "/opt/neo4j/data" "${ROOT_DIR}/neo4j/data"; do
        if [ -d "$candidate" ]; then
            echo "$candidate"
            return
        fi
    done
    echo ""
}

NEO4J_DATA_DIR=$(find_neo4j_data_dir)

# Execution summary tracking
declare -a ACTIONS_PLANNED=()
declare -a RESULTS_ENGINE=()
declare -a RESULTS_STATUS=()
declare -a RESULTS_DETAIL=()

record_status() {
    local engine="$1"
    local status="$2"
    local detail="$3"
    RESULTS_ENGINE+=("$engine")
    RESULTS_STATUS+=("$status")
    RESULTS_DETAIL+=("$detail")
}

# ------------------------------------------------------------------------------
# Build Plan
# ------------------------------------------------------------------------------
plan_engine() {
    local eng="$1"
    case "$eng" in
        rocks|rocksdb)
            ACTIONS_PLANNED+=("RocksDB  : Delete directory [${ROCKSDB_DIR}]")
            ;;
        map|mapdb)
            ACTIONS_PLANNED+=("MapDB    : Delete files & directory [${MAPDB_DIR}*]")
            ;;
        spark|sparksee)
            ACTIONS_PLANNED+=("Sparksee : Delete database file/dir [${SPARKSEE_DB}*]")
            ;;
        sql|postgres|postgresql)
            ACTIONS_PLANNED+=("PostgreSQL: Drop all LDBC tables & indexes on [${POSTGRES_URL}]")
            ;;
        neo|neo4j)
            local loc="${NEO4J_DATA_DIR:-<not detected - check neo4j_data_dir in benchmark.properties>}"
            ACTIONS_PLANNED+=("Neo4j    : Stop service [${NEO4J_SERVICE}], wipe databases/neo4j & transactions/neo4j at [${loc}], and restart service")
            ;;
    esac
}

case "$TARGET" in
    all)
        plan_engine "rocksdb"
        plan_engine "mapdb"
        plan_engine "sparksee"
        plan_engine "postgres"
        plan_engine "neo4j"
        ;;
    *)
        plan_engine "$TARGET"
        ;;
esac

echo -e "\n${BOLD}================================================================================${NC}"
echo -e "${BOLD}                     SECONDARY STORAGE RESET UTILITY                            ${NC}"
echo -e "${BOLD}================================================================================${NC}"
echo -e "Config file : ${CYAN}${CONFIG_FILE}${NC}"
echo -e "Target      : ${BOLD}${TARGET}${NC}\n"
echo -e "${YELLOW}The following actions will be performed:${NC}"
for act in "${ACTIONS_PLANNED[@]}"; do
    echo -e "  • ${act}"
done
echo ""

if [ $FORCE -eq 0 ]; then
    read -r -p "Are you sure you want to proceed with resetting storage? [y/N] " confirm
    case "$confirm" in
        [yY][eE][sS]|[yY])
            echo ""
            ;;
        *)
            echo -e "${CYAN}Reset cancelled by user.${NC}"
            exit 0
            ;;
    esac
fi

# ------------------------------------------------------------------------------
# Reset Implementations
# ------------------------------------------------------------------------------

reset_rocksdb() {
    local engine="RocksDB"
    echo -e "\n${CYAN}>>> [${engine}] Resetting storage...${NC}"
    if [ -z "$ROCKSDB_DIR" ]; then
        record_status "$engine" "SKIPPED" "rocksdb_dir not configured"
        return 0
    fi
    if [ -d "$ROCKSDB_DIR" ]; then
        rm -rf "$ROCKSDB_DIR"
        echo -e "${GREEN}✓ [${engine}] Removed directory: ${ROCKSDB_DIR}${NC}"
        record_status "$engine" "PASS" "Removed directory ${ROCKSDB_DIR}"
    else
        echo -e "  [${engine}] Directory does not exist (already clean): ${ROCKSDB_DIR}"
        record_status "$engine" "PASS" "Already clean (not found)"
    fi
}

reset_mapdb() {
    local engine="MapDB"
    echo -e "\n${CYAN}>>> [${engine}] Resetting storage...${NC}"
    if [ -z "$MAPDB_DIR" ]; then
        record_status "$engine" "SKIPPED" "mapdb_dir not configured"
        return 0
    fi
    # Delete file or directory and any associated lock/wal files
    local deleted=0
    rm -rf "${MAPDB_DIR}"* 2>/dev/null && deleted=1
    echo -e "${GREEN}✓ [${engine}] Removed files matching: ${MAPDB_DIR}*${NC}"
    record_status "$engine" "PASS" "Removed files matching ${MAPDB_DIR}*"
}

reset_sparksee() {
    local engine="Sparksee"
    echo -e "\n${CYAN}>>> [${engine}] Resetting storage...${NC}"
    if [ -z "$SPARKSEE_DB" ]; then
        record_status "$engine" "SKIPPED" "sparksee_db not configured"
        return 0
    fi
    local deleted=0
    rm -rf "${SPARKSEE_DB}"* 2>/dev/null && deleted=1
    echo -e "${GREEN}✓ [${engine}] Removed database files matching: ${SPARKSEE_DB}*${NC}"
    record_status "$engine" "PASS" "Removed files matching ${SPARKSEE_DB}*"
}

reset_postgres() {
    local engine="PostgreSQL"
    echo -e "\n${CYAN}>>> [${engine}] Resetting storage (dropping tables & indexes)...${NC}"

    cd "${ROOT_DIR}/methods/sql" || {
        record_status "$engine" "FAIL" "Directory methods/sql not found"
        return 1
    }

    if [ ! -f "PostgresColumns.class" ]; then
        javac -cp "postgresql-42.7.8.jar:." PostgresColumns.java 2>/dev/null || true
    fi

    java -cp "postgresql-42.7.8.jar:." PostgresColumns reset "${CONFIG_FILE}"
    local exit_code=$?

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ [${engine}] Successfully reset tables and indexes.${NC}"
        record_status "$engine" "PASS" "All tables & indexes dropped"
    else
        echo -e "${RED}✗ [${engine}] Failed to reset database (exit code ${exit_code}).${NC}"
        record_status "$engine" "FAIL" "Exit code ${exit_code}"
    fi
}

reset_neo4j() {
    local engine="Neo4j"
    echo -e "\n${CYAN}>>> [${engine}] Resetting storage...${NC}"

    # 1. Stop service
    echo "    Stopping Neo4j service..."
    local stopped=0
    if command -v systemctl >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo systemctl stop "$NEO4J_SERVICE" 2>/dev/null || true
        stopped=1
    elif command -v neo4j >/dev/null 2>&1; then
        neo4j stop 2>/dev/null || true
        stopped=1
    elif [ -n "$NEO4J_HOME_PROP" ] && [ -x "${NEO4J_HOME_PROP}/bin/neo4j" ]; then
        "${NEO4J_HOME_PROP}/bin/neo4j" stop 2>/dev/null || true
        stopped=1
    elif command -v brew >/dev/null 2>&1; then
        brew services stop neo4j 2>/dev/null || true
        stopped=1
    fi
    sleep 2

    # 2. Delete data & transactions folders
    if [ -n "$NEO4J_DATA_DIR" ] && [ -d "$NEO4J_DATA_DIR" ]; then
        local db_dir="${NEO4J_DATA_DIR}/databases/neo4j"
        local tx_dir="${NEO4J_DATA_DIR}/transactions/neo4j"

        echo "    Wiping Neo4j databases/neo4j and transactions/neo4j..."
        if command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
            sudo rm -rf "$db_dir" "$tx_dir" 2>/dev/null || true
        else
            rm -rf "$db_dir" "$tx_dir" 2>/dev/null || true
        fi
        echo -e "    ${GREEN}✓ Removed: ${db_dir}${NC}"
        echo -e "    ${GREEN}✓ Removed: ${tx_dir}${NC}"
    else
        echo -e "    ${YELLOW}⚠ Could not locate neo4j data directory (databases/neo4j). Check neo4j_data_dir in benchmark.properties.${NC}"
    fi

    # 3. Start service
    echo "    Restarting Neo4j service..."
    if command -v systemctl >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
        sudo systemctl start "$NEO4J_SERVICE" 2>/dev/null || true
    elif command -v neo4j >/dev/null 2>&1; then
        neo4j start 2>/dev/null || true
    elif [ -n "$NEO4J_HOME_PROP" ] && [ -x "${NEO4J_HOME_PROP}/bin/neo4j" ]; then
        "${NEO4J_HOME_PROP}/bin/neo4j" start 2>/dev/null || true
    elif command -v brew >/dev/null 2>&1; then
        brew services start neo4j 2>/dev/null || true
    fi

    echo "    Waiting 5 seconds for Neo4j to initialize..."
    sleep 5
    echo -e "${GREEN}✓ [${engine}] Storage reset and service restarted.${NC}"
    record_status "$engine" "PASS" "Wiped data/transactions and restarted"
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------

case "$TARGET" in
    all)
        reset_rocksdb
        reset_mapdb
        reset_sparksee
        reset_postgres
        reset_neo4j
        ;;
    rocks|rocksdb)
        reset_rocksdb
        ;;
    map|mapdb)
        reset_mapdb
        ;;
    spark|sparksee)
        reset_sparksee
        ;;
    sql|postgres|postgresql)
        reset_postgres
        ;;
    neo|neo4j)
        reset_neo4j
        ;;
    *)
        echo -e "${RED}[ERROR] Unknown engine: ${TARGET}${NC}"
        echo "Available options: all | rocksdb | mapdb | sparksee | postgres | neo4j"
        exit 1
        ;;
esac

# ------------------------------------------------------------------------------
# Summary Table
# ------------------------------------------------------------------------------

echo -e "\n\n${BOLD}================================================================================${NC}"
echo -e "${BOLD}                       STORAGE RESET SUMMARY REPORT                             ${NC}"
echo -e "${BOLD}================================================================================${NC}"
printf "%-15s | %-10s | %-48s\n" "ENGINE" "STATUS" "DETAILS"
echo "--------------------------------------------------------------------------------"

for i in "${!RESULTS_ENGINE[@]}"; do
    name="${RESULTS_ENGINE[$i]}"
    status="${RESULTS_STATUS[$i]}"
    detail="${RESULTS_DETAIL[$i]}"

    case "$status" in
        PASS)
            printf "%-15s | ${GREEN}%-10s${NC} | %-48s\n" "$name" "$status" "$detail"
            ;;
        SKIPPED)
            printf "%-15s | ${YELLOW}%-10s${NC} | %-48s\n" "$name" "$status" "$detail"
            ;;
        FAIL)
            printf "%-15s | ${RED}%-10s${NC} | %-48s\n" "$name" "$status" "$detail"
            ;;
    esac
done

echo "================================================================================"
echo -e "${GREEN}Reset operation completed.${NC}\n"
