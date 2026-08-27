\set ON_ERROR_STOP on

-- Demo instances for the well production model.
--
-- Deliberately small enough to hold in your head: 2 fields, 6 wells, 12 wellbores and 5
-- interventions. Five interventions across six wells means one well has none, so the demo
-- proves the LEFT JOIN is correct rather than accidentally right.
--
-- A node with properties in several containers has one row per container table, keyed by the
-- same (space, node_external_id). That is how DMS composes an instance, and it is why the
-- compiled views join on exactly that pair.

\set instance_space 'inst_well_production'

-- Asset types: what makes a node a field, a well or a wellbore.
INSERT INTO cdf_cdm.cognite_describable (space, node_external_id, name, description)
VALUES
    (:'instance_space', 'type-field',    'Field',    'A producing hydrocarbon field.'),
    (:'instance_space', 'type-well',     'Well',     'A well drilled from a single surface location.'),
    (:'instance_space', 'type-wellbore', 'Wellbore', 'A drilled hole, including sidetracks.');

INSERT INTO cdf_cdm.cognite_asset_type (space, node_external_id, code)
VALUES
    (:'instance_space', 'type-field', 'FIELD'),
    (:'instance_space', 'type-well', 'WELL'),
    (:'instance_space', 'type-wellbore', 'WELLBORE');

-- Fields, wells and wellbores are all CogniteAsset nodes in one hierarchy, exactly as
-- Cognite's own oil and gas package models functional locations.
INSERT INTO cdf_cdm.cognite_describable (space, node_external_id, name, description, tags)
VALUES
    (:'instance_space', 'FLD-DRA', 'Draugen', 'Producing oil field in the Norwegian Sea.', ARRAY['norwegian-sea']),
    (:'instance_space', 'FLD-NJO', 'Njord',   'Producing oil and gas field in the Norwegian Sea.', ARRAY['norwegian-sea']),
    (:'instance_space', 'DRA-A1', 'DRA-A1', 'Draugen A-1 oil producer.', ARRAY['producer']),
    (:'instance_space', 'DRA-A2', 'DRA-A2', 'Draugen A-2 oil producer.', ARRAY['producer']),
    (:'instance_space', 'DRA-B3', 'DRA-B3', 'Draugen B-3 water injector.', ARRAY['injector']),
    (:'instance_space', 'NJO-C1', 'NJO-C1', 'Njord C-1 oil producer.', ARRAY['producer']),
    (:'instance_space', 'NJO-C2', 'NJO-C2', 'Njord C-2 gas producer.', ARRAY['producer']),
    (:'instance_space', 'NJO-D4', 'NJO-D4', 'Njord D-4 oil producer.', ARRAY['producer']);

INSERT INTO cdf_cdm.cognite_describable (space, node_external_id, name, description)
SELECT :'instance_space', w || '-T' || t, w || '-T' || t,
       CASE t WHEN 1 THEN 'Original hole of ' || w ELSE 'Sidetrack ' || t || ' of ' || w END
FROM unnest(ARRAY['DRA-A1', 'DRA-A2', 'DRA-B3', 'NJO-C1', 'NJO-C2', 'NJO-D4']) w
CROSS JOIN generate_series(1, 2) t;

INSERT INTO cdf_cdm.cognite_sourceable (space, node_external_id, source_id, source_context, source_created_time)
SELECT space, node_external_id, 'PDM-' || node_external_id, 'production-accounting', now() - interval '400 days'
FROM cdf_cdm.cognite_describable
WHERE space = :'instance_space' AND node_external_id NOT LIKE 'type-%';

-- Hierarchy. path is the ordered ancestor chain, which is what makes subtree filtering work.
INSERT INTO cdf_cdm.cognite_asset (space, node_external_id, asset_hierarchy_parent,
                                   asset_hierarchy_root, asset_hierarchy_path, type)
VALUES
    (:'instance_space', 'FLD-DRA', NULL, 'FLD-DRA', ARRAY['FLD-DRA'], 'type-field'),
    (:'instance_space', 'FLD-NJO', NULL, 'FLD-NJO', ARRAY['FLD-NJO'], 'type-field');

