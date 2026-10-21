#!/usr/bin/env python3
# FAKED `gh`: a local stand-in backed by the scratch bare repo. It never talks to GitHub.
import json, os, subprocess, sys, shutil, time
D = os.path.dirname(os.path.abspath(__file__))
BARE = os.path.join(os.path.dirname(D), "origin.git")
ST = os.path.join(D, "state.json")
def load():
    return json.load(open(ST)) if os.path.exists(ST) else {"next": 1, "prs": {}, "ci": {}}
def save(s): json.dump(s, open(ST, "w"), indent=1)
def log(a):
    open(os.path.join(D, "calls.log"), "a").write(time.strftime("%H:%M:%S ") + " ".join(a) + "\n")
def git(*a, cwd=None):
    r = subprocess.run(["git", *a], cwd=cwd, capture_output=True, text=True)
    if r.returncode: raise SystemExit("git %s failed: %s" % (a, r.stderr))
    return r.stdout.strip()
def opt(args, name):
    return args[args.index(name) + 1] if name in args else None
def sha(branch): return git("--git-dir", BARE, "rev-parse", branch)
def run_ci(s, commit):
    if commit in s["ci"]: return s["ci"][commit]
    tmp = os.path.join(D, "tmp-ci"); shutil.rmtree(tmp, ignore_errors=True)
    git("clone", "-q", BARE, tmp); git("checkout", "-q", commit, cwd=tmp)
    r = subprocess.run(["python3", "-m", "unittest"], cwd=tmp, capture_output=True, text=True)
    s["ci"][commit] = "SUCCESS" if r.returncode == 0 else "FAILURE"
    shutil.rmtree(tmp, ignore_errors=True)
    return s["ci"][commit]
def find(s, ref):
    for n, p in s["prs"].items():
        if ref in (p["url"], n, p["head"]): return p
    raise SystemExit("no pull request found for " + ref)
a = sys.argv[1:]; log(a); s = load()
if a[:2] == ["pr", "create"]:
    n = s["next"]; s["next"] += 1
    url = "https://github.com/accept/scratch/pull/%d" % n
    s["prs"][str(n)] = {"number": n, "url": url, "head": opt(a, "--head"), "base": opt(a, "--base"), "title": opt(a, "--title"), "state": "OPEN"}
    save(s); print(url)
elif a[:2] == ["pr", "list"]:
    out = [{"url": p["url"], "number": p["number"], "state": p["state"]} for p in s["prs"].values() if p["head"] == opt(a, "--head") and p["base"] == opt(a, "--base")]
    print(json.dumps(out[:1]))
elif a[:2] == ["pr", "view"]:
    p = find(s, a[2]); head = sha(p["head"]); c = run_ci(s, head); save(s)
    roll = [{"__typename": "CheckRun", "name": "ci/test", "status": "COMPLETED", "conclusion": c, "detailsUrl": p["url"] + "/checks", "workflowName": "ci"}]
    print(json.dumps({"state": p["state"], "mergeable": "MERGEABLE", "headRefOid": head, "headRefName": p["head"], "baseRefName": p["base"], "statusCheckRollup": roll, "reviewDecision": "", "reviews": [], "comments": [], "mergeStateStatus": "CLEAN"}))
elif a[:2] == ["pr", "merge"]:
    p = find(s, a[2]); want = opt(a, "--match-head-commit"); head = sha(p["head"])
    if want and want != head: raise SystemExit("head commit does not match: %s != %s" % (want, head))
    tmp = os.path.join(D, "tmp-merge"); shutil.rmtree(tmp, ignore_errors=True)
    git("clone", "-q", BARE, tmp); git("config", "user.email", "fake@gh", cwd=tmp); git("config", "user.name", "fakegh", cwd=tmp)
    git("checkout", "-q", p["base"], cwd=tmp); git("merge", "--squash", "origin/" + p["head"], cwd=tmp)
    git("commit", "-q", "-m", "%s (#%d)" % (p["title"], p["number"]), cwd=tmp); git("push", "-q", "origin", p["base"], cwd=tmp)
    shutil.rmtree(tmp, ignore_errors=True)
    p["state"] = "MERGED"; save(s); print("merged " + p["url"])
elif a[:1] == ["api"]:
    print(json.dumps({"data": {"repository": {"pullRequest": {"reviewThreads": {"nodes": []}}}}}))
elif a[:2] == ["auth", "status"]:
    print("fakegh: logged in (FAKED)")
else:
    sys.stderr.write("fakegh: unsupported: %s\n" % a); sys.exit(1)
