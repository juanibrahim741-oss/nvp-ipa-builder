import json, math, os, re, struct, sys

MAX_PART = 1900 * 1024 * 1024  # GitHub release asset ceiling (margin included)
SRC = "model.gguf"
NAME = os.environ.get("MODEL_NAME", "model").strip() or "model"
MIN_PARTS = max(1, int(os.environ.get("MIN_PARTS", "2") or "2"))
SOURCE_URL = os.environ.get("SOURCE_URL", "")

SCALAR = {0:1, 1:1, 2:2, 3:2, 4:4, 5:4, 6:4, 7:1, 10:8, 11:8, 12:8}
T_STRING, T_ARRAY = 8, 9

class Cur:
    def __init__(self, b): self.b = b; self.off = 0
    def take(self, n):
        if self.off + n > len(self.b): raise EOFError("gguf header truncated")
        v = self.b[self.off:self.off+n]; self.off += n; return v
    def u32(self): return struct.unpack("<I", self.take(4))[0]
    def u64(self): return struct.unpack("<Q", self.take(8))[0]
    def s(self):
        n = self.u64()
        if n > (1 << 28): raise ValueError("invalid gguf string")
        return self.take(n).decode("utf-8", "replace")
    def val(self, t):
        if t in SCALAR:
            raw = self.take(SCALAR[t])
            if t == 6: return struct.unpack("<f", raw)[0]
            if t == 12: return struct.unpack("<d", raw)[0]
            return int.from_bytes(raw, "little", signed=t in (1, 3, 5, 11))
        if t == T_STRING: return self.s()
        if t == T_ARRAY:
            et, n = self.u32(), self.u64()
            if n > 100_000_000: raise ValueError("invalid gguf array")
            if et in SCALAR: self.take(n * SCALAR[et])
            elif et == T_STRING:
                for _ in range(n): self.s()
            elif et == T_ARRAY:
                for _ in range(n): self.val(T_ARRAY)
            else: raise ValueError("unknown gguf array elem type %d" % et)
            return None
        raise ValueError("unknown gguf value type %d" % t)

total = os.path.getsize(SRC)
with open(SRC, "rb") as f:
    head = f.read(min(total, 256 * 1024 * 1024))
cur = Cur(head)
if cur.u32() != 0x46554747: sys.exit("::error::not a GGUF file (bad magic)")
version = cur.u32()
if version not in (2, 3): sys.exit("::error::unsupported GGUF version %d" % version)
n_tensors, n_kv = cur.u64(), cur.u64()
meta = {}
for _ in range(n_kv):
    k = cur.s(); t = cur.u32(); v = cur.val(t)
    if v is not None: meta[k] = v
infos = []
for _ in range(n_tensors):
    nm = cur.s(); nd = cur.u32()
    if nd > 8: sys.exit("::error::corrupt gguf header (n_dims)")
    cur.take(nd * 8); cur.u32()
    infos.append((nm, cur.u64()))

align = meta.get("general.alignment", 32)
if not isinstance(align, int) or align <= 0: align = 32
data_start = math.ceil(cur.off / align) * align
prelude_end = min(data_start, total)

layers = 0
for k, v in meta.items():
    if k.endswith(".block_count") and isinstance(v, int) and v > 0:
        layers = v; break
if layers <= 0:
    mx = -1
    for nm, _ in infos:
        m = re.match(r"^blk\.(\d+)\.", nm)
        if m: mx = max(mx, int(m.group(1)))
    layers = mx + 1
if layers <= 0: sys.exit("::error::cannot determine layer count (block_count missing)")

srt = sorted(infos, key=lambda x: x[1])
tensors = []
for i, (nm, off) in enumerate(srt):
    start = data_start + off
    end = data_start + srt[i+1][1] if i + 1 < len(srt) else total
    tensors.append((nm, start, min(end, total)))

def coalesce(ranges):
    out = []
    for s, e in sorted(ranges):
        if e <= s: continue
        if out and s <= out[-1][1]: out[-1][1] = max(out[-1][1], e)
        else: out.append([s, e])
    return out

def compute(nparts):
    per = math.ceil(layers / nparts)
    buckets = [[[0, prelude_end]] if prelude_end > 0 else [] for _ in range(nparts)]
    for nm, s, e in tensors:
        m = re.match(r"^blk\.(\d+)\.", nm)
        part = min(int(m.group(1)) // per, nparts - 1) if m else 0
        buckets[part].append([s, e])
    parts = []
    for i, b in enumerate(buckets):
        rgs = coalesce(b)
        parts.append({
            "index": i,
            "layers": [i * per, min(layers, (i + 1) * per) - 1],
            "ranges": [{"start": s, "end": e} for s, e in rgs],
            "bytes": sum(e - s for s, e in rgs),
        })
    return parts

# Grow the part count until every file fits under GitHub's asset limit.
n = max(MIN_PARTS, math.ceil(total / MAX_PART))
n = min(n, 64)
parts = compute(n)
while any(p["bytes"] > MAX_PART for p in parts) and n < min(layers, 64):
    n += 1
    parts = compute(n)
if any(p["bytes"] > MAX_PART for p in parts):
    sys.exit("::error::a single part still exceeds %d MB — model too dense for GitHub assets" % (MAX_PART // (1024*1024)))

slug = re.sub(r"^_+|_+$", "", re.sub(r"[^a-z0-9]+", "_", NAME.lower()))[:48] or "model"
model_id = "nvpd_ranges_" + slug
tag_slug = slug.replace("_", "-")

os.makedirs("out", exist_ok=True)
with open(SRC, "rb") as f:
    with open("out/prelude.bin", "wb") as w:
        f.seek(0); w.write(f.read(prelude_end))
    for p in parts:
        with open("out/part_%d.bin" % p["index"], "wb") as w:
            for r in p["ranges"]:
                f.seek(r["start"]); left = r["end"] - r["start"]
                while left > 0:
                    chunk = f.read(min(left, 8 * 1024 * 1024))
                    if not chunk: sys.exit("::error::short read while slicing")
                    w.write(chunk); left -= len(chunk)
        p["file"] = "part_%d.bin" % p["index"]

manifest = {
    "modelID": model_id,
    "name": NAME,
    "kind": "gguf-ranges",
    "ggufUrl": SOURCE_URL,
    "sizeGb": round(total / 1e9, 2),
    "layers": layers,
    "minWorkers": n,
    "preludeEnd": prelude_end,
    "shards": parts,
}
with open("out/manifest.json", "w") as w:
    json.dump(manifest, w)
with open("out/SLUG", "w") as w:
    w.write(tag_slug)
print("model_id=%s layers=%d parts=%d total=%d preludeEnd=%d" % (model_id, layers, n, total, prelude_end))
for p in parts:
    print("  part %d: layers %s, %d ranges, %.1f MB" % (p["index"], p["layers"], len(p["ranges"]), p["bytes"] / 1e6))
