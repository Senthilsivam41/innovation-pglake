-- Replace the metadata path with an existing externally managed Iceberg table.
-- External mounts are read-only; pg_lake remains authoritative for tables it owns.
CREATE FOREIGN TABLE aetherlake.external_measurements ()
SERVER pg_lake
OPTIONS (
  path 's3://aetherlake/external/measurements/metadata/v1.metadata.json'
);

