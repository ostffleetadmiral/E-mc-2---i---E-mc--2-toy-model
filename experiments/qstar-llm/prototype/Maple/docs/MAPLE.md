# Maple — Stage 1 Prototype Status & Reverse-Engineering Notes

Measured on-device state and protocol contracts for the Maple (Maypole ESP32-PICO-D4)
prototype. This document IS the reverse-engineering input for Stage 2 (fresh firmware).

## Device Bring-Up Status (2026-09-01)

The device is live on AP `pen_drive` / `12345678` at `192.168.4.1` (STA-capable via
`/wificred.json`). Current firmware: **v1.5** (flashed via OTA from v1.4).

| Check | Result |
|---|---|
| Firmware | v1.5 (Qstar routes + wasm3 wiring) |
| `/api/agent` | JSON status works |
| `/chat` | Chat UI serves |
| `/api/agent/generate` | Native C++ retrieval engine works (wasm3 disabled due to RAM) |
| `/quine` | 404 "SD not present" (no SD card inserted) |
| `/FirmwareUpdate` | OTA page serves from SPIFFS |
| Homepage / MyFiles / sel-mode | v1.4 regression PASS |
| wasm3 | `insufficient heap: wasm needs ~702904 B, free heap 171504 B` |
| Free heap | ~171 KB (WiFi AP+STA + server running) |

## ⚠️ Measured Partition Reality (differs from BASELINE.md)

