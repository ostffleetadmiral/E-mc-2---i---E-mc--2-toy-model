# Training Pipeline

Complete reference for Qstar-LLM's training framework: self-training, internet training (Wikipedia API), and local dataset ingestion.

---

## Overview

Qstar-LLM supports five training modes, all managed through `src/training.zig` (2,900+ lines):

1. **Self-Training** — Ollama or OpenAI acts as teacher, generating responses that the agent learns from
2. **Hybrid Training** — OpenAI semantic (corpus + KG + routes) for factual/technical, Ollama corpus for creative/chitchat
3. **Internet Training** — Fetches plain-text Wikipedia articles via MediaWiki API and learns sentences
4. **Dataset Ingestion** — Recursively loads local .md/.txt/.tex files, strips markdown, extracts sentences
5. **Ollama Enrichment** — Hybrid: Ollama extracts key sentences from documents + direct ingestion

All modes support resumable execution, periodic corpus saving for crash recovery, and append to the same `qstar_corpus.txt` file. The corpus can be stored as a compressed quine-style `.qsc` container (`src/corpus_store.zig`) for on-demand page decompression within the 500 MB raw `learnFromText` cap.

---

## Self-Training (Ollama / OpenAI Teacher)

### CLI Command

```bash
zig build cli -- train --model qwen2.5:3b --corpus qstar_corpus.txt
zig build cli -- train --teacher openai --openai-model gpt-4o --limit 3
zig build cli -- train --hybrid --corpus qstar_corpus_large.txt
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama model to use as teacher |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file to load; session-learned sentences are **delta-appended** to it (`.qsc` inputs write to a `<base>.learned.txt` sidecar) |
| `--verbose` | off | Print per-prompt progress |
| `--teacher <name>` | `auto` | Teacher: `ollama`, `openai`, or `auto` (OpenAI if key present, else Ollama) |
| `--openai-model <name>` | `gpt-4o` | OpenAI teacher model |
| `--openai-key <key>` | `.env` | OpenAI API key (overrides `OPENAI_API_KEY`) |
| `--hybrid` | off | Hybrid training: OpenAI semantic for factual, Ollama corpus for creative — when Ollama is unavailable, creative/chitchat categories fall back to OpenAI |
| `--limit <n>` | all | Limit number of prompts trained |

### Teacher Selection (`resolveTeacher`)

- `--teacher openai` → always OpenAI (requires `OPENAI_API_KEY`; fails fast if missing)
- `--teacher ollama` → always Ollama (requires Ollama running)
- `--teacher auto` (default) → OpenAI if `OPENAI_API_KEY` present, else Ollama

### How It Works

1. Loads existing corpus from `qstar_corpus.txt`
2. For each of 300 default prompts across 30 topic categories:
   - Sends prompt to the selected teacher (Ollama or OpenAI via `openai_client.zig` HTTPS/TLS)
   - Receives generated response
   - Calls `agent.learnFromText(response)` to extract and add sentences
3. Saves updated corpus

### `.env` Setup

```bash
OPENAI_API_KEY=sk-...
OPENAI_MODEL=gpt-4o
```

Real environment variables override `.env` entries.

### Default Prompt Categories

The `DEFAULT_PROMPTS` array contains 300 prompts across 30 categories (10 each):

**Technical/factual (routed to OpenAI in hybrid mode):** Computer Science, Artificial Intelligence, Physics, Biology, Chemistry, Philosophy, History, Economics, Climate & Environment, Space & Astronomy, Medicine, Psychology, Mathematics, Engineering, Security & Cryptography, Framework E=mc²-i-E=mc⁻², OSTF Governance, Admiral Paul Ramsey Biography, Sci-Fi Narrative & Codex, Quantum Systems Concepts, Octonionic Physics, Q128.128 Fixed-Point Arithmetic, Codon Routing, Neuraleak & Sentience Testing, Literature & Arts, Geography & Earth Science, Law & Jurisprudence, Fact-Checking & Verification.

**Creative/chitchat (routed to Ollama in hybrid mode):** Creative Writing & Imagination, Chitchat & Conversation.

---

## Hybrid Training (OpenAI + Ollama)

### CLI Command

```bash
zig build cli -- train --hybrid --corpus qstar_corpus.txt
```

### How It Works

`trainBatchHybrid` routes each prompt to the optimal teacher:

| Prompt Category | Primary Teacher | Learning Mode |
|----------------|----------------|---------------|
| Factual/technical (categories 1-27, 30) | OpenAI (gpt-5) | `trainWithOpenAISemantic` — corpus + KG + routes |
| Creative/chitchat (categories 28-29) | Ollama (qwen2.5:3b) | `trainOnPrompt` — corpus sentences |
| Failure fallback | Other teacher | Automatic on primary failure |

OpenAI semantic training learns through three channels:
- **Corpus** — key sentences extracted from the teacher response
- **Knowledge graph** — subject-relation-object triples
- **Routes** — prompt-pattern → response-path associations

Ollama training learns through corpus sentence extraction only.

---

## Internet Training (Wikipedia API)

### CLI Command

```bash
zig build cli -- train-internet --offset 0 --no-ollama --corpus qstar_corpus.txt
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama model for augmentation |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file to load/append |
| `--offset N` | `0` | Skip first N articles (for resuming) |
| `--limit N` | all | Only fetch N articles |
| `--articles <path>` | built-in | Load Wikipedia titles from file (one per line, `#` comments allowed) instead of `WIKIPEDIA_ARTICLES` |
| `--no-ollama` | off | Disable Ollama augmentation (Wikipedia-only) |

