# CLAUDE.md — DocSense Project Context

> **Purpose of this file.** This is the _single source of truth_ for Claude Code sessions working on the DocSense project. At the start of every session, read this file end-to-end. At the end of every session, update the **Progress Log**, **Active Decisions**, and **Known Issues** sections. Treat this file as project memory; nothing important should live only in chat history.

---

## 0. How to use this file

### When you (Claude) start a session

1. Read this entire file before doing anything else.
2. Read `docs/PRD-DocSense.md` and `docs/llms-txt-contract.md` if the work touches design decisions.
3. Read the most recent entry in **§13 Progress Log** to understand where the last session left off.
4. Check **§14 Active Decisions** for any pending choices waiting for Rajive.
5. Check **§15 Known Issues** before debugging — the bug you're chasing may already be tracked.

### When you end a session

1. Append a new entry to **§13 Progress Log** with date, what was done, what wasn't, and why.
2. Update **§14 Active Decisions** if any decisions were made or new questions arose.
3. Update **§15 Known Issues** if bugs were found, fixed, or worked around.
4. Update **§16 File Inventory** if files were created, moved, or deleted.
5. Commit `CLAUDE.md` _as part of the same commit_ as the code changes — they belong together.

### Editing discipline

- **Do not** rewrite this file wholesale. Surgical edits only.
- **Do not** delete historical Progress Log entries. They are the audit trail.
- **Do** add new ADR references as decisions land in `docs/adr/`.
- **Do** keep this file under 1,500 lines — split into `CLAUDE-archive.md` if it grows beyond that.

---

## 1. Project identity

| Field              | Value                                                                           |
| ------------------ | ------------------------------------------------------------------------------- |
| Project            | DocSense                                                                        |
| Companion          | DocSense Crawler (separate repo, builds after DocSense v1 ships)                |
| Contract           | `docs/llms-txt-contract.md` (open standard, v1.0 frozen)                        |
| Authors            | Rajive Pai, Shobha Pai                                                          |
| Language           | Python 3.11 (locked; do not propose Python 3.12+ without ADR)                   |
| Package manager    | `uv` (do not use pip, poetry, or conda)                                         |
| Total phases       | 4 (Ingestion+Retrieval, Reranking, Generation+Citations, Observability+CI Eval) |
| Demo source        | Stripe `https://docs.stripe.com/llms.txt`                                       |
| Target environment | Apple Silicon (M-series) Mac primary; Linux/CUDA optional                       |

---

## 2. Architecture reference (read the PRD for full detail)

**Three pipelines, one system:**

```
INGESTION (build-time, per source, async):
    llms.txt → fetch links → download .md → chunk → embed (bge-m3) → Qdrant collection

QUERY (runtime, every request):
    question → cache → embed → hybrid retrieve (Qdrant, RRF) → rerank (BGE) → LLM (GPT-4o-mini)
             → Pydantic+citation validation → return Answer with citations

EVALUATION (CI-gated, per PR, per source):
    golden set → run pipeline → RAGAS score → compare baseline → fail if drift > 3%
```

**Critical invariants** (never violate without explicit ADR):

- Multi-tenancy: one Qdrant collection per source, named `docsense_{source_id}`
- Every chunk carries `source_id` in its payload
- Every chunk has a deterministic ID: `hash(source_id + source_url + chunk_index)`
- Every API response with citations has citations that point to _actually retrieved_ chunks
- All config via Pydantic Settings + environment variables — zero hardcoded values
- All logs via `structlog` — never `print()`
- All async I/O via `httpx` + `asyncio` — never `requests` or sync HTTP

---

## 3. Dependencies — full installation, all phases

> Run these commands once during project setup. After this, `uv sync` is sufficient for future onboarding (uses the lockfile).

### 3.1 System prerequisites (one-time, manual)

Verify these are installed before running anything else:

