# DocSense

**A multi-tenant, source-agnostic RAG engine that answers natural-language questions over any documentation corpus published in the `llms.txt` standard.**

DocSense combines dense and sparse vector retrieval (via Reciprocal Rank Fusion), cross-encoder reranking, and constrained LLM generation with Pydantic-validated answers and verified citations. Every request produces a distributed trace, structured logs, and cost metrics. A RAGAS-based evaluation harness in CI blocks merges on quality regression.

---

## Quick Start

### Prerequisites

- Python 3.11
- `uv` (package manager)
- Docker & Docker Compose
- ~15 GB disk for model downloads (one-time, automatic)

### Setup

```bash
# 1. Initialize the environment and start infrastructure
make setup

# 2. Wait ~30 seconds for services to come up, then verify
docker compose ps  # all services should show "Running"

# 3. Ingest a documentation source (Stripe example)
make ingest

# 4. Run a query
make query Q="How do I create a payment intent?"

# 5. Run evaluation against golden set
make eval SOURCE=stripe

# 6. See the full demo (ingest + queries + traces)
make demo
```

All commands are in the [Makefile](./Makefile). See below for the full reference.

---

## What is DocSense?

### The Problem

Enterprise users interact with documentation structured for human browsing, not machine extraction. Manual search returns ranked links; LLM chat without grounding hallucinates. Existing "Ask My Docs" solutions either lock customers into proprietary ingestion formats or require a fragile pipeline per source.

### The Solution

**One contract, one engine.**

DocSense ingests any documentation source published as `llms.txt`—an open, machine-readable format for documentation indices. Once onboarded, the engine:

1. **Retrieves** using hybrid search: dense vectors (semantic) + sparse BM25 (lexical), fused via RRF
2. **Reranks** using a cross-encoder for precision
3. **Generates** with GPT-4o-mini constrained to cite only retrieved chunks
4. **Validates** citations at runtime (100% verified sources)
5. **Observes** every step with OTel traces, structured logs, and cost tracking
6. **Evaluates** in CI using RAGAS; blocks PRs on quality regression

### Multi-Tenancy

Each documentation source gets its own Qdrant collection (`docsense_{source_id}`). Sources are isolated; re-indexing one never blocks another.

### The Contract

The [`llms.txt` standard](./docs/llms-txt-contract.md) is the seam between **DocSense Crawler** (which generates `llms.txt` from Confluence, Notion, etc.) and **DocSense** (which consumes it). This separation means:

- Customers with native `llms.txt` (Stripe, Anthropic, Vercel) use DocSense directly
- Customers without `llms.txt` run the Crawler once, then use DocSense
- The two products evolve independently with separate roadmaps