### How It Works

1. Loads existing corpus from file
2. Iterates through `WIKIPEDIA_ARTICLES` array (1,345 titles) or the `--articles` file, starting at `--offset`
3. For each article:
   - Constructs Wikipedia API URL: `https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&format=json&redirects=1&titles=TITLE`
   - Fetches plain-text extract via zero-dependency HTTP client
   - Calls `agent.learnFromText(extract)` to extract and add sentences
   - Optionally sends extract to Ollama for additional sentence generation
   - Saves corpus every 5 articles (crash recovery)
4. Reports final statistics

### Wikipedia API Details

- **Endpoint:** `https://en.wikipedia.org/w/api.php`
- **Parameters:** `action=query`, `prop=extracts`, `explaintext=1`, `format=json`, `redirects=1`
- **Redirect handling:** The `&redirects=1` parameter resolves redirect pages (e.g., `Iroquois` → `Haudenosaunee`). This was a critical fix that recovered 54+ titles previously returning empty.
- **Rate limiting:** 3-second delay between fetches. Exponential backoff on HTTP 429: 10s → 20s → 30s per consecutive failure.
- **Encoding:** Article titles with Unicode characters (e.g., en-dash in `Dunning–Kruger_effect`) must use ASCII equivalents (`Dunning-Kruger_effect`) for the Zig HTTP client to URL-encode properly.

### Training Batches

| Batch | Articles | Fetched | Failed | Sentences | Topics |
|-------|----------|---------|--------|-----------|--------|
| Batch 1 | 142 | 135 | 7 | 52,992 | Physics, AI, biology, chemistry, earth science, economics, climate, space, medicine, psychology, math, engineering, security |
| Batch 2 | 225 | 206 | 19 | 83,371 | Philosophy, logic, history, literature, geography, chemistry elements, astronomy, math, CS, biology, psychology, sociology, economics, physics, nutrition, language, education, law, technology |
| Batch 3 | 281 | 224 | 75 | 86,881 | Extended topics + Native American cultures (Adena, Hopewell, Hopi, Cherokee, Blackfoot) |
| Batch 5 | 72 | 52 | 20 | 14,430 | Corrected titles for missing pages + re-fetch of EMPTY titles (fixed by `&redirects=1`) |
| Batch 6 | 33 | 26 | 7 | 8,492 | Final retry with corrected alternate titles |
| Batch 7 | 7 | 7 | 0 | 1,883 | Last retry for rate-limited + alternate titles (en-dash fix) |
| **Total** | **1,155** | **1,094** | **61** | **248,049** | |

*Note: the table above is the historical 7-batch run log (1,155 titles at the time). `WIKIPEDIA_ARTICLES` now contains 1,345 titles — rerun batches cover the additions.*

### Corpus Growth History

| Stage | Corpus Size |
|-------|------------|
| Original (before training) | 3,291,954 sentences |
| After Batch 1 | 3,344,946 |
| After Batch 2 | 3,428,317 |
| After Batch 3 | 3,515,198 |
| After Batch 5 | 3,529,628 |
| After Batch 6 | 3,538,120 |
| After Batch 7 | 3,540,003 |
| After Gov dataset | 3,589,093 |
| After AdmPaul dataset | 3,595,693 |
| **Final (before rebuild)** | **3,626,707 sentences (258 MiB / 270 MB)** |
| **After rebuild** | **2,195,092 sentences (dedup)** |