INSERT INTO cdf_cdm.cognite_asset (space, node_external_id, asset_hierarchy_parent,
                                   asset_hierarchy_root, asset_hierarchy_path, type)
SELECT :'instance_space', w.node_external_id, w.field, w.field, ARRAY[w.field, w.node_external_id], 'type-well'
FROM (VALUES ('DRA-A1', 'FLD-DRA'), ('DRA-A2', 'FLD-DRA'), ('DRA-B3', 'FLD-DRA'),
             ('NJO-C1', 'FLD-NJO'), ('NJO-C2', 'FLD-NJO'), ('NJO-D4', 'FLD-NJO'))
     AS w(node_external_id, field);

INSERT INTO cdf_cdm.cognite_asset (space, node_external_id, asset_hierarchy_parent,
                                   asset_hierarchy_root, asset_hierarchy_path, type)
SELECT :'instance_space', w.well || '-T' || t, w.well, w.field,
       ARRAY[w.field, w.well, w.well || '-T' || t], 'type-wellbore'
FROM (VALUES ('DRA-A1', 'FLD-DRA'), ('DRA-A2', 'FLD-DRA'), ('DRA-B3', 'FLD-DRA'),
             ('NJO-C1', 'FLD-NJO'), ('NJO-C2', 'FLD-NJO'), ('NJO-D4', 'FLD-NJO'))
     AS w(well, field)
CROSS JOIN generate_series(1, 2) t;

-- Domain properties. Well-only columns are null on field rows; that is what a single wide
-- access view looks like.
INSERT INTO dm_dom_well_production.asset (space, node_external_id, asset_type, field_code)
VALUES (:'instance_space', 'FLD-DRA', 'field', 'FLD-DRA'),
       (:'instance_space', 'FLD-NJO', 'field', 'FLD-NJO');

INSERT INTO dm_dom_well_production.asset (space, node_external_id, asset_type, well_id,
                                          well_type, spud_date, water_depth_m)
VALUES
    (:'instance_space', 'DRA-A1', 'well', 'NO 6407/9-A-1', 'producer', DATE '2015-04-12', 251.0),
    (:'instance_space', 'DRA-A2', 'well', 'NO 6407/9-A-2', 'producer', DATE '2016-08-03', 249.5),
    (:'instance_space', 'DRA-B3', 'well', 'NO 6407/9-B-3', 'injector', DATE '2017-02-21', 253.2),
    (:'instance_space', 'NJO-C1', 'well', 'NO 6407/7-C-1', 'producer', DATE '2014-11-05', 330.0),
    (:'instance_space', 'NJO-C2', 'well', 'NO 6407/7-C-2', 'producer', DATE '2018-06-17', 332.8),
    (:'instance_space', 'NJO-D4', 'well', 'NO 6407/7-D-4', 'producer', DATE '2019-09-30', 328.4);

INSERT INTO dm_dom_well_production.asset (space, node_external_id, asset_type,
                                          total_depth_m, completion_type)
SELECT :'instance_space', w || '-T' || t, 'wellbore',
       2400 + ((hashtext(w) % 900 + 900) % 900)::double precision + t * 130,
       CASE WHEN t = 1 THEN 'cased hole' ELSE 'open hole' END
FROM unnest(ARRAY['DRA-A1', 'DRA-A2', 'DRA-B3', 'NJO-C1', 'NJO-C2', 'NJO-D4']) w
CROSS JOIN generate_series(1, 2) t;

-- Five interventions across six wells: NJO-D4 deliberately has none.
INSERT INTO cdf_cdm.cognite_describable (space, node_external_id, name, description)
VALUES
    (:'instance_space', 'WO-1001', 'Draugen A-1 ESP replacement', 'Replace failed electrical submersible pump.'),
    (:'instance_space', 'WO-1002', 'Draugen B-3 coiled tubing cleanout', 'Remove scale restricting injection.'),
    (:'instance_space', 'WO-1003', 'Njord C-1 gas lift valve change', 'Swap gas lift valve to restore lift.'),
    (:'instance_space', 'WO-1004', 'Njord C-2 wireline logging', 'Run production logging tool across the reservoir.'),
    (:'instance_space', 'WO-1005', 'Draugen A-2 choke replacement', 'Replace eroded production choke.');

