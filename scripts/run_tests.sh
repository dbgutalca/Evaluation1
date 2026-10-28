#!/usr/bin/env bash
# ==============================================================================
# Unified Storage Engine Verification Script (PGDF)
# Usage:
#   ./scripts/run_tests.sh           # Run tests for all engines
#   ./scripts/run_tests.sh rocks     # Test RocksDB only
#   ./scripts/run_tests.sh mapdb     # Test MapDB only
#   ./scripts/run_tests.sh sparksee  # Test Sparksee only
#   ./scripts/run_tests.sh postgres  # Test PostgreSQL only
#   ./scripts/run_tests.sh neo4j     # Test Neo4j only
# ==============================================================================

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load .env file if present
if [ -f "${ROOT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${ROOT_DIR}/.env"
    set +a
elif [ -f "${SCRIPT_DIR}/.env" ]; then
    set -a
    # shellcheck disable=SC1090
    source "${SCRIPT_DIR}/.env"
    set +a
fi

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Default Credentials
PG_URL="${PG_URL:-jdbc:postgresql://localhost:5432/postgres}"
PG_USER="${PG_USER:-postgres}"
PG_PASS="${PG_PASS:-postgres}"

NEO4J_URI="${NEO4J_URI:-bolt://localhost:7687}"
NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_PASS="${NEO4J_PASS:-password}"

TARGET="${1:-all}"

RESULTS_NAME=()
RESULTS_STATUS=()
RESULTS_DETAIL=()

record_result() {
    local name="$1"
    local status="$2"
    local detail="$3"
    RESULTS_NAME+=("$name")
    RESULTS_STATUS+=("$status")
    RESULTS_DETAIL+=("$detail")
}

run_rocks() {
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${CYAN}>>> Running Tests: RocksDB${NC}"
    echo -e "${CYAN}==================================================${NC}"
    cd "${ROOT_DIR}/methods/rocksstorage" || return 1
    
    local output
    output=$(mvn clean test 2>&1)
    local code=$?

    if [ $code -eq 0 ]; then
        echo -e "${GREEN}✓ RocksDB: All tests completed successfully.${NC}"
        record_result "RocksDB" "PASS" "Q1, Q2, Q3, Ingest, Benchmark OK"
    else
        echo -e "${RED}✗ RocksDB: Tests failed.${NC}"
        echo "$output" | tail -n 25
        record_result "RocksDB" "FAIL" "Maven test failed"
    fi
}

run_mapdb() {
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${CYAN}>>> Running Tests: MapDB${NC}"
    echo -e "${CYAN}==================================================${NC}"
    cd "${ROOT_DIR}/methods/mapdbstorage" || return 1
    
    local output
    output=$(mvn clean test 2>&1)
    local code=$?

    if [ $code -eq 0 ]; then
        echo -e "${GREEN}✓ MapDB: All tests completed successfully.${NC}"
        record_result "MapDB" "PASS" "Q1, Q2, Q3, Ingest, Benchmark OK"
    else
        echo -e "${RED}✗ MapDB: Tests failed.${NC}"
        echo "$output" | tail -n 25
        record_result "MapDB" "FAIL" "Maven test failed"
    fi
}

run_sparksee() {
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${CYAN}>>> Running Tests: Sparksee${NC}"
    echo -e "${CYAN}==================================================${NC}"
    cd "${ROOT_DIR}/methods/sparksee" || return 1

    echo "Compiling Sparksee Java sources..."
    if ! javac -cp "sparkseejava.jar:." SparkseeImplementation2.java SparkseeTest.java; then
        echo -e "${RED}✗ Sparksee: Compilation error (javac).${NC}"
        record_result "Sparksee" "FAIL" "Compilation error"
        return 1
    fi

    local output
    output=$(java -cp "sparkseejava.jar:." SparkseeTest 2>&1)
    local code=$?

    if echo "$output" | grep -q "ALL SPARKSEE TESTS PASSED SUCCESSFULLY"; then
        echo -e "${GREEN}✓ Sparksee: All tests completed successfully.${NC}"
        record_result "Sparksee" "PASS" "Q1, Q2, Q3, Ingest, Benchmark OK"
    elif echo "$output" | grep -q "\[SKIP\]"; then
        local reason
        reason=$(echo "$output" | grep "\[SKIP\]" | head -n 1)
        echo -e "${YELLOW}⚠ Sparksee: Skipped in this environment (${reason}).${NC}"
        record_result "Sparksee" "SKIP" "License or native library unavailable locally"
    else
        echo -e "${RED}✗ Sparksee: Tests failed.${NC}"
        echo "$output" | tail -n 25
        record_result "Sparksee" "FAIL" "Test execution failed"
    fi
}

run_postgres() {
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${CYAN}>>> Running Tests: PostgreSQL${NC}"
    echo -e "${CYAN}==================================================${NC}"
    cd "${ROOT_DIR}/methods/sql" || return 1

    echo "Compiling PostgreSQL Java sources..."
    if ! javac -cp "postgresql-42.7.8.jar:." PostgresColumns.java PostgresTest.java; then
        echo -e "${RED}✗ PostgreSQL: Compilation error (javac).${NC}"
        record_result "PostgreSQL" "FAIL" "Compilation error"
        return 1
    fi

    local output
    output=$(java -cp "postgresql-42.7.8.jar:." PostgresTest "$PG_URL" "$PG_USER" "$PG_PASS" 2>&1)
    local code=$?

    if echo "$output" | grep -q "ALL POSTGRESQL TESTS PASSED SUCCESSFULLY"; then
        echo -e "${GREEN}✓ PostgreSQL: All tests completed successfully.${NC}"
        record_result "PostgreSQL" "PASS" "Q1, Q2, Q3, Ingest, Benchmark OK"
    elif echo "$output" | grep -q "\[SKIP\]"; then
        local reason
        reason=$(echo "$output" | grep "\[SKIP\]" | head -n 1)
        echo -e "${YELLOW}⚠ PostgreSQL: Skipped (${reason}).${NC}"
        record_result "PostgreSQL" "SKIP" "Server offline on port 5432"
    else
        echo -e "${RED}✗ PostgreSQL: Tests failed.${NC}"
        echo "$output" | tail -n 25
        record_result "PostgreSQL" "FAIL" "Connection or test execution failed"
    fi
}

run_neo4j() {
    echo -e "\n${CYAN}==================================================${NC}"
    echo -e "${CYAN}>>> Running Tests: Neo4j${NC}"
    echo -e "${CYAN}==================================================${NC}"
    cd "${ROOT_DIR}/methods/neo4jc" || return 1

    local output
    output=$(mvn clean test \
        "-Dneo4j.uri=${NEO4J_URI}" \
        "-Dneo4j.user=${NEO4J_USER}" \
        "-Dneo4j.pass=${NEO4J_PASS}" 2>&1)
    local code=$?

    if [ $code -eq 0 ]; then
        if echo "$output" | grep -q "Skipped: 1"; then
            echo -e "${YELLOW}⚠ Neo4j: Server offline at ${NEO4J_URI}. Skipped gracefully.${NC}"
            record_result "Neo4j" "SKIP" "Bolt server offline on port 7687"
        else
            echo -e "${GREEN}✓ Neo4j: All tests completed successfully.${NC}"
            record_result "Neo4j" "PASS" "Q1, Q2, Q3, Ingest, Benchmark OK"
        fi
    else
        echo -e "${RED}✗ Neo4j: Tests failed.${NC}"
        echo "$output" | grep -E "(\[ERROR\]|AuthenticationException|ServiceUnavailableException|AssertionError|FAILED)" | tail -n 15
        record_result "Neo4j" "FAIL" "Authentication or test execution failed"
    fi
}

# Main Execution Flow
case "$TARGET" in
    all)
        run_rocks
        run_mapdb
        run_sparksee
        run_postgres
        run_neo4j
        ;;
    rocks|rocksdb)
        run_rocks
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
        echo "Invalid target: $TARGET"
        echo "Available options: all | rocks | mapdb | sparksee | postgres | neo4j"
        exit 2
        ;;