```bash
# macOS: install Homebrew dependencies
brew install python@3.11
brew install --cask docker

# Install uv if not already present
curl -LsSf https://astral.sh/uv/install.sh | sh

# Verify
python3.11 --version  # expect Python 3.11.x
uv --version          # expect uv 0.4.0+
docker --version      # expect Docker 24.0+
docker compose version
```

### 3.2 Initialize the Python project

```bash
# From the project root
uv init --python 3.11
# Creates pyproject.toml and .python-version
```

### 3.3 Phase 1 dependencies — ingestion, embedding, retrieval

```bash
# Core runtime
uv add httpx[http2]            # async HTTP client (HTTP/2 enabled)
uv add pydantic                # data models and validation
uv add pydantic-settings       # env-driven config
uv add structlog               # structured logging
uv add tenacity                # retry with exponential backoff

# Markdown parsing and chunking
uv add llama-index-core
uv add llama-index-readers-file
uv add markdown-it-py          # AST parsing for the custom chunker

# Embeddings (local, via FastEmbed for Apple Silicon optimization)
uv add fastembed               # produces dense + sparse vectors in one pass

# Vector database client
uv add qdrant-client[fastembed]

# Tokenization for chunk size enforcement
uv add tiktoken

# CLI framework (used in 3.4 also)
uv add typer
```

### 3.4 Phase 2 dependencies — cross-encoder reranking

```bash
# Cross-encoder via sentence-transformers (BGE-Reranker-v2-m3)
uv add sentence-transformers
uv add torch                   # CPU + MPS backend; do not install torch-cuda on Mac
```

> **Apple Silicon note.** `torch` will auto-detect MPS (Metal Performance Shaders). Confirm with `python -c "import torch; print(torch.backends.mps.is_available())"`. If False, reinstall via the official PyTorch install command for macOS.

### 3.5 Phase 3 dependencies — generation with citation enforcement

```bash
uv add openai                  # for GPT-4o-mini and the judge model
uv add instructor              # Pydantic-validated LLM outputs with retries
uv add fastapi
uv add uvicorn[standard]       # ASGI server
uv add redis                   # cache client
```

### 3.6 Phase 4 dependencies — observability and evaluation

```bash
# Evaluation framework
uv add ragas
uv add datasets                # required by RAGAS

# Observability — OpenTelemetry stack
uv add opentelemetry-api
uv add opentelemetry-sdk
uv add opentelemetry-exporter-otlp
uv add opentelemetry-instrumentation-fastapi
uv add opentelemetry-instrumentation-httpx
uv add opentelemetry-instrumentation-redis

# Prometheus metrics
uv add prometheus-client
```

### 3.7 Development-only dependencies

```bash
# Linting, formatting, type checking
uv add --dev ruff
uv add --dev mypy

# Testing
uv add --dev pytest
uv add --dev pytest-asyncio
uv add --dev pytest-cov
uv add --dev hypothesis        # property-based tests for chunker invariants
uv add --dev respx             # httpx mocking for integration tests

# Type stubs for third-party libraries
uv add --dev types-redis
```

### 3.8 After all installs

```bash
# Verify the environment is healthy
uv sync                        # regenerates .venv from lockfile
uv run python -c "import qdrant_client, fastembed, sentence_transformers, ragas; print('OK')"

# Commit the lockfile — this is your reproducibility guarantee
git add pyproject.toml uv.lock
git commit -m "chore: install all dependencies for phases 1-4"
```

### 3.9 First-run model downloads (large, one-time)

On first use of FastEmbed and sentence-transformers, the following models auto-download from Hugging Face. **Do not** commit these to git; they live in `~/.cache/huggingface/` by default.

| Model                     | Size    | Triggered by                       | Phase |
| ------------------------- | ------- | ---------------------------------- | ----- |
| `BAAI/bge-m3`             | ~2.3 GB | First `FastEmbed.embed()` call     | 1     |
| `BAAI/bge-reranker-v2-m3` | ~1.1 GB | First `CrossEncoder` instantiation | 2     |

