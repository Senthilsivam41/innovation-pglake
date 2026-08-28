#!/usr/bin/env python3
"""Compile Cognite Toolkit YAML into the AetherLake lakehouse runtime.

Containers become Iceberg tables, views become PostgreSQL views, and the whole model is
recorded in semantic.* so semantic.resolve() can plan queries against it.

Input is `models/build/data_models/` - the output of `cdf build`, which is the exact artifact
CDF itself consumes. Reading that rather than the raw templates means we never reimplement
Toolkit's variable substitution, and the SQL is provably generated from what CDF would receive.
Cognite system types (cdf_cdm, cdf_idm) already exist in CDF and are therefore not part of the
module tree; they are read from models/vendor/ purely to create their physical tables.

Usage:
    scripts/compile-model.py                # write docker/postgres/init/08-model.sql
    scripts/compile-model.py --check        # fail if the checked-in file is stale
"""

from __future__ import annotations

import argparse
import difflib
import re
import sys
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parent.parent
MODELS = ROOT / "models"
BUILD = MODELS / "build" / "data_models"
VENDOR = MODELS / "vendor"
STORAGE = MODELS / "aetherlake.storage.yaml"
OUT = ROOT / "docker" / "postgres" / "init" / "08-model.sql"

# Cognite system spaces: governed upstream, never deployed by us, indexes immutable.
SYSTEM_SPACES = {"cdf_cdm", "cdf_idm"}

# Reserved by CDF; must never be used as a container or view externalId.
RESERVED = {
    "Boolean", "Date", "File", "Float", "Float32", "Float64", "Int", "Int32", "Int64",
    "JSONObject", "Mutation", "Numeric", "PageInfo", "Query", "Sequence", "String",
    "Subscription", "TimeSeries", "Timestamp",
}

PG_TYPES = {
    "text": "text", "int32": "integer", "int64": "bigint", "float32": "real",
    "float64": "double precision", "boolean": "boolean", "timestamp": "timestamptz",
    "date": "date", "json": "jsonb", "enum": "text",
    # A direct relation stores the target's node_external_id. Plain equality is the only
    # join form pg_lake has a chance of pushing down into pgduck.
    "direct": "text",
}

REVERSE_KINDS = {"multi_reverse_direct_relation", "single_reverse_direct_relation"}


class ModelError(Exception):
    """A model rule was violated. Always fatal - the point is that the rules ship."""


def snake(name: str) -> str:
    s = re.sub(r"(.)([A-Z][a-z]+)", r"\1_\2", name)
    s = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", s)
    return re.sub(r"_+", "_", s).lower()


def lit(value) -> str:
    """A SQL literal. Only ever applied to values read from our own model files."""
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    return "'" + str(value).replace("'", "''") + "'"


# --------------------------------------------------------------------------- load


def load() -> dict:
    if not BUILD.is_dir():
        raise ModelError(
            f"{BUILD} not found. Run `cdf build --env dev` in models/ first (or use `make model`)."
        )

    model = {"spaces": {}, "containers": {}, "views": {}, "data_models": {}}
    # Vendor first so module files win any collision, and sort for deterministic output.
    paths = sorted(VENDOR.rglob("*.yaml")) + sorted(BUILD.glob("*.yaml"))

    for path in paths:
        parts = path.name.split(".")
        if len(parts) < 3:
            continue  # _build_environment.yaml and friends
        kind = parts[-2]
        doc = yaml.safe_load(path.read_text())
        if not isinstance(doc, dict):
            continue
        doc["__source"] = str(path.relative_to(ROOT))

        if kind == "Space":
            model["spaces"][doc["space"]] = doc
        elif kind == "Container":
            model["containers"][(doc["space"], doc["externalId"])] = doc
        elif kind == "View":
            model["views"][(doc["space"], doc["externalId"], doc["version"])] = doc
        elif kind == "DataModel":
            model["data_models"][(doc["space"], doc["externalId"], doc["version"])] = doc

    # System spaces are implied by the vendored types rather than declared as Space.yaml.
    for space, external_id in model["containers"]:
        model["spaces"].setdefault(
            space, {"space": space, "name": space, "description": "Cognite system space."}
        )

    model["storage"] = yaml.safe_load(STORAGE.read_text()) if STORAGE.exists() else {}
    return model