---

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│ SOURCE REGISTRATION                                             │
│ POST /sources → registry → background indexing job              │
│              → per-source Qdrant collection created             │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ INGESTION PIPELINE (async, per-source)                          │
│ llms.txt → fetch links → download .md → chunk → embed → index   │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ QUERY PIPELINE (runtime)                                        │
│ question → cache lookup → embed → hybrid retrieve → rerank      │
│         → prompt assemble → LLM (Pydantic-validated)            │
│         → citation validate → trace + cache + respond           │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ OBSERVABILITY                                                   │
│ OTel SDK → Jaeger (traces) → Loki (logs) → Prometheus (metrics) │
│                           ↓                                     │
│                        Grafana (dashboards)                     │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ EVALUATION (CI-gated per PR, per source)                        │
│ golden set → RAGAS scoring → GitHub Actions gate                │
│ (3% drift → fail)                                               │
└─────────────────────────────────────────────────────────────────┘
```

---

## Makefile Reference

### Core Operations

```bash
make setup          # uv sync && docker compose up -d
make ingest         # Run Stripe ingestion end-to-end
make query Q="..."  # Run a single query against Stripe
make eval SOURCE=stripe    # Run RAGAS against golden set
make demo           # End-to-end demo: ingest + queries
```

### Quality Gates

```bash
make lint           # ruff check + ruff format --check
make type           # mypy --strict src tests
make test           # pytest -q (unit + integration)
make test-int       # pytest tests/integration -q
make ci             # lint + type + test (CI pipeline)
```

### Hygiene

```bash
make clean          # Remove .pytest_cache, .mypy_cache, __pycache__
make reset-qdrant   # Drop and recreate Qdrant volume
```

---

## Configuration

All configuration is via environment variables (no hardcoded values). See [`.env.example`](./.env.example) for the full list.

Key variables:

```bash
OPENAI_API_KEY=sk-...              # Required for Phase 3+
EMBEDDING_MODEL=BAAI/bge-m3        # Default; frozen
RERANKER_MODEL=BAAI/bge-reranker-v2-m3
CHUNKING_STRATEGY=structure_first  # fixed | structure_first | semantic
QDRANT_HOST=localhost              # Default for local dev
QDRANT_PORT=6333
RAGAS_REGRESSION_THRESHOLD=0.03    # 3% = CI failure
```

Create a `.env` file (gitignored) with your secrets. See `.env.example` for placeholders.

---

## Documentation

| Document                                                           | Purpose                                                                                                                                  |
| ------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------- |
| [**docs/PRD-DocSense.md**](./docs/PRD-DocSense.md)                 | Full product requirements: design, algorithms, acceptance criteria, cost model. **Read this for design decisions.**                      |
| [**docs/llms-txt-contract.md**](./docs/llms-txt-contract.md)       | The `llms.txt` format specification. **Read this before onboarding a new source.**                                                       |
| [**docs/PRD-DocSense-Crawler.md**](./docs/PRD-DocSense-Crawler.md) | Companion product (deferred to v2). Context only; not needed for v1.                                                                     |
| [**CLAUDE.md**](./CLAUDE.md)                                       | Project memory: current status, known issues, decisions, architecture notes, file inventory. **Read this at the start of each session.** |

---

## Project Status

| Phase   | Scope                                                   | Status         |
| ------- | ------------------------------------------------------- | -------------- |
| Phase 1 | Ingestion + hybrid retrieval (3 chunkers, multi-tenant) | ⬜ Not started |
| Phase 2 | Cross-encoder reranking with skip-on-confidence         | ⬜ Not started |
| Phase 3 | Citation-enforced generation + `?explain=true` mode     | ⬜ Not started |
| Phase 4 | Observability + CI-gated RAGAS evaluation               | ⬜ Not started |

See [CLAUDE.md § Progress Log](./CLAUDE.md#13-progress-log) for detailed session history.

---

## Technology Stack

- **Language:** Python 3.11 (locked)
- **Package Manager:** `uv`
- **Vector DB:** Qdrant (self-hosted, v1.11.0)
- **Cache:** Redis
- **Embeddings:** FastEmbed (BAAI/bge-m3, dense + sparse)
- **Reranking:** Sentence-Transformers (BAAI/bge-reranker-v2-m3)
- **Generation:** OpenAI (GPT-4o-mini) + instructor (Pydantic validation)
- **Evaluation:** RAGAS (LLM-as-judge)
- **HTTP:** httpx (async, HTTP/2)
- **API:** FastAPI + typer CLI
- **Observability:** OpenTelemetry → Jaeger, Prometheus, Loki, Grafana
- **Testing:** pytest, hypothesis (property-based)
- **Linting:** ruff, mypy (strict)

---

## Development

### First-Run Model Downloads

On first execution, these models auto-download from Hugging Face (large, one-time):

| Model                     | Size    | Triggered by         |
| ------------------------- | ------- | -------------------- |
| `BAAI/bge-m3`             | ~2.3 GB | First embedding call |
| `BAAI/bge-reranker-v2-m3` | ~1.1 GB | First reranking call |

Models live in `~/.cache/huggingface/` by default. Subsequent runs are offline.

### Coding Standards

- **Format:** `ruff format` (line length 100)
- **Lint:** `ruff check` with rules E,W,F,N,B,SIM,UP,I,RUF,ASYNC
- **Types:** `mypy --strict` (no `Any` without justification)
- **Docstrings:** Google style; every public function and class
- **Logging:** `structlog` only; never `print()`
- **Commits:** Conventional Commits (`feat:`, `fix:`, `refactor:`, etc.)

### Running Tests

```bash
# All tests
make test

# Integration tests only (requires Docker stack running)
make test-int

# With coverage
pytest --cov=src tests/
```

---

## Observability Dashboards

After `make setup`, access these UIs:

| Service                  | URL                             | Default Credentials       |
| ------------------------ | ------------------------------- | ------------------------- |
| **Qdrant**               | http://localhost:6333/dashboard | —                         |
| **Jaeger** (traces)      | http://localhost:16686          | —                         |
| **Prometheus** (metrics) | http://localhost:9090           | —                         |
| **Grafana** (dashboards) | http://localhost:3000           | admin / admin             |
| **Loki** (logs)          | http://localhost:3100           | — (not yet working in v1) |

---

## Known Issues

See [CLAUDE.md § Known Issues](./CLAUDE.md#15-known-issues) for tracking bugs and workarounds.

---

## Contributing

1. Read [CLAUDE.md](./CLAUDE.md) end-to-end (it is the single source of truth for project state)
2. Read the relevant PRD section for design context
3. Write tests for new code; run `make ci` before committing
4. Follow Conventional Commits; reference issues/PRs in messages
5. Update CLAUDE.md **as part of the same commit** with your changes

---

## License

[TBD]

---

**Questions?** See the [docs](./docs) or [CLAUDE.md](./CLAUDE.md).
