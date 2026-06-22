#!/usr/bin/env python3
"""
Split a causal LM into CoreML shards for NVP-D.

NUM_SHARDS <= 1 : one whole-model shard (reliable; runs on a single device).
NUM_SHARDS  > 1 : real per-layer-block split for multi-device inference —
    shard 0        embed + layers[0:k]   input_ids     -> hidden_out
    shard 1..N-2   layers[..]             hidden_states -> hidden_out
    shard N-1      layers[..]+norm+head   hidden_states -> logits

Loaded in bfloat16 (preserves range — fp16 overflows to inf and breaks k-means),
traced in float32, palettized to 4-bit (non-fatal), compiled to .mlmodelc by the
workflow, then published as a Release. Env: MODEL_ID, NUM_SHARDS, OUT_DIR.
"""
import os, json, hashlib, traceback, gc
import numpy as np
import torch
from transformers import AutoModelForCausalLM, AutoConfig, AutoTokenizer
import coremltools as ct
from coremltools.optimize.coreml import palettize_weights, OpPalettizerConfig, OptimizationConfig

MODEL_ID = os.environ.get("MODEL_ID", "unsloth/Llama-3.2-1B-Instruct")
NUM_SHARDS = int(os.environ.get("NUM_SHARDS", "1"))
OUT = os.environ.get("OUT_DIR", "build_shards")
SEQ = 64  # fixed window for split shards (robust CoreML conversion)
os.makedirs(OUT, exist_ok=True)


def palettize(m, nbits=4):
    cfg = OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=nbits))
    return palettize_weights(m, cfg)


def causal_mask(seq):
    return torch.triu(torch.full((seq, seq), float("-inf")), diagonal=1).view(1, 1, seq, seq)


class Shard0(torch.nn.Module):
    def __init__(self, model, layers):
        super().__init__()
        self.embed = model.model.embed_tokens
        self.rotary = model.model.rotary_emb
        self.layers = torch.nn.ModuleList(layers)

    def forward(self, input_ids):
        h = self.embed(input_ids)
        pos = torch.arange(input_ids.shape[1]).unsqueeze(0)
        cos, sin = self.rotary(h, pos)
        mask = causal_mask(input_ids.shape[1])
        for l in self.layers:
            h = l(h, attention_mask=mask, position_ids=pos, position_embeddings=(cos, sin))[0]
        return h


class BlockShard(torch.nn.Module):
    def __init__(self, model, layers, with_head):
        super().__init__()
        self.rotary = model.model.rotary_emb
        self.layers = torch.nn.ModuleList(layers)
        self.norm = model.model.norm if with_head else None
        self.head = model.lm_head if with_head else None

    def forward(self, hidden_states):
        seq = hidden_states.shape[1]
        pos = torch.arange(seq).unsqueeze(0)
        cos, sin = self.rotary(hidden_states, pos)
        mask = causal_mask(seq)
        h = hidden_states
        for l in self.layers:
            h = l(h, attention_mask=mask, position_ids=pos, position_embeddings=(cos, sin))[0]
        if self.norm is not None:
            h = self.norm(h)
        if self.head is not None:
            h = self.head(h)
        return h


class Whole(torch.nn.Module):
    def __init__(self, m):
        super().__init__(); self.m = m

    def forward(self, input_ids):
        return self.m(input_ids=input_ids).logits


def convert(module, example, in_name, in_dtype, out_name, path, dynamic=False):
    module = module.float().eval()
    traced = torch.jit.trace(module, example, strict=False)
    shape = ct.Shape(shape=(1, ct.RangeDim(1, 2048))) if dynamic else example.shape
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name=in_name, shape=shape, dtype=in_dtype)],
        outputs=[ct.TensorType(name=out_name)],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS17,
    )
    try:
        ml = palettize(ml, 4)
    except Exception as e:
        print(f"  palettize skipped ({e}); saving unquantized", flush=True)
    ml.save(path)


def main():
    print(f"Loading {MODEL_ID} (bf16) …", flush=True)
    cfg = AutoConfig.from_pretrained(MODEL_ID)
    model = AutoModelForCausalLM.from_pretrained(MODEL_ID, torch_dtype=torch.bfloat16, attn_implementation="eager")
    model.config.use_cache = False
    model.eval()
    AutoTokenizer.from_pretrained(MODEL_ID).save_pretrained(os.path.join(OUT, "tokenizer"))

    L, H = cfg.num_hidden_layers, cfg.hidden_size
    shards_meta = []

    if NUM_SHARDS <= 1:
        try:
            print("Whole-model conversion …", flush=True)
            ex = torch.randint(0, cfg.vocab_size, (1, 16), dtype=torch.int32)
            convert(Whole(model), ex, "input_ids", np.int32, "logits",
                    os.path.join(OUT, "shard_0.mlpackage"), dynamic=True)
            shards_meta.append({"index": 0, "layerRange": [0, L - 1], "file": "shard_0.mlmodelc", "kind": "whole"})
            print("✅ whole model saved", flush=True)
        except Exception:
            print("❌ whole-model failed:\n" + traceback.format_exc(), flush=True)
    else:
        n = NUM_SHARDS
        bounds = [round(i * L / n) for i in range(n)] + [L]
        layers = list(model.model.layers)
        for s in range(n):
            lo, hi = bounds[s], bounds[s + 1]
            path = os.path.join(OUT, f"shard_{s}.mlpackage")
            try:
                print(f"::group::Shard {s} layers[{lo}:{hi}]", flush=True)
                if s == 0:
                    ex = torch.randint(0, cfg.vocab_size, (1, SEQ), dtype=torch.int32)
                    convert(Shard0(model, layers[lo:hi]), ex, "input_ids", np.int32, "hidden_out", path)
                    shp_in, shp_out = [1, SEQ], [1, SEQ, H]
                else:
                    with_head = (s == n - 1)
                    ex = torch.randn(1, SEQ, H)
                    convert(BlockShard(model, layers[lo:hi], with_head), ex, "hidden_states", np.float32,
                            "logits" if with_head else "hidden_out", path)
                    shp_in = [1, SEQ, H]
                    shp_out = [1, SEQ, cfg.vocab_size] if with_head else [1, SEQ, H]
                shards_meta.append({"index": s, "layerRange": [lo, hi - 1], "file": f"shard_{s}.mlmodelc",
                                    "inputShape": shp_in, "outputShape": shp_out})
                print(f"✅ shard {s} saved", flush=True)
            except Exception:
                print(f"❌ shard {s} failed:\n" + traceback.format_exc(), flush=True)
            print("::endgroup::", flush=True)
            gc.collect()

    manifest = {
        "modelID": hashlib.sha256(MODEL_ID.encode()).hexdigest(),
        "name": MODEL_ID, "architecture": getattr(cfg, "model_type", "llama"),
        "totalLayers": L, "hidden": H, "contextLength": 2048 if NUM_SHARDS <= 1 else SEQ,
        "quantization": "q4", "shards": shards_meta,
    }
    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print("Manifest:\n" + json.dumps(manifest, indent=2), flush=True)
    if not shards_meta:
        raise SystemExit("No shards produced")


if __name__ == "__main__":
    main()
