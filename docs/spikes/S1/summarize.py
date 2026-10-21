import json, glob, harness
runs = {"base (thinking off)": "results-corpus-pi-off.json", "base rep2": "results-corpus-pi-off-rep2.json", "v2 prompt": "results-corpus-pi-off-v2.json", "thinking medium": "results-corpus-pi-medium.json"}
print("| run | pass | p50 s | p95 s | ctx tok in/turn (input+cacheRead) | out tok/turn | $ /turn | parse fails |"); print("|---|---|---|---|---|---|---|---|")
D = {}
for n, f in runs.items():
    rows = json.load(open(f)); D[n] = {r["id"]: r for r in rows}
    u = [r["usage"] for r in rows if r.get("usage")]
    print("| %s | %d/%d | %.1f | %.1f | %.0f | %.0f | %.5f | %d |" % (n, sum(r["score"]["pass_"] for r in rows), len(rows), harness.pct([r["latency"] for r in rows], .5), harness.pct([r["latency"] for r in rows], .95),
          sum(x["input"] + x["cacheRead"] for x in u) / len(u), sum(x["output"] for x in u) / len(u), sum(x["cost"] for x in u) / len(u), sum(not r["score"]["parsed"] for r in rows)))
m = {r["id"]: r for r in json.load(open("results-mcp-pi.json"))}
print(); print("| id | cat | want | base | rep2 | v2 | medium | MCP |"); print("|---|---|---|---|---|---|---|---|")
from corpus import CORPUS
for it in CORPUS:
    i = it["id"]; cells = []
    for n in runs: s = D[n][i]["score"]; cells.append("ok" if s["pass_"] else "FAIL(%s)" % s["got"])
    s = m[i]["score"]; cells.append("ok" if s["pass_"] else "FAIL(%s)" % s["got"])
    print("| %s | %s | %s | %s |" % (i, it["category"], it["expect"]["cls"], " | ".join(cells)))
mr = list(m.values()); print("\nMCP: pass %d/39 p50 %.1f p95 %.1f in %.0f out %.0f $/turn %.5f turns %.1f" % (sum(r["score"]["pass_"] for r in mr), harness.pct([r["latency"] for r in mr], .5), harness.pct([r["latency"] for r in mr], .95), sum(r["in"] for r in mr) / 39, sum(r["out"] for r in mr) / 39, sum(r["cost"] for r in mr) / 39, sum(r["turns"] for r in mr) / 39))
