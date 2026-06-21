# Persistence Engines Comparison

The objective of this phase was to evaluate and compare the performance, write speed, and storage footprint of five different database technologies for storing property graphs.

## Repository Structure

*   `ids`: A text file containing the **100 unique node IDs** used as inputs for the Q1 experiment.
*   `relationships`: A text file containing the **10 relationship labels** of high cardinality used to evaluate Q2.
*   `property_value_pairs`: A text file containing the **8 property-value pairs** used to evaluate Q3.
*   `Resultados.md`: A markdown file containing the average results (ingestion time, storage footprint, and average query latencies) for all engines across different scale factors.

## Evaluated Engines

The benchmark compares five distinct storage models:
1.  **RocksDB:**
2.  **Sparksee:** 
3.  **MapDB:** 
4.  **PostgreSQL:** 
5.  **Neo4j:**

## Evaluated Queries

The systems are subjected to three primary query workloads:
*   **Q1 (getNode):** Retrieving the label and all property-value pairs of a specific node given its unique ID.
*   **Q2 (EdgesByLabel):** Retrieving the IDs of all edges matching a specific relationship label.
*   **Q3 (PropEquals):** Retrieving the IDs of all nodes matching an exact property-value condition.
