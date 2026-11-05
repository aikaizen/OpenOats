#!/usr/bin/env python3 -I
"""Build OpenOats' kb_cache.json for a folder, using Ollama embeddings, in the
same format KnowledgeBase.swift writes, so the app loads it on launch.

Usage: python3 -I scripts/build_kb_cache.py <notes-folder>
Env:   OLLAMA_URL (default http://localhost:11434), EMBED_MODEL (default nomic-embed-text)
Incremental: files whose content hash is unchanged reuse their cached embeddings.
Aborts without writing when no .md/.txt files are found. See docs/brain-sidecast.md."""
import hashlib, json, math, os, sys, urllib.request

ROOT = os.path.realpath(sys.argv[1])
OUT = os.path.expanduser("~/Library/Application Support/OpenOats/kb_cache.json")
OLLAMA = os.environ.get("OLLAMA_URL", "http://localhost:11434")
MODEL = os.environ.get("EMBED_MODEL", "nomic-embed-text")
FINGERPRINT = f"ollama|{OLLAMA}|{MODEL}|n1"
TMIN, TMAX = 80, 500

def sha(s): return hashlib.sha256(s.encode("utf-8")).hexdigest()
def words(s): return [w for w in s.split(" ") if w]

def chunk_markdown(text):
    lines = text.replace("\r\n", "\n").split("\n")
    sections, headers, cur = [], [], []
    for line in lines:
        if line.startswith("#"):
            if cur: sections.append((headers, cur))
            stripped = line.lstrip("#"); level = len(line) - len(stripped)
            htext = stripped.strip(" \t")
            nh = list(headers)
            if level <= len(nh): nh = nh[:level-1]
            nh.append(htext); headers, cur = nh, []
        else:
            cur.append(line)
    if cur: sections.append((headers, cur))
    result, pt, ph = [], "", ""
    for hs, ls in sections:
        st = "\n".join(ls).strip()
        if not st: continue
        bc = " > ".join(hs); wc = len(words(st))
        if wc < TMIN:
            if not pt: pt, ph = st, bc
            else:
                pt += "\n\n" + st
                if bc: ph = bc
            if len(words(pt)) >= TMIN: result.append((pt, ph)); pt, ph = "", ""
        elif wc > TMAX:
            if pt: result.append((pt, ph)); pt, ph = "", ""
            ws = words(st); ov = TMAX // 5; start = 0
            while start < len(ws):
                result.append((" ".join(ws[start:start+TMAX]), bc)); start += TMAX - ov
        else:
            if pt: result.append((pt, ph)); pt, ph = "", ""
            result.append((st, bc))
    if pt: result.append((pt, ph))
    if not result and text.strip():
        ws = words(text)
        if len(ws) <= TMAX: result.append((text.strip(), ""))
        else:
            ov = TMAX // 5; start = 0
            while start < len(ws):
                result.append((" ".join(ws[start:start+TMAX]), "")); start += TMAX - ov
    return result

def title_of(content, fallback):
    for line in content.split("\n"):
        t = line.strip(" \t")
        if t.startswith("# ") and not t.startswith("##"): return t[2:].strip(" \t")
    return fallback

def embed(texts):
    out = []
    for i in range(0, len(texts), 16):
        body = json.dumps({"model": MODEL, "input": texts[i:i+16]}).encode()
        req = urllib.request.Request(OLLAMA + "/v1/embeddings", body, {"Content-Type": "application/json"})
        with urllib.request.urlopen(req, timeout=300) as r:
            data = json.load(r)["data"]
        for d in sorted(data, key=lambda d: d["index"]):
            v = d["embedding"]; mag = math.sqrt(sum(x*x for x in v)) or 1.0
            out.append([x/mag for x in v])
        print(f"  embedded {min(i+16, len(texts))}/{len(texts)}", file=sys.stderr)
    return out

files = []
def _walk_err(e): print(f"walk error: {e}", file=sys.stderr)
if not os.path.isdir(ROOT): sys.exit(f"abort: cannot access {ROOT}")
for dp, dns, fns in os.walk(ROOT, onerror=_walk_err):
    dns[:] = sorted(d for d in dns if not d.startswith("."))
    for fn in fns:
        if fn.startswith("."): continue
        if fn.lower().rsplit(".", 1)[-1] in ("md", "txt") and os.path.isfile(os.path.join(dp, fn)):
            files.append(os.path.realpath(os.path.join(dp, fn)))
files.sort()
if not files: sys.exit("abort: no .md/.txt files found; leaving existing cache untouched")

try:
    old = json.load(open(OUT))
    reuse = old.get("entries", {}) if old.get("embeddingConfigFingerprint") == FINGERPRINT else {}
except Exception:
    reuse = {}
entries, jobs, texts = {}, [], []
for path in files:
    raw = open(path, "rb").read()
    if raw.startswith(b"\xef\xbb\xbf"): print("WARNING: BOM in", path, file=sys.stderr)
    try: content = raw.decode("utf-8")
    except UnicodeDecodeError: print("skip non-utf8", path, file=sys.stderr); continue
    doc_id = sha(path); key = doc_id + ":" + sha(content)
    if key in reuse:
        entries[key] = reuse[key]; continue
    local = path[len(ROOT):].lstrip("/")
    folder = os.path.dirname(local)
    title = title_of(content, os.path.splitext(os.path.basename(path))[0])
    chunks = [(t, h) for t, h in chunk_markdown(content) if t.strip()]
    for t, h in chunks:
        prefix = local + (f" > {h}" if h else "")
        texts.append(f"{prefix}\n{t.strip()}")
    jobs.append((key, doc_id, local, folder, title, chunks))

print(f"{len(files)} files, {len(entries)} unchanged, {len(jobs)} to embed ({len(texts)} chunks)", file=sys.stderr)
vecs = embed(texts) if texts else []
off = 0
for key, doc_id, local, folder, title, chunks in jobs:
    out = []
    for t, h in chunks:
        out.append({"text": t, "sourceFile": local, "documentID": doc_id, "headerContext": h,
                    "embedding": vecs[off], "relativePath": local, "folderBreadcrumb": folder,
                    "documentTitle": title}); off += 1
    entries[key] = out

cache = {"formatVersion": 1, "entries": entries, "embeddingConfigFingerprint": FINGERPRINT, "folderPaths": [ROOT]}
os.makedirs(os.path.dirname(OUT), exist_ok=True)
tmp = OUT + ".tmp"
with open(tmp, "w") as f: json.dump(cache, f)
os.chmod(tmp, 0o600); os.replace(tmp, OUT)
print(f"wrote {OUT} ({os.path.getsize(OUT)//1024} KB)", file=sys.stderr)