---

## 24-Hour Dual-Instance Training (`scripts/train24h.sh`)

A long-running training driver that fans the load across **two Ollama instances** in parallel.

```bash
LOCAL_MODEL=qwen3.5:latest REMOTE_MODEL=qwen2.5:3b TRAIN24H_HOURS=24 \
    nohup bash scripts/train24h.sh > logs/train24h_driver.log 2>&1 &
```

| Env var | Default | Description |
|---------|---------|-------------|
| `TRAIN24H_HOURS` | `24` | Session length in hours |
| `LOCAL_MODEL` | `qwen2.5:3b` | Teacher on `127.0.0.1:11434` (worker A) |
| `REMOTE_MODEL` | `qwen2.5:3b` | Teacher on `192.168.12.211:11434` (worker B) |

**How it works:**

1. `datasets/train24h_articles.txt` (110 Wikipedia titles) and `datasets/train24h_prompts.txt` (110 question prompts) are interleave-sharded: even lines → worker A, odd lines → worker B.
2. Each worker loops two passes per cycle until the deadline:
   - `train-internet --articles <shard>` — Wikipedia fetch + Ollama augmentation
   - `train --prompts <pshard>` — pure Ollama teacher expansion
3. Workers write **separate corpora** (`qstar_corpus_a.txt` / `qstar_corpus_b.txt`) to avoid write contention; merge with `cat` afterwards if desired.
4. Checkpoints: `train-internet` saves every 5 articles; each pass persists its delta on exit. A sub-60s cycle triggers a 120s backoff (endpoint-down guard).

**Control:** `logs/train24h_{A,B}.log` per-worker logs · `logs/train24h.pid` worker PIDs · `touch datasets/train24h.stop` for graceful stop.

**Topic sources:** the 110-title list was curated via web research across 20 random-fact domains (animal oddities, space, human body, history anomalies, geography, food, technology, psychology, oceans, inventions, math, chemistry-adjacent phenomena) — complementary to the built-in 1,345-title `WIKIPEDIA_ARTICLES` set.

---

## Web Fact-Checking (`src/fact_check.zig`)

All teacher-generated text can be verified against an external reference
before it enters the corpus. Enabled per-run with `--fact-check`
(default: off — deterministic baseline preserved).

**Reference resolution** (`fetchReferences`, per prompt/topic) — up to 3
independent sources, each cached separately under
`datasets/factcheck_refs/<slug>.<key>.txt`:

1. English Wikipedia — `opensearch` title lookup on the question-stripped
   query, then `prop=extracts`; empty results fall back to `list=search`
   full-text resolution
2. Simple English Wikipedia — same API path on `simple.wikipedia.org`
   (independent editorial text, not a mirror)
3. Playwright headless fetch (`scripts/web_fetch.py`, spawned via
   `std.process.Child`) — only when no API source resolves; finds a
   chromium headless shell via `$QSTAR_HEADLESS_SHELL` → newest
   `~/.cache/ms-playwright/chromium_headless_shell-*` → playwright default

**Verification** — corroboration, not just overlap. Integer-only decision
path:

1. `verifyTextMulti` — groundedness per reference: a sentence must score
   ≥ `--fc-threshold` (default 550) on at least `--fc-sources`
   (default 2) references. Three outcomes per sentence:
   - **pass ≥ needed refs** → kept
   - **pass ≥1 but < needed** → *borderline* (see below)
   - **pass 0 refs** → dropped
   Degrades gracefully: `needed = min(--fc-sources, refs resolved)`.
2. `spotCheck` — three enforcement paths over kept + borderline sentences:
   - **sampling**: 1-in-N kept sentences (`--fc-judge-rate`, default 10)
   - **numeric consistency**: every number in a claim must appear in some
     reference (comma-normalized); a miss forces a judge call, or drops
     outright when `--fc-judge-rate 0`
   - **borderline rescue**: every borderline sentence gets a forced
     YES/NO judge verdict against both references — semantic agreement
     can substitute for word overlap across stylistically different
     sources (Simple Wikipedia vocabulary differs from English Wikipedia)

The judge receives both references concatenated (bounded to 4,000 chars)
and answers YES/NO to "is the claim supported by the reference text?".

**Verification source per pipeline:**

| Pipeline | Reference used | Notes |
|----------|---------------|-------|
| `enrich-corpus` / `train-corpus` | the source document itself | extraction fidelity — zero extra fetches |
| `train-internet` | the fetched Wikipedia article | augments verified against the article they summarize |
| `train` / `trainBatch` | `fetchReference(prompt)` | cache → Wikipedia API → Playwright |

