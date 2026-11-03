#!/usr/bin/env bash
# ==============================================================================
# Usage:
#   ./scripts/compile_all.sh [engine] [--clean]
#
# Arguments:
#   engine:     Target engine: all | rocksdb | mapdb | sparksee | postgres | neo4j
#               Default: all
#   --clean:    Run clean step before compiling (e.g. mvn clean, rm *.class)
#
# Examples:
#   ./scripts/compile_all.sh
#   ./scripts/compile_all.sh all --clean
#   ./scripts/compile_all.sh rocksdb
#   ./scripts/compile_all.sh postgres
#
# Purpose:
#   Fast, offline compilation utility for all 5 benchmark graph engines.
#   Does not require database services (Postgres, Neo4j) to be running.
#   Ensures that stale .class and .jar files are regenerated before running
#   ingestion, benchmark, or reset scripts.
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
  $(basename "$0") [engine] [options]

Engines:
  all           Compile all 5 engines in sequence (default)
  rocksdb       RocksDB embedded storage engine (Maven)
  mapdb         MapDB embedded storage engine (Maven)
  sparksee      Sparksee embedded graph database (javac)
  postgres      PostgreSQL relational backend (javac)
  neo4j         Neo4j graph database backend (Maven)

Options:
  -c, --clean   Perform clean build (mvn clean / delete old .class files)
  -h, --help    Display this help message and exit
EOF
    exit 0
}

TARGET="all"
CLEAN_MODE=0

for arg in "$@"; do
    case "$arg" in
        -h|--help)
            show_help
            ;;
        -c|--clean)
            CLEAN_MODE=1
            ;;
        all|rocks|rocksdb|map|mapdb|spark|sparksee|sql|postgres|postgresql|neo|neo4j)
            TARGET="$arg"
            ;;
        *)
            echo -e "${RED}[ERROR] Unknown option or engine: ${arg}${NC}"
            echo "Run $(basename "$0") --help for usage details."
            exit 1
            ;;
    esac
done

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

echo -e "\n${BOLD}================================================================================${NC}"
echo -e "${BOLD}                     STORAGE ENGINES COMPILATION UTILITY                        ${NC}"
echo -e "${BOLD}================================================================================${NC}"
echo -e "Target     : ${BOLD}${TARGET}${NC}"
echo -e "Clean mode : $([ $CLEAN_MODE -eq 1 ] && echo "${YELLOW}enabled${NC}" || echo "disabled")\n"

