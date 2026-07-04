\set ON_ERROR_STOP on

-- Supported Iceberg evolution is serialized into the table metadata atomically.
ALTER TABLE aetherlake.events
    ADD COLUMN source text DEFAULT 'application';
ALTER TABLE aetherlake.events
    RENAME COLUMN source TO event_source;
ALTER TABLE aetherlake.events
    ALTER COLUMN event_source SET DEFAULT current_user;

CREATE OR REPLACE VIEW aetherlake.catalog AS
SELECT catalog_name, table_namespace, table_name, metadata_location
FROM iceberg_tables
WHERE table_namespace = 'aetherlake';

GRANT SELECT ON aetherlake.catalog TO :"app_user";

