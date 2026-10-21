"""S1 (b): cold vs warm. Identical large-prefix prompt (100 filler threads) sent 5x back-to-back, then a new user message with same prefix."""
import json, harness
from corpus import CORPUS
it = [i for i in CORPUS if i["id"] == "bug2"][0]; it2 = [i for i in CORPUS if i["id"] == "q1"][0]
rows = []
for k, item in enumerate([it] * 3 + [it2, it2]):
    r = harness.run_pi(harness.system_prompt(), harness.build_prompt(item["input"], 100, 40), thinking="off")
    rows.append({"call": k, "item": item["id"], "latency": r["latency"], **{x: r["usage"][x] for x in ("input", "output", "cacheRead", "cacheWrite", "cost")}}); print(rows[-1], flush=True)
json.dump(rows, open("results-cold-warm.json", "w"), indent=1)
