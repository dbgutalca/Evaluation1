# Persistence Engines Comparison

Evaluation and comparison of performance, write speed, and storage footprint on five different database technologies for storing property graphs.

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