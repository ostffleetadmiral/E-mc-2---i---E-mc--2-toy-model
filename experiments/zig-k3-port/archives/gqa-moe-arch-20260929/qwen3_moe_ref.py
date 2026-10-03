#!/usr/bin/env python3
"""qwen3_moe_ref.py — deterministic torch oracle for the generic GQA+MoE path.

Builds a TINY qwen3_moe-shaped model in pure torch (no transformers dep —
the math mirrors HF's modeling_qwen3_moe.py verbatim), writes a real
safetensors checkpoint with HF tensor names + a config.json the strict
gqa_cfg reader accepts, and emits expected last-position logits and greedy
token ids for the Zig parity gate.

Usage:  python3 sidecar/qwen3_moe_ref.py <out_dir>
Emits:  <out_dir>/model.safetensors  <out_dir>/config.json
        <out_dir>/expected.json      (prompt ids, logits, gen ids)
"""

import json
import math
import sys

import torch
from safetensors.torch import save_file

# Tiny dims — big enough to exercise every path, small enough to diff.
HIDDEN = 128
LAYERS = 4          # layer 0 dense (first_k_dense_replace=1), 1..3 MoE
VOCAB = 256
N_HEADS = 4
N_KV = 2
HEAD_DIM = 32
ROPE_THETA = 10000.0
N_EXPERTS = 8
TOPK = 2
MOE_INTER = 64
DENSE_INTER = 96
SHARED_INTER = 32
EPS = 1e-6
GEN = 4
PROMPT = [1, 40, 17, 99, 200, 7]


def rms(x, w, eps=EPS):
    return x * torch.rsqrt(x.pow(2).mean(-1, keepdim=True) + eps) * w


def rope(x, cos, sin):
    # x: [T, heads, dim]. HF rotate-half: pairs (i, i+d/2).
    d2 = x.shape[-1] // 2
    x1, x2 = x[..., :d2], x[..., d2:]
    rot = torch.cat([-x2, x1], dim=-1)
    return x * cos + rot * sin


def build_weights():
    w = {}
    g = torch.Generator().manual_seed(0x600D5EED)

    def rnd(*shape):
        return (torch.randn(*shape, generator=g) * 0.05)

    w["model.embed_tokens.weight"] = rnd(VOCAB, HIDDEN)
    w["model.norm.weight"] = 1.0 + 0.1 * rnd(HIDDEN)
    w["lm_head.weight"] = rnd(VOCAB, HIDDEN)
    for i in range(LAYERS):
        p = f"model.layers.{i}."
        w[p + "input_layernorm.weight"] = 1.0 + 0.1 * rnd(HIDDEN)
        w[p + "post_attention_layernorm.weight"] = 1.0 + 0.1 * rnd(HIDDEN)
        w[p + "self_attn.q_proj.weight"] = rnd(N_HEADS * HEAD_DIM, HIDDEN)
        w[p + "self_attn.k_proj.weight"] = rnd(N_KV * HEAD_DIM, HIDDEN)
        w[p + "self_attn.v_proj.weight"] = rnd(N_KV * HEAD_DIM, HIDDEN)
        w[p + "self_attn.o_proj.weight"] = rnd(HIDDEN, N_HEADS * HEAD_DIM)
        w[p + "self_attn.q_norm.weight"] = 1.0 + 0.05 * rnd(HEAD_DIM)
        w[p + "self_attn.k_norm.weight"] = 1.0 + 0.05 * rnd(HEAD_DIM)
        if i == 0:  # dense layer
            w[p + "mlp.gate_proj.weight"] = rnd(DENSE_INTER, HIDDEN)
            w[p + "mlp.up_proj.weight"] = rnd(DENSE_INTER, HIDDEN)
            w[p + "mlp.down_proj.weight"] = rnd(HIDDEN, DENSE_INTER)
        else:
            w[p + "mlp.gate.weight"] = rnd(N_EXPERTS, HIDDEN)
            for e in range(N_EXPERTS):
                w[p + f"mlp.experts.{e}.gate_proj.weight"] = rnd(MOE_INTER, HIDDEN)
                w[p + f"mlp.experts.{e}.up_proj.weight"] = rnd(MOE_INTER, HIDDEN)
                w[p + f"mlp.experts.{e}.down_proj.weight"] = rnd(HIDDEN, MOE_INTER)
            w[p + "mlp.shared_expert.gate_proj.weight"] = rnd(SHARED_INTER, HIDDEN)
            w[p + "mlp.shared_expert.up_proj.weight"] = rnd(SHARED_INTER, HIDDEN)
            w[p + "mlp.shared_expert.down_proj.weight"] = rnd(HIDDEN, SHARED_INTER)
            # Qwen3-MoE gates the shared expert by a scalar sigmoid.
            w[p + "mlp.shared_expert_gate.weight"] = rnd(1, HIDDEN)
    return {k: v.to(torch.float32) for k, v in w.items()}