def space_kind(space: str) -> str:
    """Instance spaces hold data, schema spaces hold the model.

    Cognite's naming convention makes this unambiguous: instance spaces are `inst_*`.
    """
    return "instance" if space.startswith("inst_") else "schema"


# ----------------------------------------------------------------------- validate


def container_property_kind(prop: dict) -> tuple[str, bool]:
    ptype = prop.get("type", {})
    return ptype.get("type", "text"), bool(ptype.get("list", False))


def transitive_implements(model: dict, key: tuple, seen: set | None = None) -> set:
    seen = seen if seen is not None else set()
    view = model["views"].get(key)
    if view is None:
        return seen
    for parent in view.get("implements") or []:
        pkey = (parent["space"], parent["externalId"], parent["version"])
        label = f"{parent['space']}:{parent['externalId']}"
        if label in seen:
            continue
        seen.add(label)
        transitive_implements(model, pkey, seen)
    return seen


def validate(model: dict) -> None:
    errors: list[str] = []
    warnings: list[str] = []

    for (space, external_id), container in model["containers"].items():
        used_for = container.get("usedFor", "node")
        props = container.get("properties") or {}
        where = container["__source"]

        if external_id in RESERVED:
            errors.append(f"{where}: externalId {external_id!r} is reserved by CDF")
        if len(props) > 100:
            errors.append(f"{where}: {len(props)} properties, the container limit is 100")

        columns: dict[str, str] = {}
        for identifier in props:
            column = snake(identifier)
            if column in columns:
                errors.append(
                    f"{where}: properties {columns[column]!r} and {identifier!r} both map to "
                    f"column {column!r}"
                )
            columns[column] = identifier

        if space not in SYSTEM_SPACES:
            for identifier, prop in props.items():
                # CDF rejects this one on deploy: "Direct relation properties must be nullable."
                if container_property_kind(prop)[0] == "direct" and prop.get("nullable") is False:
                    errors.append(
                        f"{where}: direct relation {identifier!r} is not nullable; CDF requires "
                        f"every direct relation property to be nullable"
                    )

        if used_for == "record":
            if container.get("constraints") or container.get("indexes"):
                errors.append(
                    f"{where}: usedFor: record containers must not declare constraints or indexes "
                    f"- records are not graph nodes"
                )
        elif space not in SYSTEM_SPACES:
            # Indexes on CDM types are immutable upstream, so this rule applies to ours only.
            indexed = {
                tuple(idx.get("properties", []))
                for idx in (container.get("indexes") or {}).values()
            }
            flat = {p for props_ in indexed for p in props_}
            for identifier, prop in props.items():
                if container_property_kind(prop)[0] == "direct" and identifier not in flat:
                    errors.append(
                        f"{where}: direct relation {identifier!r} has no btree index; "
                        f"traversal in both directions needs one"
                    )

    viewed_containers: set[tuple] = set()

    for key, view in model["views"].items():
        space, external_id, version = key
        where = view["__source"]

        if external_id in RESERVED:
            errors.append(f"{where}: externalId {external_id!r} is reserved by CDF")

        for identifier, prop in (view.get("properties") or {}).items():
            kind = prop.get("connectionType")
            if kind in REVERSE_KINDS:
                through = prop.get("through") or {}
                tkey = (
                    through["source"]["space"],
                    through["source"]["externalId"],
                    through["source"]["version"],
                )
                target = model["views"].get(tkey)
                forward = (target.get("properties") or {}).get(through["identifier"]) if target else None
                if forward is None:
                    errors.append(
                        f"{where}: reverse relation {identifier!r} points through "
                        f"{through['identifier']!r}, which is not a property of "
                        f"{tkey[0]}:{tkey[1]}/{tkey[2]}"
                    )
                else:
                    src = forward.get("source") or {}
                    if (src.get("space"), src.get("externalId")) != (space, external_id):
                        errors.append(
                            f"{where}: reverse relation {identifier!r} inverts "
                            f"{tkey[1]}.{through['identifier']}, whose source is "
                            f"{src.get('space')}:{src.get('externalId')} rather than "
                            f"{space}:{external_id}. Override the forward property so it "
                            f"sources this view (REVERSE-008/009)."
                        )
                continue

            if "container" not in prop:
                errors.append(f"{where}: property {identifier!r} has neither a container nor a connectionType")
                continue

            cref = prop["container"]
            ckey = (cref["space"], cref["externalId"])
            container = model["containers"].get(ckey)
            if container is None:
                errors.append(f"{where}: property {identifier!r} maps to unknown container {ckey[0]}:{ckey[1]}")
                continue
            viewed_containers.add(ckey)

            if container.get("usedFor") == "record":
                errors.append(
                    f"{where}: property {identifier!r} maps to record container "
                    f"{ckey[0]}:{ckey[1]}; records are queried directly, not through views"
                )
                continue

            cprop = (container.get("properties") or {}).get(prop["containerPropertyIdentifier"])
            if cprop is None:
                errors.append(
                    f"{where}: property {identifier!r} maps to "
                    f"{prop['containerPropertyIdentifier']!r}, which {ckey[1]} does not define"
                )
                continue

            data_type, _ = container_property_kind(cprop)
            if data_type == "direct" and "source" not in prop:
                errors.append(
                    f"{where}: direct relation {identifier!r} has no source; the UI cannot "
                    f"navigate an untyped node reference"
                )
            if data_type != "direct" and "source" in prop:
                errors.append(f"{where}: only direct relations may declare a source, but {identifier!r} does")
            if not (prop.get("description") or "").strip():
                errors.append(f"{where}: property {identifier!r} has no description")

    in_a_model: set[tuple] = set()
    for key, dm in model["data_models"].items():
        where = dm["__source"]
        asset_implementers = []
        for ref in dm.get("views") or []:
            vkey = (ref["space"], ref["externalId"], ref["version"])
            in_a_model.add(vkey)
            if vkey not in model["views"]:
                errors.append(f"{where}: references view {vkey[0]}:{vkey[1]}/{vkey[2]}, which does not exist")
                continue
            if "cdf_cdm:CogniteAsset" in transitive_implements(model, vkey):
                asset_implementers.append(ref["externalId"])
        if len(asset_implementers) > 1:
            errors.append(
                f"{where}: {key[1]}: {len(asset_implementers)} views implement "
                f"cdf_cdm:CogniteAsset ({', '.join(sorted(asset_implementers))}); exactly one is "
                f"allowed, or CDF Asset Explorer and Industry Canvas navigation breaks"
            )

    for key, view in model["views"].items():
        if key not in in_a_model:
            errors.append(f"{view['__source']}: view {key[1]}/{key[2]} is in no data model and would never deploy")

    for ckey, container in model["containers"].items():
        if container.get("usedFor") == "record" or ckey[0] in SYSTEM_SPACES:
            continue
        if ckey not in viewed_containers:
            warnings.append(f"{container['__source']}: container {ckey[1]} is exposed by no view")

    for warning in warnings:
        print(f"warning: {warning}", file=sys.stderr)
    if errors:
        raise ModelError("\n".join(f"  - {e}" for e in sorted(errors)))


