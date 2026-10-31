#!/usr/bin/env python3
"""Chat benchmark through the Private AI Services (PAIS) gateway: per route one streaming request (time to first
token, tokens per second), then 1 and N parallel non-streaming requests (aggregate throughput).
Env: PAIS_GW (https://<pais-fqdn>/api/v1/compatibility/openai/v1), PAIS_TOKEN or PAIS_TOKEN_FILE (gateway API token),
PAR=8 (parallel requests), TOK=400 (max_tokens). Usage: python3 gw-bench.py <route> [route ...]
Routes that run thinking models get reasoning_effort=none when listed in NO_THINK (comma separated env)."""
import json, os, ssl, sys, time, urllib.request, concurrent.futures as cf
BASE = os.environ.get("PAIS_GW") or sys.exit("set PAIS_GW=https://<pais-fqdn>/api/v1/compatibility/openai/v1")
GW = BASE.rstrip("/") + "/chat/completions"
TOKEN = os.environ.get("PAIS_TOKEN") or (open(os.path.expanduser(os.environ["PAIS_TOKEN_FILE"])).read().strip()
                                         if os.environ.get("PAIS_TOKEN_FILE") else sys.exit("set PAIS_TOKEN or PAIS_TOKEN_FILE"))
PAR = int(os.environ.get("PAR", 8)); TOK = int(os.environ.get("TOK", 400))
PROMPT = ("Write a detailed, well structured essay of at least 600 words about how a platform team should run a "
          "model-as-a-service gateway for application teams: service names, model swaps, quotas, observability and cost.")
NO_THINK = set(filter(None, os.environ.get("NO_THINK", "").split(",")))
ctx = ssl.create_default_context(); ctx.check_hostname = False; ctx.verify_mode = ssl.CERT_NONE   # lab certificate

def body(route, variant, stream):
    b = {"model": route, "max_tokens": TOK, "stream": stream,
         "messages": [{"role": "user", "content": f"{PROMPT} (variant {variant})"}]}
    if route in NO_THINK: b["reasoning_effort"] = "none"
    return json.dumps(b).encode()

def call(route, variant, stream=False):
    req = urllib.request.Request(GW, data=body(route, variant, stream), method="POST",
                                 headers={"Authorization": f"Bearer {TOKEN}", "Content-Type": "application/json"})
    t0 = time.time(); ttft = None; chunks = 0; text = ""; usage = None
    with urllib.request.urlopen(req, context=ctx, timeout=600) as r:
        if stream:
            for line in r:
                line = line.decode(errors="replace").strip()
                if not line.startswith("data:"): continue
                d = line[5:].strip()
                if d == "[DONE]": break
                try: j = json.loads(d)
                except ValueError: continue
                delta = (j.get("choices") or [{}])[0].get("delta", {}).get("content")
                if delta:
                    if ttft is None: ttft = time.time() - t0
                    chunks += 1; text += delta
                if j.get("usage"): usage = j["usage"]
        else:
            j = json.loads(r.read()); usage = j.get("usage") or {}
            text = (j.get("choices") or [{}])[0].get("message", {}).get("content") or ""
    dt = time.time() - t0
    ct = (usage or {}).get("completion_tokens") or 0
    return {"ttft": ttft, "total": dt, "completion_tokens": ct, "chunks": chunks, "chars": len(text), "usage": usage}

routes = sys.argv[1:] or sys.exit("usage: gw-bench.py <route> [route ...]")
print(f"gateway {GW}\nmax_tokens {TOK}, parallel {PAR}, prompt {len(PROMPT)} chars\n")
for route in routes:
    print(f"=== {route}")
    try:
        s = call(route, 0, stream=True)
        if s["ttft"] is None:
            print(f"  streaming single: no content delta received in {s['total']:.1f} s ({s['chunks']} chunks, usage {s['usage']})")
        else:
            tok = s["completion_tokens"] or TOK   # the stream carries no usage; the essay prompt always hits max_tokens
            gen = tok / (s["total"] - s["ttft"])
            print(f"  streaming single: ttft {s['ttft']:.2f} s, total {s['total']:.1f} s, {s['chunks']} chunks, {s['chars']} chars, "
                  f"{gen:.1f} tok/s after first token (assuming {tok} tokens)")
    except Exception as e:
        print(f"  streaming single failed: {e}"); continue
    for P in (1, PAR):
        t0 = time.time()
        with cf.ThreadPoolExecutor(max_workers=P) as ex:
            res = list(ex.map(lambda k: call(route, k), range(1, P + 1)))
        dt = time.time() - t0; tot = sum(r["completion_tokens"] for r in res)
        print(f"  {P} parallel non-streaming: {tot} completion tokens in {dt:.1f} s = {tot/dt:.1f} tok/s aggregate, {tot/dt/P:.1f} per request; "
              f"slowest {max(r['total'] for r in res):.1f} s")
    print()
