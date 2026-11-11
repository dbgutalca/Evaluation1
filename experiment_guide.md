# Experiment Execution and Reproduction Guide

This guide provides instructions for compiling, ingesting, benchmarking, and analyzing the secondary-memory property graph storage engines evaluated in this study (RocksDB, Sparksee, MapDB, PostgreSQL, and Neo4j).

---

## 1. Prerequisites and Environment Setup

Ensure the following system dependencies are installed and available on your system `PATH`:

* **Java Development Kit (JDK):** Version 17 or higher (`java -version`, `javac -version`).
* **Apache Maven:** Version 3.8 or higher (`mvn -version`).
* **Python:** Version 3.8 or higher (`python3 --version`).
* **PostgreSQL:** Service running locally with an accessible database named `gdb`:
  ```bash
  sudo systemctl start postgresql
  sudo -u postgres createdb gdb
  ```
* **Neo4j:** Community or Enterprise edition running locally via Bolt on port 7687:
  ```bash
  sudo systemctl start neo4j
  ```
* **Sparksee License:** Place your `sparksee.cfg` file containing valid license credentials inside `methods/sparksee/`:
  ```bash
  cp sparksee.cfg methods/sparksee/
  ```

---

## 2. Dataset Placement and Configuration

To maintain zero-copy data access and simplify paths across all 5 engines, **place the graph dataset files (`Nodes.pgdf` and `Edges.pgdf`, or `Nodes` and `Edges`) directly in the root directory of this repository**, alongside `benchmark.properties`.

1. **Create the configuration file from the template:**
   ```bash
   cp benchmark.properties.example benchmark.properties
   ```

2. **Configure dataset paths and scale parameters:**
   Edit `benchmark.properties` to specify your target scale factor (e.g., `sf1`, `sf3`, `sf10`) and point to root-level data files:
   ```properties
   scale_factor=sf1

   # Dataset files located at repository root
   nodes_path=Nodes.pgdf
   edges_path=Edges.pgdf

   # Query parameter files for the corresponding scale factor
   ids_path=params/ids_sf1
   labels_path=params/labels
   props_path=params/props_sf1

   # Output directory for result CSVs and execution logs
   results_dir=results

   # Benchmark protocol parameters
   benchmark_condition=both     # cold, warm, or both
   cold_iterations=3            # Measured cold repetitions (caches dropped before each)
   warmup_iterations=3          # Discarded warm-up passes
   measured_iterations=5        # Measured warm repetitions
   shuffle_queries=true         # Deterministic per-repetition query order shuffling
   random_seed=42
   ```

---

## 3. Step-by-Step Execution Workflow

Execute the benchmark suite following the five-stage pipeline:

```
[1. Compile] -> [2. Smoke Test] -> [3. Ingest] -> [4. Benchmark]
                                          ^
                          (Reset if needed: reset_storage.sh)
```

---

### Step 1: Offline Compilation (`compile_all.sh`)

Compiles all five backend implementations (Java source, C++ JNI wrappers, and Maven projects) offline:

```bash
# Compile all 5 engines
./scripts/compile_all.sh

# Or compile an individual engine
./scripts/compile_all.sh rocksdb
./scripts/compile_all.sh postgres
./scripts/compile_all.sh neo4j
./scripts/compile_all.sh sparksee
./scripts/compile_all.sh mapdb
```

Verify that all engines report `PASS [Exit Code: 0]`.

---

### Step 2: Pre-flight Verification (`run_tests.sh`)

Before launching long ingestion runs, execute the integration smoke test. This creates an isolated 10-node, 10-edge temporary graph to verify native libraries, database connections, and license validity:

```bash
# Run smoke tests on all engines
./scripts/run_tests.sh

# Or test a single engine
./scripts/run_tests.sh neo4j
```

Confirm that all tested backends output `PASS`.

---

### Step 3: Data Ingestion and Index Construction (`run_ingest.sh`)

Loads nodes and edges from the root PGDF files into the native secondary-memory structures and creates all required primary and secondary indexes:

```bash
# Ingest all engines sequentially
./scripts/run_ingest.sh

# Or ingest a specific engine
./scripts/run_ingest.sh rocksdb
./scripts/run_ingest.sh postgres
```

