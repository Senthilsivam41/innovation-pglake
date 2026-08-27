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


-- ---------------------------------------------------------------------------- resolver
--
-- semantic.resolve() is the only route from the application to instance data: app_user has
-- USAGE on `semantic` and on no model schema. Governance is therefore a privilege boundary,
-- not a convention - an undeclared property or traversal cannot be expressed, let alone run.
--
-- Injection safety rests on three independent defences, all of which must fail together:
--   1. Identifiers from the request are only ever lookup keys into semantic.view_properties.
--      An attacker's string never reaches format().
--   2. Everything that does reach format() as an identifier goes through %I, carrying a value
--      that came out of our own metadata.
--   3. column_name, pg_type and relation are CHECK-constrained to safe character classes, so
--      even a compromised compiler cannot plant an identifier that means something else.

-- The choke point. Every property reference in a request passes through here.
CREATE OR REPLACE FUNCTION semantic.column_for(
    p_space text, p_view text, p_version text, p_identifier text
)
RETURNS semantic.view_properties
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, semantic
AS $$
DECLARE
    prop semantic.view_properties;
BEGIN
    SELECT * INTO prop
    FROM semantic.view_properties
    WHERE space = p_space AND external_id = p_view
      AND version = p_version AND identifier = p_identifier;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'property %L is not declared on view %s:%s/%s',
                        p_identifier, p_space, p_view, p_version
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'The semantic model is the contract; only declared properties are queryable.';
    END IF;
    RETURN prop;
END
$$;