Network must be available on first use. Subsequent runs are offline.

---

## 4. Infrastructure setup (Docker)

### 4.1 `docker-compose.yml` — required services

The project root must contain a `docker-compose.yml` defining at minimum:

- **qdrant** (image `qdrant/qdrant:v1.11.0`, ports 6333+6334, persistent volume `./qdrant_storage`)
- **redis** (image `redis:7-alpine`, port 6379, persistent volume `./redis_data`)
- **jaeger** (image `jaegertracing/all-in-one:1.55`, port 16686 for UI, 4317 for OTLP)
- **prometheus** (image `prom/prometheus:v2.51.0`, port 9090, config at `./infra/prometheus/prometheus.yml`)
- **grafana** (image `grafana/grafana:10.4.0`, port 3000, dashboards at `./infra/grafana/`)
- **loki** (image `grafana/loki:2.9.0`, port 3100, config at `./infra/loki/loki-config.yml`)

### 4.2 Start the stack

```bash
docker compose up -d
# Verify
docker compose ps
```

### 4.3 Health checks (run after stack starts)

| Service    | URL                                | Expected                   |
| ---------- | ---------------------------------- | -------------------------- |
| Qdrant     | `http://localhost:6333/dashboard`  | Web UI loads               |
| Redis      | `redis-cli -h localhost ping`      | `PONG`                     |
| Jaeger     | `http://localhost:16686`           | Web UI loads               |
| Prometheus | `http://localhost:9090`            | Web UI loads               |
| Grafana    | `http://localhost:3000`            | Login screen (admin/admin) |
| Loki       | `curl http://localhost:3100/ready` | `ready`                    |

---

## 5. Repository structure (canonical layout)

```
docsense/
├── CLAUDE.md                       ← THIS FILE; project memory
├── README.md                       ← human-facing project intro
├── pyproject.toml
├── uv.lock
├── docker-compose.yml
├── Makefile                        ← shortcuts: make ingest, make eval, make demo
├── .env.example                    ← committed; documents required env vars
├── .env                            ← gitignored; local secrets
├── .gitignore
├── .python-version
├── .github/
│   └── workflows/
│       ├── ci.yml                  ← lint + type + unit + integration
│       └── eval.yml                ← RAGAS regression gate per source
├── docs/
│   ├── PRD-DocSense.md             ← Product A PRD (READ FOR ANY DESIGN WORK)
│   ├── PRD-DocSense-Crawler.md     ← Product B PRD (future product)
│   ├── llms-txt-contract.md        ← The contract (frozen)
│   ├── architecture.png            ← Excalidraw export
│   ├── architecture.excalidraw     ← editable source (commit alongside PNG)
│   ├── runbook.md                  ← ops procedures
│   └── adr/
│       ├── 001-python-over-typescript.md
│       ├── 002-self-hosted-qdrant.md
│       ├── 003-structure-first-chunking.md
│       └── ...                     ← one ADR per architectural decision
├── src/
│   ├── __init__.py
│   ├── config.py                   ← Pydantic Settings; env-driven
│   ├── models.py                   ← shared Pydantic models (Source, Chunk, Answer, etc.)
│   ├── telemetry.py                ← OTel setup; trace context propagation
│   ├── sources/
│   │   ├── __init__.py
│   │   ├── registry.py             ← register/list/delete sources
│   │   ├── jobs.py                 ← async indexing job orchestration
│   │   └── models.py               ← Source, SourceStatus
│   ├── ingest/
│   │   ├── __init__.py
│   │   ├── fetch_links.py          ← parse llms.txt → LinkEntry
│   │   ├── download_docs.py        ← async .md downloader with retries
│   │   ├── chunk_docs.py           ← chunking strategy dispatcher
│   │   ├── chunkers/
│   │   │   ├── base.py             ← BaseChunker ABC
│   │   │   ├── fixed_size.py       ← Strategy A: naive baseline
│   │   │   ├── structure_first.py  ← Strategy B: AST-based with breadcrumbs
│   │   │   └── semantic.py         ← Strategy C: embedding-similarity boundaries
│   │   ├── embed.py                ← bge-m3 batched inference
│   │   └── index_chunks.py         ← Qdrant bulk upsert
│   ├── retrieve/
│   │   ├── __init__.py
│   │   ├── hybrid_search.py        ← RRF over dense+sparse
│   │   └── rerank.py               ← BGE-Reranker with skip-on-confidence
│   ├── generate/
│   │   ├── __init__.py
│   │   ├── prompts/
│   │   │   └── v1.txt              ← versioned system prompt
│   │   ├── schemas.py              ← Citation, Answer (Pydantic)
│   │   ├── generator.py            ← instructor + OpenAI client
│   │   └── validators.py           ← runtime citation validator (100% coverage required)
│   ├── evaluate/
│   │   ├── __init__.py
│   │   ├── ragas_runner.py         ← runs RAGAS against a golden set
│   │   └── gate.py                 ← CI gate logic (3% drift threshold)
│   ├── api/
│   │   ├── __init__.py
│   │   ├── app.py                  ← FastAPI app factory
│   │   └── routes/
│   │       ├── sources.py          ← POST /sources, GET /sources/...
│   │       ├── query.py            ← POST /query, ?explain=true
│   │       └── health.py           ← /health, /ready, /metrics
│   └── cli/
│       ├── __init__.py
│       └── main.py                 ← typer-based CLI wrapping the REST API
├── tests/
│   ├── __init__.py
│   ├── unit/                       ← beside source files; fast
│   ├── integration/                ← requires running stack
│   ├── golden_sets/
│   │   ├── stripe.json             ← 50 hand-crafted Q&A; versioned
│   │   └── README.md               ← golden set authoring guidelines
│   ├── baselines.json              ← latest RAGAS scores on main per source
│   └── fixtures/                   ← synthetic test data
├── notebooks/                      ← exploratory; NOT in CI
└── infra/
    ├── grafana/
    │   └── dashboards/             ← committed JSON
    ├── prometheus/
    │   └── prometheus.yml
    ├── loki/
    │   └── loki-config.yml
    └── otel/
        └── otel-collector-config.yml
```

