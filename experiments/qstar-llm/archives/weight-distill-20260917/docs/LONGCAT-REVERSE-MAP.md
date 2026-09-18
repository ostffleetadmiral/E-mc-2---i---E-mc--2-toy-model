# LongCat-Video-Avatar-1.5 → Qstar 11D Reverse-Engineering Map

This document decomposes the LongCat-Video-Avatar-1.5 audio-driven video diffusion
pipeline into its algebraic components and maps each onto the Qstar 11-dimensional
lattice stack. The goal is a *structural port*: the same pipeline topology
re-expressed with lattice-native mechanisms in integer fixed-point — not a port
of the trained ~26B-parameter weights (bf16 floats, GPU-only; this host is CPU).

Reference: meituan-longcat/LongCat-Video-Avatar-1.5 (arXiv:2605.26486).
Architecture: Wan 2.1 3D VAE + umT5-XXL + Whisper-Large-v3 + 48-block Avatar DiT
(3D self-attn + text cross-attn + audio cross-attn w/ adaLN gate + 3D RoPE + FFN),
FlowMatchEuler scheduler (shift 7.0), DMD2 step distillation to 8 NFE, GRPO
per-frame policy optimization.

## Component map

| LongCat component | Mechanism | Dim | Qstar module | Parity |
|---|---|---|---|---|
| Wan 2.1 3D VAE | pixel↔latent spatiotemporal compression | 3D | `holo_codec.zig` (N³→16³ fold/unfold), `s7_compression.zig` (S7→S0 seed→expand) | ANALOG |
| umT5-XXL text encoder | text conditioning embeddings | 5D | `dim_5d_language.zig` bi-complex attention, `bpe_tokenizer.zig` | ANALOG |
| Whisper-Large-v3 audio encoder | mel → 33 hidden states → (4×8+1) grouped-mean-pool → (T,5,1280) | 1D+8D | `voice_codec.zig` (`encodeFrame`, `formantToLattice` — audio→lattice binding exists) | PARTIAL → `audioPool33to5` |
| Audio projector | 50Hz → 25fps → latent-rate temporal resample | 1D | `dim_1d_time.zig` | PARTIAL → `temporalResample` |
| 3D self-attention (DiT) | spatiotemporal token mixing | 5D+3D | `dim_5d_language.zig` attention, `dim_3d_space.zig` grid | ANALOG |
| 3D RoPE | rotary position embedding | 4D | `dim_4d_rotation.zig` Quaternion — RoPE is per-pair rotation | STRONG → `ropePos` |
| Text cross-attention | conditioning injection | 5D | `dim_5d_language.zig` | ANALOG |
| Audio cross-attn + adaLN | gated audio→lip injection | 7D+10D | `dim_7d_color.zig` ColorRouter weights = adaLN gate; `dim_10d_gravity.zig` DualBiComplex coupling | STRONG → `adaLNGate` |
| FlowMatchEuler (shift 7.0) | denoising timestep schedule | 8D | `dim_8d_frequency.zig` FrequencyScaler φ-cooling | ANALOG → `DenoiseSchedule` |
| 8-step DMD2 distillation | shared backbone + Gen/FakeScore LoRA roles | — | `distillation_s0.zig` projectToS0/injectFromS0 | ANALOG → `AdapterRole` |
| GRPO per-frame policy opt | self-eval → advantage → update | 6D | `dim_6d_consciousness.zig` JordanSelfModel, `metacognition_engine.zig` | STRONG |
| Reference latent | identity anchor frame | 0D | `dim_0d_origin.zig` OriginState seed | STRONG |
| Context/motion latents, cross-chunk stitch | temporal continuity | 1D | `dim_1d_time.zig`, `merge.zig` resolveConflict | ANALOG |
| Disentangled unconditional guidance | speech vs motion decoupling (audio CFG 4.0) | 10D | `dim_10d_gravity.zig` dual-bi-complex | ANALOG |
| L-RoPE multi-person binding | per-speaker position binding | 4D+id | `dim_4d_rotation.zig`, `entangle.zig`, `sybil.zig` | ANALOG |
| Noise latents | Gaussian prior init | 9D | `dim_9d_chaos.zig` ChaosInjector | STRONG |
| Video continuation | autoregressive temporal extension | 1D | `dim_1d_time.zig` advance/currentPosition | ANALOG |
| Pixel-space rasterization | latents → RGB frames | — | `transport_video.zig` (container only) | **GAP → `splat_render.zig`** |

## Gaussian Splatting mapping (3DGS, Kerbl et al. 2023)

3DGS represents a scene as sparse 3D Gaussians — mean μ∈R³, covariance
Σ = RSSᵀRᵀ (scale vector s + rotation quaternion q), color, opacity α.
Rendering: project Σ' = JWΣWᵀJᵀ (Jacobian of perspective projection), sort by
depth, alpha-composite front-to-back.

