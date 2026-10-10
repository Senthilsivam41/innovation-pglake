\set ON_ERROR_STOP on
\getenv spark_reader_password SPARK_READER_PASSWORD

SELECT format('CREATE ROLE aetherlake_spark_reader LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE PASSWORD %L', :'spark_reader_password')
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'aetherlake_spark_reader') \gexec
SELECT format('ALTER ROLE aetherlake_spark_reader PASSWORD %L', :'spark_reader_password') \gexec
SELECT format('GRANT CONNECT ON DATABASE %I TO aetherlake_spark_reader', current_database()) \gexec
GRANT USAGE ON SCHEMA aetherlake TO aetherlake_spark_reader;
GRANT SELECT ON pg_catalog.iceberg_tables, pg_catalog.iceberg_namespace_properties
    TO aetherlake_spark_reader;
GRANT SELECT ON aetherlake.events, aetherlake.event_history
    TO aetherlake_spark_reader;
