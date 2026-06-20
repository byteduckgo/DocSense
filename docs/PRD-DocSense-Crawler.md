# DocSense Crawler — Product Requirements Document

> **A documentation source adapter that converts arbitrary documentation corpora (websites, GitHub repositories, and future SaaS sources) into the open `llms.txt` standard. Outputs are directly consumable by DocSense or any other `llms.txt`-compliant RAG engine.**

| Field                          | Value                                                              |
| ------------------------------ | ------------------------------------------------------------------ |
| **Authors**                    | Rajive, Shobha                                                     |
| **Document version**           | 1.0                                                                |
| **Document status**            | Approved for implementation                                        |
| **Product codename**           | DocSense Crawler                                                   |
| **Companion product**          | DocSense (separate PRD)                                            |
| **Contract**                   | `llms-txt-contract.md` (open standard)                             |
| **Total estimated effort**     | 3 weeks (after DocSense v1 ships)                                  |
| **Demo target**                | Anthropic docs (no native `llms.txt` at project start; ideal demo) |
| **Target deployment**          | Local-first (Docker Compose), portable to Kubernetes               |
| **Total estimated cloud cost** | $5–15 USD (LLM categorization)                                     |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Goals, Non-Goals, Success Criteria](#2-goals-non-goals-success-criteria)
3. [Platform Context](#3-platform-context)
4. [System Architecture (HLD)](#4-system-architecture-hld)
5. [Detailed Design (LLD)](#5-detailed-design-lld)
6. [Adapter Pattern](#6-adapter-pattern)
7. [Technology Stack & Decisions](#7-technology-stack--decisions)
8. [Algorithms](#8-algorithms)
9. [Data Contracts & Test Data](#9-data-contracts--test-data)
10. [API & CLI Surface](#10-api--cli-surface)
11. [Coding Standards](#11-coding-standards)
12. [Observability](#12-observability)
13. [Cost Model](#13-cost-model)
14. [Acceptance Criteria](#14-acceptance-criteria)
15. [Risks & Mitigations](#15-risks--mitigations)
16. [Roadmap](#16-roadmap)
17. [Appendices](#17-appendices)

---

## 1. Executive Summary

### 1.1 Problem statement

The `llms.txt` standard is gaining adoption (Stripe, Anthropic, Vercel, and others publish one), but the vast majority of documentation sources do not. Customers with internal Confluence wikis, Notion workspaces, MkDocs sites, GitHub-hosted markdown, or generic HTML docs cannot use any `llms.txt`-compliant RAG engine without first converting their corpus.

### 1.2 Solution

**DocSense Crawler** is a documentation adapter that ingests arbitrary source formats and emits a standards-compliant `llms.txt` index plus a tree of normalized markdown files. The output is statically hostable and immediately consumable by DocSense or any other `llms.txt`-compliant ingestion engine.

v1 ships with two adapters that prove the pattern:

- **WebCrawlerAdapter** — sitemap-driven HTML → markdown conversion (covers ~85% of public doc sites)
- **GitHubMarkdownAdapter** — clones a repo, finds `.md` files, emits `llms.txt`

The `BaseAdapter` interface is the architectural keystone: Confluence, Notion, GitBook, and SaaS adapters can be added without touching the core pipeline.

### 1.3 Senior-engineering signals this product demonstrates

| Capability                 | Evidence                                                               |
| -------------------------- | ---------------------------------------------------------------------- |
| Platform/contract thinking | Output strictly conforms to open `llms.txt` standard                   |
| Adapter / Strategy pattern | `BaseAdapter` interface; v1 ships 2, future N                          |
| LLM cost discipline        | One cheap LLM call per ~50 docs for categorization                     |
| Resilience                 | Politeness controls, retries, robots.txt compliance                    |
| Restraint                  | 2 adapters, not 10 — earned, not over-built                            |
| Reusability                | Output is hostable as a static site; works with any compliant consumer |

---

## 2. Goals, Non-Goals, Success Criteria

### 2.1 Goals (priority order)

1. **G1 — Standard compliance.** Generated `llms.txt` validates against the contract specification with zero deviations.
2. **G2 — Extraction accuracy.** ≥ 95% of source pages produce non-empty, semantically-valid markdown output.
3. **G3 — Section categorization quality.** ≥ 90% of pages assigned to a human-reasonable section (judged on 30-page sample per source).
4. **G4 — Politeness.** Zero rate-limit incidents from crawled sources; respects `robots.txt`.
5. **G5 — Reusability.** Output served at a configurable HTTP endpoint is directly ingestible by DocSense without modification.
6. **G6 — Adapter extensibility.** Adding a new adapter requires no changes to core pipeline modules.

### 2.2 Non-goals

- ❌ Confluence, Notion, GitBook adapters in v1 (documented as v2 with explicit `BaseAdapter` contract)
- ❌ Real-time change detection in source (full re-crawl is acceptable)
- ❌ JavaScript-rendered SPAs requiring headless browsers (deferred; document as known limitation)
- ❌ Authentication for private sources in v1 (public sources only; auth deferred to v2)
- ❌ Incremental output updates (full re-emit each run)
- ❌ A polished UI

### 2.3 Success criteria

Project is complete when:

- Both adapters successfully produce contract-compliant `llms.txt` for at least one real source each
- DocSense successfully ingests Crawler-generated `llms.txt` end-to-end with no manual intervention
- Generated output is browsable, static-hostable, and DocSense's existing pipeline doesn't know the difference between this and Stripe's native `llms.txt`
- README + PRD + ADRs (5+) + runbook committed
- `docker compose up && uv sync && make crawl-demo` produces a working `llms.txt` for the demo source

---

## 3. Platform Context

### 3.1 Relationship to DocSense

```
   ┌────────────────────────┐
   │   Doc source (e.g.,    │
   │   Anthropic, internal  │
   │   wiki, GitHub repo)   │
   └────────────┬───────────┘
                │
                ▼
   ┌────────────────────────┐
   │  DocSense Crawler      │  ◀── this product
   │                        │
   │  Adapter → Normalize → │
   │  Categorize → Emit     │
   └────────────┬───────────┘
                │
                ▼
   ┌────────────────────────┐
   │  llms.txt + .md files  │  ◀── the contract
   │  (statically hosted)   │
   └────────────┬───────────┘
                │
                ▼
   ┌────────────────────────┐
   │  DocSense (RAG engine) │  ◀── Product A — separately developed
   └────────────────────────┘
```

The Crawler **knows nothing about DocSense**. Its only obligation is contract compliance. This is the core architectural discipline.

### 3.2 Sequencing decision

Per the platform PRD, **DocSense ships first** using Stripe's native `llms.txt`. Crawler development begins after DocSense v1 acceptance, so Crawler design benefits from real ingestion-side feedback.

---

## 4. System Architecture (HLD)

### 4.1 Component diagram

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              ADAPTER LAYER                                  │
│                                                                             │
│  ┌────────────────────┐   ┌────────────────────┐   ┌────────────────────┐   │
│  │ WebCrawlerAdapter  │   │ GitHubMarkdown     │   │ BaseAdapter (ABC)  │   │
│  │ (sitemap-driven)   │   │ Adapter            │   │ — extension point  │   │
│  └─────────┬──────────┘   └─────────┬──────────┘   └────────────────────┘   │
│            │                        │                                       │
│            └────────────┬───────────┘                                       │
└─────────────────────────┼───────────────────────────────────────────────────┘
                          │
                          ▼ emits RawDoc[]
┌─────────────────────────────────────────────────────────────────────────────┐
│                        NORMALIZATION LAYER                                  │
│                                                                             │
│  HTML → markdown (trafilatura) → cleanup → frontmatter assembly             │
└─────────────────────────────┬───────────────────────────────────────────────┘
                              │
                              ▼ NormalizedDoc[]
┌─────────────────────────────────────────────────────────────────────────────┐
│                        CATEGORIZATION LAYER                                 │
│                                                                             │
│  URL-path heuristic ──▶ LLM bucketing (GPT-4o-mini) ──▶ Section assignment  │
└─────────────────────────────┬───────────────────────────────────────────────┘
                              │
                              ▼ CategorizedDoc[]
┌─────────────────────────────────────────────────────────────────────────────┐
│                        EMIT LAYER                                           │
│                                                                             │
│  Write llms.txt ──▶ Write content/*.md ──▶ Serve over HTTP (optional)       │
└─────────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────────┐
│                          JOB ORCHESTRATION                                  │
│                                                                             │
│  POST /jobs ──▶ async crawl pipeline ──▶ GET /jobs/{id}/status              │
└─────────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Sequence — one crawl job

```
Client submits job
  │
  ▼
POST /jobs { source_type, config }
  │
  ├─▶ Job persisted; returns job_id
  │
  └─▶ Background task starts:
      │
      ├─▶ [span: adapter.discover]    list candidate URLs/paths
      ├─▶ [span: adapter.fetch]       fetch raw content per URL
      ├─▶ [span: normalize]           HTML → markdown
      ├─▶ [span: categorize]          assign sections (heuristic + LLM)
      ├─▶ [span: emit.llms_txt]       write index file
      ├─▶ [span: emit.markdown]       write content files
      └─▶ [span: serve]               (optional) start HTTP server
```

### 4.3 Output topology

```
output/
├── llms.txt                          # the contract index
└── content/
    ├── api-reference/
    │   ├── charges-create.md
    │   ├── charges-retrieve.md
    │   └── ...
    ├── webhooks/
    │   └── ...
    └── tutorials/
        └── ...
```

Every `.md` file embeds YAML frontmatter:

```yaml
---
url: https://docsense-crawler.example.com/content/api-reference/charges-create.md
title: Create a Charge
section: API Reference
description: How to create a charge against a customer
source_original_url: https://anthropic.com/api/messages
extracted_at: 2025-11-08T10:23:00Z
adapter: WebCrawlerAdapter
adapter_version: 1.0.0
---
# Create a Charge

[normalized markdown content]
```

---

## 5. Detailed Design (LLD)

### 5.1 Modules

| Module                  | Path                          | Responsibility                                 |
| ----------------------- | ----------------------------- | ---------------------------------------------- |
| `BaseAdapter`           | `src/adapters/base.py`        | Abstract interface for any source adapter      |
| `WebCrawlerAdapter`     | `src/adapters/web_crawler.py` | Sitemap-driven HTML discovery + fetch          |
| `GitHubMarkdownAdapter` | `src/adapters/github_md.py`   | Clone repo + discover `.md` files              |
| `HTMLToMarkdown`        | `src/normalize/html_to_md.py` | `trafilatura` wrapper with cleanup             |
| `Categorizer`           | `src/normalize/categorize.py` | Heuristic + LLM bucketing                      |
| `LLMsTxtEmitter`        | `src/emit/llms_txt.py`        | Writes contract-compliant `llms.txt`           |
| `MarkdownEmitter`       | `src/emit/markdown_files.py`  | Writes individual `.md` files with frontmatter |
| `StaticServer`          | `src/serve/server.py`         | Optional FastAPI server hosting output         |
| `JobOrchestrator`       | `src/jobs/orchestrator.py`    | Async pipeline with status tracking            |

### 5.2 WebCrawlerAdapter design

#### 5.2.1 Discovery (sitemap-first)

1. Fetch `{base_url}/sitemap.xml`
2. If sitemap is an index (links to other sitemaps), recurse with depth limit 2
3. Filter URLs by include/exclude patterns from config
4. Deduplicate
5. If no sitemap found → fall back to manual seed list from config; log warning
6. Result: `list[CandidateURL]`

#### 5.2.2 Politeness

- Respect `robots.txt`; honor `Crawl-Delay` directive
- User-agent: `DocSenseCrawler/1.0 (+contact-url)` — identifies itself transparently
- Default: 1 RPS per host; configurable
- Bounded concurrency (semaphore = 3 per host)
- Retry on 429/5xx with exponential backoff + jitter; max 3 retries

#### 5.2.3 Failure handling

| Failure                     | Detection                         | Response                                                    |
| --------------------------- | --------------------------------- | ----------------------------------------------------------- |
| Sitemap not found           | 404                               | Log warn; require config seed list or fail with clear error |
| `robots.txt` disallows path | Robots check                      | Skip URL; log debug                                         |
| Page 404                    | HTTP status                       | Skip; record in `failed_urls.json`                          |
| 429                         | Status                            | Backoff (2s, 4s, 8s); fail URL after 3 retries              |
| HTML extraction empty       | trafilatura returns empty         | Skip; record reason                                         |
| JS-rendered page            | Empty extraction + high HTML size | Skip; mark `js_rendered=true` in failed log                 |

### 5.3 GitHubMarkdownAdapter design

#### 5.3.1 Discovery

1. Shallow-clone repo via `git clone --depth 1 {repo_url}`
2. Walk repo tree, filter `*.md` files
3. Apply include/exclude patterns from config (e.g., exclude `node_modules/**`)
4. Result: `list[CandidatePath]`

#### 5.3.2 Frontmatter extraction

- Parse YAML frontmatter from each file (if present); preserves source-provided `title`, `section`, etc.
- Use repo-level config (e.g., `mkdocs.yml`, `docs/_sidebar.md`) to enrich categorization

### 5.4 Normalization layer

#### 5.4.1 HTML → markdown

- Primary tool: `trafilatura` (high-quality content extraction; strips nav, footer, ads)
- Fallback: `markdownify` for cases where `trafilatura` returns suspiciously short output
- Post-processing:
  - Normalize relative URLs to absolute (or rewrite to internal paths)
  - Preserve fenced code blocks verbatim
  - Strip empty paragraphs and excessive whitespace
  - Convert HTML tables to markdown tables

#### 5.4.2 Quality checks

After normalization, reject docs where:

- Length < 200 characters (likely extraction failure)
- Markdown is > 80% link text (likely a nav page)
- Detected content-type does not match expected (e.g., HTML when expecting markdown)

Rejected docs go to `failed_normalizations.json` for review.

### 5.5 Categorization layer

#### 5.5.1 Two-pass strategy

**Pass 1 — URL-path heuristic (free, fast).**

Look at URL path segments. `/docs/payments/charges/create` → guess section "Payments".

If URL path is ambiguous (`/getting-started`, `/v1/...`) → mark as "Uncategorized" and pass to LLM.

**Pass 2 — LLM bucketing (cheap, accurate).**

For uncategorized docs:

1. Pre-compute a list of candidate sections by clustering URL prefixes
2. Send a batch of N (title, first 200 chars of content) pairs to GPT-4o-mini with the candidate sections
3. LLM returns assignment per doc
4. Cost: ~$0.001 per 50 docs

#### 5.5.2 Categorization quality measurement

Hand-judge a 30-page sample per crawled source. Track:

- % assigned correctly (target ≥ 90%)
- % "Uncategorized" (target ≤ 5%)

Tracked over time as a quality metric.

### 5.6 Emit layer

#### 5.6.1 `llms.txt` format compliance

The emit module strictly follows the contract spec (`llms-txt-contract.md`). At minimum:

```
# {Project Title}

> {Brief description}

## {Section Name}

- [{title}]({url}): {description}
- [{title}]({url}): {description}

## {Another Section}

- [{title}]({url}): {description}
```

A schema validator runs on the output before write. Any deviation → fail loudly.

#### 5.6.2 Markdown file naming

Files are named: `content/{section_slug}/{page_slug}.md`. Slugs use `python-slugify` with consistent rules.

### 5.7 Static serve

After emit, optionally start a FastAPI server that serves the output tree as static files. URL structure mirrors the file tree exactly. CORS enabled by default for cross-origin RAG ingestion.

---

## 6. Adapter Pattern

### 6.1 The `BaseAdapter` interface

```
BaseAdapter (ABC):
    name: str                                  # adapter identifier
    version: str                               # semver

    async def discover(self, config) -> list[CandidateRef]
        # Return refs to candidate documents (URLs, paths, IDs)

    async def fetch(self, ref: CandidateRef) -> RawDoc
        # Fetch raw content for one ref

    def validate_config(self, config) -> None
        # Validate adapter-specific config; raise on invalid

    @property
    def supports_robots_txt(self) -> bool
        # True if this adapter respects robots.txt
```

### 6.2 Why this interface matters

The interface is the **single most important design artifact** in DocSense Crawler. It defines the contract for _future_ adapters. A reviewer reading the codebase should immediately see:

> "Adding a Notion adapter would mean implementing `discover()` (list pages via Notion API) and `fetch()` (download a page). Everything else — normalization, categorization, emission — is reused."

Make this clarity visible in the README.

### 6.3 Future adapters (documented, not implemented)

| Adapter                | Discovery                       | Fetch                  | Auth needed       |
| ---------------------- | ------------------------------- | ---------------------- | ----------------- |
| `ConfluenceAdapter`    | REST API listing                | Page export            | OAuth + API token |
| `NotionAdapter`        | Search API                      | Block tree → markdown  | Notion API token  |
| `GitBookExportAdapter` | Zip download from GitBook       | Read zipped tree       | None              |
| `MkDocsAdapter`        | Build a local site, walk output | Read from build dir    | None              |
| `SphinxAdapter`        | Read `_build/html/objects.inv`  | Convert RST → markdown | None              |

Each future adapter is ~150–300 lines of new code, zero changes to core modules.

---

## 7. Technology Stack & Decisions

### 7.1 Stack table

| Layer               | Selected                                    | Rationale                                          |
| ------------------- | ------------------------------------------- | -------------------------------------------------- |
| Language            | Python 3.11                                 | Shared with DocSense; ecosystem fit                |
| Package mgr         | `uv`                                        | Same as DocSense                                   |
| HTML extraction     | `trafilatura`                               | Best-in-class content extraction; handles ads, nav |
| Fallback extraction | `markdownify`                               | When trafilatura returns empty                     |
| HTTP client         | `httpx`                                     | Async-native; HTTP/2 support                       |
| robots.txt parser   | `protego`                                   | Reliable; respects RFC 9309                        |
| Git operations      | `dulwich` (pure Python) or `subprocess git` | Avoids native git dependency                       |
| Categorization LLM  | GPT-4o-mini                                 | $0.15/M tokens; sufficient for bucketing           |
| Job orchestration   | FastAPI `BackgroundTasks`                   | Matches DocSense pattern                           |
| Slug generation     | `python-slugify`                            | Mature, handles edge cases                         |
| Schema validation   | Pydantic v2 + custom schema check           | Catch contract drift early                         |
| API server          | FastAPI                                     | Matches DocSense; CORS-friendly for static serve   |
| Lint, type, test    | `ruff`, `mypy --strict`, `pytest`           | Matches DocSense                                   |
| Containers          | Docker Compose                              | Matches DocSense; deployable next to it            |

### 7.2 Required ADRs

- ADR-001: `trafilatura` over `readability-lxml` and `BeautifulSoup`
- ADR-002: Adapter pattern (Strategy) over conditional logic
- ADR-003: Sitemap-first discovery with manual seed fallback
- ADR-004: GPT-4o-mini for categorization (cost trade-off documented)
- ADR-005: v1 ships 2 adapters (WebCrawler + GitHubMarkdown)
- ADR-006: Full re-crawl over incremental detection

---

## 8. Algorithms

### 8.1 HTML extraction (trafilatura)

`trafilatura` uses an ensemble of heuristics:

- DOM depth analysis
- Text density per node
- Class/ID heuristics (e.g., `.content`, `#main`)
- Boilerplate detection (nav, header, footer, ad blocks)

For our purposes: black box; we measure quality empirically via the 30-page hand-judge sample.

### 8.2 LLM categorization

Single-shot batched prompt:

```
You are categorizing documentation pages into sections.

Available sections: {section_list}

For each page below, output JSON: { page_id: int, section: str }

Pages:
1. Title: "Create a Charge"
   First 200 chars: "POST /v1/charges Creates a new charge object..."
2. Title: "..."

Return only JSON array. If a page doesn't fit, use "Other".
```

Cost analysis (Section 13): ~$0.001 per 50 docs at GPT-4o-mini pricing.

### 8.3 URL slug generation

`python-slugify` with custom replacements:

- `&` → `and` (Stripe sections use ampersands)
- Strip non-ASCII
- Lowercase
- Replace internal whitespace with `-`
- Max length 80 chars

Deterministic — same input always produces same slug, enabling stable re-crawls.

---

## 9. Data Contracts & Test Data

### 9.1 Core Pydantic models

```
CandidateRef:
    ref_type: enum { url, path, id }
    ref_value: str
    discovered_via: str        # "sitemap", "seed_list", "git_walk"

RawDoc:
    candidate_ref: CandidateRef
    fetched_at: datetime
    content_type: str          # "text/html", "text/markdown"
    raw_body: str
    response_status: int

NormalizedDoc:
    candidate_ref: CandidateRef
    title: str
    body_markdown: str
    extraction_method: str     # "trafilatura", "markdownify", "native"
    word_count: int

CategorizedDoc extends NormalizedDoc:
    section: str
    categorization_method: enum { url_heuristic, llm, manual, fallback }
    categorization_confidence: float

CrawlJob:
    job_id: str
    adapter_name: str
    config: dict
    status: enum { pending, discovering, fetching, normalizing, categorizing, emitting, serving, complete, failed }
    started_at: datetime
    completed_at: datetime | None
    total_candidates: int
    total_emitted: int
    total_failed: int
    output_path: str
    serve_url: str | None
```

### 9.2 Sample data

#### Sample crawl job submission

```json
POST /jobs
{
    "adapter_name": "WebCrawlerAdapter",
    "config": {
        "base_url": "https://docs.anthropic.com",
        "project_name": "Anthropic Docs",
        "include_patterns": ["/docs/**", "/api/**"],
        "exclude_patterns": ["/changelog/**"],
        "max_pages": 500,
        "politeness_rps": 1.0
    },
    "output_path": "/output/anthropic",
    "serve": true,
    "serve_port": 8081
}
```

Response:

```json
{
	"job_id": "job_a1b2c3d4",
	"status": "pending",
	"status_url": "/jobs/job_a1b2c3d4/status"
}
```

#### Sample `llms.txt` output

```
# Anthropic Documentation

> Generated by DocSense Crawler v1.0.0 on 2025-11-08. Original source: https://docs.anthropic.com

## Getting Started

- [Welcome](content/getting-started/welcome.md): An overview of Anthropic's API and capabilities
- [Quickstart](content/getting-started/quickstart.md): Make your first API call in 5 minutes

## API Reference

- [Messages](content/api-reference/messages.md): Create a message via the Messages API
- [Models](content/api-reference/models.md): List available Claude models

## Concepts

- [Prompt engineering](content/concepts/prompt-engineering.md): Techniques for effective prompts
```

#### Sample normalized `.md` file

```markdown
---
url: https://crawler.example.com/anthropic/content/api-reference/messages.md
title: Messages
section: API Reference
description: Create a message via the Messages API
source_original_url: https://docs.anthropic.com/en/api/messages
extracted_at: 2025-11-08T10:23:00Z
adapter: WebCrawlerAdapter
adapter_version: 1.0.0
---

# Messages

The Messages API allows you to create conversational interactions with Claude.

## Create a Message

`POST /v1/messages`

[content continues...]
```

### 9.3 Synthetic test fixtures

`tests/fixtures/`:

- `mini_site/` — 5 hand-written HTML files mimicking common doc patterns
- `mini_sitemap.xml` — referencing those files
- `mini_repo/` — a directory tree mimicking a docs repo
- `expected_llms_txt.txt` — exact `llms.txt` that should be emitted from `mini_site/`
- `expected_markdown/` — exact normalized markdown for each input

Used in unit + integration tests to lock down output determinism.

---

## 10. API & CLI Surface

### 10.1 REST endpoints

```
POST   /jobs                          Submit a new crawl job
GET    /jobs                          List jobs
GET    /jobs/{job_id}                 Get job details
GET    /jobs/{job_id}/status          Get current status + progress
DELETE /jobs/{job_id}                 Cancel a running job
GET    /jobs/{job_id}/output          Download zip of output

GET    /adapters                      List available adapters with their config schemas

GET    /health                        Liveness
GET    /ready                         Readiness
GET    /metrics                       Prometheus
```

### 10.2 CLI

```
docsense-crawler adapters list
docsense-crawler crawl web --base-url https://docs.anthropic.com --out ./output/anthropic
docsense-crawler crawl github --repo https://github.com/user/docs-repo --out ./output/repo
docsense-crawler serve ./output/anthropic --port 8081
docsense-crawler status job_a1b2c3d4
```

CLI wraps REST API. No business logic in CLI itself.

### 10.3 Integration with DocSense

After a successful crawl that's served at `http://localhost:8081`, the operator runs:

```
docsense sources add \
  --name "Anthropic Docs" \
  --url "http://localhost:8081/llms.txt"
```

DocSense ingests from the served `llms.txt` indistinguishably from how it ingests Stripe's. **That seamlessness is the proof of the contract.** Capture this end-to-end flow in a demo video.

---

## 11. Coding Standards

Identical to DocSense (mirror the same toolchain and conventions):

- `ruff format` (line length 100), `ruff check`, `mypy --strict`
- Google-style docstrings
- Conventional commits
- All config via Pydantic Settings + env vars
- structlog only; never `print()`
- Coverage ≥ 80%; 100% on `src/emit/llms_txt.py` (contract correctness)
- Property-based tests via `hypothesis` for slug generation invariants

### 11.1 Project structure

```
docsense-crawler/
├── README.md
├── pyproject.toml
├── uv.lock
├── docker-compose.yml
├── Makefile
├── .env.example
├── .github/workflows/
│   ├── ci.yml
│   └── contract-validation.yml      # validates emitted llms.txt against contract schema
├── docs/
│   ├── PRD.md
│   ├── architecture.png
│   ├── runbook.md
│   └── adr/
├── src/
│   ├── config.py
│   ├── models.py
│   ├── telemetry.py
│   ├── adapters/
│   │   ├── base.py
│   │   ├── web_crawler.py
│   │   └── github_md.py
│   ├── normalize/
│   │   ├── html_to_md.py
│   │   └── categorize.py
│   ├── emit/
│   │   ├── llms_txt.py
│   │   └── markdown_files.py
│   ├── serve/
│   │   └── server.py
│   ├── jobs/
│   │   └── orchestrator.py
│   ├── api/
│   └── cli/
├── tests/
│   ├── unit/
│   ├── integration/
│   └── fixtures/
└── infra/
    ├── grafana/
    ├── prometheus/
    └── otel/
```

---

## 12. Observability

### 12.1 Trace structure per job

```
job.received                   { job_id, adapter_name }
  ├─ adapter.discover          { total_candidates, source }
  ├─ adapter.fetch             { fetched, failed, retried }
  ├─ normalize                 { extracted, rejected }
  ├─ categorize.heuristic      { categorized_by_heuristic }
  ├─ categorize.llm            { sent_to_llm, llm_cost_usd }
  ├─ emit.llms_txt             { sections, total_links }
  ├─ emit.markdown             { files_written }
  ├─ serve                     { port, url } (optional)
  └─ job.complete              { duration_ms, total_cost_usd }
```

### 12.2 Metrics

- `crawler_pages_discovered_total{adapter}`
- `crawler_pages_fetched_total{adapter, status}`
- `crawler_extraction_failures_total{reason}`
- `crawler_llm_categorization_cost_usd{adapter}`
- `crawler_job_duration_seconds{adapter}`

### 12.3 Dashboards

1. **Job operations** — active jobs, completion rate, duration histogram
2. **Adapter quality** — extraction success rate, normalization rejection rate by adapter
3. **Cost** — categorization spend per crawl, cumulative monthly
4. **Failures** — top failure reasons, top failed source domains

### 12.4 Contract validation as observability

After every emit, run the contract validator on the output. Emit a metric `crawler_contract_compliance{job_id, passed}`. A failed validation is a P0 bug — it means we shipped a non-compliant output to a downstream consumer.

---

## 13. Cost Model

### 13.1 Per-crawl cost

| Stage                         | Cost             |
| ----------------------------- | ---------------- |
| Page fetching                 | $0 (HTTP, local) |
| HTML extraction (trafilatura) | $0 (local)       |
| URL-path categorization       | $0 (heuristic)   |
| LLM categorization (Pass 2)   | $0.001 / 50 docs |

### 13.2 Sample crawl cost

| Source                      | Docs | LLM-categorized                      | Cost    |
| --------------------------- | ---- | ------------------------------------ | ------- |
| Anthropic docs (~200 pages) | 200  | ~80 (40% uncategorized by heuristic) | ~$0.002 |
| AWS service guide (~500)    | 500  | ~150                                 | ~$0.003 |
| Internal wiki (~2000)       | 2000 | ~600                                 | ~$0.012 |

### 13.3 Optimizations

- Batch LLM categorization (50 docs per call)
- Cache categorization results keyed by `hash(title + first_200_chars)` — re-crawls hit cache
- Skip LLM when heuristic confidence > 0.8

Budget alarm at $5/month (Crawler usage will be sporadic, not continuous).

---

## 14. Acceptance Criteria

### Adapter Layer

- [ ] `BaseAdapter` interface defined with abstract `discover()` and `fetch()`
- [ ] `WebCrawlerAdapter` discovers via sitemap, falls back to seed list
- [ ] `WebCrawlerAdapter` respects `robots.txt` (verified with adversarial test sites)
- [ ] `GitHubMarkdownAdapter` clones shallow and walks `*.md` files
- [ ] Adapter discovery completes in < 30s for sites with ≤ 1000 pages

### Normalization

- [ ] `trafilatura` extraction tested on the 5 fixture sites
- [ ] Fallback to `markdownify` triggers on empty-extraction cases
- [ ] Rejection criteria (length, link-density) catch the 5 known-bad fixture docs
- [ ] Code blocks preserved verbatim (zero loss across 100-doc sample)

### Categorization

- [ ] Heuristic + LLM produces ≥ 90% acceptable assignment on 30-doc hand-judged sample (per source)
- [ ] LLM cost ≤ $0.01 per 500-doc crawl
- [ ] Uncategorized rate ≤ 5%

### Emit

- [ ] Generated `llms.txt` passes the contract validator
- [ ] All markdown files have valid YAML frontmatter
- [ ] Filenames are deterministic across re-crawls of the same input

### Integration with DocSense

- [ ] Crawler-emitted output is served at HTTP endpoint
- [ ] DocSense successfully registers the served `llms.txt` as a new source
- [ ] DocSense queries return correct answers with citations pointing to served URLs
- [ ] End-to-end pipeline runtime documented (target: < 15 min for ~200-page source)

### Platform Quality

- [ ] All 6 ADRs committed
- [ ] CI validates contract compliance on every PR
- [ ] Demo video showing: configure → crawl → serve → DocSense ingests → query → answer with citations

---

## 15. Risks & Mitigations

| #   | Risk                                                | Likelihood | Impact | Mitigation                                                                         |
| --- | --------------------------------------------------- | ---------- | ------ | ---------------------------------------------------------------------------------- |
| R1  | `trafilatura` extracts poorly on a major doc site   | M          | M      | Fallback to `markdownify`; document known-bad patterns                             |
| R2  | JS-rendered SPAs return empty content               | H          | M      | Detect + skip; document headless browser as v2                                     |
| R3  | LLM categorization is non-deterministic across runs | M          | M      | Cache results; document non-determinism in ADR-004                                 |
| R4  | Source rate-limits us                               | L          | H      | Politeness defaults; respect 429; clear "report a bad citizen" docs                |
| R5  | Contract spec evolves; output goes stale            | M          | H      | Contract validator in CI; bump output `llms.txt` version field                     |
| R6  | LLM categorization cost overrun on huge corpora     | L          | M      | Cache; batch size; budget alarm                                                    |
| R7  | Generated slugs collide                             | L          | M      | Append numeric suffix on collision; unit-tested                                    |
| R8  | DocSense and Crawler version skew                   | M          | M      | Both depend on the same `llms-txt-contract.md`; contract version stamped in output |

### 15.1 Trade-offs explicitly accepted

| Decision                       | We accept                    | We sacrifice                               |
| ------------------------------ | ---------------------------- | ------------------------------------------ |
| Sitemap-first discovery        | Coverage of well-SEO'd sites | Sites without sitemaps (require seed list) |
| 2 adapters in v1               | Restraint, clear pattern     | Out-of-the-box Notion/Confluence support   |
| Full re-crawl                  | Simplicity                   | Wasted work on small updates               |
| GPT-4o-mini for categorization | Cost                         | Marginal accuracy loss vs GPT-4o           |
| No headless browser            | No Playwright dependency     | JS-rendered SPAs unsupported               |
| Public sources only (v1)       | Simplicity                   | Customer's private wikis unsupported       |

---

## 16. Roadmap

### Week 1 — Foundation + WebCrawlerAdapter

Project skeleton, uv, Docker Compose, observability. `BaseAdapter` interface. WebCrawler discovers + fetches. trafilatura normalization. Slug generation.

### Week 2 — Categorization + Emit + GitHubAdapter

URL-heuristic + LLM categorization. `llms.txt` emitter with contract validator. Markdown emitter with frontmatter. GitHubMarkdownAdapter implemented.

### Week 3 — Serve + Integration + Polish

Static server. End-to-end DocSense integration demo. Contract-validation CI. Six ADRs committed. Runbook. Demo video.

---

## 17. Appendices

### Appendix A — Glossary

| Term           | Definition                                                   |
| -------------- | ------------------------------------------------------------ |
| Adapter        | Module implementing `BaseAdapter` for a specific source type |
| Discovery      | Phase 1 of crawling: listing candidate URLs/paths            |
| Normalization  | HTML/raw → markdown conversion                               |
| Categorization | Assigning each doc to a section                              |
| Emit           | Writing the final `llms.txt` + markdown files                |
| Contract       | The `llms.txt` standard specification                        |
| Static serve   | HTTP serving of emitted output for ingestion by RAG engines  |

### Appendix B — References

- `llms.txt` proposal: <https://llmstxt.org>
- `trafilatura` paper: Barbaresi (2021), _Trafilatura: A Web Scraping Library and Command-Line Tool for Text Discovery and Extraction._
- RFC 9309 (robots.txt)
- Stripe's `llms.txt`: <https://docs.stripe.com/llms.txt> (reference implementation)

### Appendix C — CXO recruiter evaluation rubric

| Question                                           | Where the answer lives |
| -------------------------------------------------- | ---------------------- |
| Do they understand adapter / Strategy pattern?     | §6                     |
| Do they show restraint (not building 10 adapters)? | §2.2, §6.3             |
| Cost discipline in LLM use?                        | §13                    |
| Resilience and politeness?                         | §5.2.2                 |
| Contract-driven design?                            | §3, §5.6.1             |
| Quality measurement?                               | §5.5.2, §14            |
| Future-extensibility without over-engineering?     | §6                     |

---

**Document control**

| Version | Date | Author         | Change              |
| ------- | ---- | -------------- | ------------------- |
| 1.0     | —    | R. Pai, S. Pai | Initial Crawler PRD |

_End of document._