# --------------------------------------------------------------------------- emit

# Identity columns. A node is addressed by (space, node_external_id) where `space` is the
# INSTANCE space - which is why instance spaces are column values here, not schemas.
NODE_IDENTITY = [
    ("space", "text NOT NULL", "Instance space this node belongs to."),
    ("node_external_id", "text NOT NULL", "External id of the node within its instance space."),
]
RECORD_IDENTITY = [
    ("space", "text NOT NULL", "Instance space this record belongs to."),
    ("record_id", "text NOT NULL", "Identifier of the record within its instance space."),
]


def container_relation(space: str, external_id: str) -> str:
    """Containers are UNVERSIONED: they are the durable physical contract."""
    return f"{space}.{snake(external_id)}"


def view_relation(space: str, external_id: str, version: str) -> str:
    """Views are VERSIONED, exactly like DMS. A v2 view is a new relation, so versions coexist."""
    return f"{space}.{snake(external_id)}_{snake(version)}"


def storage_options(model: dict, space: str, external_id: str) -> str:
    storage = model.get("storage") or {}
    options = dict(storage.get("defaults") or {})
    options.update((storage.get("tables") or {}).get(f"{space}.{external_id}") or {})
    order = ["partition_by", "out_of_range_values", "max_snapshot_age"]
    rendered = [
        f"{key} = {lit(options[key]) if not isinstance(options[key], int) else options[key]}"
        for key in order
        if key in options
    ]
    return ",\n      ".join(rendered)


