import json
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
              (SELECT count(*) FROM dm_dom_well_production.production_measurement)
                AS measurement_count,
              current_setting('server_version_num')::int AS postgres_version_num
            """
        )
        metrics = cursor.fetchone()

        cursor.execute(
            """
            SELECT extname, extversion
            FROM pg_extension
            WHERE extname IN ('pg_lake', 'pg_cron')
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
            "measurement_count": metrics["measurement_count"],
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
        cursor.execute(
            """
            SELECT metadata_location
            FROM aetherlake.catalog
            WHERE table_name = 'events'
            """
        )
        catalog_row = cursor.fetchone()
        metadata_location = catalog_row["metadata_location"] if catalog_row else None

    table_location = metadata_location.rsplit("/metadata/", 1)[0] if metadata_location else None

    return jsonify(
        event=rows_json([created])[0],
        storage={
            "table_location": table_location,
            "metadata_location": metadata_location,
            "bucket": os.getenv("S3_BUCKET", "aetherlake"),
            "prefix": os.getenv("S3_PREFIX", "warehouse"),
        },
    ), 201


@app.post("/api/sync")
def sync_history():
    with connection() as conn, conn.cursor() as cursor:
        cursor.execute("CALL aetherlake.sync_historical_deltas(10000)")
    return jsonify(message="Historical delta committed atomically")


@app.get("/api/model")
def model():
    """The knowledge graph, as the graph panel needs it.

    Relations are derived from semantic.view_properties rather than stored separately - a
    direct relation and its reverse are two rows describing the same edge from either end.
    """
    with connection() as conn, conn.cursor() as cursor:
        cursor.execute(
            "SELECT space, kind, name, description FROM semantic.spaces ORDER BY kind, space"
        )
        spaces = rows_json(cursor.fetchall())

        cursor.execute(
            """
            SELECT dm.space, dm.external_id, dm.version, dm.name, dm.description,
                   (SELECT count(*) FROM semantic.data_model_views v
                     WHERE v.space = dm.space AND v.external_id = dm.external_id
                       AND v.version = dm.version) AS view_count
            FROM semantic.data_models dm
            ORDER BY dm.space, dm.external_id
            """
        )
        data_models = rows_json(cursor.fetchall())

        cursor.execute(
            """
            SELECT v.space, v.external_id, v.version, v.relation, v.name, v.description,
                   (SELECT count(*) FROM semantic.view_properties p
                     WHERE p.space = v.space AND p.external_id = v.external_id
                       AND p.version = v.version) AS property_count,
                   (SELECT coalesce(array_agg(i.parent_space || ':' || i.parent_external_id
                                              ORDER BY i.seq), '{}')
                      FROM semantic.view_implements i
                     WHERE i.space = v.space AND i.external_id = v.external_id
                       AND i.version = v.version) AS implements
            FROM semantic.views v
            ORDER BY v.space, v.external_id
            """
        )
        views = rows_json(cursor.fetchall())

        cursor.execute(
            """
            SELECT space, external_id, used_for, relation, name, description,
                   (SELECT count(*) FROM semantic.container_properties p
                     WHERE p.space = c.space AND p.container = c.external_id) AS property_count
            FROM semantic.containers c
            ORDER BY space, external_id
            """
        )
        containers = rows_json(cursor.fetchall())

        cursor.execute(
            """
            SELECT external_id AS from_view, space AS from_space, identifier AS property,
                   kind, source_external_id AS to_view, source_space AS to_space
            FROM semantic.view_properties
            WHERE kind <> 'primitive' AND source_external_id IS NOT NULL
            ORDER BY external_id, identifier
            """
        )
        relations = rows_json(cursor.fetchall())

    return jsonify(
        spaces=spaces,
        data_models=data_models,
        views=views,
        containers=containers,
        relations=relations,
    )


