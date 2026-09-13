# Training Pipeline

Complete reference for Qstar-LLM's training framework: self-training, internet training (Wikipedia API), and local dataset ingestion.

---

## Overview

Qstar-LLM supports four training modes, all managed through `src/training.zig` (1,234 lines):

1. **Self-Training** — Ollama or OpenAI acts as teacher, generating responses that the agent learns from
2. **Internet Training** — Fetches plain-text Wikipedia articles via MediaWiki API and learns sentences
3. **Dataset Ingestion** — Recursively loads local .md/.txt/.tex files, strips markdown, extracts sentences
4. **Ollama Enrichment** — Hybrid: Ollama extracts key sentences from documents + direct ingestion

All modes support resumable execution, periodic corpus saving for crash recovery, and append to the same `qstar_corpus.txt` file. The corpus can be stored as a compressed quine-style `.qsc` container (`src/corpus_store.zig`) for on-demand page decompression within the 500 MB raw `learnFromText` cap.

---

## Self-Training (Ollama / OpenAI Teacher)

### CLI Command

```bash
zig build cli -- train --model qwen2.5:3b --corpus qstar_corpus.txt
zig build cli -- train --teacher openai --openai-model gpt-4o --limit 3
```

### Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--model <name>` | `qwen2.5:3b` | Ollama model to use as teacher |
| `--corpus <path>` | `qstar_corpus.txt` | Corpus file to load/append |
| `--verbose` | off | Print per-prompt progress |
| `--teacher <name>` | `auto` | Teacher: `ollama`, `openai`, or `auto` (OpenAI if key present, else Ollama) |
| `--openai-model <name>` | `gpt-4o` | OpenAI teacher model |
| `--openai-key <key>` | `.env` | OpenAI API key (overrides `OPENAI_API_KEY`) |

### Teacher Selection (`resolveTeacher`)

- `--teacher openai` → always OpenAI (requires `OPENAI_API_KEY`; fails fast if missing)
- `--teacher ollama` → always Ollama (requires Ollama running)
- `--teacher auto` (default) → OpenAI if `OPENAI_API_KEY` present, else Ollama

### How It Works

1. Loads existing corpus from `qstar_corpus.txt`
2. For each of 140 default prompts across 29 topic categories:
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

Physics, mathematics, computer science, AI/ML, biology, chemistry, earth science, economics, climate, space, medicine, psychology, engineering, security, philosophy, history, literature, geography, law, education, language, sociology, political science, nutrition, technology, logic, arts, music, and general knowledge.

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
| `--no-ollama` | off | Disable Ollama augmentation (Wikipedia-only) |

### How It Works

1. Loads existing corpus from file
2. Iterates through `WIKIPEDIA_ARTICLES` array (1,155 titles) starting at `--offset`
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

The corpus file (`qstar_corpus.txt`) is a plain-text file with one sentence per line. It is loaded at startup by `loadCorpusFromFile()` which reads in 4KB chunks and appends to the agent's `dynamic_corpus` ArrayList.

### Loading

```zig
const loaded = try training.loadCorpusFromFile(&agent, "qstar_corpus.txt");
```

### Saving

```zig
try training.saveCorpusToFile(&agent, "qstar_corpus.txt");
```

### Periodic Saving

- Internet training: saves every 5 articles
- Dataset enrichment: saves every 10 files
- Final save at end of each training run

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
│      qstar_corpus.txt (327 MB, 3,999,383 sentences) │
└─────────────────────────────────────────────┘
```

---

## Full Training Push (2026-09-01)

Competitive push against OpenAI (gpt-4o-mini) — "beat them everywhere":

| Stage | Command | Result |
|-------|---------|--------|
| Prompt training | `zig build cli -- train --teacher openai` | 140 prompts, +5,163 sentences (3,627,595 → 3,632,758) |
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
