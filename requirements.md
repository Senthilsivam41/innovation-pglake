# Product & Architecture Requirements Document (PRD)
## Project Name: Project AetherLake (Common Iceberg Storage Layer)
**Status:** Draft | **Target Architecture:** Skeleton-First / Contract-First | **Storage Format:** Apache Iceberg

---

## 1. Executive Summary & Core Objective
Project **AetherLake** aims to decouple operational database engines from heavy analytical processing by establishing a unified, shared-storage data lakehouse layer. By leveraging the open-source `pg_lake` extension (which embeds a vectorized DuckDB execution engine inside PostgreSQL) alongside **Apache Iceberg**, this project establishes a single source of truth in cloud object storage (e.g., AWS S3). 

Operational applications write directly to Postgres with full ACID transactional reliability. Simultaneously, downstream analytical platforms (e.g., Snowflake, Databricks, Apache Spark) consume the exact same underlying Iceberg/Parquet metadata files natively without requiring brittle, expensive, high-maintenance Extract-Transform-Load (ETL) pipelines or traditional Change Data Capture (CDC) replication agents.

---

## 2. Architectural Blueprint & Data Flow

```
   +------------------------------------------------------------+
   |                  USER APPLICATION LAYER                    |
   |         (OLTP Clients, Microservices, API Gateways)        |
   +------------------------------------------------------------+
                                 |
                     [ Standard SQL / TCP ]
                                 v
   +------------------------------------------------------------+
   |                POSTGRESQL CORE ENGINE                      |
   |   - Auth, Connection Pooling, Query Parsing & ACL          |
   |   - Local Heap Storage (For highly transient/ACID data)    |
   +------------------------------------------------------------+
                                 |
                  [ Transparent Query Routing ]
                                 v
   +------------------------------------------------------------+
   |               PG_LAKE EXTENSION STACK                      |
   |   +--------------------------+  +-----------------------+  |
   |   |   pg_lake_iceberg        |  |  pgduck_server        |  |
   |   |   (Catalog/Metadata Mgmt)|  |  (Vectorized Engine)  |  |
   |   +--------------------------+  +-----------------------+  |
   +------------------------------------------------------------+
                                 |
               [ ACID-Guaranteed S3 Direct Multi-Write ]
                                 v
   +------------------------------------------------------------+
   |                UNIFIED OBJECT STORAGE (S3)                 |
   |   +----------------------------------------------------+   |
   |   |                Apache Iceberg Table                |   |
   |   |  - Metadata/Manifests                              |   |
   |   |  - Columnar Parquet Data Files                     |   |
   |   +----------------------------------------------------+   |
   +------------------------------------------------------------+
            /                                            \
  [ Native Catalog Read ]                       [ Native Catalog Read ]
          v                                             v
+------------------------+                    +------------------------+
|    SNOWFLAKE ENGINE    |                    |   DATABRICKS / SPARK   |
| (BI, ML, Aggregates)   |                    | (Heavy Data Sci, ML)   |
+------------------------+                    +------------------------+
```

### High-Level Components:
1. **PostgreSQL & Routing Engine:** Acts as the transactional gatekeeper. It parses incoming SQL queries and determines whether a table resides in local heap storage or external object storage.
2. **pg_lake Extension Stack:** Decouples storage and compute. It utilizes `pg_lake_iceberg` for table catalog management and routes heavy analytical execution paths to `pgduck_server` (an embedded vectorized DuckDB process).
3. **Unified Object Storage:** Standardized S3 bucket organization containing Apache Iceberg structures (metadata logs, manifest lists, manifest files, and data files formatted in Parquet).
4. **Downstream Consumers:** External engines attached via external catalogs to run multi-engine queries on identical point-in-time snapshots.

---

## 3. Functional Requirements

### 3.1 Skeleton-First Pluggable Storage Engine
* **SR-1:** The core architecture must prioritize a **Contract-First approach**. The interfaces for table writes, reads, and schema mutations must be decoupled from the raw persistence layer.
* **SR-2:** Implement pluggable persistence definitions so that local mock targets, local MinIO storage, or enterprise AWS S3 buckets can be swapped out via environmental configuration files without altering application logic.

### 3.2 Transactional Integrity & Delta Orchestration
* **SR-3:** All external writes routed through `pg_lake` must maintain strict **ACID transactional guarantees**. If an S3 multi-part upload or metadata flush fails mid-transaction, the Postgres engine must perform an automated rollback on operational states.
* **SR-4:** Implement automated, intra-database scheduling using **`pg_cron`** to run optimized delta loops. This layer will batch-transfer operational states to Iceberg tables synchronously or near-synchronously based on strict sliding window timestamps (e.g., `WHERE created_at > LAST_SYNC`).

### 3.3 Dynamic Multi-Engine Schema Evolution
* **SR-5:** Changes made to schemas via Postgres standard DDL commands (`ALTER TABLE ... ADD COLUMN`) must instantly serialize out to the Iceberg metadata JSON files.
* **SR-6:** Downstream systems (Snowflake/Databricks) reading the metadata repository must pick up schema evolutions seamlessly without requiring table drops or manual rebuilds.

---

## 4. Technical Constraints & Bounds

* **TC-1 Database Limitations:** Systems leveraging this shared pattern cannot leverage legacy production tables that are bound to native Postgres heap formats without explicit physical migration (`INSERT INTO ... SELECT`).
* **TC-2 Data Retention & Auditing:** The Iceberg metadata lifecycle must retain historical snapshot configurations to allow time-travel queries across multiple engines. However, an automated vacuum schedule must prune unreferenced Parquet files to manage cloud storage costs.
* **TC-3 Synchronicity Boundaries:** This project targets a Zero-ETL batch paradigm. Real-time streaming applications requiring sub-second, row-by-row event propagation must fallback to row-level Change Data Capture (CDC) pipelines (e.g., Debezium, Kafka).

---

## 5. Non-Functional Requirements

* **Performance:** Vectorized query scanning through `pgduck_server` must deliver columnar performance metrics comparable to native analytical engines for aggregations, avoiding typical Postgres row-oriented memory bloat.
* **Reliability:** Storage failure tolerance should be high; out-of-band cloud infrastructure outages must be captured gracefully by the application layer using standard SQL exception codes.
* **Security:** All data at rest in S3 must utilize AES-256 server-side encryption. The access control policies must follow the principle of least privilege, providing write capabilities to Postgres and read-only access to analytical platforms.
