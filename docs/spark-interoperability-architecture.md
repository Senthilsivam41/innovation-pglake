# Spark Interoperability Architecture

**Status:** Local independent Spark P0 validated; Databricks and production rollout pending
**Scope:** Read-only Spark consumption of Iceberg tables written by PostgreSQL/pg_lake  
**Current catalog:** PostgreSQL-backed Iceberg JDBC catalog  
**Databricks status:** No workspace available; compatibility experiment pending

## 1. Purpose and boundary

AetherLake keeps PostgreSQL/pg_lake as the authoritative writer and Iceberg
catalog. Independent Spark consumers read the same committed Iceberg metadata
and Parquet files without querying through PostgreSQL or pgduck_server.

The supported baseline is:

```text
Application
    │ PostgreSQL SQL
    ▼
PostgreSQL + pg_lake ── atomic catalog pointer update ──► S3/MinIO
    │                                                     ▲
    │ JDBC catalog discovery                                │ S3FileIO reads
    ▼                                                     │
Spark + Iceberg ──────────────────────────────────────────┘
```

The consumer is read-only. External engines must not modify tables owned by
pg_lake because PostgreSQL owns the catalog pointer and table metadata lifecycle.

This design does not include:

- a new REST catalog service;
- Spark or Databricks writes into pg_lake-owned tables;
- ETL, CDC, or a second copy of the data;
- Databricks certification before a real Databricks runtime test.

## 2. High-level architecture

Open the [interactive system architecture](aetherlake.architecture.html).
It separates the verified local Spark consumer from the unverified Databricks
gate, rather than presenting them as one supported runtime.

### Ownership

| Concern | Owner | Consumer behavior |
|---|---|---|
| Table schema and field IDs | pg_lake/PostgreSQL | Read and refresh |
| Current metadata pointer | PostgreSQL `iceberg_tables` | Discover through JDBC |
| Metadata/manifests/data files | S3-compatible storage | Read-only object access |
| Snapshot publication | PostgreSQL transaction | Never publish from Spark |
| Retention and vacuum | pg_lake maintenance | Must respect consumer lag |
| Authorization | PostgreSQL role + object-store policy | Dedicated read-only identity |

### Commit/read sequence

1. PostgreSQL executes a write against an Iceberg table.
2. pg_lake writes the new Iceberg metadata/data objects.
3. PostgreSQL commits the catalog pointer transactionally.
4. Spark resolves the table through the JDBC catalog.
5. Spark reads the returned metadata and Parquet files directly from object storage.
6. A later Spark planning operation observes a newer committed snapshot after its
   catalog cache expires or is refreshed.

## 3. Low-level design

Open the [interactive Spark read-path diagram](spark-interoperability.architecture.html)
for catalog discovery, object reads, and the two read-only identities. The
corresponding implementation is in the [Spark validation job](../tests/spark_interop.py),
[catalog role](../docker/postgres/init/07-spark-reader.sql), and
[MinIO policy bootstrap](../docker/minio/init-minio.sh).

### 3.1 Catalog identity and namespace

The catalog name must equal the PostgreSQL database name. With the repository
defaults:

```text
Catalog:    aetherlake
Namespace:  aetherlake
Table:      events
Spark name: aetherlake.aetherlake.events
```

The active local table currently uses PostgreSQL catalog metadata and an S3
location under the configured `S3_BUCKET`/`S3_PREFIX`. Consumers must discover
the current metadata location through the catalog; they must not hard-code or
poll a `metadata.json` path.

### 3.2 Spark catalog configuration

The following is the baseline configuration shape. Match Spark, Iceberg, and
PostgreSQL JDBC driver versions as one tested set; the pinned pg_lake source
documents an Iceberg Spark 3.5 example using `JdbcCatalog`.

```text
spark.sql.extensions=org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions
spark.sql.catalog.aetherlake=org.apache.iceberg.spark.SparkCatalog
spark.sql.catalog.aetherlake.catalog-impl=org.apache.iceberg.jdbc.JdbcCatalog
spark.sql.catalog.aetherlake.uri=jdbc:postgresql://<postgres-host>:5432/aetherlake?sslmode=require
spark.sql.catalog.aetherlake.warehouse=s3://
spark.sql.catalog.aetherlake.io-impl=org.apache.iceberg.aws.s3.S3FileIO
spark.sql.catalog.aetherlake.s3.endpoint=https://<object-store-endpoint>
spark.sql.catalog.aetherlake.cache.expiration-interval-ms=30000
```

For local MinIO only, use a reachable endpoint and path-style access:

```text
spark.sql.catalog.aetherlake.s3.endpoint=http://<minio-host>:9000
spark.sql.catalog.aetherlake.s3.path-style-access=true
```

The Spark runtime must include:

- an Iceberg Spark runtime matching the Spark/Scala version;
- the Iceberg AWS bundle for `S3FileIO`;
- the PostgreSQL JDBC driver;
- credentials supplied through the runtime secret mechanism, never committed
  in Spark configuration or event logs.

### 3.3 Read-only security contract

Create a dedicated consumer identity. Do not reuse `aetherlake_app`, which is
the application writer role.

The consumer requires:

```text
PostgreSQL:
  CONNECT on database aetherlake
  USAGE on schema aetherlake
  SELECT on approved Iceberg tables and catalog metadata
  no INSERT, UPDATE, DELETE, CREATE, ALTER, or DROP

Object storage:
  ListBucket limited to the AetherLake warehouse prefix
  GetObject limited to that prefix
  no PutObject, DeleteObject, or bucket administration
```

The repository provisions `aetherlake_spark_reader` with catalog and table
`SELECT` only. Local MinIO creates `aetherlake_spark_reader` object credentials
scoped to `GetObject` and warehouse-prefix `ListBucket`; an attempted object
write must fail. Set separate, non-default production secrets and use a
private, TLS-protected PostgreSQL endpoint and independently scoped cloud
object-storage identity. Compose's loopback-bound ports and local credentials
are not a production network or secrets deployment.

### 3.4 Data and schema contract

The first interoperability table is `aetherlake.events`:

| Column | PostgreSQL type | Consumer requirement |
|---|---|---|
| `event_id` | `uuid` | Read as a stable identifier |
| `tenant_id` | `bigint` | Preserve integer range |
| `event_type` | `text` | Preserve UTF-8 text |
| `event_time` | `timestamptz` | Preserve UTC instant and precision |
| `payload` | `jsonb` | Validate Spark projection/type mapping explicitly |
| `schema_version` | `integer` | Preserve version semantics |
| `created_at` | `timestamptz` | Preserve UTC instant and precision |
| `event_source` | `text` | Verify after schema evolution |

The table is partitioned by `day(event_time)` and `bucket(32, tenant_id)`. Spark
validation must cover partition pruning, projection, nullability, and schema
evolution. PostgreSQL DDL success alone is not evidence that an independent
engine can consume the resulting schema.

### 3.5 Freshness, snapshots, and retention

Consumers read committed snapshots, not in-flight PostgreSQL transactions.
Catalog caching is expected; the validation run must measure the visibility delay
after a PostgreSQL commit and document the configured cache interval.

Retention must exceed the maximum consumer job duration plus recovery margin.
Vacuum must not remove metadata or data files still needed by an approved
time-travel or long-running read workload.

## 4. Failure and boundary behavior

| Failure | Expected behavior |
|---|---|
| PostgreSQL unavailable | Spark cannot discover new/current tables; existing planned work may fail |
| Object storage unavailable | Catalog discovery may succeed, file reads fail clearly |
| PostgreSQL write rolls back | Spark must never observe the rolled-back snapshot |
| Schema changes | Spark refresh/replanning must observe compatible Iceberg field IDs |
| Consumer credentials are read-only | Catalog or object-store write attempts are denied |
| Consumer lags past retention | Read fails or loses time-travel availability; alert before this point |

## 5. Acceptance experiment

Run `make up && make test-spark` from the repository root. The gate uses Spark
3.5.7, Iceberg 1.9.2, PostgreSQL JDBC 42.7.7, the pinned pg_lake build,
and a disposable `aetherlake.spark_probe_*` table. It provisions the local
readers on existing volumes and drops the probe on exit. The first run pulls
the Spark image and Maven artifacts. It is a compatibility gate, not a
throughput or production-network benchmark.

The local gate currently proves:

1. List the `aetherlake` catalog and `aetherlake` namespace.
2. Load `aetherlake.aetherlake.events`.
3. Read rows and project every documented column.
4. Verify filtered and full-table scans return rows (not a measured pruning benchmark).
5. Commit another PostgreSQL row and verify Spark observes the new snapshot.
6. Perform PostgreSQL `ADD COLUMN`/rename evolution and verify Spark refresh.
7. Read a known historical snapshot before retention expiry.
8. Confirm PostgreSQL grants exclude writes and an object-store write attempt fails.
9. Record Spark, Iceberg, JDBC driver, pg_lake, PostgreSQL, and object-store versions.

Production acceptance additionally requires a staging deployment with private
network reachability, TLS, non-default secrets, cloud object-store read-only
policy, and a longer-running consumer/vacuum retention test. None is supplied
by the local Compose gate.

Databricks remains a separate compatibility gate. The target workspace/runtime
must demonstrate catalog discovery, `events` schema mapping, read freshness,
and historical reads before support is claimed. Its [documented Iceberg
limitations](https://docs.databricks.com/aws/en/iceberg) include unsupported
`UUID`, which the current `events.event_id` uses, and no partition evolution on
foreign Iceberg tables. Test a compatible projection or deliberately reviewed
schema change in staging; do not mutate the canonical event contract solely
to make an untested Databricks path appear supported. If that runtime cannot
use the PostgreSQL JDBC catalog, validate a supported catalog bridge first.

## 6. Source references

- [Pinned pg_lake interoperability documentation](https://github.com/Snowflake-Labs/pg_lake/blob/main/docs/iceberg-tables.md#accessing-iceberg-tables-with-spark)
- [Apache Iceberg JDBC catalog](https://iceberg.apache.org/docs/latest/jdbc/)
- [Apache Iceberg Spark catalog configuration](https://iceberg.apache.org/docs/latest/spark-configuration/)
- [Databricks access from Apache Iceberg clients](https://docs.databricks.com/aws/en/external-access/iceberg)