INSERT INTO cdf_cdm.cognite_schedulable (space, node_external_id, start_time, end_time, scheduled_start_time)
VALUES
    (:'instance_space', 'WO-1001', current_date - 61, current_date - 58, current_date - 62),
    (:'instance_space', 'WO-1002', current_date - 44, current_date - 42, current_date - 45),
    (:'instance_space', 'WO-1003', current_date - 30, current_date - 29, current_date - 30),
    (:'instance_space', 'WO-1004', current_date - 12, NULL,              current_date - 12),
    (:'instance_space', 'WO-1005', current_date - 5,  current_date - 3,  current_date - 6);

INSERT INTO cdf_idm.cognite_maintenance_order (space, node_external_id, main_asset, type, status, priority)
VALUES
    (:'instance_space', 'WO-1001', 'DRA-A1', 'corrective', 'complete', 1),
    (:'instance_space', 'WO-1002', 'DRA-B3', 'preventive', 'complete', 3),
    (:'instance_space', 'WO-1003', 'NJO-C1', 'corrective', 'complete', 2),
    (:'instance_space', 'WO-1004', 'NJO-C2', 'inspection', 'active',   4),
    (:'instance_space', 'WO-1005', 'DRA-A2', 'corrective', 'complete', 2);

INSERT INTO dm_dom_well_production.well_intervention (space, node_external_id, intervention_type, estimated_uplift_bpd)
VALUES
    (:'instance_space', 'WO-1001', 'esp-replacement', 420.0),
    (:'instance_space', 'WO-1002', 'coiled-tubing', 180.0),
    (:'instance_space', 'WO-1003', 'gas-lift', 260.0),
    (:'instance_space', 'WO-1004', 'wireline', 0.0),
    (:'instance_space', 'WO-1005', 'choke-replacement', 95.0);

-- 12 wellbores x 90 days x 24 hourly readings = 25,920 records.
-- Rates decline gently over the window and vary per wellbore; quality is degraded on a fixed
-- cadence rather than randomly, so re-seeding always produces identical numbers.
INSERT INTO dm_dom_well_production.production_measurement (
    space, record_id, wellbore, measured_at,
    oil_rate_bpd, gas_rate_mscfd, water_rate_bpd, tubing_head_pressure_bar, choke_percent, quality)
SELECT
    :'instance_space',
    wb.bore || ':' || to_char(ts, 'YYYYMMDDHH24'),
    wb.bore,
    ts,
    round((wb.base * (1 - 0.0015 * age) * (0.94 + 0.12 * ((hashtext(wb.bore || ts::text) % 100 + 100) % 100) / 100.0))::numeric, 2),
    round((wb.base * 0.62 * (1 - 0.0011 * age))::numeric, 2),
    round((wb.base * (0.18 + 0.0022 * age))::numeric, 2),
    round((118 - 0.08 * age + ((hashtext(wb.bore || ts::text) % 7 + 7) % 7))::numeric, 2),
    CASE WHEN wb.bore LIKE '%-T2' THEN 62.0 ELSE 78.0 END,
    CASE WHEN (age * 24 + extract(hour FROM ts)::int + (hashtext(wb.bore) % 13 + 13) % 13) % 53 = 0
         THEN 'suspect' ELSE 'good' END
FROM (
    SELECT w || '-T' || t AS bore, 900 + ((hashtext(w) % 700 + 700) % 700) + t * 55 AS base
    FROM unnest(ARRAY['DRA-A1', 'DRA-A2', 'DRA-B3', 'NJO-C1', 'NJO-C2', 'NJO-D4']) w
    CROSS JOIN generate_series(1, 2) t
) wb
CROSS JOIN LATERAL (
    SELECT ts, (current_date - ts::date) AS age
    FROM generate_series((current_date - 89)::timestamptz,
                         (current_date + interval '23 hours')::timestamptz,
                         interval '1 hour') ts
) g;