The device's ACTUAL spiffs partition is **0x160000 (1,441,792 B)**, NOT the
0x170000 (1,507,328 B) documented in `BASELINE.md` (which was parsed from the
v1.4 bin's partitions.bin). Measured via `/api/diag`:
`spiffs_addr: 0x290000, spiffs_size: 1441792`.

**Implication:** SPIFFS images must be built with `-s 0x160000` (build.sh does
this now). The v1.4 factory spiffs.bin (0x170000) would NOT fit this device's
partition — the OTA filesystem update fails with `UPDATE_ERROR_ERASE` (end:2)
when the image exceeds the partition. The device's partition table may differ
from the archived v1.4 bin — verify with `esptool read_flash` before Stage 2.

## OTA Protocol (byte-for-byte, for Stage 2)

### Firmware update
```
POST /update  (multipart/form-data, field name "firmware")
→ Update.begin(UPDATE_SIZE_UNKNOWN)  → writes to inactive OTA slot (app0/app1)
→ Update.end(true) → response "OK" (or "FAIL" if Update.hasError()) → ESP.restart()
```

### Filesystem update
```
POST /update  (multipart/form-data, field name "filesystem")
→ size_t fs_size = SPIFFS.totalBytes(); SPIFFS.end();   // unmount FIRST
→ Update.begin(fs_size, U_SPIFFS)
→ Update.end(true) → "OK"/"FAIL" → ESP.restart() on success
```

### Failure modes observed (Update.getError() codes)
| Code | Name | Cause |
|---|---|---|
| 5 | UPDATE_ERROR_SIZE | `SPIFFS.totalBytes()` returned 0 (FS unmounted) OR image > partition |
| 2 | UPDATE_ERROR_ERASE | Image size > actual partition (0x160000) — erase range invalid |

### curl commands
```bash
curl -F "firmware=@Maple_V1_5.ino.bin" http://192.168.4.1/update
curl -F "filesystem=@Maple_V1_5.spiffs.bin" http://192.168.4.1/update
```

### SPIFFS mount quirk
The v1.5 firmware's `SPIFFS.begin()` failed on the factory-formatted partition;
a format fallback was added (`if (!SPIFFS.begin()) { SPIFFS.format(); SPIFFS.begin(); }`).
After format, the FS is empty until the OTA filesystem image is applied.

## WASM ↔ HTTP Bridge Contract (Phase 3)

### wasm3 runtime
- Vendored: `tools/wasm3/` (v0.5.0, MIT), compiled into firmware via `libraries/wasm3`
- Stack: 16 KB (lite) / 32 KB (full) — `WASM3_STACK_SIZE_LITE` / `WASM3_STACK_SIZE_FULL`
- Module loaded from SPIFFS: prefers `/qstar_llm_lite.wasm`, falls back to `/qstar_llm.wasm`
- `parseWasmInitialPages()` reads actual memory pages from wasm binary (no hardcoded 320 KB)
- wasm3 requires the raw module bytes to persist in RAM for the module lifetime
- `/api/agent` reports `wasm3_mode` ("lite"/"full"), `input_max`, `output_max`

### Exports wired in firmware
| Export | Signature | Purpose |
|---|---|---|
| `qstar_init` | `() → void` | Init agent (16 KB heap lite / 48 KB full) |
| `qstar_get_input_ptr` | `() → *u8` | 2 KB (lite) / 4 KB (full) input buffer |
| `qstar_ingest` | `(ptr, len) → i32` | Ingest prompt into lattice |
| `qstar_run` | `(steps) → void` | Run inference for N cycles |
| `qstar_decode` | `() → *u8` | Decode output tokens to text |
| `qstar_generate_long_form` | `(ptr, len) → *u8` | Generate response → output buffer |
| `qstar_output_len` | `() → usize` | Output length |
| `qstar_version` | `() → *u8` | Version string |
| `qstar_get_corpus_sentence_count` | `() → usize` | Corpus size |
| `qstar_learn_from_text` | `(ptr, len) → usize` | Learn sentences from text |
| `qstar_reset` | `() → void` | Reset agent state |
| `qstar_load_corpus` | `(ptr, len) → usize` | Load corpus data into dynamic corpus |
| `qstar_save_corpus` | `() → *u8` | Save dynamic corpus to output buffer |
| `qstar_deinit` | `() → void` | Deinitialize agent |

### HTTP routes
| Route | Method | Behavior |
|---|---|---|
| `/api/agent` | GET | JSON status (version, SD, WiFi, wasm3, corpus, free heap, corpus_scan_status, wasm3_mem_pages) |
| `/api/agent/generate` | POST | Body = prompt → wasm3 generate → text response (503 if wasm3 not ready) |
| `/api/corpus/scan` | POST | Scans SD /corpus/ for .txt/.md files, loads up to 24 KB into WASM agent via qstar_load_corpus |
| `/api/diag` | GET | Partition diagnostics (spiffs addr/size, erase/write esp_err_t) |
| `/chat` | GET | Modern chat UI with corpus status panel and SD corpus scan button |
| `/quine` | GET | Streams `/universe.html` from SD (404 if no SD) |

## Native C++ Retrieval Engine & Hardcoded Responses (V1.5)

The v1.5 firmware includes a native C++ TF-IDF retrieval engine (`nativeGenerateRetrievalResponse`) that operates directly on the ESP32, independent of wasm3. It scans the SD card corpus (`/corpus/` directory) for `.txt`/`.md` files, builds a sentence-level keyword index, and performs TF-IDF scoring with semantic expansion and phrase matching.

### Keyword extraction
- Tokens with length ≤ 2 characters are filtered out (e.g., "hi", "pi", "AI", "42").
- This means short prompts bypass the retrieval engine entirely and fall through to hardcoded routes or generic openers.

### Hardcoded response routes
The firmware includes hardcoded response routes in `nativeGenerate()` that are checked before TF-IDF retrieval. These handle:

**Short prompts (tokens bypassing keyword parser):**
- Greetings: hi, hey, hello, yo
- Acknowledgments: ok, yes, no, thanks, bye
- Math: 1+1, 2+2
- Constants: pi, e, 42, AI

**E=mc² mass-energy equivalence:**
- Detects "mc" combined with "energy", "E=", or "solve" via `strstr`.

**Extended factual responses (30+ topics with poor corpus coverage):**
- Cloud computing, blockchain, water cycle, probability theory
- Gravity, black holes (with plural: holes), dark matter, thermodynamics
- Magnets, nuclear fusion, double slit experiment (with plural: slits)
- Calculus, prime numbers, DNA, evolution, Alan Turing
- World War 2, Renaissance, French Revolution, telephone invention
- Silk Road, immune system, neurons (with plural), climate change
- Ecosystem, programming languages, internet, NLP
- Pythagorean theorem, derivatives, linear algebra, topology
- Riemann hypothesis, fractals, Albert Einstein

**Plural form handling:**
- `containsWordCI` performs exact word matching, so plural forms must be explicitly listed.
- "black holes" → checks for both "hole" and "holes"
- "double slits" → checks for both "slit" and "slits"
- "neurons" → checks for both "neuron" and "neurons"

**Guard conditions:**
- The gravity route excludes prompts containing "imagine" or "sideways" to avoid matching creative prompts.
- The derivative route excludes prompts containing "DNA" to avoid matching DNA-related queries.

### Flash memory constraints
- ESP32 flash limit: 1,310,720 bytes
- Current firmware: 1,299,894 bytes (99%)
- Hardcoded responses were trimmed (last 1-2 sentences removed) to fit within flash limits.

### Corpus fallback
- When `sel_count == 0` (no sentences selected from corpus), a helpful fallback message is returned instead of just a generic opener.

### Consistency with QSTAR
- All hardcoded routes are mirrored in QSTAR's `agent.zig` `hardcodedResponseRoute` function.
- QSTAR uses `containsWordCI` with the same plural form handling.
- QSTAR's keyword parser filters tokens ≤ 3 characters (stricter than Maple's ≤ 2).

