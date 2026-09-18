# Archive: weight-distill-20260917

Passing state: safetensors parsing + weight→lattice distillation, verified
against the real LongCat-Video-Avatar-1.5 checkpoints.

## What landed
- `src/safetensors.zig` (4/4) — container parser, integer-exact bf16/f16/f32→Q64.64
- `src/weight_distill.zig` (5/5) — streaming TensorSignature (moments, 8-bin DFT
  spectrum, node binding) → QSW1 WeightSeed; `mergeSeeds` for multi-shard
- `src/longcat_port.zig` (12/12) — `weight_seed` conditions denoise sigma
- CLI: `qstar distill-weights <files...> [--out seed.qsw]`, `avatar-demo --seed-file`

## Verified against real checkpoints (weights/ dir, gitignored)
- `dmd_lora.safetensors` (2.4GB, 630,718,800 params) → 318KB, digest 4cc498b7a7356d79
- `base_model` 6 shards (31.7GB, 15,852,916,800 params, 1608 tensors) → 333KB,
  digest daa2267405e5a367. q_norm gains deepen 0.73→1.8 by block 46; adaLN bias
  drift 0→0.038 — real learned structure preserved.
- Avatar demo conditioned by both seeds; deterministic per seed.

## Verified
- zig build clean; test-agent, test-main, test-training pass
- safetensors 4/4, weight_distill 5/5, longcat_port 12/12

## Honest scope
Structural distillation (moments+spectrum+binding), not functional equivalence.
~16.5B params → ~650KB signatures preserves weight *shape*, not learned function.
