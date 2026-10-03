# gqa-moe-arch-20260929 — Phase A green state

Generic GQA+MoE architecture family landed as a **parallel path** — no K3
file was mutated (new modules only, plus dispatch wiring in main.zig and
module/test wiring in build.zig).

## Files in this archive

- `gqa_cfg.zig` — strict HF config reader (`model_type` whitelist:
  qwen3_moe, olmoe; qwen3_next/qwen3_5_moe parse but refuse until phase B;
  llama4 refuses its extra attention fields). Absent field = error.
- `gqa_ops.zig` — q128 kernels: `lnQ`/`sincosQ` (series transcendentals at
  full q128 precision — needed because q128.zig's sin/cos tables are
  2pi/1024-grain, too coarse for RoPE), `ropeApply` (rotate-half, partial
  rotary), `qkNorm`, `softmaxQ`, `siluQ`/`swiglu`, `routerTopK`
  (softmax + sigmoid-topk modes), `expertFfn`.
- `gqa_attn.zig` — causal GQA over a caller-owned [pos][nkv][hd] KV cache:
  `gqaAttnStep` (one position) and `gqaAttnSeq` (prompt).
- `gqa_bind.zig` — HF tensor-name binder on st.zig (model.layers.{i}.
  self_attn.*, mlp.gate|mlp.router alias, experts.{e}.*, shared_expert,
  shared_expert_gate, embed/lm_head/norm). Resident bf16/f32 storage,
  per-group wdt slots.
- `model_gqa.zig` — `forward`/`forwardInc` on caller-owned scratch + KV
  slices. full = inc at cached=0 (parity by construction). Includes the
  fixture oracle test.
- `qwen3_moe_ref.py` — deterministic torch oracle (no transformers dep);
  writes tests/fixtures/gqa_tiny/{model.safetensors,config.json,
  expected.json}.
- `build.zig`, `test-log.txt`.

## Gates at archive time

- `zig build test` — **55/55 steps green**, incl. the fixture oracle:
  logits <= 0.01, argmax exact, 4 generated ids exact.
- `zig build -Dtarget=wasm32-wasi` — clean.
- `zig build -Dtarget=aarch64-linux-gnu` — clean.
- K3 suite untouched and passing (it IS the regression net).
- tokenizer.json encode/decode roundtrip test added to tok.zig; runGqa
  prefers tokenizer.json over tiktoken.model when present.

## Known scope cuts (Phase A, honest)

- Experts are resident (bf16/f32 via mmw); streamed experts are a
  follow-up.
- Qwen3.5/Qwen3-Next parse but refuse until the DeltaNet phase.
- Llama 4 refuses chunked/interleaved-NoPE attention fields.
