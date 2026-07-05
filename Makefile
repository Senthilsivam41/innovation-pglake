.PHONY: bootstrap build demo up down reset wait test test-failure logs config

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

logs:
	docker compose logs -f postgres pgduck minio demo-ui

config:
	docker compose config --quiet