# ------------------------------------------------------------------------------
# Compile RocksDB (Maven)
# ------------------------------------------------------------------------------
compile_rocksdb() {
    local engine="RocksDB"
    echo -e "${CYAN}>>> [${engine}] Compiling with Maven...${NC}"
    local dir="${ROOT_DIR}/methods/rocksstorage"
    if [ ! -d "$dir" ]; then
        echo -e "${RED}✗ [${engine}] Directory methods/rocksstorage not found.${NC}"
        record_status "$engine" "FAIL" "Directory not found"
        return 1
    fi

    local mvn_cmd="mvn"
    if [ $CLEAN_MODE -eq 1 ]; then
        mvn_cmd="${mvn_cmd} clean"
    fi
    mvn_cmd="${mvn_cmd} compile test-compile -q -f \"${dir}/pom.xml\""

    if eval "$mvn_cmd"; then
        echo -e "${GREEN}✓ [${engine}] Compilation successful.${NC}"
        record_status "$engine" "PASS" "Compiled successfully (Maven)"
    else
        echo -e "${RED}✗ [${engine}] Compilation failed.${NC}"
        record_status "$engine" "FAIL" "Maven build error"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Compile MapDB (Maven)
# ------------------------------------------------------------------------------
compile_mapdb() {
    local engine="MapDB"
    echo -e "${CYAN}>>> [${engine}] Compiling with Maven...${NC}"
    local dir="${ROOT_DIR}/methods/mapdbstorage"
    if [ ! -d "$dir" ]; then
        echo -e "${RED}✗ [${engine}] Directory methods/mapdbstorage not found.${NC}"
        record_status "$engine" "FAIL" "Directory not found"
        return 1
    fi

    local mvn_cmd="mvn"
    if [ $CLEAN_MODE -eq 1 ]; then
        mvn_cmd="${mvn_cmd} clean"
    fi
    mvn_cmd="${mvn_cmd} compile test-compile -q -f \"${dir}/pom.xml\""

    if eval "$mvn_cmd"; then
        echo -e "${GREEN}✓ [${engine}] Compilation successful.${NC}"
        record_status "$engine" "PASS" "Compiled successfully (Maven)"
    else
        echo -e "${RED}✗ [${engine}] Compilation failed.${NC}"
        record_status "$engine" "FAIL" "Maven build error"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Compile Sparksee (javac)
# ------------------------------------------------------------------------------
compile_sparksee() {
    local engine="Sparksee"
    echo -e "${CYAN}>>> [${engine}] Compiling with javac...${NC}"
    local dir="${ROOT_DIR}/methods/sparksee"
    if [ ! -d "$dir" ]; then
        echo -e "${RED}✗ [${engine}] Directory methods/sparksee not found.${NC}"
        record_status "$engine" "FAIL" "Directory not found"
        return 1
    fi

    if [ $CLEAN_MODE -eq 1 ]; then
        rm -f "${dir}"/SparkseeImplementation2*.class
    fi

    if (cd "$dir" && javac -cp "sparkseejava.jar:." SparkseeImplementation2.java); then
        echo -e "${GREEN}✓ [${engine}] Compilation successful.${NC}"
        record_status "$engine" "PASS" "Compiled SparkseeImplementation2.java"
    else
        echo -e "${RED}✗ [${engine}] javac compilation failed.${NC}"
        record_status "$engine" "FAIL" "javac error"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Compile PostgreSQL (javac)
# ------------------------------------------------------------------------------
compile_postgres() {
    local engine="PostgreSQL"
    echo -e "${CYAN}>>> [${engine}] Compiling with javac...${NC}"
    local dir="${ROOT_DIR}/methods/sql"
    if [ ! -d "$dir" ]; then
        echo -e "${RED}✗ [${engine}] Directory methods/sql not found.${NC}"
        record_status "$engine" "FAIL" "Directory not found"
        return 1
    fi

    if [ $CLEAN_MODE -eq 1 ]; then
        rm -f "${dir}"/PostgresColumns*.class
    fi

    if (cd "$dir" && javac -cp "postgresql-42.7.8.jar:." PostgresColumns.java); then
        echo -e "${GREEN}✓ [${engine}] Compilation successful.${NC}"
        record_status "$engine" "PASS" "Compiled PostgresColumns.java"
    else
        echo -e "${RED}✗ [${engine}] javac compilation failed.${NC}"
        record_status "$engine" "FAIL" "javac error"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Compile Neo4j (Maven)
# ------------------------------------------------------------------------------
compile_neo4j() {
    local engine="Neo4j"
    echo -e "${CYAN}>>> [${engine}] Compiling with Maven...${NC}"
    local dir="${ROOT_DIR}/methods/neo4jc"
    if [ ! -d "$dir" ]; then
        echo -e "${RED}✗ [${engine}] Directory methods/neo4jc not found.${NC}"
        record_status "$engine" "FAIL" "Directory not found"
        return 1
    fi

    local mvn_cmd="mvn"
    if [ $CLEAN_MODE -eq 1 ]; then
        mvn_cmd="${mvn_cmd} clean"
    fi
    mvn_cmd="${mvn_cmd} compile test-compile -q -f \"${dir}/pom.xml\""

    if eval "$mvn_cmd"; then
        echo -e "${GREEN}✓ [${engine}] Compilation successful.${NC}"
        record_status "$engine" "PASS" "Compiled successfully (Maven)"
    else
        echo -e "${RED}✗ [${engine}] Compilation failed.${NC}"
        record_status "$engine" "FAIL" "Maven build error"
        return 1
    fi
}

# ------------------------------------------------------------------------------
# Dispatch
# ------------------------------------------------------------------------------
any_fail=0

case "$TARGET" in
    all)
        compile_rocksdb   || any_fail=1
        compile_mapdb     || any_fail=1
        compile_sparksee  || any_fail=1
        compile_postgres  || any_fail=1
        compile_neo4j     || any_fail=1
        ;;
    rocks|rocksdb)
        compile_rocksdb   || any_fail=1
        ;;
    map|mapdb)
        compile_mapdb     || any_fail=1
        ;;
    spark|sparksee)
        compile_sparksee  || any_fail=1
        ;;
    sql|postgres|postgresql)
        compile_postgres  || any_fail=1
        ;;
    neo|neo4j)
        compile_neo4j     || any_fail=1
        ;;
esac

# ------------------------------------------------------------------------------
# Summary Table
# ------------------------------------------------------------------------------
echo -e "\n${BOLD}================================================================================${NC}"
echo -e "${BOLD}                      COMPILATION SUMMARY REPORT                                ${NC}"
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
        FAIL)
            printf "%-15s | ${RED}%-10s${NC} | %-48s\n" "$name" "$status" "$detail"
            ;;
    esac
done

echo "================================================================================"

if [ $any_fail -eq 0 ]; then
    echo -e "${GREEN}All target engines compiled successfully.${NC}\n"
    exit 0
else
    echo -e "${RED}One or more engines failed compilation. Please inspect errors above.${NC}\n"
    exit 1
fi
