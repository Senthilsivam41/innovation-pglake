\set ON_ERROR_STOP on

CREATE EXTENSION IF NOT EXISTS pg_lake CASCADE;
CREATE EXTENSION IF NOT EXISTS pg_cron;

CREATE SCHEMA IF NOT EXISTS aetherlake;
REVOKE ALL ON SCHEMA aetherlake FROM PUBLIC;
GRANT USAGE ON SCHEMA aetherlake TO :"app_user";

-- Each managed table explicitly sets out_of_range_values=error. This keeps the
-- strictness contract visible in DDL and avoids relying on session state.
