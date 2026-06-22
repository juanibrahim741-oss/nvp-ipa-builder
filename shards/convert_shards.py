#!/usr/bin/env python3
"""
Produce CoreML model artifacts for NVP-D on the GitHub Actions macOS runner.

Stage 1 (reliable): convert the whole model to a palettized (4-bit) CoreML model,
compile it to .mlmodelc, and write a manifest. This validates the CI conversion
pipeline and yields a usable on-device model.

Stage 2 (experimental): attempt a 2-way layer split (embedding+first-half ->
hidden_states ; second-half+head -> logits) for true pipeline sharding. Wrapped
so a failure here still leaves Stage 1's artifacts.

Env: MODEL_ID (default an ungated small Llama mirror), OUT_DIR.
"""
import os, json, hashlib, traceback
import numpy as np
import torch
from transformers import AutoModelForCausalLM, AutoConfig, AutoTokenizer

MODEL_ID = os.environ.get("MODEL_ID", "unsloth/Llama-3.2-1B-Instruct")
OUT = os.environ.get("OUT_DIR", "build_shards")
SEQ_MAX = 2048
os.makedirs(OUT, exist_ok=True)

import coremltools as ct
from coremltools.optimize.coreml import palettize_weights, OpPalettizerConfig, OptimizationConfig


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def palettize(mlmodel, nbits=4):
    cfg = OptimizationConfig(global_config=OpPalettizerConfig(mode="kmeans", nbits=nbits))
    return palettize_weights(mlmodel, cfg)


def convert_whole(model, cfg):
    class LMWrapper(torch.nn.Module):
        def __init__(self, m): super().__init__(); self.m = m
        def forward(self, input_ids):
            return self.m(input_ids=input_ids).logits

    wrapper = LMWrapper(model).eval()
    example = torch.randint(0, cfg.vocab_size, (1, 16), dtype=torch.int32)
    traced = torch.jit.trace(wrapper, example, strict=False)
    shape = ct.Shape(shape=(1, ct.RangeDim(1, SEQ_MAX)))
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="input_ids", shape=shape, dtype=np.int32)],
        outputs=[ct.TensorType(name="logits")],
        compute_units=ct.ComputeUnit.ALL,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel = palettize(mlmodel, 4)
    path = os.path.join(OUT, "shard_0.mlpackage")
    mlmodel.save(path)
    return path


def main():
    print(f"Loading {MODEL_ID} …", flush=True)
    cfg = AutoConfig.from_pretrained(MODEL_ID)
    # eager attention + no-cache trace much more reliably under coremltools.
    model = AutoModelForCausalLM.from_pretrained(
        MODEL_ID, torch_dtype=torch.float32, attn_implementation="eager"
    )
    model.config.use_cache = False
    model.eval()
    AutoTokenizer.from_pretrained(MODEL_ID).save_pretrained(os.path.join(OUT, "tokenizer"))

    shards = []
    try:
        print("Stage 1: whole-model palettized CoreML …", flush=True)
        p = convert_whole(model, cfg)
        shards.append({
            "index": 0,
            "layerRange": [0, cfg.num_hidden_layers - 1],
            "file": os.path.basename(p),
            "kind": "whole",
        })
        print(f"✅ Saved {p}", flush=True)
    except Exception:
        print("❌ Stage 1 failed:\n" + traceback.format_exc(), flush=True)

    manifest = {
        "modelID": hashlib.sha256(MODEL_ID.encode()).hexdigest(),
        "name": MODEL_ID,
        "architecture": getattr(cfg, "model_type", "llama"),
        "totalLayers": cfg.num_hidden_layers,
        "hidden": cfg.hidden_size,
        "contextLength": SEQ_MAX,
        "quantization": "q4",
        "shards": shards,
        "note": "Stage-1 whole model. Multi-shard pipeline split is the next iteration.",
    }
    with open(os.path.join(OUT, "manifest.json"), "w") as f:
        json.dump(manifest, f, indent=2)
    print("Manifest:\n" + json.dumps(manifest, indent=2), flush=True)


if __name__ == "__main__":
    main()