The correspondence to the lattice is nearly literal:

| 3DGS primitive | Lattice source |
|---|---|
| Sparse point set | 421 E0 nodes (sparse by construction — splatting's key insight) |
| μ ∈ R³ | node (x,y,z) coord in the 15³ space grid |
| Rotation quaternion q | `dim_4d_rotation.Quaternion` |
| Scale vector s | channel activation spread |
| Color / opacity | 8-channel activation magnitudes (octonionic channel routing) |
| Depth sort + α-composite | integer sort + fixed-point blend — `splat_render.zig` |

All splat math is closed-form: quaternion→matrix, 3×3 products, 2×2 inverse,
exp(-½dᵀΣ⁻¹d). `fixed_point.zig` provides RNE mul/div/sqrt/exp — no f64 in the
core path.

## Infinite Corridors mapping (recursive portal feedback)

The "infinite corridor" idiom (indraloop-style): F_{n+1} = composite(source,
transform(F_n, H·A)) — deterministic recursive self-composition. In the lattice
this is iterated holographic folding: `holo_codec` fold levels (16→512, 6 levels)
with per-level re-entry, plus the Möbius boundary self-inverse (e7→e2
reflection). `corridorStep` composes one fold level per iteration, giving a
deterministic infinite-zoom rendering loop with zero external state.

## Whisper pooling — the exact integer analog

Whisper-large emits 33 hidden states (embedding + 32 layers). LongCat pools them
as 4 groups of 8 + 1 singleton → 5 channels, then resamples 50Hz→25fps→latent.
`audioPool33to5` reproduces this exactly in i128 — grouped mean is integer
division. Input can come from real audio via `voice_codec.encodeFrame` →
`formantToLattice`, making the conditioning path fully lattice-native.

## Weight distillation (safetensors → lattice seed)

`src/safetensors.zig` parses the safetensors container (8-byte LE header length
→ JSON metadata → typed data offsets) and `src/weight_distill.zig` streams each
tensor in bounded windows (never fully resident) to produce a `TensorSignature`:
element count, Q64.64 mean/RMS moments, an 8-bin integer-DFT spectral signature,
and a node binding (FNV-1a hash → E0 node). Signatures aggregate into a
`WeightSeed` (QSW1 format: magic, digest, channel_sum, per-tensor records).

The seed conditions `runAvatarFrame`'s denoise loop: per step, sigma is scaled
by `1 + channel_sum[step % 8]/4` — the source model's aggregate spectral shape
becomes the lattice's trajectory bias. CLI: `qstar distill-weights <file>
[--out seed.qsw] [--max-elems N]`; `qstar avatar-demo --seed-file seed.qsw`.

Verified against the real checkpoints:

- `lora/dmd_lora.safetensors` (2.4 GB, 630,718,800 params, ~1800 tensors) →
  318 KB seed, digest `4cc498b7a7356d79`. The signature correctly separates
  tensor families — `lora_down` RMS ≈ 9e-3 vs `lora_up` RMS ≈ 5e-4,
  `alpha_scale` = 0.5 exactly.
- `base_model/diffusion_pytorch_model-0000{1..6}` (31.7 GB, 15,852,916,800
  params, 1608 tensors, merged via `mergeSeeds`) → 333 KB seed, digest
  `daa2267405e5a367`. Signatures expose real learned structure: `attn.q_norm`
  gains deepen with layer (0.73 at block 0 → 1.8 at block 46), `adaLN` biases
  drift 0→0.038, audio cross-attn norms pinned ≈0.93 — the 48-block
  `LongCatVideoAvatarTransformer3DModel` layout matches `config.json`
  (hidden 4096, depth 48, 32 heads, patch [1,2,2], audio_channel 1280,
  audio_window 5).

Multi-file CLI: `qstar distill-weights shard1 ... shard6 --out seed.qsw`

## Scope caveat

This port reproduces LongCat's *orchestration skeleton* — scheduler, positional
encoding, conditioning gates, pooling, latent stream selection, rasterization —
as deterministic fixed-point modules, plus a real weight-structure distillation
of the published checkpoints. The distilled seed captures each tensor's moments,
spectrum, and lattice binding — *structure*, not function: ~26B params → a few
hundred KB of signatures cannot reproduce the original model's outputs.
Conditioning via `weight_seed` biases the denoise trajectory; it does not
transfer learned capability. Output is a lattice-driven avatar renderer,
architecturally isomorphic but not photoreal. If production video output is
required later, the fallback is a `longcat_client.zig` HTTP adapter to a remote
GPU host running the official checkpoint (maple_client pattern) — not part of
this phase.
