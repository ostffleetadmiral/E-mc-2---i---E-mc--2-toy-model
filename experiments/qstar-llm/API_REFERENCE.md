# Qstar-LLM API Reference

Canonical location: [docs/API_REFERENCE.md](docs/API_REFERENCE.md)

Notes on current types (as of the Q128.128 migration):

- `metacognition_engine.EvaluationResult.scores` is `[8]q128.Fp` (i256), `overall` is `q128.Fp`.
- `SelfModel` fields (`activation_entropy`, `channel_imbalance`, etc.) are `q128.Fp`.
- Trivium and Quadrivium layer scores are `q128.Fp`; lattice activations are `[]const [8]i128` (8 channels).
- `voice_codec.zig` uses its own internal `CHANNEL_COUNT = 7` representation (`[421][7]i128` speaker hypervectors, `[7]i128` spectral envelopes) — this is the audio codec's own layout, not the agent state.
- The agent lattice state is `[421][8]i128` (53,888 bytes); LLM tokens map to channels e1–e5.
