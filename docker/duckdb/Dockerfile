# A stock, unmodified DuckDB: the openness proof has to come from an engine that is obviously
# not part of this stack.
#
# The pgduck sidecar cannot serve here. Its custom build reports version v0.0.1, for which
# DuckDB's extension repository publishes no artifacts, so `iceberg` cannot be installed - the
# same gap the README already documents for `spatial`. And read_parquet() over the data
# directory is not an equivalent proof: it reads every Parquet file present, including ones
# superseded by copy-on-write DELETE, so it over-counts exactly where the SDM rebuild happens.
#
# Extensions are baked at build time so the demo never needs the network.
# duckdb/duckdb publishes only :latest, so pin the multi-arch index by digest to keep the
# supply chain immutable in the same way the MinIO images are pinned.
FROM duckdb/duckdb@sha256:69b2f746c2d179c0e8d47914f2cff6a9af863372732822fb84e88047f4f2ebf1

RUN ["/duckdb", "-c", "INSTALL httpfs; INSTALL iceberg;"]

# CSV without headers so callers can read a single scalar without parsing box-drawing output.
ENTRYPOINT ["/duckdb", "-csv", "-noheader", "-c"]