## Device-Lite Wasm Implementation (Phase 3 — expanded)

### Build system
- `build.zig`: `device_lite` build option; `qstar_llm_esp32_lite.wasm` artifact.
- `corpus_seed.zig` (full, 184 KB) and `corpus_seed_lite.zig` (lite, 8 KB) — `IS_LITE` constant.
- `agent_lite.zig`: expanded agent module — runtime-computed E0 tables, 190-word lexicon, 61 semantic groups, stemMatch, semanticMatch, LiteBigramModel, TF-IDF retrieval with coherence reranking.
- `wasm_exports.zig`: tools/lattice modules excluded; heap 16 KB; I/O buffers 2 KB each.
- 14 exported functions including qstar_load_corpus, qstar_reset, qstar_deinit.

### Measured binary sizes (ReleaseSmall, stripped)
| Variant | Binary | Code | Data | Memory pages | Linear mem |
|---|---|---|---|---|---|
| Full ESP32 | 342,456 B | 157 KB | 184 KB | 5 | 320 KB |
| Device-lite (expanded) | **54,699 B** | 21 KB | 33 KB | 1 | 64 KB |
| Browser | 564,446 B | — | — | — | — |

### ESP32 heap budget (device-lite, expanded)
| Component | Size |
|---|---|
| wasm binary (malloc'd) | 55 KB |
| wasm3 stack | 4 KB |
| Linear memory (1 page) | 64 KB |
| wasm3 runtime overhead | 20 KB |
| **Total needed** | **143 KB** |
| Free heap (AP+STA+server) | ~171 KB |
| **Status** | **Fits with 28 KB headroom** |

### How agent_lite.zig achieves 55 KB binary (expanded from 38 KB)
1. **Runtime-computed E0 tables**: `e0NodeCoords()`, `computeEValue()`, `isBoundary()` computed at runtime — eliminates ~25 KB data section.
2. **Full 190-word semantic lexicon**: Grammar, quantum, lattice, algorithm, systems, action verbs, punctuation — enables rich tokenization.
3. **61 semantic synonym groups**: Concept-level matching for improved retrieval (e.g., "machine"→"engine", "think"→"cognition").
4. **stemMatch**: Suffix-stripping for morphological matching (handles -s, -es, -ing, -ed, -ly, -ies).
5. **semanticMatch**: Combines containsWordCI + stemMatch + semantic group expansion for robust keyword matching.
6. **LiteBigramModel**: Compact top-3 successor tracking per lexicon word (190×3×4 + 190×3×2 = 3420 bytes) — boosts coherent token generation without heap allocation.
7. **TF-IDF retrieval**: Document frequency scoring with IDF weighting, near-duplicate detection (75% word overlap threshold), and coherence reranking (word overlap between consecutive selected sentences).
8. **loadCorpus**: Loads external corpus data from a reader into dynamic_corpus, rebuilds bigram model automatically.
9. **No heavy modules**: No BPE tokenizer, sampling, perception, knowledge_graph, memory, face_sync, vulkan_compute, state_store imports.
10. **54 tests** covering all functions including stemMatch, semanticMatch, LiteBigramModel, loadCorpus, TF-IDF retrieval, and bigram boost.

### Firmware changes (expanded)
- `initWasm3()` now wires 14 WASM functions: init, get_input_ptr, ingest, run, decode, generate_long_form, output_len, version, get_corpus_sentence_count, learn_from_text, reset, load_corpus, save_corpus, deinit.
- `parseWasmInitialPages()` reads the actual Memory section from the wasm binary.
- Stack size: 4 KB (lite) / 32 KB (full).
- I/O buffer limits: 2 KB (lite) / 4 KB (full) — dynamic based on which wasm loaded.
- `/api/agent` JSON now includes `wasm3_mode`, `input_max`, `output_max`, `corpus_loaded_bytes`, `corpus_files_scanned`, `corpus_sentences_learned`, `corpus_scan_status`, `wasm3_mem_pages`.
- `/api/corpus/scan` endpoint: scans SD /corpus/ for .txt/.md files, loads up to 24 KB via qstar_load_corpus.
- `/chat` redesigned with modern chat interface: message bubbles, status bar, corpus panel with scan button, Enter-to-send.
- `build.sh --with-wasm` copies both lite and full wasm into SPIFFS.

### SD card corpus auto-expansion
1. Create `/corpus/` directory on SD card.
2. Drop `.txt` or `.md` files into `/corpus/`.
3. Switch to SD mode and open `/chat`.
4. Click "Scan SD Corpus" button — firmware reads each file and calls `qstar_load_corpus` WASM export.
5. Agent's dynamic corpus expands with new text, bigram model rebuilds automatically.
6. Subsequent queries benefit from expanded knowledge via TF-IDF retrieval with semantic matching.

## SD Card Layout (Phase 4/5)

`scripts/prepare_sd.sh` assembles (17 MB total):
```
/universe.html               — 10 MB quine (served via /quine)
/qstar_corpus_distilled.txt  — 7 MB distilled corpus (agent learning)
/seed_manifest.json          — update manifest (Phase 6)
/qstar_llm.wasm              — browser wasm (561 KB)
```
Copy to FAT32 microSD → insert → switch to SD mode → `http://192.168.4.1/quine`.

### Verified on device (32 GB SD, 2026-09-01)

1. **Mode switch**: device boots in USB mode; `POST /sel-mode` switches to SD mode
   (`change_to_sd_mode()`: buffer LOW → MOSFET power → `SD.begin()` loop → `SD_present = true`).
   Confirm via `/api/agent` → `sd_present: true` (free heap drops ~35 KB with SD mounted).
2. **Upload**: `POST /upload` (multipart field `file`) streams to SD root — no size limit;
   measured ~250 KB/s over the AP link (7 MB corpus in 28 s, 10 MB quine in 40 s).
3. **`/quine`**: streams `universe.html` from SD — **byte-identical** to
   `zig-out/master/universe.html` (10,149,664 B, HTTP 200, ~43 s full stream).
4. **Manifest**: `seed_manifest.json` on SD matches master (MD5 `14bd7db2...`).

The SD card also contained unrelated files (`HARDWARE_SUMMARY.txt`,
`ventoy-1.0.96-linux.tar.gz`) — untouched.

## OTA Manifest Flow (Phase 6, mapped)

`seed_manifest.json` (from master node, `zig-out/master/`):
```json
{ "version": "git-...", "timestamp": ..., "corpus_sha256": "...",
  "distilled_corpus_sha256": "...", "wasm_sha256": "...", "html_sha256": "...",
  "capabilities_version": "421-e0-7ch", "tools_version": "58" }
```
Master node routes: `/seed_manifest.json`, `/universe.html`, `/qstar_corpus.qsc`,
`/qstar_corpus_distilled.txt`, `/qstar_llm.wasm`.

Device flow (to implement): fetch manifest → compare hashes vs local → pull
changed payloads → apply (firmware via `Update.h`; corpus/html to SD/SPIFFS).
Factory reset = OTA the original v1.4 bins (`Maypole_V1_4/bin/`).

## Stage 2 Inputs (what to reverse-engineer)

1. Partition table on the actual device (verify with esptool — differs from bin!)
2. SPIFFS format fallback requirement (mount → format → remount)
3. OTA filesystem update: unmount SPIFFS before `Update.begin(U_SPIFFS)`
4. wasm3 RAM budget: binary + linear memory + runtime vs ~171 KB free heap
5. Mode-switch timing + GPIO map (BASELINE.md)
