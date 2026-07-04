\set ON_ERROR_STOP on

CREATE OR REPLACE PROCEDURE aetherlake.sync_historical_deltas(batch_size integer DEFAULT 10000)
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, aetherlake
AS $$
DECLARE
    locked boolean;
BEGIN
    locked := pg_try_advisory_xact_lock(hashtextextended('aetherlake.history-sync', 0));
    IF NOT locked THEN
        RAISE NOTICE 'AetherLake history synchronization is already running';
        RETURN;
    END IF;

    WITH batch AS MATERIALIZED (
        SELECT o.event_id
        FROM aetherlake.history_outbox o
        LEFT JOIN aetherlake.history_sync_ledger l USING (event_id)
        WHERE l.event_id IS NULL
        ORDER BY o.enqueued_at, o.event_id
        LIMIT batch_size
        FOR UPDATE OF o SKIP LOCKED
    ), archived AS (
        INSERT INTO aetherlake.event_history (
            event_id, tenant_id, event_type, event_time, payload,
            schema_version, archived_at
        )
        SELECT e.event_id, e.tenant_id, e.event_type, e.event_time, e.payload,
               e.schema_version, clock_timestamp()
        FROM aetherlake.events e
        JOIN batch b USING (event_id)
        RETURNING event_id
    ), recorded AS (
        INSERT INTO aetherlake.history_sync_ledger(event_id)
        SELECT event_id FROM archived
        RETURNING event_id
    )
    DELETE FROM aetherlake.history_outbox o
    USING recorded r
    WHERE o.event_id = r.event_id;

    -- Clear already-recorded outbox entries left by a retried invocation.
    DELETE FROM aetherlake.history_outbox o
    USING aetherlake.history_sync_ledger l
    WHERE o.event_id = l.event_id;
END
$$;

SELECT cron.schedule(
    'aetherlake-history-delta',
    :'delta_cron',
    format('CALL aetherlake.sync_historical_deltas(%s)', :'delta_batch_size')
);

