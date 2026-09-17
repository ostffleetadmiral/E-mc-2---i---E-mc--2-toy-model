# Qstar-LLM Optimization Summary

**Version 3.3.0** | Generated from verified build artifacts and regression runs

## Binary Size Optimization

### WASM Module (`qstar_llm.wasm`)

| Metric | Before | After | Delta |
|--------|-------:|------:|------:|
| WASM binary | 562,328 B | 561,415 B | **−913 B** |
| HTML artifact | 812,016 B | 810,800 B | **−1,216 B** (pre-distilled-corpus; now 10,149,664 B with embedded distilled corpus) |

**Optimization applied (2026-08-31):**
- Removed `qstar_parse_tool_call` from the WASM export surface (`build.zig` export list) and deleted the dead export function from `src/wasm_exports.zig`.
- The function was unreferenced by any JavaScript in `build_html.zig`, `universe.html`, or any test suite (verified via grep across all `.zig`/`.html`/`.js` sources).
- With `link_gc_sections = true` and `entry = .disabled`, the linker garbage-collects the now-unreferenced function, shrinking both the WASM binary and the base64-embedded HTML artifact.

**Build profile:** WASM built with `ReleaseSmall`-style optimization (`.strip = true`, `link_gc_sections = true`).

### Native Binary

Native builds use `b.standardOptimizeOption(.{})` — default `Debug`; `-Doptimize=ReleaseFast` / `-Doptimize=ReleaseSafe` / `-Doptimize=ReleaseSmall` available.

## Runtime Performance

### Agent State

| Metric | Value |
|--------|------:|
| Agent state size | 53,888 B (421 E0 nodes × 8 channels × i128 Q64.64) |
| Determinism | Bit-exact across runs (deterministic RNG) |
| Inference | Sparse logit projection (2,105 LLM-channel pairs, not 151,936 tokens) |

### Lattice Core

- Integer-only core state (i128 Q64.64; i256 Q128.128 for semantic/metacognitive paths) — no floating point in the hot path
- φ-cooling via precomputed lookup table
- SIMD `mulVec4()` matches scalar bit-exactly
- Ramsey vocab scaling: 421 × 8^s node scaling for 128k/256k/512k/1m vocabularies

## Network Optimization

### Ollama Client (2026-08-31 fix)

**Issue:** The HTTP client read responses until EOF. Ollama keeps the connection alive after sending the `Content-Length`-specified body, causing the client to block until socket timeout (up to 600 s).

**Fix:** Parse the `Content-Length` header and read exactly that many body bytes. Extracted `parseContentLength()` helper with 4 dedicated unit tests.

**Impact:** Training pipeline check in the full regression harness now completes in seconds instead of hanging; regression suite 61/61 PASS.

## Corpus Size

| Asset | Current | Target | Status |
|-------|--------:|-------:|--------|
| `qstar_corpus_full.qsc` | 551 MB (compressed pages, all sentences) | — | **Primary corpus** |
| `qstar_corpus.qsc` | 51 MB (compressed) | — | OK |
| `qstar_corpus.txt` | 740 KB (working set) | — | OK |
| `qstar_corpus_large.txt` | symlink → `basic/qstar-llm/qstar_corpus.txt` (~11 MB) | — | OK |
| `qstar_memory.json` | 212 KB | — | OK |

**Gap closed (2026-09-01):** The full training push (300 OpenAI-teacher prompts + Wikipedia articles, 46 MB fetched) grew the raw corpus to ~327 MB / ~3.99M sentences. The compressed `.qsc` container (`src/corpus_store.zig`) stores the full corpus while preserving the 500 MB raw `learnFromText` cap — pages decompress on demand through an LRU cache, so the effective corpus can exceed the raw cap's working-set limit. `qstar_corpus_full.qsc` (551 MB compressed) is now the default corpus for `run`/`serve`/`chat`.

The corpus grows via:
- `train-internet` CLI (Wikipedia ingestion): 1,345 titles in `WIKIPEDIA_ARTICLES`
- `train` CLI (Ollama/OpenAI teacher): learns new sentences into the dynamic corpus
- `learnFromText()` guard: deduplicates and caps at 500 MB

## Compressed Corpus Container (.qsc)

