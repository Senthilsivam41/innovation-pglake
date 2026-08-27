#!/usr/bin/env bash
# The semantic layer is a contract. These assertions are what make that true rather than aspirational.
set -Eeuo pipefail

root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"

if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

: "${POSTGRES_DB:=aetherlake}"
: "${POSTGRES_USER:=aetherlake_admin}"
: "${APP_USER:=aetherlake_app}"

psql_exec=(docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB")

# Metadata describes physical reality: every declared relation actually exists.
"${psql_exec[@]}" -Atqc "SELECT bool_and(to_regclass(relation) IS NOT NULL) FROM semantic.containers" | grep -qx t
"${psql_exec[@]}" -Atqc "SELECT bool_and(to_regclass(relation) IS NOT NULL) FROM semantic.views" | grep -qx t

# Every property is documented, or the model is opaque to search, AI tooling and humans alike.
"${psql_exec[@]}" -Atqc \
  "SELECT NOT EXISTS (SELECT 1 FROM semantic.view_properties WHERE coalesce(description, '') = '')" | grep -qx t

# Every relation resolves to a view that is actually in the model.
"${psql_exec[@]}" -Atqc "
  SELECT NOT EXISTS (
    SELECT 1 FROM semantic.view_properties p
     WHERE p.kind <> 'primitive'
       AND NOT EXISTS (SELECT 1 FROM semantic.views v
                        WHERE v.space = p.source_space AND v.external_id = p.source_external_id
                          AND v.version = p.source_version))" | grep -qx t

# Exactly one CogniteAsset implementer per data model, or CDF UI navigation breaks.
"${psql_exec[@]}" -Atqc "
  SELECT bool_and(implementers <= 1) FROM (
    SELECT count(*) FILTER (WHERE EXISTS (
             SELECT 1 FROM semantic.view_implements i
              WHERE i.space = v.space AND i.external_id = v.external_id AND i.version = v.version
                AND i.parent_space = 'cdf_cdm' AND i.parent_external_id = 'CogniteAsset')) AS implementers
      FROM semantic.data_model_views dmv
      JOIN semantic.views v ON v.space = dmv.view_space AND v.external_id = dmv.view_external_id
                           AND v.version = dmv.view_version
     GROUP BY dmv.space, dmv.external_id, dmv.version) t" | grep -qx t

# Schema spaces and instance spaces are genuinely different things here, not a label.
"${psql_exec[@]}" -Atqc "SELECT count(*) > 0 FROM semantic.spaces WHERE kind = 'instance'" | grep -qx t

# Governance is a privilege boundary: the app role reaches instance data only through resolve().
"${psql_exec[@]}" -Atqc \
  "SELECT has_schema_privilege('$APP_USER', 'dm_dom_well_production', 'USAGE')" | grep -qx f
"${psql_exec[@]}" -Atqc \
  "SELECT has_function_privilege('$APP_USER', 'semantic.resolve(jsonb)', 'EXECUTE')" | grep -qx t

"${psql_exec[@]}" <<'SQL'
DO $$
DECLARE result jsonb;
BEGIN
    -- A declared traversal resolves. Draugen has three wells; one of them, DRA-A1, has an
    -- intervention, so the reverse relation must return a populated array for it.
    result := semantic.resolve($j${
        "space": "dm_dom_well_production", "view": "Asset", "version": "v1",
        "properties": ["name", "assetType"],
        "filter": {"equals": {"property": ["assetType"], "value": "well"}},
        "traverse": [{"property": "interventions", "properties": ["name", "status"]}],
        "limit": 10, "explain": true
    }$j$::jsonb);

    IF (result ->> 'rowCount')::int <> 6 THEN
        RAISE EXCEPTION 'expected 6 wells, resolver returned %', result ->> 'rowCount';
    END IF;
    IF result -> 'explain' -> 'sql' IS NULL THEN
        RAISE EXCEPTION 'explain requested but no generated SQL was returned';
    END IF;
    IF jsonb_array_length(result -> 'explain' -> 'sources') < 2 THEN
        RAISE EXCEPTION 'a traversing query must report both source views and their snapshots';
    END IF;
    -- Exactly one of the six wells has no intervention, which is what proves the join is a
    -- LEFT JOIN rather than accidentally matching everything.
    IF (SELECT count(*) FROM jsonb_array_elements(result -> 'items') i
         WHERE jsonb_array_length(i -> 'interventions') = 0) <> 1 THEN
        RAISE EXCEPTION 'expected exactly one well with no interventions';
    END IF;
END
$$;

DO $$
DECLARE rejected boolean;
BEGIN
    -- An undeclared property is not a query. This is the whole governance claim.
    BEGIN
        rejected := false;
        PERFORM semantic.resolve('{"space":"dm_dom_well_production","view":"Asset",
                                   "version":"v1","properties":["operatingCost"]}'::jsonb);
    EXCEPTION WHEN invalid_parameter_value THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'undeclared property was accepted'; END IF;

    -- Nor is an undeclared traversal.
    BEGIN
        rejected := false;
        PERFORM semantic.resolve('{"space":"dm_dom_well_production","view":"Asset","version":"v1",
                                   "traverse":[{"property":"purchaseOrders"}]}'::jsonb);
    EXCEPTION WHEN invalid_parameter_value THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'undeclared traversal was accepted'; END IF;

    -- Relations are traversed, not filtered on.
    BEGIN
        rejected := false;
        PERFORM semantic.resolve('{"space":"dm_dom_well_production","view":"Asset","version":"v1",
                                   "filter":{"equals":{"property":["interventions"],"value":"x"}}}'::jsonb);
    EXCEPTION WHEN invalid_parameter_value THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'filtering on a relation was accepted'; END IF;

    -- A value that cannot be the modelled type is rejected before it reaches the SQL.
    BEGIN
        rejected := false;
        PERFORM semantic.resolve('{"space":"dm_dom_well_production","view":"Asset","version":"v1",
                                   "filter":{"range":{"property":["waterDepthM"],"gte":"deep"}}}'::jsonb);
    EXCEPTION WHEN invalid_parameter_value THEN rejected := true;
    END;
    IF NOT rejected THEN RAISE EXCEPTION 'an uncastable filter value was accepted'; END IF;
END
$$;
SQL

echo "Semantic model tests passed"
