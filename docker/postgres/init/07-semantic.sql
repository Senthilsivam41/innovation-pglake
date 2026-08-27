\set ON_ERROR_STOP on

-- The semantic layer: CDF Data Modeling Service semantics over Iceberg.
--
-- Heap storage stays confined to control-plane state (see 02-contract.sql). Model metadata
-- is control plane: the resolver does point lookups against it on every request, it needs
-- real primary keys and CHECK constraints (two of which are injection controls), and it must
-- be transactionally consistent with the DDL the compiler emits alongside it.
--
-- scripts/compile-model.py is the only writer of semantic.*; semantic.resolve() is the only
-- reader. Both halves are re-appliable in isolation, which is what lets a recompiled model be
-- applied to a running database.

CREATE SCHEMA IF NOT EXISTS semantic;
REVOKE ALL ON SCHEMA semantic FROM PUBLIC;
GRANT USAGE ON SCHEMA semantic TO :"app_user";

CREATE TABLE semantic.spaces (
    space       text PRIMARY KEY,
    kind        text NOT NULL CHECK (kind IN ('schema', 'instance')),
    name        text,
    description text
) USING heap;

CREATE TABLE semantic.containers (
    space       text NOT NULL REFERENCES semantic.spaces(space),
    external_id text NOT NULL,
    used_for    text NOT NULL CHECK (used_for IN ('node', 'record')),
    -- Constrained because it is interpolated into dynamic SQL as an identifier.
    relation    text NOT NULL UNIQUE CHECK (relation ~ '^[a-z_][a-z0-9_]{0,62}\.[a-z_][a-z0-9_]{0,62}$'),
    name        text,
    description text,
    PRIMARY KEY (space, external_id)
) USING heap;

CREATE TABLE semantic.container_properties (
    space        text NOT NULL,
    container    text NOT NULL,
    identifier   text NOT NULL,
    data_type    text NOT NULL CHECK (data_type IN
                     ('text', 'int32', 'int64', 'float32', 'float64', 'boolean',
                      'timestamp', 'date', 'json', 'direct', 'enum')),
    is_list      boolean NOT NULL DEFAULT false,
    nullable     boolean NOT NULL DEFAULT true,
    column_name  text NOT NULL CHECK (column_name ~ '^[a-z_][a-z0-9_]{0,62}$'),
    pg_type      text NOT NULL CHECK (pg_type ~ '^[a-z0-9 \[\]]+$'),
    name         text,
    description  text,
    PRIMARY KEY (space, container, identifier),
    FOREIGN KEY (space, container) REFERENCES semantic.containers(space, external_id) ON DELETE CASCADE
) USING heap;

CREATE TABLE semantic.views (
    space           text NOT NULL REFERENCES semantic.spaces(space),
    external_id     text NOT NULL,
    version         text NOT NULL,
    relation        text NOT NULL UNIQUE CHECK (relation ~ '^[a-z_][a-z0-9_]{0,62}\.[a-z_][a-z0-9_]{0,62}$'),
    -- The container the compiled view scans first. Reproduces CDF's default
    -- hasData(<the view's own container>) filter and gives the cheapest plan.
    anchor_space    text NOT NULL,
    anchor_container text NOT NULL,
    name            text,
    description     text,
    PRIMARY KEY (space, external_id, version),
    FOREIGN KEY (anchor_space, anchor_container) REFERENCES semantic.containers(space, external_id)
) USING heap;

CREATE TABLE semantic.view_implements (
    space              text NOT NULL,
    external_id        text NOT NULL,
    version            text NOT NULL,
    seq                integer NOT NULL,
    parent_space       text NOT NULL,
    parent_external_id text NOT NULL,
    parent_version     text NOT NULL,
    PRIMARY KEY (space, external_id, version, seq),
    FOREIGN KEY (space, external_id, version) REFERENCES semantic.views ON DELETE CASCADE
) USING heap;

-- One row per EFFECTIVE property. The compiler resolves inheritance once at build time, so
-- the resolver never walks the implements graph: every property lookup is a single PK probe.
CREATE TABLE semantic.view_properties (
    space       text NOT NULL,
    external_id text NOT NULL,
    version     text NOT NULL,
    identifier  text NOT NULL,
    kind        text NOT NULL CHECK (kind IN
                    ('primitive', 'direct',
                     'multi_reverse_direct_relation', 'single_reverse_direct_relation')),
    -- primitive and direct: where the bytes live
    container_space      text,
    container_external_id text,
    container_identifier text,
    column_name          text CHECK (column_name ~ '^[a-z_][a-z0-9_]{0,62}$'),
    pg_type              text CHECK (pg_type ~ '^[a-z0-9 \[\]]+$'),
    -- direct and reverse: what the far end is
    source_space       text,
    source_external_id text,
    source_version     text,
    -- reverse only: the forward property being inverted
    through_space       text,
    through_external_id text,
    through_version     text,
    through_identifier  text,
    inherited_from text,
    name           text,
    description    text,
    PRIMARY KEY (space, external_id, version, identifier),
    FOREIGN KEY (space, external_id, version) REFERENCES semantic.views ON DELETE CASCADE,
    CHECK ((kind IN ('primitive', 'direct')) = (container_space IS NOT NULL)),
    CHECK ((kind IN ('primitive', 'direct')) = (column_name IS NOT NULL)),
    CHECK ((kind LIKE '%reverse%') = (through_identifier IS NOT NULL))
) USING heap;

CREATE TABLE semantic.data_models (
    space       text NOT NULL REFERENCES semantic.spaces(space),
    external_id text NOT NULL,
    version     text NOT NULL,
    name        text,
    description text,
    PRIMARY KEY (space, external_id, version)
) USING heap;

CREATE TABLE semantic.data_model_views (
    space            text NOT NULL,
    external_id      text NOT NULL,
    version          text NOT NULL,
    view_space       text NOT NULL,
    view_external_id text NOT NULL,
    view_version     text NOT NULL,
    PRIMARY KEY (space, external_id, version, view_space, view_external_id, view_version),
    FOREIGN KEY (space, external_id, version) REFERENCES semantic.data_models ON DELETE CASCADE
) USING heap;

-- No further indexes: these tables hold a few hundred rows and are reloaded wholesale by the
-- compiler. A sequential scan over them is sub-microsecond.

-- Current Iceberg snapshot of a physical table, so a query result can report exactly which
-- snapshot it read. Same lake_iceberg.metadata() path used by tests/smoke.sh and load_test.py.
CREATE OR REPLACE FUNCTION semantic.snapshot_id(p_relation text)
RETURNS bigint
LANGUAGE sql
STABLE
SET search_path = pg_catalog, semantic
AS $$
    SELECT (lake_iceberg.metadata(t.metadata_location) ->> 'current-snapshot-id')::bigint
    FROM iceberg_tables t
    WHERE t.table_namespace = split_part(p_relation, '.', 1)
      AND t.table_name = split_part(p_relation, '.', 2)
$$;

GRANT SELECT ON ALL TABLES IN SCHEMA semantic TO :"app_user";
GRANT EXECUTE ON FUNCTION semantic.snapshot_id(text) TO :"app_user";
