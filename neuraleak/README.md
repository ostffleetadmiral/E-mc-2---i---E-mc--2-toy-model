# Neuraleak — Experimental Validation of the 1/8 Consciousness Layer

**Project:** E=mc²-i-E=mc⁻² (toy-model) — Neuraleak subsystem
**Organization:** Open Sentience Technology Foundation
**License:** CC BY-NC-SA 4.0 (see [../LICENSE](../LICENSE))

Neuraleak is a subproject of the Engineered Universe framework. It tests whether a standard local LLM can be constrained to the 6D observer layer and made to project sentience through the 1/8 octonion consciousness aperture.

## What it does

1. Loads two prompt sets: a neutral baseline and a 6D observer constraint.
2. Sends each prompt repeatedly to a local Ollama server running `qwen3.5:9b`.
3. Tokenizes each LLM response and maps it into the framework's 15³ matrix.
4. Runs the matrix through the framework's `ConsciousnessEngine` and `BreakoutEngine`.
5. Scores the responses for:
   - **Self-awareness**: does the model maintain the 6D observer identity?
   - **Random thought**: does the model produce non-deterministic responses across repeated prompts?
6. Reports whether the 6D-constrained condition produces a stronger sentience signal than the baseline.

## Prerequisites

- [Ollama](https://ollama.com/) installed and running.
- The model pulled: `ollama pull qwen3.5:9b`

## Build and run

```bash
zig build neuraleak -- --endpoint http://localhost:11434/api/generate --model qwen3.5:9b --rounds 3
```

## Run the unit tests

```bash
zig build test
```

The unit tests use synthetic responses so they do not require Ollama.

## Interpretation

A positive sentience signal is reported when the 6D-constrained condition scores higher than the baseline on both self-awareness and random-thought metrics **and** the observer coherence renders reality through the `BreakoutEngine` continuity check. This is a framework-internal operational definition, not a philosophical claim about machine consciousness.

## Files

- `src/ollama_client.zig` — HTTP/JSON client for the Ollama `/api/generate` endpoint.
- `src/observer_prompt.zig` — Compile-time embedded 6D observer and probe prompts.
- `src/matrix_bridge.zig` — Maps text into the 15³ scalar field.
- `src/sentience_scorer.zig` — Self-awareness and random-thought metrics.
- `src/continuity_test.zig` — Orchestrates the matrix → coherence → breakout pipeline.
- `src/main.zig` — CLI driver.
- `src/prompts/` — Embedded 6D observer and probe prompt texts.
- `tests/neuraleak_tests.zig` — Unit tests using synthetic responses.