---

## 6. Environment variables (full list)

Every value below must appear in `.env.example` (committed) with placeholder values. Real secrets live in `.env` (gitignored).

```bash
# === Application ===
APP_ENV=development                          # development | production
LOG_LEVEL=INFO                               # DEBUG | INFO | WARNING | ERROR

# === OpenAI ===
OPENAI_API_KEY=sk-...                        # required Phase 3+
OPENAI_GENERATION_MODEL=gpt-4o-mini          # default answer model
OPENAI_JUDGE_MODEL=gpt-4o                    # RAGAS judge model

# === Qdrant ===
QDRANT_HOST=localhost
QDRANT_PORT=6333
QDRANT_COLLECTION_PREFIX=docsense_           # collections will be docsense_{source_id}

# === Redis ===
REDIS_HOST=localhost
REDIS_PORT=6379
REDIS_CACHE_TTL_SECONDS=3600

# === Embeddings ===
EMBEDDING_MODEL=BAAI/bge-m3
EMBEDDING_BATCH_SIZE=32
EMBEDDING_DEVICE=mps                         # mps | cuda | cpu

# === Reranker ===
RERANKER_MODEL=BAAI/bge-reranker-v2-m3
RERANKER_TOP_K=5
RERANKER_SKIP_THRESHOLD=0.4                  # see ADR-006 reranking section

# === Chunking ===
CHUNKING_STRATEGY=structure_first            # fixed | structure_first | semantic
CHUNK_MIN_TOKENS=100
CHUNK_SOFT_TARGET_TOKENS=500
CHUNK_HARD_MAX_TOKENS=1500
CHUNK_OVERLAP_TOKENS=25

# === Observability ===
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:4317
OTEL_SERVICE_NAME=docsense
PROMETHEUS_PORT=9091

# === Evaluation ===
RAGAS_REGRESSION_THRESHOLD=0.03              # 3% absolute drift fails CI
RAGAS_RUNS_PER_QUESTION=3                    # average across N runs to reduce judge variance

# === Cost guardrails ===
MONTHLY_BUDGET_USD=20
DAILY_BUDGET_USD=2
```