def emit_containers(model: dict) -> list[str]:
    out = ["-- Containers become Iceberg tables. Unversioned: they are the durable contract."]
    for (space, external_id), container in sorted(model["containers"].items()):
        used_for = container.get("usedFor", "node")
        identity = RECORD_IDENTITY if used_for == "record" else NODE_IDENTITY
        columns = [f"    {name:<32} {decl}" for name, decl, _ in identity]

        for identifier, prop in (container.get("properties") or {}).items():
            data_type, is_list = container_property_kind(prop)
            pg_type = PG_TYPES[data_type] + ("[]" if is_list else "")
            null = "" if prop.get("nullable", True) else " NOT NULL"
            columns.append(f"    {snake(identifier):<32} {pg_type}{null}")

        if used_for == "node":
            # Soft delete, so removing an instance never needs DML on an Iceberg table.
            columns.append(f"    {'deleted':<32} boolean NOT NULL DEFAULT false")

        out.append(
            f"CREATE TABLE IF NOT EXISTS {container_relation(space, external_id)} (\n"
            + ",\n".join(columns)
            + "\n)\nUSING iceberg\nWITH (\n      "
            + storage_options(model, space, external_id)
            + "\n);"
        )
    return out


def effective_properties(model: dict, key: tuple) -> dict:
    """Properties of a view, with `implements` flattened.

    The compiler walks the inheritance graph once, here, so the resolver never has to:
    every property lookup at query time is a single primary-key probe.
    """
    view = model["views"][key]
    props: dict[str, tuple[dict, str | None]] = {}
    for parent in view.get("implements") or []:
        pkey = (parent["space"], parent["externalId"], parent["version"])
        if pkey not in model["views"]:
            continue  # System view we did not vendor; its properties are mapped explicitly.
        label = f"{parent['space']}:{parent['externalId']}/{parent['version']}"
        for identifier, (prop, origin) in effective_properties(model, pkey).items():
            props[identifier] = (prop, origin or label)
    for identifier, prop in (view.get("properties") or {}).items():
        props[identifier] = (prop, None)  # Most derived wins.
    return props


def anchor_of(model: dict, key: tuple, props: dict) -> tuple[str, str]:
    space, external_id, _ = key
    referenced = [
        (p["container"]["space"], p["container"]["externalId"])
        for p, _ in props.values()
        if "container" in p
    ]
    own = [c for c in referenced if c[0] == space]
    for candidate in own:
        if candidate[1] == external_id:
            return candidate
    if own:
        return own[0]
    if referenced:
        return referenced[0]
    raise ModelError(f"view {space}:{external_id} maps no container properties")


