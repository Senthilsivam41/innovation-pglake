# syntax=docker/dockerfile:1.7
# AetherLake runtime overlay. Base images are reproducibly built from the
# pinned Snowflake-Labs/pg_lake source by scripts/build-images.sh.
ARG PG_LAKE_POSTGRES_IMAGE=aetherlake/pg-lake-postgres:01c529d
ARG PGDUCK_IMAGE=aetherlake/pgduck-server:01c529d

FROM ${PG_LAKE_POSTGRES_IMAGE} AS postgres
USER root
COPY docker/postgres/entrypoint.sh /usr/local/bin/aetherlake-postgres
COPY docker/postgres/init/ /docker-entrypoint-initdb.d/
RUN chmod 0555 /usr/local/bin/aetherlake-postgres \
    && chmod 0444 /docker-entrypoint-initdb.d/*.sql
USER 1001:1001
ENTRYPOINT ["/usr/local/bin/aetherlake-postgres"]

FROM ${PGDUCK_IMAGE} AS pgduck
USER root
COPY docker/pgduck/entrypoint.sh /usr/local/bin/aetherlake-pgduck
COPY docker/pgduck/init.sql.template /etc/aetherlake/init.sql.template
RUN chmod 0555 /usr/local/bin/aetherlake-pgduck \
    && chmod 0444 /etc/aetherlake/init.sql.template
USER 1001:1001
ENTRYPOINT ["/usr/local/bin/aetherlake-pgduck"]

