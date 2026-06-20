.PHONY: setup ingest query eval demo lint type test test-int ci clean reset-qdrant

setup:
	uv sync
	docker compose up -d

ingest:
	uv run -m src.cli.main sources ingest stripe

query:
	@if [ -z "$(Q)" ]; then echo "Usage: make query Q='your question here'"; exit 1; fi
	uv run -m src.cli.main query stripe "$(Q)"

eval:
	@if [ -z "$(SOURCE)" ]; then echo "Usage: make eval SOURCE=stripe"; exit 1; fi
	uv run -m src.evaluate.ragas_runner $(SOURCE)

demo:
	uv run -m src.cli.main demo

lint:
	ruff check src tests
	ruff format --check src tests

type:
	mypy src tests --strict

test:
	pytest -q tests/unit tests/integration

test-int:
	pytest -q tests/integration

ci: lint type test

clean:
	rm -rf .pytest_cache .mypy_cache .ruff_cache __pycache__ src/__pycache__ tests/__pycache__
	find . -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null || true

reset-qdrant:
	docker compose exec qdrant rm -rf /qdrant/storage
	docker compose restart qdrant
