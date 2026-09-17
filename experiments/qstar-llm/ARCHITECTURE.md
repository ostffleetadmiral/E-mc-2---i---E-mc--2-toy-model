# Qstar-LLM Architecture

Canonical location: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md)

Current architecture facts:

- **Lattice state**: 421 E0 nodes × 8 channels (e0–e7) = `[421][8]i128` = 53,888 bytes. LLM tokens occupy channels e1–e5; e0 (origin), e6 (self-recognition), e7 (shadow/gravity) are reserved.
- **Arithmetic tiers**: lattice state is Q64.64 (i128, i256 intermediates); the metacognition/semantic layer is Q128.128 (i256, i512 intermediates via `q128.zig`); peripherals downscale to Q32.32 (i64) via `fp_bridge`.
- **GPU path**: `vulkan_compute.zig` + shaders use a separate 7-channel prototype layout.
- **External sidecars (optional)**: ONNX Runtime + Vulkan via dlopen; Ollama / llama-server / OpenAI / Kimi as teachers and confidence-routed fallbacks.
- **Tests**: ~2,610 total (2,536 in src + 74 in tests/).
