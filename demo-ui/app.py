import os
import time
from datetime import date, datetime
from decimal import Decimal
from uuid import UUID

import psycopg
from flask import Flask, jsonify, render_template, request
from psycopg.rows import dict_row


app = Flask(__name__)
app.config["MAX_CONTENT_LENGTH"] = 64 * 1024


def connection():
    return psycopg.connect(
        host=os.getenv("PGHOST", "postgres"),
        port=os.getenv("PGPORT", "5432"),
        dbname=os.getenv("PGDATABASE", "aetherlake"),
        user=os.getenv("PGUSER", "aetherlake_admin"),
        password=os.getenv("PGPASSWORD"),
        connect_timeout=3,
        row_factory=dict_row,
    )


def rows_json(rows):
    def convert(value):
        if isinstance(value, (datetime, date, UUID, Decimal)):
            return str(value)
        return value

    return [{key: convert(value) for key, value in row.items()} for row in rows]


@app.get("/")
def index():
    return render_template(
        "index.html",
        bucket=os.getenv("S3_BUCKET", "aetherlake"),
        prefix=os.getenv("S3_PREFIX", "warehouse"),
        minio_console=os.getenv("MINIO_CONSOLE_URL", "http://localhost:9001"),
    )


@app.get("/healthz")
def healthz():
    try:
        with connection() as conn, conn.cursor() as cursor:
            cursor.execute("SELECT aetherlake.healthcheck() AS healthy")
            healthy = cursor.fetchone()["healthy"]
        return jsonify({"healthy": healthy}), 200 if healthy else 503
    except psycopg.Error as error:
        return jsonify({"healthy": False, "error": error.diag.message_primary}), 503


@app.get("/api/overview")
def overview():
    started = time.perf_counter()
    with connection() as conn, conn.cursor() as cursor:
        cursor.execute(
            """
            SELECT
              (SELECT count(*) FROM aetherlake.events) AS event_count,
              (SELECT count(*) FROM aetherlake.event_history) AS history_count,
              (SELECT count(*) FROM aetherlake.history_outbox) AS outbox_count,
              (SELECT count(*) FROM aetherlake.catalog) AS iceberg_tables,
              current_setting('server_version_num')::int AS postgres_version_num
            """
        )
        metrics = cursor.fetchone()

        cursor.execute(
            """
            SELECT extname, extversion
            FROM pg_extension
            WHERE extname IN ('pg_lake', 'pgduck_server', 'cron')
            ORDER BY extname
            """
        )
        extensions = cursor.fetchall()

        cursor.execute(
            """
            SELECT table_name, metadata_location
            FROM aetherlake.catalog
            ORDER BY table_name
            """
        )
        catalog = cursor.fetchall()

        cursor.execute(
            """
            SELECT jobname, schedule, active
            FROM cron.job
            WHERE command LIKE '%aetherlake%'
            ORDER BY jobname
            """
        )
        jobs = cursor.fetchall()

    return jsonify(
        metrics={
            "event_count": metrics["event_count"],
            "history_count": metrics["history_count"],
            "outbox_count": metrics["outbox_count"],
            "iceberg_tables": metrics["iceberg_tables"],
            "query_ms": round((time.perf_counter() - started) * 1000, 1),
            "postgres_version": metrics["postgres_version_num"],
        },
        extensions=rows_json(extensions),
        catalog=rows_json(catalog),
        jobs=rows_json(jobs),
    )


@app.get("/api/events")
def events():
    with connection() as conn, conn.cursor() as cursor:
        cursor.execute(
            """
            SELECT event_id, tenant_id, event_type, event_time,
                   payload, schema_version, created_at
            FROM aetherlake.events
            ORDER BY event_time DESC
            LIMIT 12
            """
        )
        return jsonify(events=rows_json(cursor.fetchall()))


@app.post("/api/events")
def create_event():
    body = request.get_json(silent=True) or {}
    try:
        tenant_id = int(body.get("tenant_id", 1001))
    except (TypeError, ValueError):
        return jsonify(error="Tenant ID must be an integer"), 400

    event_type = str(body.get("event_type", "stakeholder.demo")).strip()
    message = str(body.get("message", "Stakeholder demo event")).strip()
    if not event_type or len(event_type) > 120 or len(message) > 500:
        return jsonify(error="Event type or message invalid"), 400

    with connection() as conn, conn.cursor() as cursor:
        cursor.execute(
            """
            INSERT INTO aetherlake.events(tenant_id, event_type, payload)
            VALUES (%s, %s, jsonb_build_object(
                'message', %s::text,
                'origin', 'stakeholder-ui',
                'demo_id', 'demo-001'
            ))
            RETURNING event_id, event_time
            """,
            (tenant_id, event_type, message),
        )
        created = cursor.fetchone()

    return jsonify(event=rows_json([created])[0]), 201


@app.post("/api/sync")
def sync_history():
    with connection() as conn, conn.cursor() as cursor:
        cursor.execute("CALL aetherlake.sync_historical_deltas(10000)")
    return jsonify(message="Historical delta committed atomically")


@app.errorhandler(psycopg.Error)
def database_error(error):
    app.logger.exception("Database request failed")
    return jsonify(error=error.diag.message_primary or "Database request failed"), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")), debug=False)