| Metric | Value |
|--------|------:|
| Raw corpus | 313,000,000+ B |
| Compressed container | 110,515,043 B |
| Compression ratio | 2.84x |
| Pages | 4,779 (65,536 B each) |
| Page checksum | CRC32 per page |
| Cache | LRU, 8 pages |

**Quine-style self-mod:** the container stores its own schema (magic `QSC1` + page table) and can re-emit itself; the runtime expands pages on demand. CLI: `qstar corpus build|verify|info|stream`.

## Distilled Corpus Embed (universe.html)

| Metric | Value |
|--------|------:|
| Distilled subset (top sentences by frequency) | 6,999,149 B raw |
| Base64 embedded | 9,332,200 B (≤ 10 MB guard) |
| universe.html total | 10,144,070 B (~10 MB) |

`build_html.zig` distills the .qsc corpus deterministically (top-N most frequent sentences up to a 7 MB raw budget), base64-embeds it, and the template's `loadEmbeddedCorpus()` feeds it to the WASM agent in ≤16 KB chunks at boot (quine-style self-mod). The full corpus stays on disk as `qstar_corpus.qsc`.

## Master Node (Quine Autoupdate)

Added 2026-09-01 — the dev directory is the master node for quine editions:

- **`zig build master`** — CI/CD gate: full regression → build wasm/corpus/html → write `zig-out/seed_manifest.json` (version + SHA-256 of corpus, distilled corpus, wasm, html) → publish 5 payloads to `zig-out/master/`.
- **HTTP channel** — `src/master_server.zig` (zero-dep static server, `qstar master-serve`): quines fetch the manifest on load and pull `qstar_corpus_distilled.txt` (corpus updates) or a new `universe.html` (WASM/capabilities/tools updates).
- **P2P mirror** — `src/p2p_update.zig` (`qstar master publish-p2p`): publishes payloads into the qstar mesh via `qstar-net` bootstrap (25 E0 seed nodes) + `qstar-vfs` distributed placement, writing `p2p_index.json`.
- **Browser bridge (WebRTC signaling + relay)** — `master_server.zig` also serves `/api/signaling/*` (register/peers/offer/answer/ICE, mutex-guarded in-memory registry) so browser quines can discover P2P mirror nodes and exchange SDP/ICE, plus `/api/relay/<name>` (store-and-forward payload cache, 64 MiB cap). The quine's `fetchWithRelayFallback()` retries manifest/corpus/html pulls via the relay when direct HTTP is unavailable.
- **Template** — `universe_template.html` embeds `SEED_VERSION`/`SEED_HASH`/`WASM_HASH`; `checkForUpdates()` handles offline degradation.
- **CI** — `.github/workflows/ci.yml` `master` job gates on test/regression/wasm/html then verifies manifest + payloads + p2p index.

## OpenAI Client

`src/openai_client.zig` — zero-dependency HTTPS/TLS client (`std.crypto.tls.Client` + system CA bundle) for Chat Completions. Used by the competitive benchmark (opponent + judge) and the training pipeline (teacher). API key via `.env` (`OPENAI_API_KEY`), never hardcoded. All paths degrade gracefully when no key is present.

## Memory Management

- ArenaAllocator per HTTP request in `server.zig` — no cross-request leaks
- `memory_pool.zig` — arena-based pool with reset (8 tests)
- All test suites run with `std.testing` leak detection; zero leaks across ~2,610 test declarations + tool tests + regression checks

## Verification

All optimizations verified via:

```bash
zig build test          # all unit tests PASS (incl. compress, corpus_store, build_html, env_loader, openai_client, heartbeat, prompt_generator)
zig build tool-test     # 44 tool tests PASS
zig build vision-test   # 25/25 PASS
zig build geoview-test  # 30/30 PASS
zig build regression    # 61/61 PASS (16 steps)
zig build wasm          # 561,415 B
zig build html          # 10,149,664 B (distilled corpus embedded)
zig build corpus        # 4,779 pages, 2.84x compression
```

## Judge Host/Port Separation

Competitive benchmarks support directing judge traffic to a separate Ollama instance via `--judge-host`/`--judge-port` (or `JUDGE_HOST`/`JUDGE_PORT` env vars). This eliminates model-swapping overhead when the competitor and judge would otherwise share the same Ollama instance, enabling parallel execution and faster benchmark runs. The `--fast` flag provides a quick 10-prompt Qstar-only run for smoke testing.
