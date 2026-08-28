# Use the repo virtualenv when it exists; requirements-dev.txt is build-time only.
PYTHON := $(shell test -x .venv/bin/python && echo .venv/bin/python || echo python3)

.PHONY: bootstrap build demo up down reset wait test test-failure logs config \
        model model-check probe seed-scale test-semantic test-sdm test-openness test-all \
        cdf-deploy cdf-push cdf-parity

bootstrap:
	@test -f .env || cp .env.example .env
	@echo "Review .env, then run: make build up test"

build:
	./scripts/build-images.sh

demo:
	./scripts/demo.sh

up:
	docker compose up -d
	./scripts/wait-healthy.sh

down:
	docker compose down

reset:
	docker compose down --volumes --remove-orphans

wait:
	./scripts/wait-healthy.sh

test:
	./tests/smoke.sh

test-failure:
	./tests/storage-failure.sh

# Compile the Cognite Toolkit YAML into docker/postgres/init/08-model.sql. `cdf build` runs
# first so the compiler reads the exact artifact CDF itself would consume.
model:
	cd models && cdf build --env dev
	$(PYTHON) scripts/compile-model.py

model-check:
	cd models && cdf build --env dev
	$(PYTHON) scripts/compile-model.py --check

# The same YAML, deployed to the live project rather than compiled into Postgres. Needs CDF
# credentials in .env; cdf-parity exits 1 if the two runtimes disagree.
cdf-deploy:
	cd models && cdf build --env dev && cdf deploy --env dev

cdf-push:
	$(PYTHON) scripts/cdf-parity.py push

cdf-parity:
	$(PYTHON) scripts/cdf-parity.py compare

probe:
	./tests/pglake-probe.sh

test-semantic:
	./tests/semantic-model.sh

test-sdm:
	./tests/sdm-job.sh

test-openness:
	./tests/openness.sh

# Generate production history at volume. Defaults to 10M rows, roughly a minute.
seed-scale:
	./scripts/seed-scale.sh $(or $(ROWS),10000000) $(or $(CHUNK),250000)

test-all: test test-semantic test-sdm test-openness

logs:
	docker compose logs -f postgres pgduck minio demo-ui

config:
	docker compose config --quiet
