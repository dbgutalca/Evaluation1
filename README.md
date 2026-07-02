# Performance Evaluation of Secondary-Memory Storage Methods for Property Graphs (Supplementary material)

This repository contains supplementary material of the article "Performance Evaluation of Secondary-Memory Storage Methods for Property Graphs".

## Abstract
We present an experimental study of secondary-memory storage alternatives for property graphs. To remove the main-memory storage bottleneck of PathDB—an in-memory engine specialized in evaluating regular path queries (RPQs)—we implement and integrate five on-disk backends based on MapDB, RocksDB, Sparksee, PostgreSQL, and Neo4j. Each backend is tailored to the underlying technology, respectively leveraging (i) disk-based hash maps and B-trees (MapDB), (ii) a column-family key–value layout (RocksDB), (iii) a schema-aware native graph store (Sparksee), (iv) an entity–attribute–value (EAV) relational schema (PostgreSQL), and (v) a homogeneous labeled-property model (Neo4j). Using LDBC SNB Datagen graphs at scale factors 0.1, 0.3, 1.0, and 3.0, we measure ingestion time, disk footprint, and the average latency of three representative access patterns: node lookup by identifier, edge retrieval by label, and node retrieval by property value. Across all scales, RocksDB delivers the best overall trade-off, achieving the lowest query latency together with the fastest ingestion and smallest footprint, and is therefore selected as PathDB’s candidate secondary-memory backend.

## Repository Structure

*   **`methods/`**: Directory containing the source code for each evaluated database prototype.
    *   `rocksstorage/`: RocksDB Java implementation (Maven project).
    *   `mapdbstorage/`: MapDB Java implementation (Maven project).
    *   `neo4jc/`: Neo4j Java client implementation (Maven project).
    *   `sparksee/`: Sparksee Java implementation (precompiled jars included).
    *   `sql/`: PostgreSQL Java implementation (JDBC driver included).
*   **`ids`**: A text file containing the **100 unique node IDs** used as inputs for the Q1 experiment.
*   **`relationships`**: A text file containing the **10 relationship labels** of high cardinality used to evaluate Q2.
*   **`property_value_pairs`**: A text file containing the **8 property-value pairs** used to evaluate Q3.
*   **`results.md`**: A markdown file containing the average results (ingestion time, storage footprint, and average query latencies) for all engines across different scale factors.

---

## Evaluated Engines

The benchmark compares five distinct storage models:

1.  **RocksDB:** Embedded high-performance key-value store. Uses manual binary serialization via `ByteBuffer` and custom-built prefix-based indexes.
2.  **Sparksee:** Embedded native graph database. Relies on internal object identifiers (OIDs) and native bitmap-based index structures.
3.  **MapDB:** Embedded Java-native collection database. Uses Java serialization and on-disk B-Tree structures (`NavigableSet`).
4.  **PostgreSQL:** Relational database management system. Simulates property graphs using a vertical Entity-Attribute-Value (EAV) mapping table for properties.
5.  **Neo4j:** Client-server native graph database. Interacted with using Cypher queries via the official Java driver.

---

## Evaluated Workloads

The systems are subjected to three primary query workloads:

*   **Q1 (getNode):** Retrieving the label and all property-value pairs of a specific node given its unique ID.
*   **Q2 (EdgesByLabel):** Retrieving the IDs of all edges matching a specific relationship label.
*   **Q3 (PropEquals):** Retrieving the IDs of all nodes matching an exact property-value condition.
*   **Ingest (Bulk Load):** Loading all nodes and edges from a PGDF representation into the target engine and building all necessary indexes.