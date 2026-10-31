#!/usr/bin/env python3
"""Embedding load through the PAIS gateway: N parallel workers, each sends batches of B texts to /v1/embeddings for
D seconds. Prints requests/s, texts/s and latency percentiles.
Env: PAIS_GW, PAIS_TOKEN or PAIS_TOKEN_FILE, PAR=4 workers, BATCH=16 texts per request, DUR=30 seconds.
Usage: python3 emb-bench.py [route]  (default bge-m3-vgpu4c)"""
import json, os, ssl, sys, time, urllib.request, concurrent.futures as cf, statistics
BASE = os.environ.get("PAIS_GW") or sys.exit("set PAIS_GW=https://<pais-fqdn>/api/v1/compatibility/openai/v1")
GW = BASE.rstrip("/") + "/embeddings"
TOKEN = os.environ.get("PAIS_TOKEN") or (open(os.path.expanduser(os.environ["PAIS_TOKEN_FILE"])).read().strip()
                                         if os.environ.get("PAIS_TOKEN_FILE") else sys.exit("set PAIS_TOKEN or PAIS_TOKEN_FILE"))
PAR = int(os.environ.get("PAR", 4)); BATCH = int(os.environ.get("BATCH", 16)); DUR = int(os.environ.get("DUR", 30))
ROUTE = sys.argv[1] if len(sys.argv) > 1 else "bge-m3-vgpu4c"
CTX = ssl.create_default_context(); CTX.check_hostname = False; CTX.verify_mode = ssl.CERT_NONE   # lab certificate
TEXTS = [f"Platform teams run a model-as-a-service gateway: service names, quotas, observability, cost. Sentence {i} about "
         f"one GPU shared by many tenants on a vSphere host with NVIDIA vGPU, measured in the lab." for i in range(BATCH)]
def one():
    body = json.dumps({"model": ROUTE, "input": TEXTS}).encode()
    req = urllib.request.Request(GW, data=body, headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    t0 = time.time()
    with urllib.request.urlopen(req, context=CTX, timeout=120) as r:
        j = json.load(r)
    return time.time() - t0, len(j.get("data", [])), len(j["data"][0]["embedding"]) if j.get("data") else 0
def worker():
    lat = []; texts = 0; end = time.time() + DUR; dim = 0
    while time.time() < end:
        try:
            dt, n, dim = one(); lat.append(dt); texts += n
        except Exception as e:
            lat.append(float("nan")); print("  error:", str(e)[:120])
    return lat, texts, dim
print(f"route {ROUTE}, {PAR} workers, {BATCH} texts per request, {DUR} s")
t0 = time.time()
with cf.ThreadPoolExecutor(PAR) as ex:
    res = list(ex.map(lambda _: worker(), range(PAR)))
wall = time.time() - t0
lat = [l for r in res for l in r[0] if l == l]; texts = sum(r[1] for r in res); dim = max(r[2] for r in res)
lat.sort()
p = lambda q: lat[min(len(lat) - 1, int(q * len(lat)))] if lat else float("nan")
print(f"  {len(lat)} requests, {texts} texts in {wall:.1f} s = {len(lat)/wall:.1f} req/s, {texts/wall:.0f} texts/s; "
      f"latency median {statistics.median(lat):.2f} s, p90 {p(0.9):.2f} s, max {lat[-1]:.2f} s; dim {dim}")
