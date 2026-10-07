# Performance Evaluation of Secondary-Memory Storage Methods for Property Graphs (Supplementary material)

This repository contains supplementary material of the article "Performance Evaluation of Secondary-Memory Storage Methods for Property Graphs".

## Abstract
We present an experimental study of secondary-memory storage alternatives for property graphs. To remove the main-memory storage bottleneck of PathDB—an in-memory engine specialized in evaluating regular path queries (RPQs)—we implement and integrate five on-disk backends based on MapDB, RocksDB, Sparksee, PostgreSQL, and Neo4j. Each backend is tailored to the underlying technology, respectively leveraging (i) disk-based hash maps and B-trees (MapDB), (ii) a column-family key–value layout (RocksDB), (iii) a schema-aware native graph store (Sparksee), (iv) an entity–attribute–value (EAV) relational schema (PostgreSQL), and (v) a homogeneous labeled-property model (Neo4j). Using LDBC SNB Datagen graphs at scale factors 0.1, 0.3, 1.0, and 3.0, we measure ingestion time, disk footprint, and the average latency of three representative access patterns: node lookup by identifier, edge retrieval by label, and node retrieval by property value. Across all scales, RocksDB delivers the best overall trade-off, achieving the lowest query latency together with the fastest ingestion and smallest footprint, and is therefore selected as PathDB’s candidate secondary-memory backend.

---

## Evaluated Engines

The benchmark compares five distinct storage models:

1.  **RocksDB:** Embedded high-performance key-value store. Uses manual binary serialization via `ByteBuffer` and custom-built prefix-based indexes.
2.  **Sparksee:** Embedded native graph database. Relies on internal object identifiers (OIDs) and native bitmap-based index structures.
3.  **MapDB:** Embedded Java-native collection database. Uses Java serialization and on-disk B-Tree structures (`NavigableSet`).
4.  **PostgreSQL:** Relational database management system. Simulates property graphs using a vertical Entity-Attribute-Value (EAV) mapping table for properties.
5.  **Neo4j:** Client-server native graph database. Interacted with using Cypher queries via the official Java driver.

---

## Datasets

As evaluation datasets, we used four property graphs produced with the LDBC Social Network Benchmark (SNB) Data Generator. Specifically, we generate four graphs with scale factors 0.1, 0.3, 1.0, and 3.0, respectively. The generator produces a directory of CSV files, each corresponding to an element of the SNB schema. To streamline ingestion into PathDB, we developed a Python tool that transforms and consolidates these CSVs into two PGDF files: nodes.pgdf (node records) and edges.pgdf (edge records). Reproducible generation and conversion instructions are available at [here](https://github.com/urzuaf/ldbc-to-pgdf). The following table shows basic information about the generated graph instances.

| Graph | Scale Factor | Nodes | Edges | Disk Size |
|---|---|---|---|---|
| G1 | 0.1 | 367,342 | 1,760,926 | 216 MB |
| G2 | 0.3 | 940,322 | 5,003,201 | 609 MB |
| G3 | 1.0 | 2,997,354 | 17,196,776 | 2.0 GB |
| G4 | 3.0 | 8,513,157 | 51,035,227 | 6.1 GB |

The datasets can be downloaded from [here](https://drive.google.com/drive/folders/1bFwZx0RRvLi9lhKBQNaeUpRD6ygiiJD0). 

---

## Evaluated Workloads

The systems are subjected to three primary query workloads:

*   **Q1 (getNode):** Retrieving the label and all property-value pairs of a specific node given its unique ID.
*   **Q2 (EdgesByLabel):** Retrieving the IDs of all edges matching a specific relationship label.
*   **Q3 (PropEquals):** Retrieving the IDs of all nodes matching an exact property-value condition.
*   **Ingest (Bulk Load):** Loading all nodes and edges from a PGDF representation into the target engine and building all necessary indexes.

---

## Parameter Generation and Workload Inputs

To ensure reproducible and uniform sampling across scale factors, query parameters are generated dynamically using `generate_params.py`:

*   **`generate_params.py`**: A Python script that parses `sf*/Nodes.pgdf` and applies *Reservoir Sampling* (`NUM_SAMPLES = 100`, `SEED = 42`) over the dynamic entity labels (`COMMENT`, `FORUM`, `PERSON`, `POST`).
*   **`params/`**: Output directory containing generated parameter files for each scale factor (`sf01`, `sf03`, `sf1`, `sf3`):
    *   `ids_sf<scale>`: Text file containing **100 sampled node IDs** per scale factor used as inputs for **Q1**.
    *   `props_sf<scale>`: Text file containing **100 sampled property-value pairs** (`key=value`) per scale factor used as inputs for **Q3**.

---

## Directory Structure and Related Information

*   **`methods/`**: Directory containing the source code for each evaluated database prototype.
    *   `rocksstorage/`: RocksDB Java implementation (Maven project).
    *   `mapdbstorage/`: MapDB Java implementation (Maven project).
    *   `neo4jc/`: Neo4j Java client implementation (Maven project).
    *   `sparksee/`: Sparksee Java implementation (precompiled JARs included).
    *   `sql/`: PostgreSQL Java implementation (JDBC driver included).
*   **`generate_params.py`**: Python script to extract reproducible input parameters from `sf*/Nodes.pgdf`.
*   **`params/`**: Directory containing scale-factor specific input files (`ids_sf*` and `props_sf*`).
