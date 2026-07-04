\set ON_ERROR_STOP on

SELECT cron.schedule(
    'aetherlake-iceberg-maintenance',
    :'vacuum_cron',
    'VACUUM (ICEBERG)'
);

CREATE OR REPLACE FUNCTION aetherlake.healthcheck()
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
    SELECT EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_lake')
       AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron')
       AND to_regclass('aetherlake.events') IS NOT NULL
$$;

REVOKE ALL ON FUNCTION aetherlake.healthcheck() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION aetherlake.healthcheck() TO :"app_user";