esac

# Summary Table
echo -e "\n\n================================================================================"
echo -e "                     STORAGE ENGINE TEST SUMMARY REPORT                         "
echo -e "================================================================================"
printf "%-15s | %-10s | %-50s\n" "ENGINE" "STATUS" "DETAILS"
echo "--------------------------------------------------------------------------------"

fail_count=0
pass_count=0
skip_count=0

for i in "${!RESULTS_NAME[@]}"; do
    name="${RESULTS_NAME[$i]}"
    status="${RESULTS_STATUS[$i]}"
    detail="${RESULTS_DETAIL[$i]}"

    case "$status" in
        PASS)
            printf "%-15s | ${GREEN}%-10s${NC} | %-50s\n" "$name" "$status" "$detail"
            ((pass_count++))
            ;;
        SKIP)
            printf "%-15s | ${YELLOW}%-10s${NC} | %-50s\n" "$name" "$status" "$detail"
            ((skip_count++))
            ;;
        FAIL)
            printf "%-15s | ${RED}%-10s${NC} | %-50s\n" "$name" "$status" "$detail"
            ((fail_count++))
            ;;
    esac
done
echo "================================================================================"
echo -e "Totals: ${pass_count} passed, ${skip_count} skipped (no local service), ${fail_count} failed."

if [ "$fail_count" -gt 0 ]; then
    echo -e "${RED}Test suite encountered failures. Please review logs above.${NC}"
    exit 1
else
    echo -e "${GREEN}All evaluated engines are verified and in a consistent state!${NC}"
    exit 0
fi
