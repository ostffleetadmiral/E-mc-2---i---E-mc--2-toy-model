# Multimodal Lattice-Native Coverage Map

This document records the full multimodel reverse-engineering sweep: external
AI checkpoints decomposed into Qstar's 11-dimensional lattice architecture and
distilled into compact QSW2 weight seeds.

The approach is *structural reverse engineering*, not model porting: each
external model is mapped back through the same 11D generative chain that
produced Qstar itself (0D origin → 10D gravity closure), so every component
lands on the dimensional modules that express its function — attention on 5D,
temporal structure on 1D, latent compression on 3D, schedules on 8D,
modulation/coupling on 10D, chaos priors on 9D.

## The generative chain (shared spine)

Every distilled model below is a point in the same space the lattice was
generated from:

| Stage | Mechanism | Dim |
|---|---|---|
| Embedding / tokenization | discrete → continuous | 5D bi-complex |
| Positional structure | RoPE / sinusoidal / learned | 4D quaternion |
| Token mixing | self/cross attention | 5D attention |
| Channel expansion | FFN / gated MLP | 7D channel routing |
| Depth ordering | block index 0..N | 1D temporal axis |
| Conditioning | adaLN / timestep / cross-attn | 10D coupling gate |
| Noise schedule | denoise trajectory | 8D φ-cooling |
| Prior | Gaussian init | 9D chaos |
| Latent space | pixel↔latent codec | 3D spatial grid |
| Metacognition | eval/score/adapter roles | 6D Jordan self-model |

## Distilled families (verified seeds)

Param counts are measured during distillation (exact element sums), not repo
advertising numbers.

### LongCat-Video-Avatar-1.5 (audio→video)

| Component | Params | Seed | Digest |
|---|---|---|---|
| Avatar DiT (48 blk, bf16) | 15,852,916,800 | 627 KB | `daa2267405e5a367` |
| DiT int8 mirror (i8+f32+bf16) | ~15.86 B | 877 KB | `cacb559e7d7a549c` |
| umT5-XXL text encoder (f32) | 5,680,910,336 | 100 KB | `a1218068a154725a` |
| Whisper-Large-v3 (f16) | 1,543,490,560 | 275 KB | `34be50866535cd10` |
| Parent LoRAs (cfg_step+refine) | ~1.43 B | 1.2 MB | `52769b90da531438` |
| DMD LoRA (bf16) | 630,718,800 | 530 KB | `4cc498b7a7356d79` |
| Wan 3D VAE (f32) | 126,892,531 | 41 KB | `6c9110888ec263a8` |

### Wan2.1-T2V-1.3B (text→video) — Wan-AI/Wan2.1-T2V-1.3B-Diffusers

| Component | Params | Seed | Digest |
|---|---|---|---|
| DiT (30 blk, `attn1/attn2` naming) | 1,418,996,800 | 317 KB | `72af2230c967881a` |
| umT5-XXL text encoder | 5,680,910,336 | 100 KB | `a1218068a154725a` |
| Wan 3D VAE | 126,892,531 | 77 KB | `6c9110888ec263a8` |

**Lineage proof (digest equality):** Wan2.1's VAE digest `6c9110888ec263a8`
and umT5 digest `a1218068a154725a` are byte-identical to LongCat's — LongCat is
built directly on Wan2.1's foundation and ships the same frozen components.
The digests independently confirm what the config claims.

### CogVideoX-2b (text→video) — zai-org/CogVideoX-2b

| Component | Params | Seed | Digest |
|---|---|---|---|
| DiT (30 blk, expert adaLN) | 1,693,783,872 | 292 KB | `ee14f7760030e85d` |
| T5-XXL text encoder | 4,762,310,656 | 91 KB | `6df4dbe7df4906ce` |
| 3D VAE | 215,583,907 | 175 KB | `3878c92fb0a410cb` |

### HunyuanVideo (text→video) — hunyuanvideo-community/HunyuanVideo