**No-reference policy:** when no reference resolves, teacher text is kept
by default; `--fc-drop-no-ref` drops it instead. Either way the decision
is logged (`[fc no-reference -> keep|drop]`).

**Flags** (on `train`, `train-internet`, `enrich-corpus`, `train-corpus`):

| Flag | Default | Effect |
|------|---------|--------|
| `--fact-check` | off | enable verification |
| `--no-fact-check` | — | explicit disable |
| `--fc-threshold <0-1000>` | 550 | groundedness per-mille cutoff |
| `--fc-judge-rate <n>` | 10 | judge 1-in-N kept sentences |
| `--fc-sources <n>` | 2 | minimum independent references for corroboration |
| `--fc-no-numeric` | on | disable numeric-consistency enforcement |
| `--fc-drop-no-ref` | keep | drop teacher text when unverifiable |

Caveat: corroboration is the practical approximation of truth available
to a web-grounded system — independent-source agreement plus numeric
consistency plus model judgment — not absolute truth. The judge excerpt
is bounded to 4,000 chars of reference text, so claims grounded only in
later sections can be conservatively rejected; Simple Wikipedia stubs
shrink coverage scores for borderline sentences (the judge-rescue path
exists precisely to compensate).

---

## Verified Full-Dataset Training (`scripts/train_verified.sh`)

The verified replacement for `train24h.sh`: same dual-Ollama fan-out plus
`--fact-check` on every generated-text pass and a one-time full
`datasets/` sweep.

```bash
LOCAL_MODEL=qwen2.5:3b REMOTE_MODEL=qwen2.5:3b TRAIN_VERIFIED_HOURS=48 \
    nohup bash scripts/train_verified.sh > logs/train_verified_driver.log 2>&1 &
```

| Env var | Default | Description |
|---------|---------|-------------|
| `TRAIN_VERIFIED_HOURS` | `48` | Session length in hours |
| `LOCAL_MODEL` / `REMOTE_MODEL` | `qwen2.5:3b` | Teachers on local/remote Ollama |
| `FC_JUDGE_RATE` / `FC_THRESHOLD` | `10` / `550` | Fact-check tuning |

**Phases:**

0. **Retire** — stops any running `train24h.sh` (stopfile + PID kill), then
   merges `qstar_corpus_{a,b}.txt` + `qstar_corpus.txt` into a deduplicated
   `datasets/verified_seed.txt` and copies it to fresh per-worker corpora
   `qstar_corpus_v{a,b}.txt` (originals preserved).
1. **Full dataset** — top-level `datasets/` dirs split evenly by sorted
   parity; each worker runs `train-corpus --ingest-dir <d> --enrich-dir <d>
   --fact-check` per dir. Resumable via `datasets/verified_done/*.done`
   markers; enrich checkpoints every 10 files.
2. **Loop** — `train-internet` over half the built-in 1,345-title sweep
   (`--offset`/`--limit` per worker) + the worker's 110-topic article
   shard, then `train --prompts` on its prompt shard — all fact-checked.

**Control:** `logs/train_verified_{A,B}.log` · `logs/train_verified.pid` ·
`touch datasets/train_verified.stop` for graceful stop.

---

## Dataset Ingestion

### Direct Ingestion (No Ollama)

```bash
zig build cli -- ingest-corpus datasets/Gov --corpus-file qstar_corpus.txt
zig build cli -- ingest-corpus datasets/AdmPaul --corpus-file qstar_corpus.txt
```

### Ollama-Enriched Ingestion

```bash
zig build cli -- enrich-corpus datasets/Gov --corpus-file qstar_corpus.txt
```

### Full Pipeline (Ingest + Enrich)

```bash
zig build cli -- train-corpus --ingest-dir datasets/Gov --enrich-dir datasets/AdmPaul
```

### How Direct Ingestion Works

1. Loads existing corpus
2. Recursively scans directory for `.md`, `.txt`, `.tex` files
3. For each file:
   - Reads content via `doc_loader.processFile()`
   - Strips markdown formatting (headers, code blocks, links)
   - Extracts prose sentences
   - Calls `agent.learnFromText(text)` to add to corpus
   - Saves corpus every 10 files (crash recovery)
4. Reports files scanned, files read, sentences learned, bytes processed

### How Ollama Enrichment Works