@app.get("/api/model/view/<external_id>")
def model_view(external_id):
    with connection() as conn, conn.cursor() as cursor:
        cursor.execute(
            """
            SELECT v.space, v.external_id, v.version, v.relation, v.name, v.description,
                   (SELECT coalesce(array_agg(i.parent_space || ':' || i.parent_external_id
                                              ORDER BY i.seq), '{}')
                      FROM semantic.view_implements i
                     WHERE i.space = v.space AND i.external_id = v.external_id
                       AND i.version = v.version) AS implements
            FROM semantic.views v
            WHERE v.external_id = %s
            ORDER BY v.version DESC
            LIMIT 1
            """,
            (external_id,),
        )
        view = cursor.fetchone()
        if view is None:
            return jsonify(error=f"View {external_id} is not in the model"), 404

        cursor.execute(
            """
            SELECT identifier, kind, pg_type, column_name, description, name,
                   container_external_id AS container, container_identifier,
                   source_external_id AS target_view, inherited_from
            FROM semantic.view_properties
            WHERE space = %s AND external_id = %s AND version = %s
            ORDER BY (kind = 'primitive') DESC, identifier
            """,
            (view["space"], view["external_id"], view["version"]),
        )
        properties = rows_json(cursor.fetchall())

    return jsonify(view=rows_json([view])[0], properties=properties)


@app.post("/api/query")
def query():
    """Plan and run a request against the model.

    semantic.resolve() does the planning; this route only carries JSON. An undeclared property
    or traversal surfaces as 400 via the invalid_parameter_value handler below, not as the
    global 503 - a rejected query is the guardrail working, not the database being down.
    """
    body = request.get_json(silent=True) or {}
    payload = body.get("request", body)
    payload.setdefault("explain", True)

    started = time.perf_counter()
    with connection() as conn, conn.cursor() as cursor:
        cursor.execute("SELECT semantic.resolve(%s::jsonb) AS result", (json.dumps(payload),))
        result = cursor.fetchone()["result"]
    result["queryMs"] = round((time.perf_counter() - started) * 1000, 1)
    return jsonify(result)


@app.post("/api/sdm/build")
def sdm_build():
    body = request.get_json(silent=True) or {}
    window_from = body.get("from")
    window_to = body.get("to")

    with connection() as conn, conn.cursor() as cursor:
        if window_from and window_to:
            cursor.execute(
                "CALL aetherlake.build_well_production_daily(%s::date, %s::date)",
                (window_from, window_to),
            )
        else:
            cursor.execute("CALL aetherlake.build_well_production_daily()")
        cursor.execute(
            """
            SELECT build_id, target, window_from, window_to, source_views,
                   snapshot_before, snapshot_after, rows_written, duration_ms, built_at
            FROM aetherlake.sdm_build_log
            ORDER BY build_id DESC
            LIMIT 1
            """
        )
        build = cursor.fetchone()

    return jsonify(rows_json([build])[0] if build else {})


@app.get("/api/lineage")
def lineage():
    limit = min(max(request.args.get("limit", 8, type=int), 1), 50)
    with connection() as conn, conn.cursor() as cursor:
        cursor.execute(
            """
            SELECT build_id, target, window_from, window_to, source_views,
                   snapshot_before, snapshot_after, rows_written, duration_ms, built_at
            FROM aetherlake.sdm_build_log
            ORDER BY build_id DESC
            LIMIT %s
            """,
            (limit,),
        )
        builds = rows_json(cursor.fetchall())
    return jsonify(builds=builds)


@app.errorhandler(psycopg.errors.InvalidParameterValue)
def rejected_by_model(error):
    """The semantic model refused the request. That is a 400, not a 503.

    Flask dispatches to the most specific handler, so this coexists with the generic
    psycopg.Error handler below.
    """
    return jsonify(error=error.diag.message_primary, hint=error.diag.hint), 400


@app.errorhandler(psycopg.Error)
def database_error(error):
    app.logger.exception("Database request failed")
    return jsonify(error=error.diag.message_primary or "Database request failed"), 503


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.getenv("PORT", "8080")), debug=False)
