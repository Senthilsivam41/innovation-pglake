\set ON_ERROR_STOP on

CREATE TABLE aetherlake.events (
    event_id uuid NOT NULL DEFAULT gen_random_uuid(),
    tenant_id bigint NOT NULL,
    event_type text NOT NULL,
    event_time timestamptz NOT NULL DEFAULT clock_timestamp(),
    payload jsonb NOT NULL,
    schema_version integer NOT NULL DEFAULT 1,
    created_at timestamptz NOT NULL DEFAULT clock_timestamp()
)
USING iceberg
WITH (
    partition_by = 'day(event_time), bucket(32, tenant_id)',
    out_of_range_values = 'error',
    max_snapshot_age = 86400
);

CREATE TABLE aetherlake.event_history (
    event_id uuid NOT NULL,
    tenant_id bigint NOT NULL,
    event_type text NOT NULL,
    event_time timestamptz NOT NULL,
    payload jsonb NOT NULL,
    schema_version integer NOT NULL,
    archived_at timestamptz NOT NULL
)
USING iceberg
WITH (
    partition_by = 'day(event_time), bucket(32, tenant_id)',
    out_of_range_values = 'error',
    max_snapshot_age = 604800
);

-- Heap storage is intentionally confined to orchestration state.
CREATE TABLE aetherlake.history_outbox (
    event_id uuid PRIMARY KEY,
    enqueued_at timestamptz NOT NULL DEFAULT clock_timestamp()
) USING heap;

CREATE TABLE aetherlake.history_sync_ledger (
    event_id uuid PRIMARY KEY,
    synced_at timestamptz NOT NULL DEFAULT clock_timestamp()
) USING heap;

CREATE OR REPLACE FUNCTION aetherlake.enqueue_history()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aetherlake
AS $$
BEGIN
    INSERT INTO aetherlake.history_outbox(event_id) VALUES (NEW.event_id);
    RETURN NEW;
END
$$;

CREATE TRIGGER events_history_outbox
AFTER INSERT ON aetherlake.events
FOR EACH ROW EXECUTE FUNCTION aetherlake.enqueue_history();

GRANT SELECT, INSERT, UPDATE, DELETE ON aetherlake.events TO :"app_user";
GRANT SELECT ON aetherlake.event_history TO :"app_user";