def emit_views(model: dict) -> list[str]:
    out = [
        "-- Views become PostgreSQL views. Versioned, with `implements` already flattened.",
        "-- Reverse relations deliberately produce NO column: a correlated array subquery on",
        "-- every scan would wreck both the view and DuckDB's ability to read the Parquet.",
        "-- Connections live in semantic.view_properties and are joined on demand.",
    ]
    for key in sorted(model["views"]):
        space, external_id, version = key
        props = effective_properties(model, key)
        anchor = anchor_of(model, key, props)

        aliases = {anchor: "n"}
        joins = []
        for prop, _ in props.values():
            if "container" not in prop:
                continue
            ckey = (prop["container"]["space"], prop["container"]["externalId"])
            if ckey in aliases:
                continue
            alias = f"c{len(aliases)}"
            aliases[ckey] = alias
            joins.append(
                f"  LEFT JOIN {container_relation(*ckey)} {alias}"
                f" USING (space, node_external_id)"
            )

        select = ["  n.space", "  n.node_external_id"]
        for identifier, (prop, _) in props.items():
            if prop.get("connectionType") in REVERSE_KINDS:
                continue
            ckey = (prop["container"]["space"], prop["container"]["externalId"])
            column = snake(prop["containerPropertyIdentifier"])
            alias = aliases[ckey]
            select.append(
                f"  {alias}.{column}" if column == snake(identifier)
                else f"  {alias}.{column} AS {snake(identifier)}"
            )

        out.append(
            f"CREATE OR REPLACE VIEW {view_relation(space, external_id, version)} AS\nSELECT\n"
            + ",\n".join(select)
            + f"\n  FROM {container_relation(*anchor)} n\n"
            + ("\n".join(joins) + "\n" if joins else "")
            + " WHERE NOT n.deleted;"
        )
    return out


def insert(table: str, columns: list[str], rows: list[list]) -> str:
    if not rows:
        return f"-- no rows for {table}"
    values = ",\n    ".join("(" + ", ".join(lit(v) for v in row) + ")" for row in rows)
    return f"INSERT INTO {table}\n    ({', '.join(columns)})\nVALUES\n    {values};"


def emit_metadata(model: dict) -> list[str]:
    out = [
        "-- The knowledge graph itself. scripts/compile-model.py is its only writer;",
        "-- semantic.resolve() is its only reader. Reloaded wholesale so this file stays",
        "-- re-appliable against a running database.",
        "DELETE FROM semantic.data_model_views;",
        "DELETE FROM semantic.data_models;",
        "DELETE FROM semantic.view_properties;",
        "DELETE FROM semantic.view_implements;",
        "DELETE FROM semantic.views;",
        "DELETE FROM semantic.container_properties;",
        "DELETE FROM semantic.containers;",
        "DELETE FROM semantic.spaces;",
    ]

    out.append(insert(
        "semantic.spaces", ["space", "kind", "name", "description"],
        [[s, space_kind(s), d.get("name"), d.get("description")]
         for s, d in sorted(model["spaces"].items())],
    ))

    out.append(insert(
        "semantic.containers", ["space", "external_id", "used_for", "relation", "name", "description"],
        [[s, e, c.get("usedFor", "node"), container_relation(s, e), c.get("name"), c.get("description")]
         for (s, e), c in sorted(model["containers"].items())],
    ))

    rows = []
    for (s, e), container in sorted(model["containers"].items()):
        for identifier, prop in (container.get("properties") or {}).items():
            data_type, is_list = container_property_kind(prop)
            rows.append([
                s, e, identifier, data_type, is_list, prop.get("nullable", True),
                snake(identifier), PG_TYPES[data_type] + ("[]" if is_list else ""),
                prop.get("name"), prop.get("description"),
            ])
    out.append(insert(
        "semantic.container_properties",
        ["space", "container", "identifier", "data_type", "is_list", "nullable",
         "column_name", "pg_type", "name", "description"],
        rows,
    ))

    view_rows, implements_rows, property_rows = [], [], []
    for key in sorted(model["views"]):
        space, external_id, version = key
        view = model["views"][key]
        props = effective_properties(model, key)
        anchor = anchor_of(model, key, props)
        view_rows.append([
            space, external_id, version, view_relation(*key),
            anchor[0], anchor[1], view.get("name"), view.get("description"),
        ])
        for seq, parent in enumerate(view.get("implements") or []):
            implements_rows.append([
                space, external_id, version, seq,
                parent["space"], parent["externalId"], parent["version"],
            ])
        for identifier, (prop, inherited) in props.items():
            connection = prop.get("connectionType")
            source = prop.get("source") or {}
            if connection in REVERSE_KINDS:
                through = prop["through"]
                property_rows.append([
                    space, external_id, version, identifier, connection,
                    None, None, None, None, None,
                    source.get("space"), source.get("externalId"), source.get("version"),
                    through["source"]["space"], through["source"]["externalId"],
                    through["source"]["version"], through["identifier"],
                    inherited, prop.get("name"), prop.get("description"),
                ])
                continue
            ckey = (prop["container"]["space"], prop["container"]["externalId"])
            cprop = model["containers"][ckey]["properties"][prop["containerPropertyIdentifier"]]
            data_type, is_list = container_property_kind(cprop)
            property_rows.append([
                space, external_id, version, identifier,
                "direct" if data_type == "direct" else "primitive",
                ckey[0], ckey[1], prop["containerPropertyIdentifier"],
                snake(identifier), PG_TYPES[data_type] + ("[]" if is_list else ""),
                source.get("space"), source.get("externalId"), source.get("version"),
                None, None, None, None,
                inherited, prop.get("name"), prop.get("description"),
            ])

    out.append(insert(
        "semantic.views",
        ["space", "external_id", "version", "relation", "anchor_space", "anchor_container",
         "name", "description"],
        view_rows,
    ))
    out.append(insert(
        "semantic.view_implements",
        ["space", "external_id", "version", "seq", "parent_space", "parent_external_id",
         "parent_version"],
        implements_rows,
    ))
    out.append(insert(
        "semantic.view_properties",
        ["space", "external_id", "version", "identifier", "kind",
         "container_space", "container_external_id", "container_identifier",
         "column_name", "pg_type",
         "source_space", "source_external_id", "source_version",
         "through_space", "through_external_id", "through_version", "through_identifier",
         "inherited_from", "name", "description"],
        property_rows,
    ))

    out.append(insert(
        "semantic.data_models", ["space", "external_id", "version", "name", "description"],
        [[s, e, v, d.get("name"), d.get("description")]
         for (s, e, v), d in sorted(model["data_models"].items())],
    ))
    out.append(insert(
        "semantic.data_model_views",
        ["space", "external_id", "version", "view_space", "view_external_id", "view_version"],
        [[s, e, v, r["space"], r["externalId"], r["version"]]
         for (s, e, v), d in sorted(model["data_models"].items())
         for r in (d.get("views") or [])],
    ))
    return out


