# Datasets

Reference for all datasets used in Qstar-LLM training and ingestion.

---

## Overview

Qstar-LLM's knowledge corpus is built from these sources:

1. **Wikipedia articles** — 1,155 titles fetched via MediaWiki API across 7 training batches
2. **Gov dataset** — 1,091 local .md files covering governance, legal, ethics, and financial topics
3. **AdmPaul dataset** — 83 local files covering sci-fi lore, governance, and technical architecture
4. **Reference datasets** — Webster's Dictionary (6 files), Black's Law Dictionary (3 files), General Knowledge (5 files), Wikipedia extracts (3 files)

All sources are ingested into `qstar_corpus.txt` (327 MB, 3,999,383 sentences after the 2026-09-01 full training push).

---

## Wikipedia Training Corpus

### Statistics

| Metric | Value |
|--------|-------|
| Total article titles | 1,155 |
| Successfully fetched | 1,094 |
| Failed/empty | 61 |
| Sentences learned | 248,049 |
| Bytes fetched | ~194MB |
| Training batches | 7 |

### Topic Coverage

| Category | Example Articles |
|----------|-----------------|
| Physics | Quantum mechanics, General relativity, Thermodynamics, String theory, Electromagnetism |
| AI/ML | Artificial intelligence, Neural network, Machine learning, Deep learning, Natural language processing |
| Biology | DNA, Evolution, Cell, Ecology, Microbiology, Neuron |
| Chemistry | Periodic table, Chemical bond, Organic chemistry, Biochemistry, Aluminium, Catalysis |
| Earth Science | Climate change, Ocean, Atmosphere, Geology, Hurricane |
| Economics | Supply and demand, GDP, Inflation, Behavioral economics, Economic globalization |
| Space | Solar System, Black hole, Big Bang, Cosmology, Exoplanet, Apollo program |
| Medicine | Immune system, Vaccine, Antibiotic, Cardiovascular disease, Organ transplant |
| Psychology | Consciousness, Cognitive bias, Dunning-Kruger effect, Memory, Emotion |
| Mathematics | Calculus, Algebra, Statistics, Fractal, Fibonacci, Game theory |
| Engineering | Semiconductor, Transistor, Microprocessor, Telecommunication |
| Philosophy | Descartes, Existentialism, Stoicism, Ethics, Free will, Phenomenology |
| History | World War I, World War II, Cold War, Roman Empire, Ancient Egypt, Renaissance |
| Literature | Shakespeare, Poetry, Novel, Haiku, Film |
| Geography | Earth, Ocean, Mountain, Desert, River |
| Chemistry Elements | Oxygen, Hydrogen, Gold, Iron, Uranium |
| Astronomy | Moon, Sun, Planets, Comets, Supernova |
| CS Extended | Algorithms, Compilers, Turing machines, Cryptography, Quantum computing |
| Logic | Syllogism, Bayesian inference, Critical thinking, Propositional logic, Formal fallacy |
| Native American | Iroquois Confederacy, Navajo, Cherokee, Hopewell, Cahokia, Anishinaabe, Cheyenne, Algonquian |
| General | Human, Mythology, Dreamcatcher, Kiva, Sun dance, Peace pipe |

### Wikipedia API Configuration

- **URL:** `https://en.wikipedia.org/w/api.php?action=query&prop=extracts&explaintext=1&format=json&redirects=1&titles=TITLE`
- **Redirect handling:** `&redirects=1` resolves redirect pages (critical fix)
- **Rate limiting:** 3s delay, exponential backoff (10s/20s/30s)
- **Encoding:** ASCII-only titles (en-dash `–` replaced with hyphen `-`)

---

## Gov Dataset

### Location

`/home/ADMPaul/qstar-llm/datasets/Gov/`

### Statistics

| Metric | Value |
|--------|-------|
| Files | 1,091 |
| Sentences learned | 49,090 |
| Bytes processed | 9MB |
| File types | .md |

### Content Categories

- **Legal** — Statutes, regulations, legal frameworks, compliance procedures
- **Ethics** — Ethical guidelines, codes of conduct, ethical decision-making frameworks
- **Financial** — Budget procedures, financial regulations, audit standards
- **Onboarding** — Administrative procedures, organizational structures, training protocols
- **Governance** — Policy documents, administrative law, governmental structures

### Ingestion Command

```bash
zig build cli -- ingest-corpus datasets/Gov --corpus-file qstar_corpus.txt
```

---

## AdmPaul Dataset

### Location

`/home/ADMPaul/qstar-llm/datasets/AdmPaul/`

### Statistics

| Metric | Value |
|--------|-------|
| Files | 83 (74 .md + 9 .txt) |
| Sentences learned | 6,600 |
| Bytes processed | 15MB |
| File types | .md, .txt |

### Content Categories

- **Sci-fi Lore** — Fictional universe lore, worldbuilding documents, narrative archives
- **Governance** — Administrative frameworks, organizational policies
- **Technical Architecture** — System design documents, technical specifications, architecture references

### Ingestion Command

```bash
zig build cli -- ingest-corpus datasets/AdmPaul --corpus-file qstar_corpus.txt
```

---

## Reference Datasets

### Webster's Dictionary

**Location:** `datasets/webster_dictionary/`

| Metric | Value |
|--------|-------|
| Files | 6 |
| Size | 27MB |
| Content | Webster's Revised Unabridged Dictionary |

### Black's Law Dictionary

**Location:** `datasets/blacks_law/`

| Metric | Value |
|--------|-------|
| Files | 3 |
| Size | 28KB |
| Content | Black's Law Dictionary reference |

### General Knowledge

**Location:** `datasets/general_knowledge/`

| Metric | Value |
|--------|-------|
| Files | 5 |
| Size | 24KB |
| Content | General knowledge reference facts |

### Wikipedia Extracts

**Location:** `datasets/wikipedia/`

| Metric | Value |
|--------|-------|
| Files | 3 |
| Size | 16KB |
| Content | Curated Wikipedia article extracts |

---

## Corpus File

### File

`qstar_corpus.txt`

### Statistics

| Metric | Value |
|--------|-------|
| File size | 258 MiB (270 MB) |
| Lines (sentences) | 2,195,092 |
| Format | Plain text, one sentence per line |

### Growth History

| Stage | Sentences | Delta |
|-------|-----------|-------|
| Pre-training baseline | 3,291,954 | — |
| After Wikipedia (all batches) | 3,540,003 | +248,049 |
| After Gov dataset | 3,589,093 | +49,090 |
| After AdmPaul dataset | 3,595,693 | +6,600 |
| **Final (before rebuild)** | **3,626,707** | **+334,753** |
| **After corpus rebuild** | **2,195,092** | — |

Note: The corpus was rebuilt on 2026-08-29, reducing the line count from 3,626,707 to 2,195,092 (deduplication and format normalization). The training history above reflects the original growth trajectory.

---

## Supported File Types

The `doc_loader.zig` module processes the following file extensions:

| Extension | Processing |
|-----------|-----------|
| `.md` | Markdown stripped (headers, code blocks, links, images) |
| `.txt` | Read as-is |
| `.tex` | LaTeX commands stripped, prose extracted |

All other file types are skipped during directory traversal.
