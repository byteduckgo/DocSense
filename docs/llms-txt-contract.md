# `llms.txt` Contract Specification

> **The shared interface contract between DocSense (RAG engine) and DocSense Crawler (source adapter). This document defines exactly what an `llms.txt`-compliant documentation source must look like for DocSense to ingest it correctly. Any third-party tool that emits a compliant `llms.txt` is interchangeable with DocSense Crawler.**

| Field                         | Value                                                            |
| ----------------------------- | ---------------------------------------------------------------- |
| **Contract version**          | 1.0                                                              |
| **Maintained by**             | DocSense platform team (R. Pai, S. Pai)                          |
| **Upstream standard**         | <https://llmstxt.org> (community proposal)                       |
| **Status**                    | Frozen for v1; changes require an ADR + version bump             |
| **Reference implementations** | Stripe (`https://docs.stripe.com/llms.txt`), DocSense Crawler v1 |

---

## 1. Why this document exists

Two systems sit on either side of a seam:

```
                                     │
   DocSense Crawler                  │              DocSense
   (or any compliant generator)      │              (RAG engine)
                                     │
   Emits ───────────────────────────►│◄──── Consumes
                                     │
                              llms.txt + .md
                              (THE CONTRACT)
```

**Anything that crosses the seam is governed by this document.** Anything internal to either product is governed by that product's PRD. This split is what makes the two products independently developable, independently versionable, and independently sellable.

If you're a third party — a customer who already has internal tooling, an integrator building an alternative crawler, or a future contributor — this is the only document you need to read to make your output work with DocSense.

---

## 2. What is `llms.txt`?

