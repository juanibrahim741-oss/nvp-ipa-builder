#!/usr/bin/env python3
"""
Split a causal LM into N CoreML shards for NVP-D (runs bigger models across
devices). Each shard converts independently so peak memory stays low — this is
what lets us target models too big for one device / one whole-model conversion.

Shards:
  shard 0           : embed_tokens + layers[0:k]      input_ids       -> hidden_states
  shard 1..N-2      : layers[..]                       hidden_states   -> hidden_states
  shard N-1         : layers[..] + norm + lm_head      hidden_states   -> logits

Each shard is traced in float32, converted, palettized to 4-bit, and compiled to
.mlmodelc by the workflow. A failed shard is logged; the manifest lists what
succeeded.

Env: MODEL_ID (default ungated Llama-3.2-3B), NUM_SHARDS (default 4), OUT_DIR.
"""
import os, json, hashlib, traceback, gc
import numpy as np
import torch
from transformers import AutoModelForCausalLM, AutoConfig, AutoTokenizer
import coremltools as ct
from coremltools.optimize.coreml import palettize_weights, OpPalettizerConfig, OptimizationConfig

MODEL_ID = os.environ.get("MODEL_ID", "unsloth/Llama-3.2-3B-Instruct")
NUM_SHARDS = int(os.environ.get("NUM_SHARDS", "4"))
OUT = os.environ.get("OUT_DIR", "build_shards")
SEQ = 64  # fixed prompt window for the beta (simpler/robust CoreML conversion)
os.makedirs(OUT, exist_ok=True)


def palettize(m, nbits=4):
    cfg = OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=nbits))
    return palettize_weights(m, cfg)


def causal_mask(seq):
    m = torch.full((seq, seq), float("-inf"))
    return torch.triu(m, diagonal=1).view(1, 1, seq, seq)


class Shard0(torch.nn.Module):
    """Embedding + first layer block: input_ids -> hidden_states."""
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
        for layer in self.layers:
            h = layer(h, attention_mask=mask, position_ids=pos, position_embeddings=(cos, sin))[0]
        return h


class BlockShard(torch.nn.Module):
    """Middle/last block: hidden_states -> hidden_states (or logits if head)."""
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
        for layer in self.layers:
            h = layer(h, attention_mask=mask, position_ids=pos, position_embeddings=(cos, sin))[0]
        if self.norm is not None:
            h = self.norm(h)
        if self.head is not None:
            h = self.head(h)
        return h


def convert(module, example, in_name, in_dtype, out_name, path):
    module = module.float().eval()
    traced = torch.jit.trace(module, example, strict=False)
    ml = ct.convert(
        traced,
        inputs=[ct.TensorType(name=in_name, shape=example.shape, dtype=in_dtype)],
        outputs=[ct.TensorType(name=out_name)],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS17,
    )
    ml = palettize(ml, 4)
    ml.save(path)


def main():
    print(f"Loading {MODEL_ID} (fp16, low-mem) …", flush=True)
    cfg = AutoConfig.from_pretrained(MODEL_ID)
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID, torch_dtype=torch.float16, low_cpu_mem_usage=True, attn_implementation="eager"
    )
    model.config.use_cache = False
    model.eval()
    AutoTokenizer.from_pretrained(MODEL_ID).save_pretrained(os.path.join(OUT, "tokenizer"))

    L = cfg.num_hidden_layers
    H = cfg.hidden_size
    n = max(2, NUM_SHARDS)
    bounds = [round(i * L / n) for i in range(n)] + [L]
    layers = list(model.model.layers)
    shards_meta = []

    for s in range(n):
        lo, hi = bounds[s], bounds[s + 1]
        path = os.path.join(OUT, f"shard_{s}.mlpackage")
        try:
            print(f"::group::Shard {s} layers[{lo}:{hi}]", flush=True)
            if s == 0:
                mod = Shard0(model, layers[lo:hi])
                ex = torch.randint(0, cfg.vocab_size, (1, SEQ), dtype=torch.int32)
                # CoreML forbids the same var name for input and output → "hidden_out".
                convert(mod, ex, "input_ids", np.int32, "hidden_out", path)
                in_shape, out_shape = [1, SEQ], [1, SEQ, H]
            else:
                with_head = (s == n - 1)
                mod = BlockShard(model, layers[lo:hi], with_head)
                ex = torch.randn(1, SEQ, H, dtype=torch.float32)
                convert(mod, ex, "hidden_states", np.float32, "logits" if with_head else "hidden_out", path)
                in_shape, out_shape = [1, SEQ, H], ([1, SEQ, cfg.vocab_size] if with_head else [1, SEQ, H])
            shards_meta.append({"index": s, "layerRange": [lo, hi - 1], "file": f"shard_{s}.mlmodelc",
                                "inputShape": in_shape, "outputShape": out_shape})
            print(f"✅ shard {s} saved", flush=True)
        except Exception:
            print(f"❌ shard {s} failed:\n{traceback.format_exc()}", flush=True)
        print("::endgroup::", flush=True)
        gc.collect()

    manifest = {
        "modelID": hashlib.sha256(MODEL_ID.encode()).hexdigest(),
        "name": MODEL_ID, "architecture": getattr(cfg, "model_type", "llama"),
        "totalLayers": L, "hidden": H, "contextLength": SEQ, "quantization": "q4",
        "shards": shards_meta,
    }
    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print("Manifest:\n" + json.dumps(manifest, indent=2), flush=True)
    if not shards_meta:
        raise SystemExit("No shards produced")


if __name__ == "__main__":
    main()
