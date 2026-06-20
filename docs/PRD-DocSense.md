# DocSense — Product Requirements Document

> **A multi-tenant, source-agnostic RAG engine that answers natural-language questions over any documentation corpus published in the `llms.txt` standard. Built for citation rigor, hybrid retrieval precision, observability, and CI-gated regression safety.**

| Field | Value |
|---|---|
| **Authors** | Rajive Pai, Shobha Pai |
| **Document version** | 2.1 |
| **Document status** | Approved for implementation |
| **Product codename** | DocSense |
| **Companion product** | DocSense Crawler (separate PRD) |
| **Contract** | `llms-txt-contract.md` (open standard) |
| **Total estimated effort** | 6 weeks (1 engineer, part-time) |
| **Demo source** | Stripe (`https://docs.stripe.com/llms.txt`) |
| **Target deployment** | Local-first (Docker Compose), portable to Kubernetes |
| **Total estimated cloud cost** | $30–50 USD (development + evaluation) |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Goals, Non-Goals, Success Criteria](#2-goals-non-goals-success-criteria)
3. [Platform Context](#3-platform-context)
4. [System Architecture (HLD)](#4-system-architecture-hld)
5. [Detailed Design (LLD) per Phase](#5-detailed-design-lld-per-phase)
6. [Multi-Tenancy Design](#6-multi-tenancy-design)
7. [Technology Stack & Tooling Decisions](#7-technology-stack--tooling-decisions)
8. [Algorithms & Mathematical Foundations](#8-algorithms--mathematical-foundations)
9. [Data Contracts & Test Data](#9-data-contracts--test-data)
10. [API Surface](#10-api-surface)
11. [Coding Standards](#11-coding-standards)
12. [Observability & Explainability](#12-observability--explainability)
13. [Cost Model](#13-cost-model)
14. [Acceptance Criteria per Phase](#14-acceptance-criteria-per-phase)
15. [Risks & Mitigations](#15-risks--mitigations)
16. [Roadmap](#16-roadmap)
17. [Appendices](#17-appendices)

---

## 1. Executive Summary

### 1.1 Problem statement

Enterprise users interact daily with documentation that is structured for humans browsing pages, not for machines extracting answers. Manual search returns ranked link lists; LLM chat without grounding hallucinates. Existing "Ask My Docs" solutions either (a) lock customers into a proprietary ingestion format, or (b) require a separate, fragile pipeline per documentation source.

### 1.2 Solution

**DocSense** is a multi-tenant RAG engine with a single ingestion contract: the open [`llms.txt`](https://llmstxt.org) standard. Any documentation source that publishes (or can be converted to) an `llms.txt` index can be onboarded with a single API call. The engine combines dense vector retrieval (semantic), BM25 sparse retrieval (lexical) fused via Reciprocal Rank Fusion (RRF), a cross-encoder reranker for precision, and a constrained LLM that produces Pydantic-validated answers with verified citations. A RAGAS-based evaluation harness runs in CI and blocks merges on quality regression.

Sources without a native `llms.txt` are converted by the companion product, **DocSense Crawler** — but DocSense itself doesn't know or care where its `llms.txt` came from. That separation of concerns is the architectural keystone.

### 1.3 Senior-engineering signals this project demonstrates

| Capability | Evidence in this product |
|---|---|
| Platform thinking | Source-agnostic ingestion via an open contract |
| Multi-tenancy | Per-source isolation in Qdrant collections |
| Trade-off literacy | ADRs for every non-obvious choice |
| Cost sensitivity | Per-query cost modeling; budget alarms; cache strategy |
| Observability | Distributed tracing, structured logs, SLO dashboards |
| Explainability | `?explain=true` mode surfaces retrieval scores, reranker deltas, validation outcomes |
| Reproducibility | Locked dependencies, containerized infrastructure, deterministic evaluation |
| Regression safety | RAGAS gate on every PR; per-source golden sets versioned with code |

---

## 2. Goals, Non-Goals, Success Criteria

### 2.1 Goals (in priority order)

1. **G1 — Answer quality.** Faithfulness ≥ 0.90 and answer relevancy ≥ 0.85 (RAGAS) per source.
2. **G2 — Citation rigor.** 100% of factual claims cite a retrieved chunk with a verifiable source URL.
3. **G3 — Latency.** p95 end-to-end ≤ 2500ms (cold); ≤ 800ms (cache hit).
4. **G4 — Multi-source isolation.** Per-source collections; one source's re-index never blocks another.
5. **G5 — Observability.** Every request emits a distributed trace, structured log, and cost record.
6. **G6 — Regression safety.** PRs blocked if any RAGAS metric drops > 3% absolute vs main baseline.
7. **G7 — Cost predictability.** p95 cost-per-query ≤ $0.002; monthly alarm at $20.

### 2.2 Non-goals

- ❌ Polished consumer-facing UI (CLI + REST API only)
- ❌ Real-time multi-user authentication / RBAC
- ❌ Cross-source federated search in v1 (deferred to v2; documented in ADR)
- ❌ Real-time document update detection (nightly re-index is acceptable)
- ❌ Fine-tuning embeddings or LLM (separate portfolio project)
- ❌ Non-English queries
- ❌ Production SLAs (this is a portfolio system)

### 2.3 Success criteria

Project is complete when:

- All four phases meet acceptance criteria (Section 14)
- CI pipeline green; RAGAS gate enforced on every PR
- At least two distinct sources (Stripe + one other) successfully onboarded and queryable
- Observability dashboards display the last 100 queries with full traces
- README, PRD, ADRs (8+), runbook committed and lint-clean
- `docker compose up && uv sync && make demo` runs end-to-end on a clean machine

---

## 3. Platform Context

### 3.1 Two-product system

DocSense is one of two products in a documentation-intelligence platform:

```
                    ┌─────────────────────────┐
                    │   DocSense Crawler      │
                    │   (Product B)           │
                    │                         │
                    │  Confluence, Notion,    │
                    │  arbitrary URLs ───────►│  generates llms.txt
                    └─────────────┬───────────┘
                                  │
                                  │ publishes
                                  ▼
                    ┌─────────────────────────┐
                    │      llms.txt           │
                    │   (the open contract)   │
                    │                         │
                    │  Index + markdown files │
                    └─────────────┬───────────┘
                                  │
                                  │ ingested by
                                  ▼
                    ┌─────────────────────────┐
                    │      DocSense           │
                    │      (Product A)        │
                    │                         │
                    │  Multi-tenant RAG       │
                    │  Answers w/ citations   │
                    └─────────────────────────┘
```

### 3.2 Why the contract matters

DocSense treats every source identically. Stripe's `llms.txt` and a Crawler-generated `llms.txt` are indistinguishable to the engine. Consequences:

- **Customers with existing `llms.txt`** (Stripe, Anthropic, Vercel) skip the Crawler entirely.
- **Customers without `llms.txt`** run the Crawler once, host the output, then onboard normally.
- **Two products evolve independently** with their own roadmaps, SLOs, and quality metrics.
- **The contract is open** — DocSense will work with any third-party `llms.txt` generator a customer chooses.

The full contract specification lives in [`llms-txt-contract.md`](./llms-txt-contract.md).

---

## 4. System Architecture (HLD)

### 4.1 Component diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          SOURCE REGISTRATION                                 │
│                                                                              │
│   POST /sources ──▶ Source Registry ──▶ Background indexing job             │
│                          │                                                   │
│                          └──▶ Per-source Qdrant collection created           │
└──────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                          INGESTION PIPELINE (per source, async)              │
│                                                                              │
│   llms.txt ──▶ Fetcher ──▶ Chunker ──▶ Embedder ──▶ Qdrant Writer          │
│   (any URL)   (httpx)    (LlamaIdx)   (bge-m3)    (per-source col)         │
└──────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                          QUERY PIPELINE (runtime)                            │
│                                                                              │
│   POST /query { source_id, question }                                        │
│       │                                                                      │
│       ├─▶ Redis cache lookup                                                 │
│       ├─▶ bge-m3 embedding (dense + sparse)                                  │
│       ├─▶ Qdrant hybrid retrieve (RRF, top 20) — scoped to source_id        │
│       ├─▶ BGE-Reranker (top 5) — skippable on high-confidence               │
│       ├─▶ Prompt assemble (versioned)                                        │
│       ├─▶ GPT-4o-mini via instructor (Pydantic-validated)                    │
│       ├─▶ Runtime citation validator                                         │
│       └─▶ Cached response + emitted trace                                    │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                          OBSERVABILITY PLANE                                 │
│                                                                              │
│   OTel SDK ──▶ Jaeger (traces) ──▶ Loki (logs) ──▶ Prometheus (metrics)    │
│                                                ──▶ Grafana (dashboards)     │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                          EVALUATION LOOP (CI-gated per source)               │
│                                                                              │
│   Per-source golden set ──▶ RAGAS scoring ──▶ GitHub Actions gate           │
│   (Stripe.json, etc.)      (LLM-as-judge)    (3% drift → fail)              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Deployment topology

- **Local (dev + portfolio demo):** Docker Compose. Single machine; persistent volumes for Qdrant, Redis, observability stack.
- **Production path (documented, not implemented):** Same compose → Kubernetes manifests; Qdrant Cloud or self-hosted HA; managed observability.

### 4.3 Query call sequence

```
Client
  │
  ▼
FastAPI ──▶ AuthN/AuthZ stub (passthrough in v1)
  │
  ▼
Query Router ──▶ Cache lookup (hit → return)
  │
  ├─▶ [span: embed.dense]   bge-m3 dense vector
  ├─▶ [span: embed.sparse]  bge-m3 sparse vector
  ├─▶ [span: retrieve]      Qdrant hybrid, scoped to source_id
  ├─▶ [span: rerank]        BGE-Reranker (or skip)
  ├─▶ [span: prompt]        Assemble with citations enforcement
  ├─▶ [span: generate]      GPT-4o-mini via instructor
  ├─▶ [span: validate]      Pydantic + runtime citation checks
  └─▶ [span: respond]       Cache write, emit trace, return
```

---

## 5. Detailed Design (LLD) per Phase

### 5.1 Phase 1 — Ingestion + Hybrid Retrieval (source-agnostic)

#### 5.1.1 Modules

| Module | Path | Responsibility |
|---|---|---|
| `SourceRegistry` | `src/sources/registry.py` | Register/list/delete sources; track index status |
| `LinkHarvester` | `src/ingest/fetch_links.py` | Parse `llms.txt` (any source) → `LinkEntry` records |
| `MarkdownFetcher` | `src/ingest/download_docs.py` | Async-fetch `.md` URLs with rate-limiting, backoff |
| `Chunker` | `src/ingest/chunk_docs.py` | Structure-aware markdown chunking |
| `Embedder` | `src/ingest/embed.py` | Batched bge-m3 dense + sparse inference |
| `QdrantWriter` | `src/ingest/index_chunks.py` | Bulk upsert to source-specific collection |
| `IndexingJob` | `src/sources/jobs.py` | Async job orchestration with status tracking |

#### 5.1.2 Chunking strategy

Chunking is the single most consequential decision in the entire ingestion pipeline. A bad chunker invalidates every downstream investment in retrieval, reranking, and generation quality. This section documents the strategy in depth because every numeric parameter must be defensible, not inherited from tutorials.

##### 5.1.2.1 First principles

A chunk has three different consumers, each with different needs:

| Consumer | Wants | Why |
|---|---|---|
| **Embedder** (bge-m3) | One coherent idea per chunk | Vector represents semantic content; mixed topics → diluted vector |
| **Retriever** (Qdrant + RRF) | Small enough to be precise; large enough to be self-contained | Tiny fragments need many; oversized chunks waste budget on irrelevant content |
| **Generator** (GPT-4o-mini) | Complete context within compact size | Incomplete context → hallucination; oversized context → wasted tokens and cost |

These three pull in different directions. **A rigid token count cannot satisfy all three** — the right answer depends on the *shape* of the content. This pipeline picks the chunk boundary using structure and semantics; token counts are guardrails, not targets.

##### 5.1.2.2 Failure modes we explicitly engineer against

The chunker design below directly mitigates three failure modes observed in naïve "fixed token + overlap" chunkers. Each is illustrated with a Stripe-derived worked example.

###### Failure Mode A — "Surgically Chopped Sentence"

> *Source content (≈420 tokens at the boundary):*
>
> "...The `payment_method` parameter accepts a PaymentMethod ID, a Source ID, or, if `customer` is provided, the customer's default payment method. Returns a 402 `card_declined` if the card is rejected..."
>
> *Fixed 400-token splitter cuts here* ⬇
>
> Chunk N ends: "...the customer's default payment method."
> Chunk N+1 begins: "Returns a 402 `card_declined` if the card is rejected..."

A query like *"What does card_declined mean?"* retrieves chunk N+1 in isolation. The chunk says nothing about *which API* returns this error, *which parameter* triggered it, or *what context* it lives in. The LLM either refuses or fabricates the linkage. A 50-token overlap *might* save it — depending entirely on where the boundary fell relative to the relevant sentence.

**Root cause:** Token-count splitting is blind to semantic boundaries.

**Our mitigation:** Walk the markdown AST; split on header boundaries first, never mid-paragraph.

###### Failure Mode B — "Atomic Bomb In A Tiny Fragment"

> *Source content (≈90 tokens):*
>
> "## Webhook Signing Secrets
>
> When you create a webhook endpoint, Stripe generates a signing secret. Store it securely. Never expose it in client-side code.
>
> ```python
> webhook_secret = 'whsec_...'
> ```"

A "minimum 400 token" rule forces this 90-token section to be merged with an adjacent section — say, "Webhook Idempotency." Now a query about *signing secrets* retrieves a chunk that's 80% about idempotency. The signal-to-noise ratio collapses. The reranker may or may not recover; the LLM definitely wastes tokens reading irrelevant content.

**Root cause:** Forced merging dilutes semantically-coherent small content.

**Our mitigation:** Below-minimum sections are emitted as standalone chunks *with their breadcrumb*, not merged with siblings. The breadcrumb (~20 tokens) provides the contextual anchor that the small body lacks.

###### Failure Mode C — "Code Block Tragedy"

> *Source content:* a 700-token Python tutorial showing webhook verification as a complete script.

A "max 600 tokens" rule splits the script mid-function. Retrieval returns half a function. The LLM tries to explain how to verify webhooks using code that doesn't compile. The user copy-pastes it into production and a webhook handler silently drops events.

**Root cause:** Rigid maximums don't respect natural atomicity of code, tables, and procedures.

**Our mitigation:** Atomic units (code blocks, tables, numbered procedures, definition lists) are *never* split. The chunk is allowed to grow beyond the soft target — even to the hard max — to keep them whole.

##### 5.1.2.3 The four-pass chunking algorithm

The chunker operates in four passes. Each pass has a single responsibility.

**Pass 1 — AST-based structural splitting**

Parse the markdown into an AST. Walk it. Each `##` (h2) section becomes a *candidate chunk*. This honors the document author's own statement of "what belongs together." For sections that contain `###` (h3) sub-sections AND exceed the soft target, recurse one level deeper.

**Pass 2 — Size decision per candidate**

For each candidate chunk:

```
if token_count <= HARD_MAX_TOKENS:
    if token_count >= MIN_CHUNK_TOKENS:
        → emit as-is (it's a natural, well-sized unit)
    else:
        → emit as-is anyway (below-min but semantically coherent)
        → flag for "thin chunk" observability metric
        (rationale: forced merging is worse than thin chunks — see Failure Mode B)

elif token_count > HARD_MAX_TOKENS:
    → recursively split on next-deepest header level
    → if still oversized after recursion, fall through to paragraph-split
    → BUT respect Pass 3 atomicity rules absolutely
```

**Pass 3 — Atomicity guardrail**

Before any split lands, check that no atomic unit crosses the proposed boundary. Atomic units (in order of detection priority):

1. Fenced code blocks (delimited by ` ``` `)
2. Markdown tables
3. Numbered procedures (consecutive `1.`, `2.`, ... at same indent level)
4. Definition lists (markdown `term: definition` blocks)

If a proposed boundary would split an atomic unit, the algorithm **biases the boundary outward** — the chunk grows to encompass the entire atomic unit, even past `HARD_MAX_TOKENS`. The chunk has a *soft cap*, not a *hard limit*. Exception logged: `chunk_oversized_for_atomicity=true`.

**Pass 4 — Breadcrumb prepending and overlap policy**

Each emitted chunk gets, at its top:

```
Section: {h1_title} > {h2_title} > {h3_title}
URL: {source_url}

{chunk_body}
```

The breadcrumb is cheap (typically 15-30 tokens) and replaces the *function* of token-overlap: anchoring the chunk to its origin. Even if the previous chunk and the next chunk are about the same topic, every chunk *self-identifies* its topic.

**Overlap policy (this is the part where we depart from "50 tokens" defaults):**

- **Default overlap: 25 tokens** at the start of each chunk (continuation of the prior chunk's last sentence). This is a *safety net*, intentionally small, configurable, and audited as an experiment.
- **Atomic-unit overlap: full duplication.** If a code block, table, or procedure straddles where a boundary *would* have fallen, the entire atomic unit appears in *both* adjacent chunks. Partial code is useless; full code in both is worth the storage cost.
- **Why 25, not 0, and not 50:** This is the explicit safety-net hypothesis. We expect breadcrumbs to do most of the work; the 25-token tail is insurance against boundary edge cases. The number is small enough to be cheap (~6% overhead vs 12% at 50 tokens) but non-zero to test whether *any* overlap adds measurable value. The experiment in §5.1.2.6 will measure overlap=0 vs overlap=25 head-to-head; we commit to publishing the result and adjusting if 0 wins.

##### 5.1.2.4 Parameter table — every number justified

| Parameter | Value | Justification |
|---|---|---|
| `MIN_CHUNK_TOKENS` | **100** | Below this, bge-m3 embedding vectors are dominated by noise rather than semantic content (empirical: vectors of <100-token inputs cluster tightly regardless of topic). 100 keeps thin chunks usable while flagging them. |
| `SOFT_TARGET_TOKENS` | **500** | Anthropic's contextual retrieval research and OpenAI's RAG benchmarks both find retrieval precision peaks in the 400-600 range for technical content. 500 is the midpoint. Smaller than typical defaults because Stripe API docs are *vertically dense* — one endpoint is one concept. |
| `HARD_MAX_TOKENS` | **1500** | Soft cap, not absolute. Well below bge-m3's 8192 context. Generous enough that atomic units almost never exceed it (largest Stripe code block we measured: ~1100 tokens). When exceeded, the chunker logs and continues. |
| `OVERLAP_TOKENS` | **25** (default, configurable) | Half of the legacy default of 50. Intentional safety-net hypothesis: we expect breadcrumbs to do most of the work; this small overlap is insurance to be tested empirically. |
| `BREADCRUMB_FORMAT` | `Section: {path}\nURL: {url}` | Two lines; ~15-30 tokens; provides topic anchor and citation source in every chunk. Inspired by Anthropic's contextual retrieval (Sept 2024) but uses deterministic structural context instead of an LLM-generated prefix. |
| `ATOMIC_UNITS` | code, tables, procedures, definition lists | Empirically the four content types where partial extraction is worse than no extraction. |
| `RECURSION_DEPTH` | 2 (h2 → h3) | Beyond h3, structural meaning becomes ambiguous in Stripe's docs. Manual inspection of 50 random pages confirmed h4+ is mostly stylistic, not semantic. |

##### 5.1.2.5 Three configurable strategies — chunker is pluggable

The chunker exposes a Strategy interface. v1 ships three strategies; the production default is selected by the experimental result (§5.1.2.6), not pre-chosen.

| Strategy | Description | Hypothesis |
|---|---|---|
| **A. FixedSizeChunker** | Naïve 400-token windows with 50-token overlap; no structure awareness. The baseline. | Worst on precision; included as a comparison baseline. |
| **B. StructureFirstChunker** | The four-pass algorithm above. | Best balance of precision and recall for technical docs. |
| **C. SemanticChunker** | Splits on bge-m3-computed sentence-similarity drops within sections (using a sentence-similarity gradient with threshold 0.55). Falls back to structure when sentences are too short to embed reliably. | May win on prose-heavy concept pages; may lose on dense API references where every parameter is a topic shift. |

All three respect the atomicity guardrail (Pass 3). They differ only in how they detect *topic* boundaries.

##### 5.1.2.6 The chunking experiment (acceptance criterion)

We commit to running, in CI as a one-time experiment before main launch:

1. Build the corpus three times — once per strategy.
2. Run the same 50-question golden set through the full pipeline against each indexed corpus.
3. Measure for each strategy:

| Metric | Definition | Direction |
|---|---|---|
| Context Precision (RAGAS) | Of retrieved chunks, fraction judged relevant | ↑ better |
| Context Recall (RAGAS) | Of ground-truth claims, fraction covered | ↑ better |
| Avg chunks retrieved (after rerank) | Top-5 always; this measures chunk fragmentation | informational |
| Avg tokens shipped to LLM | Sum of chunk tokens in the prompt | ↓ better (cost) |
| Cost per query | End-to-end USD | ↓ better |
| Faithfulness (RAGAS) | Of answer claims, fraction entailed by context | ↑ better |

4. **Publish the comparison table in the README** with real numbers, regardless of outcome. If FixedSize wins (unexpected but possible), we ship it and explain why. The point is data-driven choice, not ideology.

5. **Pick the winning strategy as the production default**, with the others retained as configurable for future re-evaluation.

##### 5.1.2.7 Observability hooks (boundary-level)

Every chunk emitted carries observability metadata that lets future engineers audit chunking quality without re-running:

```
chunk_metadata:
    strategy: enum {fixed, structure_first, semantic}
    token_count: int
    is_thin: bool                    # below MIN_CHUNK_TOKENS
    is_oversized: bool               # above HARD_MAX_TOKENS (atomicity preserved)
    breadcrumb_token_count: int
    overlap_token_count: int
    atomic_units_preserved: list[str]   # e.g., ["code_python", "table"]
    boundary_reason: enum {h2_split, h3_split, paragraph_split, atomic_extend}
```

This metadata flows into both the Qdrant payload and OTel traces. Quality dashboards in Grafana can then aggregate: *"How many thin chunks in source X? How often does atomic-extend fire?"* This makes chunking quality a measurable, monitored property — not a black box.

##### 5.1.2.8 Why no LLM-based contextual prefix (yet)

Anthropic's contextual retrieval research uses a *generated* per-chunk context prefix produced by an LLM. We deliberately use *deterministic structural context* (the breadcrumb) instead. Trade-off accepted:

| Approach | Cost | Quality ceiling | Reproducibility |
|---|---|---|---|
| Anthropic contextual (LLM-generated) | ~$1 per 1000 chunks indexed | Highest reported | Non-deterministic; re-indexing produces different prefixes |
| Our structural breadcrumb | $0 | Slightly lower | Fully deterministic |

For a portfolio project, **determinism + zero per-chunk cost** outweighs the marginal quality lift. ADR-013 documents this trade-off explicitly and lists the LLM-prefix approach as a deferred v2 experiment.

#### 5.1.3 Other ingestion invariants

- Every chunk carries `source_id` in its payload
- Chunk IDs are deterministic: `hash(source_id + source_url + chunk_index)`
- Re-indexing the same source with the same strategy produces byte-identical chunks (deterministic chunking is an invariant property, tested via golden-file comparison)

#### 5.1.4 Qdrant collection design (per source)

```python
# Pseudo-config (verify against current Qdrant client API)
collection_name = f"docsense_{source_id}"  # e.g., docsense_stripe

vectors_config = {
    "dense": VectorParams(size=1024, distance=Distance.COSINE),
}
sparse_vectors_config = {
    "sparse": SparseVectorParams(),
}

# Indexed payload fields for fast filtering
payload_schema = {
    "section": "keyword",
    "chunk_type": "keyword",
    "has_code": "bool",
    "source_id": "keyword",  # redundant within a collection but useful for cross-source debugging
}
```

#### 5.1.5 Failure modes (ingestion pipeline)

| Failure | Detection | Response |
|---|---|---|
| `llms.txt` fetch 404 | HTTP status | Job → `failed`; emit error event with reason |
| `llms.txt` malformed | Parser exception | Job → `failed`; log first parser line that errored |
| Source `.md` 404 | HTTP status | Log warn; record in job's `failed_downloads`; continue |
| 429 rate limit | Header + status | Exponential backoff with jitter; max 3 retries |
| Qdrant unavailable | Connection error | Fail fast; job → `retry_scheduled` |
| Embedding OOM | Process killed | Halve batch; resume from last checkpoint |

### 5.2 Phase 2 — Cross-Encoder Reranking

#### 5.2.1 Module

```
src/retrieve/rerank.py
    Reranker
        __init__(model_name = "BAAI/bge-reranker-v2-m3")
        rerank(query: str, candidates: list[Chunk], top_k: int = 5) -> list[RerankedChunk]
        should_skip(candidates: list[Chunk]) -> bool   # confidence-based skip logic
```

#### 5.2.2 Skip-on-confidence heuristic

If `candidates[0].score - candidates[1].score > 0.4`, skip reranking. Empirically these cases are already correct; skipping saves ~200ms p95 latency. Logged as `rerank.skipped=true` in the trace for observability.

#### 5.2.3 Latency budget for rerank step

| Operation | Budget |
|---|---|
| Tokenize 20 (q, d) pairs | 20 ms |
| Forward pass (MPS / CUDA) | 180 ms |
| Sort and slice | 1 ms |
| **Total** | **~200 ms** |

### 5.3 Phase 3 — Citation-Enforced Generation

#### 5.3.1 Three-layer hallucination defense

| Layer | Mechanism | Prevents |
|---|---|---|
| 1. Prompt | Strict system prompt with refusal clause | Off-context speculation |
| 2. Schema | Pydantic model with min-length citations | Missing source references |
| 3. Runtime | Post-generation validator | Hallucinated chunk IDs, broken spans |

#### 5.3.2 Response schema

```
Citation:
    chunk_id: str           # must match a retrieved chunk's ID
    source_url: HttpUrl     # used for direct link to docs
    quoted_span: str        # exact verbatim text from chunk
    relevance: float ∈ [0, 1]

Answer:
    answer_text: str
    citations: list[Citation]
    confidence: enum { high, medium, low, insufficient_context }
    refused: bool
    source_id: str          # which source this answer came from
    trace_id: str
    total_cost_usd: float
    total_duration_ms: int
```

#### 5.3.3 Runtime validator

After LLM returns a Pydantic-conformant response, validator confirms:

1. Every `chunk_id` is in the retrieved-and-reranked set
2. Every `quoted_span` is a verbatim substring of its referenced chunk
3. Every `source_url` matches the chunk's source URL
4. If `refused=true`, citations may be empty; otherwise must be ≥ 1

Failure → mark response invalid, retry once with stricter prompt, then refusal.

### 5.4 Phase 4 — Observability + CI-Gated Evaluation

#### 5.4.1 Per-source golden sets

`tests/golden_sets/{source_id}.json` — one file per onboarded source. Each entry:

```
{
    question_id: str
    question: str
    type: enum { semantic, keyword, mixed, adversarial }
    expected_section: str
    expected_keywords: list[str]
    ground_truth_answer: str
    version: int
    added_in_commit: str
}
```

#### 5.4.2 RAGAS gate in CI

On every PR:

1. Spin up full stack (Qdrant, Redis, OTel)
2. For each onboarded source, run its golden set through the pipeline
3. RAGAS scores each response on Faithfulness, Answer Relevancy, Context Precision, Context Recall
4. Compare to per-source baseline in `evaluation/baselines.json`
5. **Gate:** if any metric drops > 3% absolute on any source → CI fails
6. On merge to main: baseline auto-updates per source

#### 5.4.3 Observability stack

| Layer | Tool | Purpose |
|---|---|---|
| Tracing | OpenTelemetry SDK + Jaeger | End-to-end traces with per-span timing |
| Logging | `structlog` + Loki | Structured JSON logs queryable by `trace_id` |
| Metrics | OTel Metrics + Prometheus | Latency histograms, cost counters, hit rates |
| Dashboards | Grafana | p50/p95/p99 latency, cost/day, RAGAS trends |
| Alerts | Grafana Alerting | Cost > $X/day, p95 > 3s, faithfulness < 0.85 |

---

## 6. Multi-Tenancy Design

### 6.1 The collection-per-source pattern (ADR-009)

Each registered source gets its own Qdrant collection named `docsense_{source_id}`. Examples:

- `docsense_stripe`
- `docsense_anthropic`
- `docsense_internal_wiki`

### 6.2 Why this pattern

| Benefit | Detail |
|---|---|
| Re-index isolation | Re-indexing Stripe doesn't touch Anthropic's collection |
| Per-source quotas | Future: different SLAs per source |
| Embedding model migration | Upgrade one source at a time |
| Backup/restore granularity | Restore just one source without affecting others |
| Clean deletion | `DELETE /sources/stripe` drops the entire collection — instant, no orphan chunks |

### 6.3 What this pattern sacrifices

- Cross-source queries require app-level fan-out (acceptable; cross-source is rare and out of v1 scope)
- More collections to monitor — mitigated by uniform naming and a single Grafana dashboard variable

### 6.4 Source lifecycle states

```
unregistered → registered → indexing → ready → re-indexing → ready
                                  ↓
                               failed (manual restart required)
                                  ↓
                            deleted (collection dropped)
```

State transitions emit events to OTel for observability.

---

## 7. Technology Stack & Tooling Decisions

> **Language choice:** Python. Despite the author's TypeScript background, the production RAG ecosystem (LlamaIndex, RAGAS, sentence-transformers, FastEmbed, instructor, Pydantic) is Python-first. Choosing languages by ecosystem fit rather than personal comfort is itself a senior signal. This decision is captured in ADR-001.

### 7.1 Stack table

| Layer | Selected | Rationale |
|---|---|---|
| Language | Python 3.11 | Ecosystem dominance for RAG tooling |
| Package mgr | `uv` | 10-100× faster than pip; modern lockfile |
| Vector DB | Qdrant (self-hosted) | Native hybrid search; multi-collection isolation; free |
| Embeddings | BAAI/bge-m3 (FastEmbed) | Dense + sparse + ColBERT in one pass; offline |
| Chunking | LlamaIndex `MarkdownNodeParser` | Header-aware; respects code blocks |
| Reranker | BAAI/bge-reranker-v2-m3 | Quality ≈ Cohere Rerank 3 at $0 |
| LLM (generation) | GPT-4o-mini | Cheapest with strict JSON + tool calling |
| LLM (judge) | GPT-4o | Highest faithfulness per RAGAS benchmarks |
| Schema | Pydantic v2 | Industry standard for AI APIs |
| LLM client | `instructor` | Auto-retries on malformed JSON; first-class Pydantic |
| API server | FastAPI | Async-native; OpenAPI auto-gen; Pydantic-integrated |
| Job queue | FastAPI `BackgroundTasks` (v1) → Celery (future) | Sufficient for v1; documented upgrade path |
| Cache | Redis 7 | TTL primitives; persistence; observable |
| Eval | RAGAS | LLM-as-judge industry standard |
| Tracing | OpenTelemetry + Jaeger | Open standard; vendor-neutral |
| Logs | structlog + Loki | Structured-first; pairs with Grafana |
| Metrics | OTel Metrics + Prometheus | Pull-based; SLO-friendly |
| Dashboards | Grafana | Free; integrates with the rest |
| CI/CD | GitHub Actions | Free for public repos |
| Lint | `ruff` | Single tool replacing flake8 + black + isort |
| Type check | `mypy --strict` | Catches more; better Pydantic integration |
| Test | `pytest` + `pytest-asyncio` | Async-first; rich fixtures |
| Containers | Docker Compose | Portable; mirrors Kubernetes structure |

### 7.2 Required ADRs

- ADR-001: Python over TypeScript
- ADR-002: Self-hosted Qdrant over managed Pinecone
- ADR-003: Structure-first chunking with breadcrumbs (supersedes earlier "400-token" default)
- ADR-004: bge-m3 over OpenAI embeddings
- ADR-005: Hybrid retrieval as default
- ADR-006: Three-layer hallucination defense
- ADR-007: OpenTelemetry over vendor APM
- ADR-008: 3% RAGAS regression threshold for CI gate
- ADR-009: Collection-per-source multi-tenancy
- ADR-010: Full re-index (deferred incremental updates)
- ADR-011: BackgroundTasks for v1 job queue (deferred Celery)
- ADR-012: REST API + CLI for source registration (deferred web UI)
- ADR-013: Three configurable chunking strategies; production default chosen by experiment, not fiat. Deterministic structural breadcrumb over LLM-generated contextual prefix (cost + reproducibility trade-off).

---

## 8. Algorithms & Mathematical Foundations

### 8.1 Reciprocal Rank Fusion (RRF)

For dense ranking $R_d$ and sparse ranking $R_s$:

$$\text{RRF}(d) = \frac{1}{k + r_d(d)} + \frac{1}{k + r_s(d)}$$

where $r_*(d)$ is the rank of document $d$ in source $*$ (1-indexed), and $k = 60$ (Cormack et al. 2009).

**Why RRF over score normalization:** Dense scores ∈ [0,1] (cosine), BM25 ∈ [0, ∞). Normalization is unstable across queries; rank fusion is scale-free.

### 8.2 BM25 (sparse)

$$\text{BM25}(D, Q) = \sum_{q \in Q} \text{IDF}(q) \cdot \frac{f(q, D) \cdot (k_1 + 1)}{f(q, D) + k_1 \cdot (1 - b + b \cdot \frac{|D|}{\text{avgdl}})}$$

Defaults: $k_1 = 1.5$, $b = 0.75$.

### 8.3 Dense retrieval (cosine)

bge-m3 outputs L2-normalized vectors, so dot product equals cosine similarity:

$$\text{sim}(\vec{q}, \vec{d}) = \vec{q} \cdot \vec{d}$$

### 8.4 Cross-encoder rerank

Score $g(q, d)$ where $g$ is a transformer attending across the concatenated $[q ; d]$ sequence. ~50× slower per pair than bi-encoder, materially higher accuracy.

### 8.5 RAGAS metrics

| Metric | Definition |
|---|---|
| Faithfulness | Fraction of answer claims entailed by retrieved context |
| Answer Relevancy | Cosine similarity of (LLM-generated question → original question) |
| Context Precision | Fraction of retrieved chunks judged relevant |
| Context Recall | Fraction of ground-truth claims covered by retrieved chunks |

---

## 9. Data Contracts & Test Data

### 9.1 Core Pydantic models

```
Source:
    source_id: str (slug, e.g., "stripe")
    name: str (display name)
    llms_txt_url: HttpUrl
    status: enum { unregistered, indexing, ready, failed, deleted }
    indexed_at: datetime | None
    chunk_count: int
    refresh_schedule: cron-expression | None

LinkEntry:
    url: HttpUrl
    title: str
    section: str
    description: str

Chunk:
    id: str (deterministic: hash(source_id + url + chunk_index))
    text: str
    source_id: str
    source_url: HttpUrl
    section_path: list[str]
    header_path: list[str]
    has_code: bool
    code_langs: list[str]
    token_count: int
    chunk_type: enum

EmbeddedChunk extends Chunk:
    dense_vector: list[float] (length 1024)
    sparse_vector: dict[str, float]

RetrievedChunk extends Chunk:
    retrieval_score: float
    rerank_score: float | None
    rank: int

Citation:
    chunk_id: str
    source_url: HttpUrl
    quoted_span: str
    relevance: float ∈ [0, 1]

Answer:
    answer_text: str
    citations: list[Citation]
    confidence: enum
    refused: bool
    source_id: str
    trace_id: str
    total_cost_usd: float
    total_duration_ms: int
```

### 9.2 Sample data

#### Sample `Source`

```json
{
    "source_id": "stripe",
    "name": "Stripe API Documentation",
    "llms_txt_url": "https://docs.stripe.com/llms.txt",
    "status": "ready",
    "indexed_at": "2025-11-08T03:00:00Z",
    "chunk_count": 3142,
    "refresh_schedule": "0 3 * * *"
}
```

#### Sample golden question

```json
{
    "question_id": "stripe-q-001",
    "question": "What does the decline code `insufficient_funds` mean?",
    "type": "keyword",
    "expected_section": "Payments > Declines > Decline codes",
    "expected_keywords": ["insufficient_funds", "402"],
    "ground_truth_answer": "The decline code insufficient_funds indicates the card lacks sufficient funds. This is a soft decline; recommended action is to request an alternative payment method.",
    "version": 1,
    "added_in_commit": "abc1234"
}
```

#### Sample trace

```json
{
    "trace_id": "7f4a8e9c1d2b3f5a",
    "source_id": "stripe",
    "spans": [
        { "name": "cache.lookup", "duration_ms": 3, "attrs": { "hit": false } },
        { "name": "embed.dense", "duration_ms": 47, "attrs": { "tokens": 12 } },
        { "name": "embed.sparse", "duration_ms": 49, "attrs": { "nnz": 28 } },
        { "name": "retrieve.hybrid", "duration_ms": 31, "attrs": { "collection": "docsense_stripe", "top_k": 20 } },
        { "name": "rerank", "duration_ms": 198, "attrs": { "skipped": false } },
        { "name": "llm.generate", "duration_ms": 1340, "attrs": { "model": "gpt-4o-mini", "cost_usd": 0.000356 } },
        { "name": "validate.citations", "duration_ms": 2, "attrs": { "passed": true } }
    ]
}
```

---

## 10. API Surface

### 10.1 REST endpoints

```
POST   /sources                       Register a new source (returns job_id)
GET    /sources                       List all registered sources
GET    /sources/{source_id}           Get source details + status
GET    /sources/{source_id}/status    Get current indexing job status
DELETE /sources/{source_id}           Delete source + drop collection
POST   /sources/{source_id}/reindex   Trigger full re-index

POST   /query                         Answer a question (scoped to source_id)
POST   /query?explain=true            Same, with full intermediate state

GET    /health                        Liveness probe
GET    /ready                         Readiness probe (Qdrant + Redis reachable)
GET    /metrics                       Prometheus scrape endpoint
```

### 10.2 Sample `POST /query`

Request:
```json
{
    "source_id": "stripe",
    "question": "How do I refund a partial charge?"
}
```

Response (200):
```json
{
    "answer_text": "To refund a partial charge, ...",
    "citations": [
        {
            "chunk_id": "stripe_refunds_create_0003",
            "source_url": "https://docs.stripe.com/api/refunds/create.md",
            "quoted_span": "Pass the amount parameter to refund a portion",
            "relevance": 0.94
        }
    ],
    "confidence": "high",
    "refused": false,
    "source_id": "stripe",
    "trace_id": "7f4a8e9c1d2b3f5a",
    "total_cost_usd": 0.000356,
    "total_duration_ms": 1675
}
```

### 10.3 CLI

```
docsense sources add --name "Stripe" --url "https://docs.stripe.com/llms.txt"
docsense sources list
docsense sources status stripe
docsense sources delete stripe
docsense query stripe "How do I refund a partial charge?"
docsense query stripe "..." --explain
docsense eval stripe                # run RAGAS against stripe.json golden set
```

The CLI wraps the REST API. No business logic in CLI.

---

## 11. Coding Standards

### 11.1 Style

- `ruff format` with line length 100
- `ruff check` with rules: `E,W,F,N,B,SIM,UP,I,RUF,ASYNC`
- `mypy --strict`; all public functions typed
- Google-style docstrings on public surfaces
- No `from x import *`; no `print()` (use structlog)

### 11.2 Project structure

```
docsense/
├── README.md
├── pyproject.toml
├── uv.lock
├── docker-compose.yml
├── Makefile
├── .env.example
├── .github/workflows/
│   ├── ci.yml             # lint + type + unit + integration
│   └── eval.yml           # RAGAS gate per source
├── docs/
│   ├── PRD.md             # this file
│   ├── llms-txt-contract.md
│   ├── architecture.png
│   ├── architecture.excalidraw
│   ├── runbook.md
│   └── adr/
├── src/
│   ├── config.py
│   ├── models.py
│   ├── telemetry.py
│   ├── sources/
│   │   ├── registry.py
│   │   ├── jobs.py
│   │   └── models.py
│   ├── ingest/
│   ├── retrieve/
│   ├── generate/
│   ├── evaluate/
│   ├── api/
│   └── cli/
├── tests/
│   ├── unit/
│   ├── integration/
│   ├── golden_sets/
│   │   ├── stripe.json
│   │   └── anthropic.json
│   ├── baselines.json
│   └── fixtures/
├── notebooks/             # exploratory; not in CI
└── infra/
    ├── grafana/
    ├── prometheus/
    └── otel/
```

### 11.3 Conventional commits

`feat:`, `fix:`, `refactor:`, `docs:`, `test:`, `chore:`, `perf:`. Atomic commits. Message explains *why*, not *what*.

### 11.4 PR standards

PR description answers: **What changed? Why? How tested? Risk?**

Required CI checks: lint, type, unit, integration, RAGAS gate (per source).

ADR required for any architectural change.

### 11.5 Configuration

Pydantic Settings. All config via env vars. `.env.example` committed. Secrets never logged.

### 11.6 Testing

- Unit tests beside source files
- Integration tests in `tests/integration/`, spin up real Qdrant + Redis
- Coverage targets: ≥ 80% overall, 100% on `src/generate/validators.py`
- Property-based tests via `hypothesis` for chunker invariants

---

## 12. Observability & Explainability

### 12.1 SLOs

| SLO | Target | Window |
|---|---|---|
| p95 latency (cold) | ≤ 2500ms | Rolling 1h |
| p95 latency (cache hit) | ≤ 800ms | Rolling 1h |
| Refusal rate | ≤ 15% | Rolling 24h |
| Citation validity | 100% | Rolling 24h |
| Cost per query (p95) | ≤ $0.002 | Rolling 24h |
| RAGAS faithfulness | ≥ 0.90 | 7-day rolling, per source |

### 12.2 Dashboards (Grafana, committed JSON)

1. **Operations** — latency histograms, error rates, cache hit rate, requests/min, per source
2. **Cost** — cost-per-query distribution, cumulative spend, tokens consumed, per source
3. **Quality** — RAGAS scores over time, refusal rate trend, citation validity rate, per source
4. **Source health** — index status, chunk count per source, last successful indexing, indexing duration

### 12.3 Explainability — `?explain=true`

Returns full intermediate state:

```
{
    answer_text, citations, confidence, refused, ...,
    explanation: {
        retrieval: {
            top_20_chunks: [{ chunk_id, rrf_score, from }],
            rerank_swaps: [{ chunk_id, before_rank, after_rank }],
            rerank_skipped: bool
        },
        prompt: { version_hash, input_tokens },
        generation: { model, output_tokens, stop_reason },
        validation: { schema_pass, citation_pass, spans_verified }
    },
    trace_url: "http://localhost:16686/trace/{trace_id}"
}
```

This is **the killer demo feature.** When you screen-share `?explain=true` in an interview, retrieval scores, reranker swaps, and validation outcomes are all visible. Interviewers will lean forward.

---

## 13. Cost Model

### 13.1 Per-query cost (cache miss baseline)

| Stage | Cost |
|---|---|
| Embedding (local bge-m3) | $0.0000 |
| Hybrid retrieval (Qdrant local) | $0.0000 |
| Reranker (local) | $0.0000 |
| LLM input: ~1812 tokens × $0.15/M | $0.000272 |
| LLM output: ~150 tokens × $0.60/M | $0.000090 |
| **Total** | **~$0.00036** |

### 13.2 Sensitivity table

| Scenario | Cost/query | Notes |
|---|---|---|
| Baseline | $0.00036 | GPT-4o-mini, 5 chunks of 1.8KB each |
| GPT-4o instead | $0.00891 | 25× more expensive |
| Claude Haiku | $0.00078 | ~2× more |
| Drop reranker | $0.00036 | Quality −15%; latency −200ms |
| Cache hit | $0.00000 | Redis read only |

### 13.3 Monthly forecast

| Usage | Queries/day | Cache hit rate | Monthly cost |
|---|---|---|---|
| Development | 50 | 30% | $0.38 |
| Per RAGAS eval run | 50 × 2 models | n/a | $0.50/run |
| Demo traffic | 200 | 60% | $0.86 |
| Worst-case dev month | 500 + 30 eval runs | 50% | **$18.50** |

Budget alarm at $20/month.

### 13.4 Optimizations

- Redis cache, 1h TTL, keyed by `hash(source_id + normalized_question)`
- Confidence-based reranker skip on wide-margin retrievals
- Batch embedding (32 chunks/batch)
- GPT-4o-mini default; escalate to GPT-4o only on `low_confidence` retries
- OpenAI prompt caching headers where supported

---

## 14. Acceptance Criteria per Phase

### Phase 1 — Ingestion + Hybrid Retrieval

- [ ] `POST /sources` registers a new source; indexing job runs async
- [ ] `GET /sources/{id}/status` reports `indexing → ready` with chunk count
- [ ] ≥ 95% of `llms.txt` links successfully fetched and indexed for Stripe
- [ ] All three chunking strategies (Fixed, StructureFirst, Semantic) implemented behind the Strategy interface
- [ ] Chunker invariant tests pass: zero atomic units (code blocks, tables) split across chunks; every chunk carries breadcrumb; deterministic byte-identical output on re-run
- [ ] **Chunking experiment executed and published**: 50 golden questions × 3 strategies, results table in README with Context Precision, Recall, Faithfulness, cost-per-query, and chosen production default
- [ ] Per-chunk observability metadata (strategy, is_thin, is_oversized, atomic_units_preserved, boundary_reason) visible in OTel traces
- [ ] Hybrid retrieval returns 20 results in p95 < 100ms
- [ ] Documented comparison: vector-only vs BM25-only vs hybrid (hybrid wins ≥ 80% on Stripe golden set)
- [ ] Unit test coverage > 80%; property-based tests (hypothesis) for chunker invariants
- [ ] ADRs 001-005 and ADR-013 committed
- [ ] Second source successfully onboarded (proves multi-tenancy)

### Phase 2 — Cross-Encoder Reranking

- [ ] Reranker latency p95 ≤ 250ms on 20 candidates
- [ ] Documented A/B: hybrid-only vs hybrid+rerank, showing ≥ 5-point RAGAS improvement
- [ ] Skip-on-confidence triggers on > 30% of golden queries; verified in traces
- [ ] Reranker unit tests cover ordering, ties, skip logic

### Phase 3 — Citation-Enforced Generation

- [ ] 100% of non-refusal responses include ≥ 1 valid citation
- [ ] Runtime validator rejects ≥ 99% of synthetically-corrupted responses
- [ ] Refusal rate on out-of-corpus questions ≥ 95% (test: 10 questions about an unrelated source)
- [ ] Prompt versioning live; prompt hash in every trace
- [ ] `?explain=true` returns full intermediate state
- [ ] ADR-006 committed

### Phase 4 — Observability + CI Evaluation

- [ ] OTel traces visible in Jaeger for every query
- [ ] Four Grafana dashboards committed (Operations, Cost, Quality, Source Health)
- [ ] All 6 SLOs measured and dashboarded
- [ ] RAGAS evaluation runs in CI in < 10 minutes for each registered source
- [ ] PR successfully blocked when a deliberate regression is introduced
- [ ] Cost alarms tested
- [ ] Runbook covers: add a source, update prompt, handle failed eval, roll back
- [ ] ADRs 007-008 committed

### Platform-Level

- [ ] Two distinct sources successfully onboarded (Stripe + one other)
- [ ] Per-source isolation verified (re-indexing source A does not affect source B)
- [ ] Cross-source filtering correctness tested
- [ ] All 13 ADRs committed

---

## 15. Risks & Mitigations

| # | Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|---|
| R1 | bge-m3 quality below OpenAI on certain corpora | M | M | A/B test per source; fallback documented in ADR-004 |
| R2 | RAGAS LLM-judge variance produces flaky CI | H | M | 3-run averaging; 3% threshold; judge model version pinned |
| R3 | Apple Silicon MPS instability with large batches | M | L | Batch size 32; CPU fallback on OOM |
| R4 | A source publishes malformed `llms.txt` | M | M | Defensive parser; clear error events; job → failed with diagnosable reason |
| R5 | OpenAI cost overrun | L | H | Budget alarms; auto-disable at $20/month |
| R6 | Reranker latency degrades UX | M | M | Skip-on-confidence; observable in dashboards |
| R7 | Golden set drift makes baseline meaningless | M | H | Versioned; ramp-test new questions for 1 week |
| R8 | Adversarial prompts bypass citation defense | L | H | Three-layer defense; adversarial questions in golden set |
| R9 | Re-indexing during query traffic causes errors | M | M | Per-source collection isolation; queries route to old collection until new is `ready` |

### 15.1 Trade-offs explicitly accepted

| Decision | We accept | We sacrifice |
|---|---|---|
| Local-first stack | Free, private, portable | Slower than managed; setup complexity |
| Hybrid retrieval default | Better recall on keywords | +30ms p50 vs vector-only |
| Cross-encoder reranking | +5–15% quality | +200ms p95 |
| Pydantic + runtime validation | Citation rigor | +10ms p95 |
| 3% CI gate threshold | Quality safety | Occasional flaky PRs |
| GPT-4o-mini default | 25× cheaper | Marginally lower quality on edges |
| Full re-index (v1) | Simplicity | Wasted work on small updates |
| BackgroundTasks (v1) | No new infra | Limited concurrency vs Celery |

---

## 16. Roadmap

### Week 1 — Foundation
Project skeleton, uv, Docker Compose, Qdrant, observability stack. Source registry skeleton.

### Week 2 — Ingestion (source-agnostic)
Link harvester (generalized), markdown fetcher, chunker, embedder. Stripe successfully indexed.

### Week 3 — Retrieval & Reranking
Hybrid retrieval. BGE-Reranker. 10-question Stripe golden set. v0 baseline.

### Week 4 — Generation & Citations
Prompt versioning. Pydantic + instructor. Runtime validator. `?explain=true`. FastAPI live.

### Week 5 — Observability & Evaluation
OTel wired everywhere. Four Grafana dashboards. Cost telemetry. RAGAS gate. Golden set → 50.

### Week 6 — Multi-tenancy proof + Polish
Onboard a second source (proves the pattern). All ADRs reviewed. README, runbook, demo video.

---

## 17. Appendices

### Appendix A — Glossary

| Term | Definition |
|---|---|
| RAG | Retrieval-Augmented Generation |
| RRF | Reciprocal Rank Fusion |
| Bi-encoder | Embedding model encoding query and doc separately |
| Cross-encoder | Reranker scoring (q, d) jointly |
| Faithfulness | RAGAS metric: answer stays within context |
| Golden set | Curated Q&A pairs as ground truth for eval |
| SLO | Service Level Objective |
| ADR | Architecture Decision Record |
| `llms.txt` | Open standard documentation index for AI ingestion (see contract doc) |

### Appendix B — References

- Cormack et al. (2009). *Reciprocal Rank Fusion outperforms Condorcet and individual Rank Learning Methods.* SIGIR.
- Chen, J. et al. (2024). *BGE-M3.* arXiv:2402.03216.
- Robertson & Zaragoza (2009). *BM25 and Beyond.* Foundations and Trends in IR.
- Lewis, P. et al. (2020). *Retrieval-Augmented Generation for Knowledge-Intensive NLP Tasks.* NeurIPS.
- ES, S. et al. (2023). *RAGAS.* arXiv:2309.15217.
- llms.txt proposal: <https://llmstxt.org>
- OpenTelemetry semantic conventions: <https://opentelemetry.io/docs/specs/semconv/>

### Appendix C — CXO recruiter evaluation rubric

| Question | Where the answer lives |
|---|---|
| Do they understand naïve RAG's failure modes? | §1.1, §5.3.1 |
| Do they grasp dense vs sparse trade-offs? | §8 |
| Cost discipline? | §13 |
| Regression safety? | §5.4.2, ADR-008 |
| Observability and explainability? | §12 |
| What they didn't build, and why? | §2.2 |
| Platform thinking? | §3, §6 |
| Multi-tenancy understanding? | §6 |
| Hand-off readiness? | §16, runbook |

---

**Document control**

| Version | Date | Author | Change |
|---|---|---|---|
| 1.0 | — | R. Pai, S. Pai | Initial single-product PRD |
| 2.0 | — | R. Pai, S. Pai | Split into Product A (DocSense) + B (Crawler); multi-tenancy added |
| 2.1 | — | R. Pai, S. Pai | Chunking redesign: three configurable strategies, failure-modes worked examples, breadcrumb-based context, all parameters justified, ADR-013 added |

*End of document.*