| Component | Params | Seed | Digest |
|---|---|---|---|
| MMDiT transformer (dual-stream, 6 shards) | 12,821,012,544 | 506 KB | `c3cbb669cc557da5` |
| LLaVA-Llama text encoder (4 shards) | 7,505,186,816 | 116 KB | `3becd9d63f4156ee` |
| CLIP-L text encoder | 123,060,480 | 80 KB | `2bdc583b9fade9c7` |
| Causal 3D VAE | 246,478,803 | 99 KB | `ae4c428f2b60d792` |

Note: Hunyuan's CLIP-L has the *same param count* as SDXL's CLIP-L
(123,060,480) but a different digest — same architecture, different fine-tuned
weights. Digest discrimination holds at the weight level.

### FLUX.1-schnell (text→image) — Comfy-Org/flux1-schnell + comfyanonymous/flux_text_encoders

| Component | Params | Seed | Digest |
|---|---|---|---|
| MMDiT transformer (fp16, single file) | 11,891,178,560 | 305 KB | `a3859c78824b9a51` |
| T5-XXL text encoder (fp16) | 4,893,906,944 | 91 KB | `2d2e70c5f7f7f2fc` |
| CLIP-L text encoder | 123,060,480 | 80 KB | `2bdc583b9fade9c7` |
| ae VAE (bf16, `Kijai/flux-fp8` mirror) | 83,819,683 | 94 KB | `bc577948cd79a20c` |

### SDXL-base-1.0 (text→image) — stabilityai/stable-diffusion-xl-base-1.0

| Component | Params | Seed | Digest |
|---|---|---|---|
| UNet (down/mid/up blocks, attn1/attn2) | 2,567,463,684 | 690 KB | `a552990c082787f6` |
| CLIP-G (OpenCLIP ViT-bigG) | 694,659,840 | — | `791074bcc0bb667a` |
| CLIP-L | 123,060,480 | — | `af5f7869d91d04f2` |
| VAE (f32) | 83,653,863 | 98 KB | `7fa5a85ff2dec3be` |

### LTX-Video 2B v0.9.1 (text→video + i2v) — Lightricks/LTX-Video

| Component | Params | Seed | Digest |
|---|---|---|---|
| DiT + bundled VAE (single file) | 2,858,362,546 | 419 KB | `fb33488f353a682e` |

Notable: the file bundles `vae.per_channel_statistics` tensors with RMS
~2×10⁹ (pixel-scale quantization stats) — the extreme values that drove the
DECODE_CLAMP + saturating-accumulation hardening.

### CLIP ViT-L/14 (image↔text embedding) — openai/clip-vit-large-patch14

| Component | Params | Seed | Digest |
|---|---|---|---|
| Full dual encoder (text+vision) | 427,616,847 | 240 KB | `52b0e558853f4c39` |

### Qwen3-0.6B (text→text LLM) — Qwen/Qwen3-0.6B

| Component | Params | Seed | Digest |
|---|---|---|---|
| Full LLM (28 blk, GQA, gate/up/down proj) | 751,632,384 | 125 KB | `b8fe244a78e3aa7d` |

### SD3.5-medium (text→image) — stabilityai/stable-diffusion-3.5-medium

| Component | Params | Seed | Digest |
|---|---|---|---|
| MMDiT transformer | 2,469,663,936 | 353 KB | `f87c588b04ec1e66` |
| CLIP-L text encoder | 123,650,304 | 79 KB | `7251abf2936cf7bf` |
| CLIP-G text encoder | 694,659,840 | 207 KB | `ff6201dd61cc48c2` |
| T5-XXL text encoder (2 shards) | 4,762,310,656 | 89 KB | `6df4dbe7df4906ce` |
| VAE | 83,819,683 | 95 KB | `30fd53028920279b` |

SD3.5's MMDiT uses joint-stream `transformer_blocks` with `add_q/k/v_proj`
context attention and `ff_context` — the `mmdit` family. Its T5-XXL is
byte-identical to CogVideoX's (shared digest), a fourth shared-component
lineage proof.

## Modality coverage

`src/modality.zig` routes each capability through the 11D ladder:

| Modality | Route | Covered by |
|---|---|---|
| text→text | 5→1→10 | Qwen3 |
| text→image | 5→8→7→3→10 | SDXL, FLUX |
| text→video | 5→1→3→8→7→10 | Wan2.1, CogVideoX, Hunyuan, LTX |
| audio→video | 1→7→3→8→10 | LongCat |
| speech→text | 1→8→5 | Whisper (LongCat component) |
| text embedding | 5→10 | umT5, T5-XXL, CLIP-L/G, LLaVA |
| image embedding | 3→4→7 | CLIP ViT-L/14 |
| latent codec | 3→8→1 | 9 VAE seeds |
| adapter | 10 | DMD LoRA, parent LoRAs |

## Verified cross-family findings

- **Shared components have shared digests.** Wan2.1↔LongCat VAE and umT5 are
  byte-identical (lineage proven by digest, not documentation).
- **Same-architecture variants discriminate.** SDXL CLIP-L vs Hunyuan CLIP-L:
  identical 123,060,480 params, distinct digests.
- **Depth-resolved structure is real.** attn norm gains grow with block index
  in every DiT (Wan `norm_q` 0.90→1.58 across 30 blocks; LongCat `q_norm`
  0.73→1.8 across 48) — captured per-block in `BlockProfile`.
- **Quantization is visible.** int8 DiT shows `weight_int8` payloads (RMS
  15–52) paired with per-channel `weight_scale` envelopes (~2e-4–2e-3).
- **Conditioning discriminates at render.** 13 seeds → 11 distinct
  deterministic images under identical prompts; the 2 collisions are
  *shared components* — `hunyuan_clip`/`flux_schnell_clip` are byte-identical
  weights (same digest) and `cogvideox_t5`/`flux_schnell_t5xxl` are the same
  T5-XXL weights in different dtypes (distinct digest, identical normalized
  channel spectrum `0.119 0.128 0.113 0.139 0.122 0.138 0.119 0.121`).
- **T5-XXL is a shared component across three families.** CogVideoX, FLUX,
  and SD3.5 all condition on the same google T5-XXL; the SD3.5 distill is
  byte-identical to CogVideoX's (digest `6df4dbe7df4906ce`), while FLUX's
  fp16 copy differs only by dtype (same normalized channel spectrum).
  umT5 (Wan/LongCat) is a different encoder with a different spectral shape.

## Multi-seed composition

Seeds compose at the conditioning layer the same way components compose in a
diffusion pipeline: encoder seeds shape the prompt/text gates, the DiT seed
drives depth-resolved sigma modulation, VAE seeds inform the latent-codec
route, and LoRA seeds act as 10D adapters.

Composition recipe (mirrors the source pipelines):

1. **Text conditioning** — hash the prompt into the 5 adaLN gates
   (`image-demo --prompt`), or load an encoder seed (umT5/T5-XXL/CLIP/LLaVA)
   to condition on that family's learned text structure.
2. **Backbone** — pass the DiT/UNet seed via `--seed-file`: `stepChannel`
   maps the seed's block profiles onto the denoise schedule (48-block
   LongCat, 30-block Wan, dual-stream FLUX/Hunyuan all reduce through the
   same BlockProfile → step-group path).
3. **Adapters** — LoRA seeds merge arithmetically: `mergeSeeds` unions
   signatures, re-folds the channel sum, and unions block profiles —
   the same recipe used for LongCat's cfg_step + refinement + DMD LoRAs.
4. **Cross-family** — because every seed is the same 8-channel shape, any
   seed can condition any render: a CLIP seed biases a Wan trajectory just
   as a VAE seed biases a FLUX one. Distinct digests produce distinct
   trajectories; shared components (identical digests) produce identical
   conditioning — which is the desired semantic.

## Registry

`src/model_registry.zig` + `models/registry.json` (parity-tested) hold 32
entries mapping every component to family / modality / scheduler / params /
seed / status: 33 distilled, 0 gated, 0 pending — the full registry. `qstar model-map` prints the live table with on-disk seed
detection.

## Scope caveat

A QSW seed captures weight *structure* — exact param count, per-tensor
moments, 8-segment energies, 8-bin spectra, functional roles, block profiles —
at roughly 10,000× compression. It is enough for deterministic conditioning,
lineage proofs, quantization analysis, and component discrimination. It is
not, at this compression, a functional reproduction of the source model's
inference; parity at that level would require a separate inference-path
demonstration.