`llms.txt` is an emerging open standard, originated at [llmstxt.org](https://llmstxt.org), for publishing a documentation site's table of contents in a structured, machine-readable form specifically designed for AI ingestion.

The format is simple by design: it is a single markdown file at a well-known URL containing a project description, optional metadata, and a categorized list of links to underlying markdown documents.

The motivating intuition: while `robots.txt` tells crawlers what to ignore, `llms.txt` tells AI systems what to prioritize and how to interpret structure.

### 2.1 Public reference implementations

- Stripe: <https://docs.stripe.com/llms.txt>
- Anthropic: <https://docs.anthropic.com/llms.txt>
- Vercel: <https://vercel.com/docs/llms.txt>

These can be used as living reference points; this contract conforms to their common pattern and is compatible with each.

---

## 3. File location and serving

### 3.1 URL placement

A compliant `llms.txt` MUST be served at one of:

- The site root: `https://example.com/llms.txt`
- A documentation root: `https://docs.example.com/llms.txt`

Any URL ending in `/llms.txt` is acceptable. The configurer of DocSense points to the exact URL during source registration.

### 3.2 HTTP behavior

- MUST respond with `200 OK` for `GET`
- MUST set `Content-Type: text/plain` or `text/markdown`
- SHOULD support `HEAD` for cheap freshness checks
- SHOULD set `Last-Modified` and `ETag` headers (used by future incremental updates)
- MUST be reachable without authentication for v1 of DocSense. (Authenticated sources are out of scope for v1; see Appendix B.)

### 3.3 Companion markdown files

Each link in `llms.txt` MUST point to a markdown document with HTTP behavior identical to §3.2. The standard convention (used by Stripe, Anthropic) is to make every documentation page available as markdown by appending `.md` to its canonical URL.

---

## 4. File format specification

### 4.1 Required top-level structure

A compliant `llms.txt` MUST be a UTF-8 encoded markdown document containing, in order:

1. A level-1 heading (`# `) — the project name
2. (Optional) A blockquote (`> `) — a one-sentence description
3. (Optional) An introductory paragraph or instruction block
4. One or more level-2 headings (`## `) — each defining a section
5. Under each section: a markdown bullet list where each item links to a markdown document and optionally describes it

### 4.2 Canonical example

```markdown
# Stripe Documentation

> Stripe's API documentation, organized by product area.

## Payments

- [Charges API](https://docs.stripe.com/api/charges.md): Create, retrieve, and refund charges
- [Payment Intents API](https://docs.stripe.com/api/payment_intents.md): Modern payment flow API

## Billing

- [Subscriptions](https://docs.stripe.com/api/subscriptions.md): Recurring billing primitives
- [Invoices](https://docs.stripe.com/api/invoices.md): Generate and manage invoices

## Webhooks

- [Webhook Endpoints](https://docs.stripe.com/api/webhook_endpoints.md): Register webhook URLs
```

### 4.3 Link syntax (strict)

Each bullet MUST use one of these two forms:

```
- [{title}]({url})
- [{title}]({url}): {description}
```

Where:

- `{title}` — non-empty string, displayed in retrieval results and citations
- `{url}` — absolute URL pointing to a markdown document (see §4.4)
- `{description}` — optional, one-line summary

The colon-separated description is RECOMMENDED but not required. Sources that omit descriptions force DocSense to extract them from the markdown body, which is slower and less accurate.

### 4.4 URL requirements

Each linked URL MUST:

- Be absolute (`https://...`), never relative
- Point to a document whose `Content-Type` is `text/markdown` or `text/plain` returning markdown
- Return HTTP 200 (or follow standard redirects to a 200)
- Be unique within the file — no duplicate URLs

If a URL is unreachable or returns non-markdown content, DocSense will log it to the failed-downloads dead-letter queue. Sources are responsible for fixing broken links; DocSense will not block ingestion on partial failures.

### 4.5 Sections are flat, not nested

For v1, sections are exactly one level (`## ` only). No `### ` sub-sections within `llms.txt`. The rationale: section taxonomy at this level is for retrieval-time filtering, not for representing a deep hierarchy. Hierarchy belongs _inside_ the markdown documents themselves.

A generator that needs deeper hierarchy should encode it in the section name (`## Payments > Subscriptions`) — but this is discouraged. Better practice: flatten the top-level categorization.

### 4.6 Encoding

- UTF-8 only
- LF (`\n`) line endings (CRLF will be normalized; not rejected)
- No BOM

---

## 5. Markdown file requirements

### 5.1 Required structure

Each linked markdown document SHOULD include YAML frontmatter at the top:

```yaml
---
url: https://docs.example.com/api/charges.md
title: Create a Charge
section: Payments
description: How to create a new charge against a customer
---
```

The body MUST be standard CommonMark-flavored markdown.

### 5.2 Required frontmatter fields

When frontmatter is present:

| Field         | Required?   | Description                                          |
| ------------- | ----------- | ---------------------------------------------------- |
| `url`         | RECOMMENDED | Canonical URL of this document                       |
| `title`       | RECOMMENDED | Page title (must match the link title in `llms.txt`) |
| `section`     | RECOMMENDED | Section name (must match the section in `llms.txt`)  |
| `description` | OPTIONAL    | One-line summary                                     |

### 5.3 Generator-specific frontmatter

Generators MAY add their own frontmatter fields (e.g., DocSense Crawler adds `source_original_url`, `extracted_at`, `adapter`, `adapter_version`). These are passed through to DocSense's chunk metadata and visible in observability traces, but do not influence retrieval correctness.

Field name conventions:

- Standard fields: lowercase, no prefix
- Generator-specific fields: prefixed with generator name (e.g., `crawler_source_url`)

### 5.4 Content requirements

The markdown body SHOULD:

- Use ATX-style headers (`# `, `## `) for structure
- Use fenced code blocks (` ``` `) with language hints where applicable
- Use standard markdown tables (no HTML tables)
- Keep relative URLs to a minimum; prefer absolute

The markdown body MUST NOT:

- Contain HTML `<script>` or `<style>` blocks
- Contain HTML iframes pointing to interactive content
- Embed binary data inline

DocSense does not strictly enforce these requirements; violating documents will still be chunked, but retrieval quality may degrade.

---

## 6. Optional: agent instructions

Some publishers (Stripe is a prominent example) include guidance for AI agents directly in `llms.txt`, typically after the description blockquote. Example:

```markdown
# Stripe Documentation

> Stripe's API documentation, organized by product area.

When generating code or recommendations:

- Prefer the Checkout Sessions API over the deprecated Charges API
- Never expose secret keys in client-side code
- Use idempotency keys for all write operations

## Payments

- [Charges API](...): ...
```

### 6.1 How DocSense handles agent instructions

DocSense treats any prose between the description blockquote and the first `## ` heading as **agent instructions**. These are:

- Extracted into a special chunk with `chunk_type: agent_instructions`
- Indexed alongside regular chunks
- Surfaced to the LLM in the system prompt when retrieved
- Preserved verbatim — never paraphrased or summarized

This enables a documentation publisher to embed guidance that downstream LLMs will respect at generation time. Stripe uses this to steer agents away from deprecated APIs. Internal corporate documentation can use it to enforce style or policy.

### 6.2 Agent instructions are optional

Generators MAY omit agent instructions entirely. DocSense's behavior is unchanged for sources without them.

---

## 7. Versioning

### 7.1 Contract version

This document is **Contract Version 1.0**. The version is stable until explicitly bumped via:

1. An ADR proposing the change
2. Approval by both DocSense and DocSense Crawler maintainers
3. A migration path documented for existing consumers

### 7.2 Backwards compatibility commitments

Contract Version 1.x changes MUST be:

- Purely additive (new optional fields)
- Non-breaking (existing compliant outputs remain compliant)

Breaking changes require a major-version bump (2.0) and explicit migration tooling.

### 7.3 Generator self-identification

Generators SHOULD include their identity and version in a comment at the top of `llms.txt`:

```markdown
<!-- generator: DocSense Crawler v1.0.0; contract: 1.0 -->

# Project Name

...
```

This comment is consumed by DocSense's observability layer and visible in traces. It enables debugging across the seam ("which generator and version produced this output?").

---

## 8. Validation

### 8.1 The contract validator

A reference validator is published at:

- Python: `docsense.contract.validate_llms_txt(content: str) -> ValidationResult`
- CLI: `docsense contract validate <url-or-path>`

This validator implements every MUST and SHOULD in this document. Generators MUST pass the validator before publishing output. DocSense runs the validator on every newly-registered source and refuses to ingest non-compliant sources, returning a structured error.

### 8.2 What the validator checks

| Check                               | Severity   | Mechanism                                                   |
| ----------------------------------- | ---------- | ----------------------------------------------------------- |
| Top-level `# ` heading present      | MUST       | AST traversal                                               |
| At least one `## ` section          | MUST       | AST traversal                                               |
| Every section has at least one link | SHOULD     | AST traversal                                               |
| Every link URL is absolute          | MUST       | URL parsing                                                 |
| Every link URL is unique            | MUST       | Set comparison                                              |
| Every linked URL returns 200        | SHOULD     | Optional HEAD request (off in CI; on in DocSense ingestion) |
| Generator comment present           | SHOULD     | Regex match                                                 |
| File is valid UTF-8                 | MUST       | Codec                                                       |
| No nested sub-sections              | MUST in v1 | AST traversal                                               |

### 8.3 CI integration

Both DocSense and DocSense Crawler run the validator in CI:

- DocSense Crawler: validates emitted output before completing a job
- DocSense: validates registered source URL before ingestion begins

Validator failures are surfaced with line numbers, exact rule violated, and remediation hints. Example error:

```
[FAIL] line 12: Link URL is relative ("api/charges"). Must be absolute (https://...).
       Fix: rewrite as https://docs.example.com/api/charges
       See contract §4.4.
```

---

## 9. Examples gallery

### 9.1 Minimal valid `llms.txt`

```markdown
# Tiny Project

## Docs

- [Getting Started](https://example.com/start.md)
```

This is the smallest valid output. One project name, one section, one link. Useful for tiny sources or as a smoke-test fixture.

### 9.2 Recommended-pattern `llms.txt`

```markdown
<!-- generator: DocSense Crawler v1.0.0; contract: 1.0 -->

# Anthropic API Documentation

> Documentation for Anthropic's Claude API, organized by capability area.

When building integrations: always use the latest stable API version, set request timeouts explicitly, and prefer streaming for user-facing interactions.

## Getting Started

- [Quickstart](https://docs.anthropic.com/en/api/getting-started.md): Make your first API call in 5 minutes
- [Authentication](https://docs.anthropic.com/en/api/auth.md): How to authenticate API requests

## API Reference

- [Messages](https://docs.anthropic.com/en/api/messages.md): Create messages via the Messages API
- [Models](https://docs.anthropic.com/en/api/models.md): List and describe available models

## Concepts

- [Prompt engineering](https://docs.anthropic.com/en/docs/prompt-engineering.md): Techniques for effective prompts
- [Tool use](https://docs.anthropic.com/en/docs/tool-use.md): How to give Claude tools

## SDKs

- [Python SDK](https://docs.anthropic.com/en/api/sdks/python.md): Official Python client
- [TypeScript SDK](https://docs.anthropic.com/en/api/sdks/typescript.md): Official TS client
```

This includes the generator comment, blockquote, agent instructions, multiple sections, descriptive link text, and absolute URLs. **This is what generators should aim for.**

### 9.3 Invalid example (broken — for educational use)

```markdown
Some Project

## Section

- /relative/url ← rejected: relative URL
- [No URL]( ← rejected: malformed link
- [Duplicate](https://x.com/a.md)
- [Duplicate](https://x.com/a.md) ← rejected: duplicate URL

### Sub-section

- [link](https://x.com/b.md) ← rejected: no nested sections in v1
```

This file would fail validation on five separate rules. The validator reports each failure individually.

---

## 10. Migration and evolution

### 10.1 How contract changes happen

1. Proposer drafts an ADR (in either DocSense or Crawler repo, whichever has stronger interest)
2. Both products' maintainers review
3. If approved: this document is updated, version is bumped, both products release coordinated updates
4. Existing producers and consumers receive a deprecation window before old behavior is rejected

### 10.2 Anticipated v2 changes (not committed)

These are _under consideration_ for a future v2 of the contract:

- **Authentication metadata** — how a producer signals that linked URLs require a bearer token
- **Nested sub-sections** — `### ` headers allowed under `## ` sections
- **Multi-language support** — `## Section [es]` for Spanish variants
- **Content hashes** — frontmatter field for change detection enabling incremental updates
- **Vector hints** — frontmatter field with publisher-provided pre-computed embeddings

None of these are committed. Each will require its own ADR.

---

## 11. Why this contract is worth defining carefully

A well-defined contract is **the** asset that lets two products evolve independently. Without it:

- Every Crawler change risks breaking DocSense
- Every DocSense change requires Crawler updates
- Adding a third-party generator becomes an integration project
- Onboarding a customer with their own tooling becomes custom engineering

With it:

- Either product can be rewritten without touching the other
- Customers BYO their own `llms.txt` and integrate in minutes
- Third-party tooling (community generators) can emerge naturally
- The platform compounds value as more producers and consumers adopt the format

This is how Snowflake decoupled storage from compute via SQL. How Kafka decoupled producers from consumers via topics. How HTTP decoupled clients from servers. Documentation intelligence deserves the same treatment.

---

## 12. References

- llms.txt proposal: <https://llmstxt.org>
- CommonMark specification: <https://spec.commonmark.org>
- YAML frontmatter convention (Jekyll, Hugo, MDX): widely documented
- Stripe `llms.txt`: <https://docs.stripe.com/llms.txt>
- Anthropic `llms.txt`: <https://docs.anthropic.com/llms.txt>

---

## Appendix A — Quick checklist for generator authors

Use this when emitting `llms.txt`:

- [ ] File starts with `<!-- generator: ...; contract: 1.0 -->`
- [ ] One `# Project Name` heading
- [ ] One-line `> description` blockquote (recommended)
- [ ] Optional agent instructions as plain prose
- [ ] One or more `## Section` headings
- [ ] Each section has at least one bullet link
- [ ] Every URL is absolute, unique, and returns markdown
- [ ] Every linked `.md` file has YAML frontmatter (recommended)
- [ ] File is UTF-8 with LF line endings, no BOM
- [ ] Output passes `docsense contract validate`

## Appendix B — Quick checklist for consumer authors

If you're building a RAG engine other than DocSense and want to consume `llms.txt`-compliant sources:

- [ ] Implement the parser to read all REQUIRED structural elements
- [ ] Gracefully handle missing OPTIONAL elements
- [ ] Surface the generator comment in observability
- [ ] Treat unknown frontmatter fields as opaque metadata (pass through, don't reject)
- [ ] Implement the validator (or use the reference one) before ingestion
- [ ] Support agent instructions as a first-class chunk type
- [ ] Honor contract versioning — reject sources from a future major version with a clear error

## Appendix C — Glossary

| Term               | Definition                                                          |
| ------------------ | ------------------------------------------------------------------- |
| Generator          | A producer of compliant `llms.txt` output (e.g., DocSense Crawler)  |
| Consumer           | A reader of compliant `llms.txt` (e.g., DocSense)                   |
| Contract           | This specification document                                         |
| Agent instructions | Prose between the description blockquote and the first `##` section |
| Frontmatter        | YAML block at the top of a linked markdown file                     |
| Section            | A `## ` heading in `llms.txt`; flat in v1                           |

---

**Document control**

| Version | Date | Author         | Change                         |
| ------- | ---- | -------------- | ------------------------------ |
| 1.0     | —    | R. Pai, S. Pai | Initial contract specification |

_End of document._