def render(model: dict) -> str:
    schemas = sorted({s for s in model["spaces"] if space_kind(s) == "schema"})
    header = (
        "-- generated by scripts/compile-model.py from models/ -- do not edit\n"
        "--\n"
        "-- Regenerate with `make model`. CI runs `make model-check`, so a hand edit here\n"
        "-- fails the build rather than silently drifting from the Toolkit YAML.\n"
        "\n"
        "\\set ON_ERROR_STOP on"
    )
    schema_block = (
        "-- A CDF schema space is a PostgreSQL schema. Instance spaces are NOT schemas: they\n"
        "-- are the value of the `space` column on every row, which is what DMS means by them.\n"
        + "\n".join(f"CREATE SCHEMA IF NOT EXISTS {s};" for s in schemas)
    )
    body = [header, schema_block, *emit_containers(model), *emit_views(model), *emit_metadata(model)]
    return "\n\n".join(body) + "\n"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="fail if the checked-in SQL is stale instead of rewriting it")
    args = parser.parse_args()

    try:
        model = load()
        validate(model)
        sql = render(model)
    except ModelError as error:
        print(f"model validation failed:\n{error}", file=sys.stderr)
        return 1

    if args.check:
        current = OUT.read_text() if OUT.exists() else ""
        if current != sql:
            diff = difflib.unified_diff(
                current.splitlines(keepends=True), sql.splitlines(keepends=True),
                fromfile=f"{OUT.relative_to(ROOT)} (checked in)", tofile="(regenerated)",
            )
            sys.stderr.writelines(diff)
            print(f"\n{OUT.relative_to(ROOT)} is stale; run `make model`", file=sys.stderr)
            return 1
        print(f"{OUT.relative_to(ROOT)} is up to date")
        return 0

    OUT.write_text(sql)
    print(f"wrote {OUT.relative_to(ROOT)} "
          f"({len(model['containers'])} containers, {len(model['views'])} views, "
          f"{len(model['data_models'])} data models)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
