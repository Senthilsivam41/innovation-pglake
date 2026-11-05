"""Independent Spark/Iceberg read proof; invoked by spark-interoperability.sh."""

import os
import sys

from pyspark.sql import SparkSession


phase, probe, prior_snapshot = sys.argv[1:4]
catalog = os.environ["POSTGRES_DB"]
assert catalog.isidentifier() and probe.isidentifier()
key = f"spark.sql.catalog.{catalog}"
spark = (
    SparkSession.builder.master("local[2]")
    .appName("aetherlake-spark-interoperability")
    .config("spark.sql.extensions", "org.apache.iceberg.spark.extensions.IcebergSparkSessionExtensions")
    .config(key, "org.apache.iceberg.spark.SparkCatalog")
    .config(f"{key}.catalog-impl", "org.apache.iceberg.jdbc.JdbcCatalog")
    .config(f"{key}.uri", f"jdbc:postgresql://postgres:5432/{catalog}")
    .config(f"{key}.jdbc.user", "aetherlake_spark_reader")
    .config(f"{key}.jdbc.password", os.environ["SPARK_READER_PASSWORD"])
    .config(f"{key}.warehouse", "s3://")
    .config(f"{key}.io-impl", "org.apache.iceberg.aws.s3.S3FileIO")
    .config(f"{key}.s3.endpoint", os.environ["S3_ENDPOINT"])
    .config(f"{key}.s3.path-style-access", "true")
    .config(f"{key}.cache-enabled", "false")
    .config("spark.redaction.regex", "(?i)secret|password|token|access[.]key")
    .getOrCreate()
)
spark.sparkContext.setLogLevel("ERROR")
table = f"{catalog}.aetherlake.{probe}"
events = f"{catalog}.aetherlake.events"

try:
    assert probe in [row.tableName for row in spark.sql(f"SHOW TABLES IN {catalog}.aetherlake").collect()]
    columns = {"event_id", "tenant_id", "event_type", "event_time", "payload", "schema_version", "created_at", "event_source"}
    assert columns <= set(spark.table(events).columns)
    event = spark.table(events).select(*sorted(columns)).first()
    assert event is not None
    assert spark.table(events).count() >= 1
    assert spark.table(events).filter(f"tenant_id = {event.tenant_id}").count() >= 1

    frame = spark.table(table)
    assert frame.filter("id = 1").select("message").first()[0] == "before"
    if phase == "baseline":
        assert frame.count() == 1
    else:
        assert "event_source" in frame.columns
        assert frame.filter("id = 2").select("event_source").first()[0] == "postgres"
        assert frame.count() == 2
        historic = spark.read.option("snapshot-id", prior_snapshot).table(table)
        assert historic.count() == 1
        assert historic.select("id").first()[0] == 1
    print(f"Spark {phase}: catalog, events, probe, and snapshot checks passed")
finally:
    spark.stop()