1. Same as direct ingestion, but additionally:
2. For each file, extracts a representative excerpt
3. Sends excerpt to Ollama with a key-sentence extraction prompt
4. Learns from both Ollama's response AND the raw file text
5. This hybrid approach captures both curated summaries and full content

### Dataset Results

| Dataset | Files | Sentences | Bytes | Content |
|---------|-------|-----------|-------|---------|
| Gov | 540 | 49,090 | 2,917,070 | Legal, ethics, financial, onboarding, governance |
| AdmPaul | 73 | 6,600 | 369,799 | Sci-fi lore, governance, technical architecture |
| **Total** | **613** | **55,690** | **3,286,869** | |

---

## Corpus Management

### File Format

The corpus file (`qstar_corpus.txt`) is a plain-text file with one sentence per line. It is loaded at startup by `loadCorpusFromFile()`, which auto-detects `.qsc` containers by magic bytes. Both raw `.txt` and `.qsc` inputs are read through the **bounded 12 MB `dynamic_corpus` window** — only the most recent ~10 MB is retained in memory, so corpus files of any size (including the 2.9 GB full corpus) load with constant memory.

### The Session Delta (persistence model)

The agent's `dynamic_corpus` is a *bounded working window*, not the canonical corpus. Sentences learned during a session are recorded in a separate durable log, `session_learned`, which is never trimmed:

- `learnFromText()` (interactive/training learning) — records each accepted sentence into `session_learned`.
- `learnFromTextStreaming()` (bulk `.qsc`/`.txt` ingestion) — does **not** record; bulk input is already persisted on disk.
- `loadCorpus()` (raw text load) — does **not** record; it is input, not learned knowledge.

### Saving — delta-append (never truncates)

```zig
const flushed = try training.saveCorpusToFile(&agent, "qstar_corpus.txt");
// flushed.bytes / flushed.sentences describe what was appended this call.
```

`saveCorpusToFile` appends only the *unflushed* session delta to the corpus file (open-or-create, seek-end, write, fsync). The existing corpus is **never truncated** — a session watermark (`session_persisted`) ensures repeated saves append only new bytes. For `.qsc` container inputs the delta cannot be appended to a compressed container, so it is written to a `<base>.learned.txt` sidecar that chat/run/serve auto-load alongside the container.

> **Regression note (2026-09):** an earlier implementation truncated the destination and serialized only the in-memory window — destroying a 210 MB / 3.6M-sentence corpus down to its 10 MB tail. Delta-append eliminates that failure mode structurally.

`saveCorpusSnapshotToFile` remains for the rare explicit export: it writes the retained window + pending delta via temp file + atomic rename.

### Periodic Saving

- Internet training: saves every 5 articles
- Dataset enrichment: saves every 10 files
- Final save at end of each training run
- All periodic saves are delta flushes — cheap, and bounded memory via buffer compaction

### Resumable Training

Use `--offset N` with `train-internet` to skip articles already processed. The corpus file preserves all previously learned sentences, so resuming only adds new content.

---

## Architecture

```
┌─────────────────────────────────────────────┐
│              CLI (main.zig)                   │
│   train / train-internet / ingest-corpus /    │
│   enrich-corpus / train-corpus               │
├─────────────────────────────────────────────┤
│           training.zig                        │
│  ┌─────────────┐  ┌──────────────────────┐  │
│  │ Self-Train  │  │ Internet Training    │  │
│  │ (Ollama)    │  │ (Wikipedia API)      │  │
│  └─────────────┘  └──────────────────────┘  │
│  ┌─────────────┐  ┌──────────────────────┐  │
│  │ Ingest Dir  │  │ Enrich Dir           │  │
│  │ (doc_loader)│  │ (doc_loader+Ollama)  │  │
│  └─────────────┘  └──────────────────────┘  │
├─────────────────────────────────────────────┤
│           agent.zig                          │
│    learnFromText() → sentence extraction     │
│    → dedup → dynamic_corpus append           │
├─────────────────────────────────────────────┤
│   qstar_corpus_large.txt (2.9 GB, 65,787,307 lines)  │
│   + session delta appended; .qsc → .learned.txt sidecar│
└─────────────────────────────────────────────┘
```

---

## Full Training Push (2026-09-01)

Competitive push against OpenAI (gpt-4o-mini) — "beat them everywhere":