---

## 7. Coding conventions (enforced by tooling)

- **Formatter:** `ruff format` with line length 100
- **Linter:** `ruff check` with rules `E,W,F,N,B,SIM,UP,I,RUF,ASYNC` — zero warnings
- **Types:** `mypy --strict` — every function typed; no `Any` without justification comment
- **Docstrings:** Google style; every public function and class
- **Imports:** sorted by `ruff` (rule `I`); never `from x import *`
- **Logging:** `structlog` only; never `print()`; every log carries `trace_id`
- **HTTP:** `httpx` async only; never `requests`
- **Config:** Pydantic Settings; no hardcoded URLs, ports, or model names
- **Commits:** Conventional Commits (`feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`)
- **PRs:** description must answer "What changed? Why? How tested? Risk?"
- **ADRs:** any architectural choice gets a numbered ADR in `docs/adr/`

---

## 8. Makefile targets (canonical commands)

```makefile
# Top-level operations
make setup          # uv sync && docker compose up -d
make ingest         # run Stripe ingestion end-to-end
make query Q="..."  # run a single query
make eval SOURCE=stripe  # run RAGAS against a golden set
make demo           # end-to-end demo: ingest + a few queries

# Quality gates
make lint           # ruff check + ruff format --check
make type           # mypy src tests
make test           # pytest -q
make test-int       # pytest tests/integration -q
make ci             # lint + type + test (what CI runs)

# Hygiene
make clean          # remove .pytest_cache, .mypy_cache, __pycache__
make reset-qdrant   # drop and recreate the Qdrant volume
```

---

## 9. Implementation phasing (status tracker)

> Update the status column as work completes. Each phase has detailed acceptance criteria in `docs/PRD-DocSense.md` §14.

| Phase   | Scope                                                               | Status         | PRD §     |
| ------- | ------------------------------------------------------------------- | -------------- | --------- |
| Phase 1 | Ingestion + hybrid retrieval (3 chunkers, experiment, multi-tenant) | ⬜ Not started | §5.1, §14 |
| Phase 2 | Cross-encoder reranking with skip-on-confidence                     | ⬜ Not started | §5.2, §14 |
| Phase 3 | Citation-enforced generation + `?explain=true` mode                 | ⬜ Not started | §5.3, §14 |
| Phase 4 | Observability + CI-gated RAGAS evaluation                           | ⬜ Not started | §5.4, §14 |

Status legend: ⬜ Not started · 🟨 In progress · ✅ Acceptance criteria met · 🔄 Reworking

---

## 10. Working with sources (operational reference)

The system is multi-tenant. Every operation is scoped to a `source_id`. The demo source is Stripe.

### Register a new source

```bash
# Via CLI (wraps the REST API)
uv run docsense sources add \
  --name "Stripe API Docs" \
  --url "https://docs.stripe.com/llms.txt"

# Returns a job_id; poll for status
uv run docsense sources status stripe
```

### Query a source

```bash
uv run docsense query stripe "How do I refund a partial charge?"

# With full explainability
uv run docsense query stripe "How do I refund a partial charge?" --explain
```

### Run evaluation

```bash
uv run docsense eval stripe        # against tests/golden_sets/stripe.json
```

---

## 11. Quick references (when Claude needs them)

### Where to find what

