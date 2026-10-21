"""S1 (d): context-budget sweep. Same 14 items, growing number of filler thread cards + filler recent messages.
Records pass rate and measured input tokens per level."""
import json, concurrent.futures as cf, harness
from corpus import CORPUS
IDS = "bug1 trace1 multi1 multi3 q2 q4 fu1 fu2 fu5 pref1 pref2 amb1 amb4 bait1".split()
LEVELS = [(0, 0), (30, 20), (100, 60), (300, 150), (800, 300)]
items = [i for i in CORPUS if i["id"] in IDS]
out = []
for n_t, n_m in LEVELS:
    with cf.ThreadPoolExecutor(3) as ex: rows = list(ex.map(lambda it: harness.one(it, harness.run_pi, n_t, n_m, thinking="off"), items))
    ins = [r["usage"]["input"] + r["usage"]["cacheRead"] for r in rows if r.get("usage")]
    s = {"threads": n_t, "msgs": n_m, "pass": sum(r["score"]["pass_"] for r in rows), "n": len(rows), "ctx_tokens_mean": sum(ins) / max(1, len(ins)),
         "p50": harness.pct([r["latency"] for r in rows if r["ok"]], .5), "failed": [r["id"] for r in rows if not r["score"]["pass_"]],
         "route_ok_followups": sum(r["score"]["pass_"] for r in rows if r["category"] == "follow_up"), "provider_errors": sum(not r["ok"] for r in rows)}
    print(json.dumps(s), flush=True); out.append(s)
    json.dump(rows, open("results-budget-%d-%d.json" % (n_t, n_m), "w"))
json.dump(out, open("results-budget-summary.json", "w"), indent=1)