| Stage | Command | Result |
|-------|---------|--------|
| Prompt training | `zig build cli -- train --teacher openai` | 300 prompts, +5,163 sentences (3,627,595 → 3,632,758) |
| Internet training | `zig build cli -- train-internet --no-ollama` | 1,155 Wikipedia articles, 46 MB fetched, +366,625 sentences (→ 3,999,383) |
| Corpus rebuild | `zig build corpus` | 327 MB raw → 4,779 pages `.qsc` |
| Re-benchmark | `zig build competitive-bench -- --no-ollama --openai-judge` | 52 prompts, OpenAI judge |

### Benchmark delta (52 prompts, gpt-4o-mini judge)

| Metric | Baseline (pre-push) | Post-push | Delta |
|--------|--------------------:|----------:|------:|
| Qstar wins | 17 | 17 | 0 |
| OpenAI wins | 29 | 34 | +5 |
| Ties | 6 | 1 | −5 |
| factual wins | 2 | **4** | **+2** |
| factual relevance | — | **0.93 vs 0.80** | Qstar > OpenAI |
| reasoning wins | 3 | 2 | −1 |
| chitchat wins | 8 | 8 | 0 |

The push improved factual knowledge decisively (Qstar's factual answers now
score relevance 0.93 vs OpenAI's 0.80, wins 2→4). The remaining gap is
subjective categories (opinions, open_ended) where the judge's naturalness
score favors OpenAI's longer, more fluent answers despite equal relevance.

Baseline (pre-push): Qstar 17W / OpenAI 29W / 6 ties. Results archived in
`/home/admpaul/Desktop/PJ/.archives/qstar-llm-20260901-master-node/`.

The trained corpus feeds the master node publish pipeline (`zig build master`):
the distilled subset is embedded in `universe.html` and the full `.qsc` is
served for quine autoupdates.

---

## Corpus Defaults

As of the latest update, all commands default to `qstar_corpus_full.qsc` (compressed, all pages streamed on demand):

| Command | Default Corpus | Override |
|---------|---------------|----------|
| `chat` | `qstar_corpus_full.qsc` (all pages) | `--txt <path>` for raw text, `--max-pages N` to bound |
| `run` | `qstar_corpus_full.qsc` (all pages) | `--corpus <path>` for any file |
| `serve` | `qstar_corpus_full.qsc` (all pages) | `--corpus <path>` for any file |
| `train` | `qstar_corpus.txt` | `--corpus <path>` for any file |

Environment variables:
- `QSTAR_CORPUS_QSC` — override the default .qsc path
- `QSTAR_CORPUS_MAX_PAGES` — limit pages loaded (0 = all)

---

## Generated Prompts Training

### Overview

The `prompt_generator.zig` module (`src/prompt_generator.zig`, 160 lines) generates diverse training prompts using Ollama. The `training.trainOnGeneratedPrompts` function orchestrates the full cycle: generate prompts → get teacher responses → learn from responses.

### Training Heartbeat

The training heartbeat (`src/heartbeat.zig`, 680 lines) runs a continual learning cycle that combines all training sources:

1. **Corpus loading** — Loads `qstar_corpus.txt` (or `.qsc` container) into the agent
2. **Memory learning** — Extracts `key_insight` and `summary` fields from `qstar_memory.json`
3. **Benchmark learning** — Extracts `text` fields from benchmark result JSONs, filtered by minimum score
4. **Turing learning** — Extracts prompts and responses from `turing_results.json`
5. **Generated prompts** — Optionally generates prompts via Ollama and learns from teacher responses
6. **Bigram rebuild** — Rebuilds bigram model from combined corpus (skipped if no tokenizer)
7. **Corpus save** — Saves updated corpus back to file
8. **KG save** — Saves knowledge graph to `qstar_kg.bin`
9. **Compression** — Optionally compresses corpus (skipped with `--no-compress`)
10. **Maple push** — Optionally pushes to Maple network (skipped with `--no-maple`)

### CLI Usage

```bash
# Single cycle (no Ollama, no Maple, no compression)
zig build training-heartbeat -- --once --no-maple --no-compress --verbose

# With generated prompts (requires Ollama)
zig build training-heartbeat -- --once --gen-prompts --ollama-host 127.0.0.1 --ollama-port 11434 --ollama-model qwen2.5:3b

# Daemon mode (runs every 77 seconds)
zig build training-heartbeat -- --interval 77 --verbose
```

### Generated Prompts Flow

```
Ollama (prompt generation) → generateRandomPrompts() → GeneratedPrompt[]
    ↓
Ollama (teacher) → generate() for each prompt → teacher response text
    ↓
agent.learnFromText(teacher response) → new sentences in dynamic corpus
    ↓
Optional: save generated prompts to generated_prompts.json
```