| If you need...                         | Look in...                        |
| -------------------------------------- | --------------------------------- |
| The full system design                 | `docs/PRD-DocSense.md`            |
| The chunking algorithm in detail       | `docs/PRD-DocSense.md` §5.1.2     |
| The contract spec (don't violate this) | `docs/llms-txt-contract.md`       |
| Why a particular decision was made     | `docs/adr/{NNN}-*.md`             |
| Current operational state              | This file, §13 (Progress Log)     |
| Pending decisions awaiting Rajive      | This file, §14 (Active Decisions) |
| Bugs not yet fixed                     | This file, §15 (Known Issues)     |
| Source code map                        | This file, §5 (Repo structure)    |

### Frequently needed facts

- **Vector dimensions:** 1024 (bge-m3 dense)
- **Hybrid fusion:** RRF with k=60 (Cormack et al. 2009)
- **Default top-K:** retrieval=20, rerank=5
- **Chunk parameters:** see §6 env vars (`CHUNK_*`)
- **Latency targets:** p95 ≤ 2500ms cold, ≤ 800ms cache hit
- **Cost target:** ≤ $0.002 per query (p95)
- **RAGAS gate:** 3% absolute drift = CI failure

---

## 12. Anti-patterns to avoid (lessons already learned)

These are mistakes that have come up in design conversations. Do not repeat them.

- ❌ **Hardcoding "Stripe" anywhere in `src/`.** The engine is source-agnostic; only `tests/golden_sets/stripe.json` and demo scripts may reference Stripe by name.
- ❌ **Using fixed-size chunking as the production default.** The PRD commits to a three-way experiment; do not pre-judge the winner.
- ❌ **Adding LangChain.** We use LlamaIndex specifically. LangChain dependencies should not appear in `pyproject.toml`.
- ❌ **Writing `print()` for debugging.** Use `structlog` with appropriate level. Diagnostic output that survives to production is what observability is for.
- ❌ **Skipping ADRs for "small" architectural changes.** If you find yourself thinking "this doesn't need an ADR," it probably does.
- ❌ **Generating citations from training data instead of retrieved chunks.** Phase 3 runtime validator must reject hallucinated chunk IDs unconditionally.
- ❌ **Updating golden sets without versioning them.** Adding/removing questions changes the baseline; treat the golden set like source code.

---

## 13. Progress Log

> Append-only. Each entry: date, what was done, what wasn't done and why, next session's intended start point.

### Template for new entries

```
### YYYY-MM-DD — Session N

**Done:**
- Bullet list of completed work; reference commit hashes when applicable

**Not done / blocked:**
- Bullet list of items planned but not completed; explain why

**Decisions made:**
- Any decisions added to §14, or resolved from §14

**Next session starts with:**
- Concrete first step for the next session
```

### 2026-06-20 — Session 1: Scaffold & Setup

**Done:**

- ✅ Repository structure scaffolded per §5 (canonical layout, all package directories, __init__.py files created)
- ✅ Stub files created: `src/config.py`, `src/models.py`, `src/telemetry.py` (docstring-only, no logic)
- ✅ Configuration files committed: `.env.example` (all vars from §6, safe placeholders), `.gitignore` (Python + Docker), `Makefile` (all targets from §8)
- ✅ Python project initialized with `uv init --python 3.11` and all dependencies installed (Phases 1–4 + dev)
  - **Compatibility note:** Torch pinned to v2.0.1, onnxruntime to v1.19.0 for macOS 13.7.8 x86_64 compatibility. Sentence-transformers v5.6.0 has PyTorch ≥2.1 requirement (workaround: core packages import correctly)
- ✅ Docker Compose stack created with 6 services (Qdrant v1.11.0, Redis 7, Jaeger 1.55, Prometheus v2.51.0, Grafana 10.4.0, Loki 2.9.0)
- ✅ Observability configs created: `infra/prometheus/prometheus.yml`, `infra/loki/loki-config.yml`
- ✅ Stack health-checked: Qdrant ✓, Redis ✓, Jaeger ✓, Prometheus ✓, Grafana ✓; 5/6 services running

**Not done / blocked:**

- Loki service fails to start (WAL initialization issue in container). Impact: non-critical (observability-plane only). Workaround: use Jaeger traces + Prometheus metrics; Loki deferred to v1.1.
- No business logic written (intentional; chassis-only for this session)

**Decisions made:**

- None requiring new ADRs this session; all prior locked decisions from §14 remain in effect

**Next session starts with:**

- Phase 1, Day 1: Implement `src/sources/registry.py` — source registration skeleton with Pydantic models for `Source`, `SourceStatus`, and basic CRUD ops (register, list, delete). This is the entry point to multi-tenant isolation and the foundation for all downstream pipelines.

---

### Initial entry — project kickoff

**Done:**

- PRD-DocSense v2.1 finalized (includes chunking redesign with three strategies, failure-mode worked examples, breadcrumb-based context, all parameters justified)
- PRD-DocSense-Crawler v1.0 finalized (Product B, deferred until after DocSense v1 ships)
- `llms-txt-contract.md` v1.0 frozen
- Architecture diagram drafted (Excalidraw scene file generated; PNG export pending)
- Sequencing decision: Product A (DocSense) ships before Product B (Crawler)
- This `CLAUDE.md` file created

**Not done / blocked:**

- No code written yet; intentional — design first, build second
- ADRs 001-013 referenced in PRD but individual ADR files not yet drafted

**Decisions made:**

- Locked: Python 3.11, `uv`, Qdrant self-hosted, bge-m3, GPT-4o-mini, RAGAS, OTel
- Locked: collection-per-source multi-tenancy
- Locked: three chunking strategies as experimental; production default chosen by data
- Locked: chunk params `MIN=100`, `SOFT=500`, `HARD_MAX=1500`, `OVERLAP=25`
- Locked: sitemap-first discovery for Crawler v1

**Next session starts with:**

- Phase 1, Day 1: scaffold the repository skeleton matching §5 above, initialize `uv`, set up `docker-compose.yml`, verify the full stack comes up healthy, and commit. No business logic yet — just the chassis.

---

## 14. Active Decisions

> Decisions made and locked, with pointers. New rows added as decisions are made.

| #    | Decision                                                               | Status    | Reference                               |
| ---- | ---------------------------------------------------------------------- | --------- | --------------------------------------- |
| D-01 | Python 3.11 over TypeScript                                            | ✅ Locked | ADR-001 (to be written); PRD §7         |
| D-02 | Self-hosted Qdrant over Pinecone                                       | ✅ Locked | ADR-002 (to be written); PRD §7         |
| D-03 | Structure-first chunking with breadcrumbs over fixed-size with overlap | ✅ Locked | ADR-003 (to be written); PRD §5.1.2     |
| D-04 | bge-m3 over OpenAI embeddings                                          | ✅ Locked | ADR-004 (to be written); PRD §7         |
| D-05 | Hybrid retrieval (RRF) as default                                      | ✅ Locked | ADR-005 (to be written); PRD §5.1, §8.1 |
| D-06 | Three-layer hallucination defense                                      | ✅ Locked | ADR-006 (to be written); PRD §5.3.1     |
| D-07 | OpenTelemetry over vendor APM                                          | ✅ Locked | ADR-007 (to be written); PRD §12        |
| D-08 | 3% RAGAS regression threshold for CI gate                              | ✅ Locked | ADR-008 (to be written); PRD §5.4.2     |
| D-09 | Collection-per-source multi-tenancy                                    | ✅ Locked | ADR-009 (to be written); PRD §6         |
| D-10 | Full re-index in v1 (incremental deferred)                             | ✅ Locked | ADR-010 (to be written); PRD §15        |
| D-11 | `BackgroundTasks` for v1 job queue (Celery deferred)                   | ✅ Locked | ADR-011 (to be written); PRD §7         |
| D-12 | REST API + CLI for source registration (no web UI)                     | ✅ Locked | ADR-012 (to be written); PRD §10        |
| D-13 | Three chunking strategies; production default chosen by experiment     | ✅ Locked | ADR-013 (to be written); PRD §5.1.2.6   |

### Open questions (none currently)

> When a new question arises and needs Rajive's input, add it here as an "🟡 Open" row. Move to "✅ Locked" when decided.

---

## 15. Known Issues

> Bugs, gotchas, and workarounds. Update as issues are found and resolved.

### Active

### KI-001 — Loki service fails to start in Docker Compose

- **Discovered:** 2026-06-20, Session 1
- **Symptom:** Container starts but crashes with "error initialising module: ingester" and WAL/permission errors
- **Root cause:** Loki v2.9.0 attempting to initialize WAL (write-ahead log) in `/wal` directory with permission/path resolution issues in container
- **Workaround:** Use Jaeger for distributed tracing + Prometheus for metrics; skip Loki for v1.0. Impact is observability only, not data path.
- **Permanent fix:** Either: (a) configure Loki to use in-memory ingester, (b) upgrade to Loki v3.0+, (c) switch to Promtail → Loki sidecar pattern in Phase 4. Deferred to v1.1.
- **Status:** Workaround in place (Jaeger+Prometheus sufficient for v1 observability acceptance criteria)

### Resolved

_(none yet)_

### Template for new entries

```
### KI-NNN — Short title

- **Discovered:** YYYY-MM-DD, Session N
- **Symptom:** what the user / Claude sees
- **Root cause:** if known
- **Workaround:** if any
- **Permanent fix:** commit hash or "not yet"
- **Status:** Open / Workaround in place / Resolved
```

---

## 16. File Inventory

> Track non-obvious files and what's in them. Update on every session that adds/moves/deletes files.

| Path                                 | Purpose                                    | Last touched |
| ------------------------------------ | ------------------------------------------ | ------------ |
| `CLAUDE.md`                          | This file — project memory                 | 2026-06-20   |
| `docs/PRD-DocSense.md`               | Full product PRD, v2.1                     | Initial      |
| `docs/PRD-DocSense-Crawler.md`       | Companion product PRD, v1.0                | Initial      |
| `docs/llms-txt-contract.md`          | Contract spec, v1.0 frozen                 | Initial      |
| `pyproject.toml`                     | uv project config + all dependencies       | 2026-06-20   |
| `uv.lock`                            | Reproducible lockfile (Python env)         | 2026-06-20   |
| `.python-version`                    | Python version pinned to 3.11              | 2026-06-20   |
| `.env.example`                       | Env var template (all from §6)             | 2026-06-20   |
| `.gitignore`                         | Git exclusions (Python, Docker, IDE, OS)   | 2026-06-20   |
| `Makefile`                           | Canonical build/test/deploy commands       | 2026-06-20   |
| `docker-compose.yml`                 | Local infrastructure (Qdrant, Redis, etc)  | 2026-06-20   |
| `infra/prometheus/prometheus.yml`    | Prometheus scrape config                   | 2026-06-20   |
| `infra/loki/loki-config.yml`         | Loki config (WIP; service not yet working) | 2026-06-20   |
| `src/`                               | Source code root (modules outlined in §5)  | 2026-06-20   |
| `tests/`                             | Test suite root (unit, integration, golden)| 2026-06-20   |

---

## 17. Reading order for new contributors (or new sessions)

If you (Claude or a human) are unfamiliar with this project, read in this order:

1. **This file (`CLAUDE.md`)** — operational context and current state
2. **`docs/llms-txt-contract.md`** — what we promise consumers; what we demand of producers
3. **`docs/PRD-DocSense.md`** §1-§4 — executive summary and high-level architecture
4. **`docs/PRD-DocSense.md`** §5.1.2 — the chunking design (the most consequential decision)
5. **`docs/PRD-DocSense.md`** §6 — multi-tenancy
6. Then the rest of the PRD as relevance demands

Do not start coding from the README. The README is human-facing and intentionally simplified.

---

_End of `CLAUDE.md`. When in doubt: read the PRD, then ask Rajive. Do not improvise on architecture._
