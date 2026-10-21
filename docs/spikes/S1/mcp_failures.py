"""S1 (c) failure modes over MCP (run AFTER mcp_trial.py; shares the call log).
 A. partial execution: server fails the 2nd create call (S1_FAIL_NTH=2) on a 3-task input.
 B. malformed call: user asks for a workflow that is not in the enum.
 C. replay variance: the same input 4x -> are tool-call args byte-identical (could a content hash be an idempotency key)?"""
import json, mcp_trial as m, harness
from corpus import CORPUS
by = {i["id"]: i for i in CORPUS}
out = {}
m.set_fail_nth(2); r = m.run(by["multi3"]); out["A_partial"] = {"calls": r["calls"], "turns": r["turns"]}; m.set_fail_nth(0)
bad = {"id": "bad_wf", "category": "x", "input": "Start a thread with workflow 'hotfix' to fix the footer year typo.", "expect": {}}
r = m.run(bad); out["B_malformed"] = {"calls": r["calls"]}
reps = [m.run(by["bug1"]) for _ in range(4)]
out["C_variance"] = [[(c["tool"], c["args"].get("title"), c["args"].get("workflow"), len(c["args"].get("prompt", ""))) for c in x["calls"]] for x in reps]
json.dump(out, open("results-mcp-failures.json", "w"), indent=1)
for k, v in out.items(): print(k, json.dumps(v)[:1500])
