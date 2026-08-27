#!/usr/bin/env bash
# Generate production history at volume, for the "this scales" part of the demo.
#
# Server-side INSERT ... SELECT, in chunks. Two properties of pg_lake drive that shape:
#
#   - Every committed transaction publishes an Iceberg snapshot, and DML takes a table lock.
#     Many small concurrent writes therefore serialise and produce a snapshot each; this is a
#     lakehouse, not an OLTP queue. load_test.py still measures that contention deliberately -
#     it is a load test - but it is the wrong way to create volume.
#   - A single very large insert fans out across (month x bucket) partitions and exhausts the
#     object-store connection pool. 250k rows failed on this build; 100k lands in about a
#     second. Chunking is the difference between "scales" and "IO Error".
#
# Usage: scripts/seed-scale.sh [total_rows] [chunk_rows]
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

total=${1:-1000000}
chunk=${2:-100000}

psql_exec=(docker compose exec -T postgres psql -X -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB")

before=$("${psql_exec[@]}" -Atqc "SELECT count(*) FROM dm_dom_well_production.production_measurement")
started=$(date +%s)

offset=0
while (( offset < total )); do
  size=$(( total - offset < chunk ? total - offset : chunk ))
  "${psql_exec[@]}" -Atqc "
    INSERT INTO dm_dom_well_production.production_measurement
      (space, record_id, wellbore, measured_at, oil_rate_bpd, gas_rate_mscfd, water_rate_bpd,
       tubing_head_pressure_bar, choke_percent, quality)
    SELECT 'inst_well_production',
           'scale:' || (g + $offset),
           (ARRAY['DRA-A1-T1','DRA-A1-T2','DRA-A2-T1','DRA-A2-T2','DRA-B3-T1','DRA-B3-T2',
                  'NJO-C1-T1','NJO-C1-T2','NJO-C2-T1','NJO-C2-T2','NJO-D4-T1','NJO-D4-T2'])
             [1 + (g + $offset) % 12],
           now() - (((g + $offset) % 525600) || ' minutes')::interval,
           900 + (g % 700), 560 + (g % 400), 180 + (g % 300), 110 + (g % 20), 78,
           CASE WHEN g % 53 = 0 THEN 'suspect' ELSE 'good' END
    FROM generate_series(1, $size) g" >/dev/null
  offset=$(( offset + size ))
  printf '\r  %s / %s rows' "$offset" "$total"
done
printf '\n'

elapsed=$(( $(date +%s) - started ))
after=$("${psql_exec[@]}" -Atqc "SELECT count(*) FROM dm_dom_well_production.production_measurement")
snapshots=$("${psql_exec[@]}" -Atqc "
  SELECT jsonb_array_length(lake_iceberg.metadata(metadata_location) -> 'snapshots')
    FROM iceberg_tables
   WHERE table_namespace = 'dm_dom_well_production' AND table_name = 'production_measurement'")

echo "Rows: $before -> $after (+$(( after - before )))"
echo "Elapsed: ${elapsed}s  ~$(( (after - before) / (elapsed > 0 ? elapsed : 1) )) rows/sec"
echo "Iceberg snapshots on the table: $snapshots"