-- A literal, validated by casting to the type the model declares and then escaped by
-- PostgreSQL's own quote_literal. A value that will not cast raises 22023 rather than
-- producing a syntax error.
CREATE OR REPLACE FUNCTION semantic.lit(p_value jsonb, p_pg_type text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, semantic
AS $$
DECLARE
    quoted text;
BEGIN
    -- p_pg_type reaches format() unquoted. That is safe only because every pg_type stored in
    -- semantic.* is CHECK-constrained to ^[a-z0-9 \[\]]+$.
    EXECUTE format('SELECT quote_literal(%L::%s::text)', p_value #>> '{}', p_pg_type) INTO quoted;
    RETURN quoted || '::' || p_pg_type;
EXCEPTION WHEN others THEN
    RAISE EXCEPTION 'value % is not valid for type %s', p_value, p_pg_type
        USING ERRCODE = 'invalid_parameter_value';
END
$$;

CREATE OR REPLACE FUNCTION semantic.lit_array(p_values jsonb, p_pg_type text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, semantic
AS $$
DECLARE
    base  text := rtrim(p_pg_type, '[]');
    items text[];
BEGIN
    IF p_values IS NULL OR jsonb_typeof(p_values) <> 'array' THEN
        RAISE EXCEPTION 'expected a JSON array of values'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    SELECT array_agg(semantic.lit(e, base)) INTO items FROM jsonb_array_elements(p_values) e;
    RETURN 'ARRAY[' || array_to_string(items, ', ') || ']';
END
$$;

CREATE OR REPLACE FUNCTION semantic.compile_range(p_col text, p_body jsonb, p_pg_type text)
RETURNS text
LANGUAGE plpgsql
IMMUTABLE
SET search_path = pg_catalog, semantic
AS $$
DECLARE
    parts text[] := '{}';
BEGIN
    IF p_body ? 'gte' THEN parts := parts || format('%s >= %s', p_col, semantic.lit(p_body->'gte', p_pg_type)); END IF;
    IF p_body ? 'gt'  THEN parts := parts || format('%s > %s',  p_col, semantic.lit(p_body->'gt',  p_pg_type)); END IF;
    IF p_body ? 'lte' THEN parts := parts || format('%s <= %s', p_col, semantic.lit(p_body->'lte', p_pg_type)); END IF;
    IF p_body ? 'lt'  THEN parts := parts || format('%s < %s',  p_col, semantic.lit(p_body->'lt',  p_pg_type)); END IF;
    IF cardinality(parts) = 0 THEN
        RAISE EXCEPTION 'range filter needs at least one of gte, gt, lte, lt'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    RETURN '(' || array_to_string(parts, ' AND ') || ')';
END
$$;

CREATE OR REPLACE FUNCTION semantic.compile_filter(
    p_space text, p_view text, p_version text, p_filter jsonb, p_alias text
)
RETURNS text
LANGUAGE plpgsql
STABLE
SET search_path = pg_catalog, semantic
AS $$
DECLARE
    op    text;
    body  jsonb;
    parts text[];
    prop  semantic.view_properties;
    col   text;
    path  jsonb;
BEGIN
    IF p_filter IS NULL OR jsonb_typeof(p_filter) <> 'object' THEN
        RETURN 'true';
    END IF;

    SELECT key, value INTO op, body FROM jsonb_each(p_filter) LIMIT 1;
    IF op IS NULL THEN
        RETURN 'true';
    END IF;

    IF op IN ('and', 'or') THEN
        SELECT array_agg(semantic.compile_filter(p_space, p_view, p_version, e, p_alias))
          INTO parts
          FROM jsonb_array_elements(body) e;
        RETURN '(' || array_to_string(parts, ' ' || upper(op) || ' ') || ')';
    ELSIF op = 'not' THEN
        RETURN 'NOT (' || semantic.compile_filter(p_space, p_view, p_version, body, p_alias) || ')';
    END IF;

    path := body -> 'property';
    IF path IS NULL OR jsonb_typeof(path) <> 'array' OR jsonb_array_length(path) = 0 THEN
        RAISE EXCEPTION 'filter operator %L needs a property path', op
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    -- DMS property paths are [space, view/version, property]; only the leaf names a property.
    prop := semantic.column_for(p_space, p_view, p_version,
                                path ->> (jsonb_array_length(path) - 1));
    IF prop.kind NOT IN ('primitive', 'direct') THEN
        RAISE EXCEPTION 'cannot filter on relation property %L; traverse it instead', prop.identifier
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    col := format('%I.%I', p_alias, prop.column_name);

    IF op = 'equals' THEN
        RETURN format('%s = %s', col, semantic.lit(body -> 'value', prop.pg_type));
    ELSIF op = 'in' THEN
        RETURN format('%s = ANY (%s)', col, semantic.lit_array(body -> 'values', prop.pg_type));
    ELSIF op = 'exists' THEN
        RETURN format('%s IS NOT NULL', col);
    ELSIF op = 'prefix' THEN
        RETURN format('%s LIKE %L', col,
                      replace(replace(replace(body ->> 'value', '\', '\\'), '%', '\%'), '_', '\_') || '%');
    ELSIF op = 'range' THEN
        RETURN semantic.compile_range(col, body, prop.pg_type);
    ELSIF op = 'containsAny' THEN
        RETURN format('%s && %s', col, semantic.lit_array(body -> 'values', prop.pg_type));
    ELSIF op = 'containsAll' THEN
        RETURN format('%s @> %s', col, semantic.lit_array(body -> 'values', prop.pg_type));
    END IF;

    RAISE EXCEPTION 'unsupported filter operator %L', op
        USING ERRCODE = 'invalid_parameter_value';
END
$$;


-- Plan and run a query against the model. Request shape follows CDF's /instances/list, with
-- traversals expanded inline. It is deliberately NOT the multi-result-set /instances/query
-- `with`/`select` graph - say so rather than implying parity.
--
--   {"space": "...", "view": "...", "version": "v1",
--    "instanceSpaces": ["inst_..."],
--    "properties": ["name", "wellType"],
--    "filter": {"and": [{"equals": {"property": ["assetType"], "value": "well"}}]},
--    "traverse": [{"property": "interventions", "properties": ["name"], "limit": 5}],
--    "limit": 25, "cursor": "...", "explain": true}
CREATE OR REPLACE FUNCTION semantic.resolve(request jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, semantic
AS $$
DECLARE
    known_keys   text[] := ARRAY['space', 'view', 'version', 'instanceSpaces', 'properties',
                                 'filter', 'traverse', 'limit', 'cursor', 'explain'];
    stray        text;
    v_space      text := request ->> 'space';
    v_view       text := request ->> 'view';
    v_version    text := coalesce(request ->> 'version', 'v1');
    v_limit      integer := least(greatest(coalesce((request ->> 'limit')::integer, 25), 1), 1000);
    view_row     semantic.views;
    target_row   semantic.views;
    prop         semantic.view_properties;
    forward      semantic.view_properties;
    child        semantic.view_properties;
    identifier   text;
    spec         jsonb;
    obj_parts    text[] := '{}';
    child_parts  text[] := '{}';
    join_parts   text[] := '{}';
    where_parts  text[] := '{}';
    sources      jsonb := '[]'::jsonb;
    seen_tables  text[] := '{}';
    child_limit  integer;
    alias        text;
    n            integer := 0;
    sql          text;
    items        jsonb;
    last_key     text;
    cursor_raw   text;
    started      timestamptz := clock_timestamp();
    result       jsonb;
    v_properties jsonb;
BEGIN
    SELECT k INTO stray
    FROM jsonb_object_keys(request) k
    WHERE k <> ALL (known_keys)
    LIMIT 1;
    IF stray IS NOT NULL THEN
        RAISE EXCEPTION 'unknown request key %L', stray
            USING ERRCODE = 'invalid_parameter_value',
                  HINT = 'Supported keys: ' || array_to_string(known_keys, ', ');
    END IF;

    SELECT * INTO view_row
    FROM semantic.views
    WHERE space = v_space AND external_id = v_view AND version = v_version;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'view %s:%s/%s is not in the model', v_space, v_view, v_version
            USING ERRCODE = 'invalid_parameter_value';
    END IF;
    sources := sources || jsonb_build_object(
        'view', format('%s:%s/%s', v_space, v_view, v_version),
        'relation', view_row.relation,
        'snapshotId', semantic.snapshot_id(view_row.relation));
    seen_tables := seen_tables || view_row.relation;

    -- Projection. Default to every scalar and direct property the view declares; an explicit
    -- list keeps the caller's order.
    IF request -> 'properties' IS NULL THEN
        SELECT coalesce(jsonb_agg(to_jsonb(vp.identifier) ORDER BY vp.identifier), '[]'::jsonb)
          INTO v_properties
          FROM semantic.view_properties vp
         WHERE vp.space = v_space AND vp.external_id = v_view AND vp.version = v_version
           AND vp.kind IN ('primitive', 'direct');
    ELSE
        v_properties := request -> 'properties';
    END IF;

    FOR identifier IN SELECT e #>> '{}' FROM jsonb_array_elements(v_properties) e
    LOOP
        prop := semantic.column_for(v_space, v_view, v_version, identifier);
        IF prop.kind IN ('multi_reverse_direct_relation', 'single_reverse_direct_relation') THEN
            RAISE EXCEPTION 'property %L is a relation; list it under "traverse", not "properties"',
                            identifier
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
        obj_parts := obj_parts || format('%L, t.%I', prop.identifier, prop.column_name);
    END LOOP;

    -- Traversals. Only relations the model declares can be walked, and a traversal is paid
    -- for only when asked - which is also how CDF resolves them.
    FOR spec IN SELECT value FROM jsonb_array_elements(coalesce(request -> 'traverse', '[]'::jsonb))
    LOOP
        identifier := spec ->> 'property';
        prop := semantic.column_for(v_space, v_view, v_version, identifier);
        IF prop.kind = 'primitive' THEN
            RAISE EXCEPTION 'property %L is a scalar and cannot be traversed', identifier
                USING ERRCODE = 'invalid_parameter_value';
        END IF;

        SELECT * INTO target_row
        FROM semantic.views
        WHERE space = prop.source_space AND external_id = prop.source_external_id
          AND version = prop.source_version;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'traversal %L targets view %s:%s/%s, which is not in the model',
                            identifier, prop.source_space, prop.source_external_id, prop.source_version
                USING ERRCODE = 'invalid_parameter_value';
        END IF;

        n := n + 1;
        alias := 'r' || n;
        child_parts := ARRAY[format('%L, %I.space', 'space', alias),
                             format('%L, %I.node_external_id', 'externalId', alias)];
        FOR child IN
            SELECT c.*
            FROM jsonb_array_elements(coalesce(spec -> 'properties', '[]'::jsonb)) e
            CROSS JOIN LATERAL semantic.column_for(target_row.space, target_row.external_id,
                                                   target_row.version, e #>> '{}') c
        LOOP
            IF child.kind NOT IN ('primitive', 'direct') THEN
                RAISE EXCEPTION 'nested traversal %L is not supported; issue a second query',
                                child.identifier
                    USING ERRCODE = 'invalid_parameter_value';
            END IF;
            child_parts := child_parts || format('%L, %I.%I', child.identifier, alias, child.column_name);
        END LOOP;

        IF NOT (target_row.relation = ANY (seen_tables)) THEN
            sources := sources || jsonb_build_object(
                'view', format('%s:%s/%s', target_row.space, target_row.external_id, target_row.version),
                'relation', target_row.relation,
                'snapshotId', semantic.snapshot_id(target_row.relation));
            seen_tables := seen_tables || target_row.relation;
        END IF;

        IF prop.kind = 'direct' THEN
            -- Forward: this row stores the target's external id. One-to-one, so no aggregate.
            join_parts := join_parts || format(
                E'LEFT JOIN LATERAL (\n'
                 '    SELECT jsonb_build_object(%L) AS item\n'
                 '    FROM %s %I\n'
                 '    WHERE %I.space = t.space AND %I.node_external_id = t.%I\n'
                 ') %I ON true',
                array_to_string(child_parts, ', '), target_row.relation, alias,
                alias, alias, prop.column_name, alias || '_j');
            obj_parts := obj_parts || format('%L, %I.item', identifier, alias || '_j');
        ELSE
            -- Reverse: invert the forward property and write the predicate against the child.
            forward := semantic.column_for(prop.through_space, prop.through_external_id,
                                           prop.through_version, prop.through_identifier);
            child_limit := least(greatest(coalesce((spec ->> 'limit')::integer, 100), 1), 1000);
            join_parts := join_parts || format(
                E'LEFT JOIN LATERAL (\n'
                 '    SELECT %s AS item\n'
                 '    FROM (SELECT * FROM %s x\n'
                 '           WHERE x.space = t.space AND x.%I = t.node_external_id\n'
                 '           ORDER BY x.node_external_id LIMIT %s) %I\n'
                 ') %I ON true',
                CASE WHEN prop.kind = 'single_reverse_direct_relation'
                     THEN format('jsonb_build_object(%L)', array_to_string(child_parts, ', '))
                     ELSE format('jsonb_agg(jsonb_build_object(%L) ORDER BY %I.node_external_id)',
                                 array_to_string(child_parts, ', '), alias)
                END,
                target_row.relation, forward.column_name, child_limit, alias, alias || '_j');
            obj_parts := obj_parts || format(
                CASE WHEN prop.kind = 'single_reverse_direct_relation'
                     THEN '%L, %I.item'
                     ELSE '%L, coalesce(%I.item, ''[]''::jsonb)'
                END, identifier, alias || '_j');
        END IF;
    END LOOP;

    where_parts := where_parts || semantic.compile_filter(v_space, v_view, v_version,
                                                          request -> 'filter', 't');

    IF request -> 'instanceSpaces' IS NOT NULL THEN
        where_parts := where_parts || format('t.space = ANY (%s)',
                                             semantic.lit_array(request -> 'instanceSpaces', 'text'));
    END IF;

    -- Keyset pagination on (space, node_external_id). No `sort`: Iceberg has no cursorable
    -- index, and offset paging lies as soon as anything is written concurrently.
    IF request ->> 'cursor' IS NOT NULL THEN
        cursor_raw := convert_from(decode(request ->> 'cursor', 'base64'), 'UTF8');
        where_parts := where_parts || format(
            '(t.space, t.node_external_id) > (%L::text, %L::text)',
            split_part(cursor_raw, ':', 1),
            substr(cursor_raw, strpos(cursor_raw, ':') + 1));
    END IF;

    sql := format(
        E'SELECT t.space,\n'
         '       t.node_external_id,\n'
         '       jsonb_build_object(%L, ''node'', %L, t.space, %L, t.node_external_id, %s) AS item\n'
         '  FROM %s t\n'
         '%s'
         ' WHERE %s\n'
         ' ORDER BY t.space, t.node_external_id\n'
         ' LIMIT %s',
        'instanceType', 'space', 'externalId', array_to_string(obj_parts, ', '),
        view_row.relation,
        CASE WHEN cardinality(join_parts) = 0 THEN '' ELSE array_to_string(join_parts, E'\n') || E'\n' END,
        array_to_string(where_parts, E'\n   AND '),
        v_limit);

    EXECUTE format(
        'SELECT coalesce(jsonb_agg(item ORDER BY space, node_external_id), ''[]''::jsonb),
                max(space || '':'' || node_external_id)
           FROM (%s) q', sql)
    INTO items, last_key;

    result := jsonb_build_object(
        'items', items,
        'rowCount', jsonb_array_length(items),
        'nextCursor', CASE WHEN jsonb_array_length(items) = v_limit AND last_key IS NOT NULL
                           THEN encode(convert_to(last_key, 'UTF8'), 'base64') END);

    IF coalesce((request ->> 'explain')::boolean, false) THEN
        result := result || jsonb_build_object('explain', jsonb_build_object(
            'sql', sql,
            'sources', sources,
            'elapsedMs', round(extract(epoch FROM clock_timestamp() - started)::numeric * 1000, 1)));
    END IF;

    RETURN result;
END
$$;

REVOKE ALL ON FUNCTION semantic.resolve(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION semantic.resolve(jsonb) TO :"app_user";
GRANT EXECUTE ON FUNCTION semantic.column_for(text, text, text, text) TO :"app_user";