#### Output Metrics:
* Generates `results/ingest.csv` and per-engine CSVs (`ingest_<engine>.csv`).
* Metrics captured include total nodes, total edges, data insertion time (`T_Insert`), secondary index creation time (`T_Index`), and total ingestion wall-clock time (`T_Total`).

#### Storage Locations:
* **RocksDB:** `methods/rocksstorage/rocksdb_data/` (SST files and WAL).
* **MapDB:** `methods/mapdbstorage/mapdb_data*` (Memory-mapped B-Tree storage).
* **Sparksee:** `methods/sparksee/sparksee_db.gdb` (Native bitmap graph store).
* **PostgreSQL:** Tables inside the local database `gdb`.
* **Neo4j:** Store files in the service directory (`/var/lib/neo4j/data/databases/neo4j/`).

---

### Step 4: Workload Benchmark Execution (`run_benchmark.sh`)

Executes the three canonical secondary-memory query patterns:
* **Q1 (`getNode`):** Point lookup retrieving node label and properties by unique identifier.
* **Q2 (`getEdgesByLabel`):** Massive scan retrieving all edge endpoints matching a relationship label.
* **Q3 (`getNodesByProperty`):** Attribute index lookup retrieving node IDs matching an exact `key=value` predicate.

```bash
# Execute benchmark across all backends
./scripts/run_benchmark.sh

# Or execute specific engines
./scripts/run_benchmark.sh postgres
./scripts/run_benchmark.sh neo4j
```

#### Key Capabilities of the Benchmark Runner:
1. **Selective Auto-Cleanup:** Before running an engine, the script cleans only that engine's previous benchmark metrics (`benchmark_<engine>.csv` and `ram_usage_<engine>.csv`), keeping results from other engines completely intact.
2. **Cold Cache Enforcement:** Before every cold repetition, the script flushes the Linux page cache (`sync; echo 3 > /proc/sys/vm/drop_caches`) and restarts the background service (PostgreSQL/Neo4j). For Neo4j, it actively waits on TCP port 7687 to prevent connection errors.
3. **Warm Pass Protocol:** Executes unmeasured warm-up iterations to saturate buffer caches before collecting measured repetitions.
4. **RAM Utilization Sampler:** Monitors process memory at 200 ms intervals:
   * **Embedded Engines (RocksDB, MapDB, Sparksee):** Measures process Resident Set Size (RSS).
   * **PostgreSQL:** Measures client RSS plus server Proportional Set Size (PSS) via `/proc/$PID/smaps_rollup` to avoid multi-counting shared buffer pool pages.
   * **Neo4j:** Measures combined Bolt client RSS and server JVM daemon RSS.
5. **Metric Consolidation:** Automatically merges all per-engine runs into `results/benchmark.csv` and `results/ram_usage.csv`.

#### Running via SSH (Background / Detached):
For long-running benchmarks on remote VMs, run within a `tmux` session to ensure resilience against SSH disconnections:
```bash
tmux
./scripts/run_benchmark.sh neo4j
# Detach with: Ctrl + b, then d
# Re-attach with: tmux attach
```

---

### Step 5: Storage Reset (`reset_storage.sh`)

To wipe database stores and restart cleanly (e.g., when switching scale factors or recovering from an interrupted ingestion):

```bash
# Wipe all 5 backends
./scripts/reset_storage.sh all

# Or reset an individual backend
./scripts/reset_storage.sh rocksdb
./scripts/reset_storage.sh postgres
./scripts/reset_storage.sh neo4j
```

Add `--force` or `-f` to bypass interactive confirmation prompts.

---
### Transferring Results from Remote VM to Local Machine:
If operating on a restricted VM without direct inbound ports:
1. **On the Local Receiver Machine:**
   ```bash
   python3 scripts/results_transfer.py receive --port 8080 --token "secret123" --single
   ```
2. **On the Remote VM (Sender):**
   ```bash
   python3 scripts/results_transfer.py send \
     --url "https://<PUBLIC_ENDPOINT>/upload" \
     --token "secret123" \
     --dir results \
     --tag sf1
   ```
   *(Alternatively, copy directly over SSH using `scp -r user@remote:~/Evaluation1/results ./received_results/sf1`).*