def forward(w, ids):
    """HF Qwen3Moe dataflow, T positions, causal. Returns [T, vocab]."""
    T = len(ids)
    x = w["model.embed_tokens.weight"][torch.tensor(ids)]  # [T,H]
    pos = torch.arange(T, dtype=torch.float64)
    inv = 1.0 / (ROPE_THETA ** (torch.arange(0, HEAD_DIM, 2, dtype=torch.float64) / HEAD_DIM))
    ang = pos[:, None] * inv[None, :]
    cos = torch.cat([ang.cos(), ang.cos()], -1)[:, None, :]  # [T,1,hd]
    sin = torch.cat([ang.sin(), ang.sin()], -1)[:, None, :]
    scale = 1.0 / math.sqrt(HEAD_DIM)

    for i in range(LAYERS):
        p = f"model.layers.{i}."
        # ---- attention block ----
        h = rms(x, w[p + "input_layernorm.weight"])
        q = (h.double() @ w[p + "self_attn.q_proj.weight"].double().T).view(T, N_HEADS, HEAD_DIM)
        k = (h.double() @ w[p + "self_attn.k_proj.weight"].double().T).view(T, N_KV, HEAD_DIM)
        v = (h.double() @ w[p + "self_attn.v_proj.weight"].double().T).view(T, N_KV, HEAD_DIM)
        q = rms(q.double(), w[p + "self_attn.q_norm.weight"].double())  # per-head RMSNorm
        k = rms(k.double(), w[p + "self_attn.k_norm.weight"].double())
        q = rope(q, cos, sin)
        k = rope(k, cos, sin)
        kk = k.repeat_interleave(N_HEADS // N_KV, dim=1)  # GQA expand
        vv = v.repeat_interleave(N_HEADS // N_KV, dim=1)
        att = torch.einsum("thd,shd->ths", q, kk) * scale
        mask = torch.triu(torch.full((T, T), float("-inf"), dtype=torch.float64), 1)
        att = att + mask[:, None, :]  # [T,1,T] broadcasts over heads
        att = att.softmax(-1)
        o = torch.einsum("ths,shd->thd", att, vv).reshape(T, N_HEADS * HEAD_DIM)
        x = x + (o @ w[p + "self_attn.o_proj.weight"].double().T).float()

        # ---- mlp block ----
        h = rms(x.double(), w[p + "post_attention_layernorm.weight"].double())
        if i == 0:
            g = h @ w[p + "mlp.gate_proj.weight"].double().T
            u = h @ w[p + "mlp.up_proj.weight"].double().T
            y = (torch.nn.functional.silu(g) * u) @ w[p + "mlp.down_proj.weight"].double().T
        else:
            logits_e = h @ w[p + "mlp.gate.weight"].double().T           # [T,E]
            probs = logits_e.softmax(-1)                                # softmax router
            wv, idx = probs.topk(TOPK, dim=-1)                          # [T,k]
            wv = wv / wv.sum(-1, keepdim=True)                          # norm_topk_prob
            y = torch.zeros(T, HIDDEN, dtype=torch.float64)
            for t in range(T):
                for j in range(TOPK):
                    e = int(idx[t, j])
                    g = h[t] @ w[p + f"mlp.experts.{e}.gate_proj.weight"].double().T
                    u = h[t] @ w[p + f"mlp.experts.{e}.up_proj.weight"].double().T
                    fe = (torch.nn.functional.silu(g) * u) @ w[p + f"mlp.experts.{e}.down_proj.weight"].double().T
                    y[t] += wv[t, j] * fe
            # shared expert: scalar sigmoid gate (Qwen3-MoE convention)
            g = h @ w[p + "mlp.shared_expert.gate_proj.weight"].double().T
            u = h @ w[p + "mlp.shared_expert.up_proj.weight"].double().T
            se = (torch.nn.functional.silu(g) * u) @ w[p + "mlp.shared_expert.down_proj.weight"].double().T
            sg = torch.sigmoid(h @ w[p + "mlp.shared_expert_gate.weight"].double().T)  # [T,1]
            y += sg * se
        x = x + y.float()

    h = rms(x.double(), w["model.norm.weight"].double())
    return h @ w["lm_head.weight"].double().T  # [T,V]


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: qwen3_moe_ref.py <out_dir>")
    out = sys.argv[1]
    w = build_weights()

    cfg = {
        "model_type": "qwen3_moe",
        "hidden_size": HIDDEN,
        "num_hidden_layers": LAYERS,
        "vocab_size": VOCAB,
        "rms_norm_eps": EPS,
        "max_position_embeddings": 4096,
        "num_attention_heads": N_HEADS,
        "num_key_value_heads": N_KV,
        "head_dim": HEAD_DIM,
        "rope_theta": ROPE_THETA,
        "num_experts": N_EXPERTS,
        "num_experts_per_tok": TOPK,
        "moe_intermediate_size": MOE_INTER,
        "shared_expert_intermediate_size": SHARED_INTER,
        "norm_topk_prob": True,
        "decoder_sparse_step": 1,
        "first_k_dense_replace": 1,
        "intermediate_size": DENSE_INTER,
        "tie_word_embeddings": False,
        "hidden_act": "silu",
        "attention_bias": False,
        "use_bias": False,
    }

    with torch.no_grad():
        logits = forward(w, PROMPT)  # [T,V]
        last = logits[-1]
        gen = []
        ids = list(PROMPT)
        cur = int(last.argmax())
        for _ in range(GEN):
            gen.append(cur)
            ids.append(cur)
            lg = forward(w, ids)
            cur = int(lg[-1].argmax())

    save_file(w, f"{out}/model.safetensors")
    with open(f"{out}/config.json", "w") as f:
        json.dump(cfg, f, indent=1)
    with open(f"{out}/expected.json", "w") as f:
        json.dump({
            "prompt": PROMPT,
            "logits": last.tolist(),
            "gen_ids": gen,
        }, f)
    print(f"wrote {out}: logits[0]={last[0].item():.6f} gen={gen}")


if __name__ == "__main__":
    main()
