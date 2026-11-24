// Regression tests for the helpers in common.js that are pure (the module imports "herdr", which only exists
// inside the app, so it is stubbed here).
// Run: bun test ops/herdr-sidebar/test   (bun is not a devbox package and CI does not run this suite)
import { test, expect, mock } from "bun:test";
import { summarizePr } from "../mods/foreman-run/model.js";

let execImpl = async () => ({ code: 0, stdout: "", stderr: "" }); // what the stubbed exec() answers; a test sets it
mock.module("herdr", () => ({ exec: (...a) => execImpl(...a), home: () => "/h", window: () => ({ platform: "macos" }) }));
const {
  approveBody, approveMergeArgs, approvePrompt, approveTask, beadId, canMerge, clearRuns, completionToast, countCleared, currentPhase, findApprovable, foreman, foremanArgv,
  foremanDo, hideCleared, isApprovable, isClearable, isFullSha, isResettable, mergeArgs, mergeErrorText, mergePrompt, mergeVerbsCheck, parseActivityCommand, parseCleared,
  parseGhLogin, pruneCleared, resetPrompt, runLabel, shortSha, trackCompletions,
} = await import("../common.js");

// What the run list carries for a run in the middle of a workflow (sunstoneos-m1zz: create-prd done, refine-prd running).
const prdRun = (status, ids = ["r-p001", "r-p002"]) => ({
  status, phase_ids: ids, workflow_name: null,
  workflow_snapshot: { workflow_name: "prd", phases: ["create-prd", "refine-prd", "create-trd"].map((name, i) => ({ name, index: i + 1, phase_id: `r-p00${i + 1}` })) },
});

test("an active run is labelled with the phase it is in, then its workflow", () => {
  expect(currentPhase(prdRun("in_progress"))).toBe("refine-prd");
  expect(runLabel(prdRun("in_progress"))).toBe("refine-prd · prd");
  expect(runLabel(prdRun("in_progress", ["r-p001"]))).toBe("create-prd · prd");
  expect(runLabel(prdRun("in_progress", ["r-p003", "r-p001", "r-p002"]))).toBe("create-trd · prd"); // the highest index, whatever the order
  // The snapshot's own phase_id decides, not the shape of the id: ids that do not end in -pNNN still resolve.
  const odd = { status: "in_progress", phase_ids: ["x-a", "x-b"], workflow_snapshot: { workflow_name: "prd", phases: [{ name: "one", index: 1, phase_id: "x-a" }, { name: "two", index: 2, phase_id: "x-b" }] } };
  expect(runLabel(odd)).toBe("two · prd");
});

test("a run with no phase to name, or one that is not active, is labelled by its workflow", () => {
  expect(runLabel(prdRun("in_progress", []))).toBe("prd"); // no phase started yet
  expect(runLabel(prdRun("in_progress", ["r-p009"]))).toBe("prd"); // the snapshot does not name it
  expect(runLabel({ status: "in_progress", workflow_name: "fix" })).toBe("fix"); // a list without phases or snapshot
  expect(runLabel(prdRun("failed"))).toBe("prd"); // finished: the workflow alone
  expect(runLabel({ status: "in_progress", phase_ids: ["r-p001"], workflow_snapshot: { workflow_name: "fix", phases: [{ name: "fix", index: 1 }] } })).toBe("fix"); // same name, said once
});
test("beadId takes the bead id off a beads task id", () => {
  expect(beadId({ task_id: "beads:foreman:foreman-jzycy" })).toBe("foreman-jzycy");
  expect(beadId({ task_id: "beads:ensemble:br-bhj9" })).toBe("br-bhj9");
});

test("beadId keeps a dotted child bead whole", () => {
  expect(beadId({ task_id: "beads:foreman:foreman-vbfmo.1" })).toBe("foreman-vbfmo.1");
});

test("beadId is everything after the second colon, and the run's project is not a gate", () => {
  expect(beadId({ task_id: "beads:foreman:foreman-x:y" })).toBe("foreman-x:y");
  expect(beadId({ task_id: "beads:ensemble:br-bhj9", project_id: "some-other-project" })).toBe("br-bhj9");
});

test("beadId is null for anything that is not a bead", () => {
  for (const task_id of ["coord-63933494f1a", "adhoc-1c2d3e", "post-merge-smoke-1557", "beads:foreman:", "beads::foreman-x", "kata:foreman:foreman-x", "", null, undefined, 42]) {
    expect(beadId({ task_id })).toBeNull();
  }
  expect(beadId({})).toBeNull();
  expect(beadId(null)).toBeNull();
  expect(beadId(undefined)).toBeNull();
});

test("beadId does not take a bead out of the middle of another id", () => {
  expect(beadId({ task_id: "x-beads:foreman:foreman-jzycy" })).toBeNull();
});

const run = (run_id, status) => ({ run_id, status });

test("only failed, stuck and cancelled runs are clearable", () => {
  for (const s of ["failed", "stuck", "cancelled"]) expect(isClearable(run("r", s))).toBe(true);
  for (const s of ["completed", "in_progress", "awaiting_worker", "paused", undefined]) expect(isClearable(run("r", s))).toBe(false);
  expect(isClearable(null)).toBe(false);
});

test("clearRuns records the status of the clearable runs only and leaves its input alone", () => {
  const before = { old: "failed" };
  const after = clearRuns(before, [run("a", "failed"), run("b", "completed"), run("c", "stuck"), run("d", "in_progress")]);
  expect(after).toEqual({ old: "failed", a: "failed", c: "stuck" });
  expect(before).toEqual({ old: "failed" });
});

test("a cleared run is hidden, counted, and everything else stays", () => {
  const runs = [run("a", "failed"), run("b", "failed"), run("c", "completed")];
  const cleared = clearRuns({}, [runs[0]]);
  expect(hideCleared(runs, cleared).map((r) => r.run_id)).toEqual(["b", "c"]);
  expect(countCleared(runs, cleared)).toBe(1);
  expect(hideCleared(runs, {})).toEqual(runs);
});

test("a cleared run shows again once its status changes (retried, resumed, stuck -> failed)", () => {
  const cleared = { a: "failed", b: "stuck" };
  const runs = [run("a", "in_progress"), run("b", "failed"), run("c", "failed")];
  expect(hideCleared(runs, cleared).map((r) => r.run_id)).toEqual(["a", "b", "c"]);
  expect(countCleared(runs, cleared)).toBe(0);
});

test("pruneCleared drops runs that are no longer listed, and drops nothing for an empty listing", () => {
  const cleared = { a: "failed", gone: "failed" };
  expect(pruneCleared(cleared, [run("a", "failed"), run("b", "failed")])).toEqual({ a: "failed" });
  expect(pruneCleared(cleared, [])).toBe(cleared);
});

test("parseCleared keeps only a JSON object's string entries and shrugs off anything else", () => {
  expect(parseCleared('{"a":"failed","b":3,"c":null}')).toEqual({ a: "failed" });
  for (const bad of [null, undefined, "", "not json", "[]", '["a"]', "3", "null"]) expect(parseCleared(bad)).toEqual({});
});

test("only a failed run is offered a reset", () => {
  expect(isResettable({ status: "failed" })).toBe(true);
  for (const status of ["stuck", "blocked", "paused", "cancelled", "completed", "in_progress", undefined]) expect(isResettable({ status })).toBe(false);
  expect(isResettable(null)).toBe(false);
});

test("the reset confirmation names the run and says what a reset does not do", () => {
  const { title, detail } = resetPrompt({ run_id: "run-abc", workflow_name: "fix", task_id: "beads:foreman:foreman-jzycy", status: "failed" });
  expect(title).toBe("Reset this run?");
  expect(detail).toContain("fix foreman-jzycy (run-abc)");
  expect(detail).toContain("does not restart the work");
  expect(detail).toContain("event history stays");
});

test("the reset confirmation falls back to the task id for a run that is not a bead, and to the workflow snapshot's name", () => {
  const { detail } = resetPrompt({ run_id: "run-x", workflow_snapshot: { workflow_name: "plan" }, task_id: "adhoc-1c2d3e", status: "failed" });
  expect(detail).toContain("plan adhoc-1c2d3e (run-x)");
});

test("only a queue entry that is awaiting approval and not stale is approvable", () => {
  expect(isApprovable({ kind: "open", task_id: "beads:foreman:foreman-x", stale: false })).toBe(true);
  expect(isApprovable({ kind: "slot", task_id: "beads:foreman:foreman-x" })).toBe(false); // approved already, waiting for a slot
  expect(isApprovable({ kind: "open", task_id: "t", stale: true })).toBe(false);
  for (const task_id of ["", null, undefined, 7]) expect(isApprovable({ kind: "open", task_id })).toBe(false);
  expect(isApprovable(null)).toBe(false);
});

test("the approval request is the one the removed CLI verb sent: type, task_id and approved_by, nothing the gateway reserves", () => {
  const body = approveBody("beads:foreman:foreman-x");
  expect(body).toEqual({ type: "task.approve", payload: { task_id: "beads:foreman:foreman-x", approved_by: "herdr-sidebar" } });
  for (const reserved of ["approval_id", "approved_at", "run_id", "workflow_snapshot"]) expect(body.payload).not.toHaveProperty(reserved);
  expect(body).not.toHaveProperty("command_id");
});

test("the approval confirmation names the task and its project and says that it starts a run", () => {
  const { title, detail } = approvePrompt({ kind: "open", task_id: "beads:foreman:foreman-x", project_id: "foreman", title: "Fix the thing" });
  expect(title).toBe("Approve this task?");
  expect(detail).toContain("Fix the thing · foreman-x (project foreman)");
  expect(detail).toContain("starts a run");
  expect(approvePrompt({ task_id: "adhoc-1" }).detail).toContain("adhoc-1. Approving");
});

test("the entry awaiting approval is found even when a stale slot entry of the same task is listed before it", () => {
  const stale = { kind: "slot", task_id: "beads:foreman:foreman-x", run_id: "run-old", stale: true };
  const open = { kind: "open", task_id: "beads:foreman:foreman-x", stale: false };
  expect(findApprovable([stale, open], "beads:foreman:foreman-x")).toBe(open);
  expect(findApprovable([stale], "beads:foreman:foreman-x")).toBeUndefined(); // nothing awaits approval any more
  expect(findApprovable([open], "beads:foreman:foreman-y")).toBeUndefined();
});

// What curl prints as callApi reads it: the body, then the HTTP status on a line of its own.
const curlSaid = (body, status) => ({ code: 0, stdout: `${typeof body === "string" ? body : JSON.stringify(body)}\n${status}`, stderr: "" });
// Runs approveTask against what exec() answers and reports how it ended: {body} for a resolution, {error} for a rejection.
const approval = (answer) => {
  execImpl = async () => answer;
  return approveTask("beads:foreman:foreman-x").then((body) => ({ body }), (error) => ({ error }));
};

test("an accepted approval resolves; the request is a POST whose JSON body is an argument of its own and whose token never is", async () => {
  let call;
  execImpl = async (cmd, args) => {
    call = { cmd, args };
    return curlSaid({ status: "accepted", result: { task_id: "beads:foreman:foreman-x", run_id: "run-1", replayed: false } }, 201);
  };
  expect((await approveTask("beads:foreman:foreman-x")).status).toBe("accepted");
  const [flag, script, ...positional] = call.args;
  expect([call.cmd, flag]).toEqual(["sh", "-c"]);
  expect(positional.slice(-2)).toEqual(["/api/commands", JSON.stringify(approveBody("beads:foreman:foreman-x"))]); // $1 and $2 of the script
  expect(script).toContain("-X POST");
  expect(script).toContain('--data "$2"'); // the body is data: it is never spliced into the script
  expect(script).toContain("-H @-"); // the token header is read from stdin ...
  expect(script).not.toMatch(/-H\s+["']?Authorization/); // ... and is never an argument of curl
});

test("a refusal, a failed call and any answer that is not an accepted command are errors, never a success", async () => {
  // the command controller's refusals: 422 {error: inspect(reason)}, 403 {error: "command_not_allowed"}
  const refused = await approval(curlSaid({ error: '{:task_not_approvable, "ready"}' }, 422));
  expect(refused.body).toBeUndefined();
  expect([refused.error.message, refused.error.status]).toEqual(['{:task_not_approvable, "ready"}', 422]);
  const notAllowed = await approval(curlSaid({ error: "command_not_allowed", type: "task.approve" }, 403));
  expect([notAllowed.error.message, notAllowed.error.status]).toEqual(["command_not_allowed", 403]);
  // an error status whose body has no `error` field (409 version_conflict, 504 command_timeout carry `code`)
  const timeout = await approval(curlSaid({ code: "command_timeout", retryable: true }, 504));
  expect(timeout.body).toBeUndefined();
  expect([timeout.error.message, timeout.error.status]).toEqual(["HTTP 504 from /api/commands", 504]);
  // a 2xx that is not the controller's acceptance: another server, a proxy, a changed contract
  const odd = await approval(curlSaid({ ok: true }, 200));
  expect(odd.body).toBeUndefined();
  expect(odd.error.message).toBe('unexpected answer: {"ok":true}');
  // not JSON at all, and no answer at all
  const html = await approval(curlSaid("<html>Bad Gateway</html>", 502));
  expect(html.error.message).toBe("unexpected response from /api/commands (HTTP 502)");
  const silent = await approval({ code: 0, stdout: "", stderr: "" });
  expect(silent.error.message).toBe("unexpected response from /api/commands");
  // curl itself failed (the server is down): its own line
  const down = await approval({ code: 7, stdout: "", stderr: "curl: (7) Failed to connect to 127.0.0.1 port 4766 after 0 ms\n" });
  expect(down.error.message).toBe("curl: (7) Failed to connect to 127.0.0.1 port 4766 after 0 ms");
});

// ------------------------------------------------------------------------------------ completion notifications

const poll = (state, ...runs) => trackCompletions(state, runs);
const ids = (r) => r.completed.map((x) => x.run_id);

test("the first poll only records a baseline: nothing is announced, completed runs included", () => {
  const first = poll(null, run("a", "in_progress"), run("b", "completed"), run("c", "failed"), run("d", "paused"));
  expect(first.completed).toEqual([]);
  expect(first.state).not.toBeNull();
  // ...and what the baseline saw going is what a later completion is measured against
  expect(ids(poll(first.state, run("a", "completed"), run("b", "completed"), run("c", "failed"), run("d", "paused")))).toEqual(["a"]);
});

test("a run that goes from in_progress to completed is announced once and never again", () => {
  const base = poll(null, run("a", "in_progress")).state;
  const done = poll(base, run("a", "completed"));
  expect(ids(done)).toEqual(["a"]);
  expect(ids(poll(done.state, run("a", "completed")))).toEqual([]); // the next poll: still completed, not news
  expect(ids(poll(done.state, run("a", "completed"), run("b", "in_progress")))).toEqual([]);
});

test("paused, awaiting_worker, stuck and blocked runs that complete are announced too", () => {
  for (const before of ["paused", "awaiting_worker", "in_progress", "stuck", "blocked"]) {
    const base = poll(null, run("a", before)).state;
    expect(ids(poll(base, run("a", "completed")))).toEqual(["a"]);
  }
});

test("failed and cancelled runs are not announced, nor is a run first seen already completed, nor completed twice in a row", () => {
  const base = poll(null, run("f", "in_progress"), run("x", "in_progress"), run("done", "completed")).state;
  const next = poll(base, run("f", "failed"), run("x", "cancelled"), run("done", "completed"), run("new", "completed"));
  expect(next.completed).toEqual([]); // "new" appeared already completed: nobody saw it going
});

test("a run that is re-opened and completes again is not announced twice", () => {
  const a = poll(null, run("a", "in_progress"));
  const b = poll(a.state, run("a", "completed"));
  const c = poll(b.state, run("a", "in_progress")); // a stale source flapped it back
  const d = poll(c.state, run("a", "completed"));
  expect([ids(a), ids(b), ids(c), ids(d)]).toEqual([[], ["a"], [], []]);
});

test("every run that completed in one poll is announced, in the listing's order", () => {
  const base = poll(null, run("a", "in_progress"), run("b", "paused"), run("c", "in_progress")).state;
  expect(ids(poll(base, run("c", "completed"), run("a", "completed"), run("b", "paused")))).toEqual(["c", "a"]);
});

test("an empty listing (a failed or racing read) changes nothing: the transition is still seen afterwards", () => {
  const base = poll(null, run("a", "in_progress")).state;
  const empty = poll(base);
  expect(empty.completed).toEqual([]);
  expect(empty.state).toBe(base);
  expect(ids(poll(empty.state, run("a", "completed")))).toEqual(["a"]);
  // an empty FIRST poll is the baseline: runs that show up completed afterwards were not seen going
  expect(ids(poll(poll(null).state, run("a", "completed")))).toEqual([]);
});

test("trackCompletions changes neither its state nor the listing it is given", () => {
  const base = poll(null, run("a", "in_progress")).state;
  const runs = [run("a", "completed")];
  const before = JSON.stringify({ seen: [...base.seen], notified: [...base.notified], runs });
  const next = trackCompletions(base, runs);
  expect(JSON.stringify({ seen: [...base.seen], notified: [...base.notified], runs })).toBe(before);
  expect(next.state).not.toBe(base);
  expect(next.state.notified.has("a")).toBe(true);
});

test("an announced run is remembered only while it is listed, so the state cannot grow for the life of the panel", () => {
  const a = poll(null, run("a", "in_progress"), run("b", "in_progress"));
  const b = poll(a.state, run("a", "completed"), run("b", "completed"));
  expect([...b.state.notified].sort()).toEqual(["a", "b"]);
  const c = poll(b.state, run("b", "completed"), run("x", "in_progress")); // "a" has left the listing
  expect([...c.state.notified]).toEqual(["b"]);
  expect([...c.state.seen.keys()].sort()).toEqual(["b", "x"]);
  // what is still listed stays announced once: a stale source flapping "b" back and forth does not announce it again
  const d = poll(c.state, run("b", "in_progress"), run("x", "in_progress"));
  expect(ids(poll(d.state, run("b", "completed"), run("x", "in_progress")))).toEqual([]);
  // an empty listing (a failed read) forgets nothing
  expect(poll(c.state).state).toBe(c.state);
});

test("the notification names the workflow and the bead, falls back to the task id, the title, the run id, and carries the run id in its action", () => {
  const t = completionToast({ run_id: "run-1", workflow_name: "fix", task_id: "beads:foreman:foreman-vbfmo.12" });
  expect(t).toEqual({ title: "Foreman", body: "fix foreman-vbfmo.12 completed", level: "success", timeout: 30000, action: { name: "foreman-runs.open-run-activity:run-1" } });
  expect(completionToast({ run_id: "run-2", workflow_snapshot: { workflow_name: "prd" }, task_id: "adhoc-1c2d3e" }).body).toBe("prd adhoc-1c2d3e completed");
  expect(completionToast({ run_id: "run-3", title: "Write the docs" }).body).toBe("run Write the docs completed");
  expect(completionToast({ run_id: "run-4" }).body).toBe("run run-4 completed");
});

test("what a notification's click delivers to the panel is parsed back to the run id (Herdr drops args and the mod's prefix)", () => {
  const delivered = (r) => completionToast(r).action.name.replace(/^foreman-runs\./, "");
  expect(parseActivityCommand(delivered({ run_id: "run-d0f4.9-b" }))).toEqual({ runId: "run-d0f4.9-b" });
  expect(parseActivityCommand("foreman-runs.open-run-activity:run-1")).toEqual({ runId: "run-1" });
  expect(parseActivityCommand("foreman-runs:open-run-activity:run-1")).toEqual({ runId: "run-1" });
});

test("open-run-activity without a usable run id is still recognised (so it can say what is missing); other commands are not", () => {
  for (const raw of ["open-run-activity", "open-run-activity:", "open-run-activity:has space", "open-run-activity:run/1", "open-run-activity:run-1;rm -rf"]) {
    expect(parseActivityCommand(raw)).toEqual({ runId: null });
  }
  for (const raw of ["toggle-failed", "foreman-runs.reset-confirmed", "focus", "open-run-activity-x:run-1", "xopen-run-activity:run-1", "", null, undefined]) {
    expect(parseActivityCommand(raw)).toBeNull();
  }
});

// ------------------------------------------------------------------------------------------------ merging a PR

const SHA = "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d";
// What GET /api/runs/:id/prs answers for one PR (ForemanServer.PrWatch.DTO), reduced the way the run-detail tab reads it.
const prDto = (over = {}) => ({
  pr_url: "https://github.com/acme/app/pull/12", repo_id: null, status: "open", head_sha: SHA, base_branch: "main", branch_name: "foreman/fix-x",
  merge_gate: "pending", watching: true, checks_state: "passing", checks: { items: [{ name: "ci", state: "passing", conclusion: "success" }] },
  eligibility: { status: "eligible", reasons: [], waived: [] }, ...over,
});
const pr = (over) => summarizePr(prDto(over));
const reasonOf = (over) => {
  const r = canMerge(pr(over));
  expect(r.ok).toBe(false);
  return r.reason;
};

test("an open PR with a full head, a pending gate and eligible evidence is mergeable in two steps", () => {
  expect(canMerge(pr())).toEqual({ ok: true, step: "approve", reason: "" });
});

test("a PR whose gate is already approved needs the merge alone", () => {
  expect(canMerge(pr({ merge_gate: "approved" }))).toMatchObject({ ok: true, step: "merge" });
});

test("only the server's `eligible` is one-click: off, waived, ineligible, unknown, missing and anything new are not", () => {
  expect(reasonOf({ eligibility: { status: "off", reasons: [] } })).toMatch(/no required checks.*--acknowledge-gate-off/);
  expect(reasonOf({ eligibility: { status: "waived", reasons: [], waived: [{ code: "skipped", subject: "lint" }] } })).toMatch(/waiver \(skipped \(lint\)\)/);
  expect(reasonOf({ eligibility: { status: "ineligible", reasons: [{ code: "failing", subject: "ci" }, { code: "risk_high" }] } })).toMatch(/not eligible: failing \(ci\); risk_high/);
  expect(reasonOf({ eligibility: { status: "ineligible", reasons: [] } })).toMatch(/not eligible: no reason given/);
  expect(reasonOf({ eligibility: { status: "unknown", reasons: [{ code: "evidence_unreadable" }] } })).toMatch(/could not judge.*evidence_unreadable/);
  expect(reasonOf({ eligibility: undefined })).toMatch(/could not judge/); // the model reads a record with none as unknown
  expect(reasonOf({ eligibility: { status: "pending-review", reasons: [] } })).toMatch(/eligibility is pending-review/);
});

test("only an open PR is mergeable: merged, closed, conflicted and anything else are refused with the state named", () => {
  expect(reasonOf({ status: "merged" })).toMatch(/already merged/);
  expect(reasonOf({ status: "closed" })).toMatch(/closed without being merged/);
  expect(reasonOf({ status: "conflicted" })).toMatch(/merge conflicts/);
  expect(reasonOf({ status: "draft" })).toMatch(/status is draft, not open/);
  expect(reasonOf({ status: undefined })).toMatch(/no status/);
});

test("the head must be a full commit SHA: an approval names the exact commit reviewed", () => {
  expect(isFullSha(SHA)).toBe(true);
  expect(isFullSha("a".repeat(64))).toBe(true);
  for (const bad of [undefined, null, "", SHA.slice(0, 8), SHA.slice(0, 39), `${SHA}0`, `${SHA.slice(0, 39)}g`, 123]) expect(isFullSha(bad)).toBe(false);
  for (const head_sha of [undefined, SHA.slice(0, 8), SHA.slice(0, 39)]) expect(reasonOf({ head_sha })).toMatch(/no full head commit SHA/);
  expect(shortSha(SHA)).toBe("1a2b3c4d");
});

test("the merge gate must be pending or approved; the server reports it for a run's primary PR only", () => {
  expect(reasonOf({ merge_gate: "none" })).toMatch(/merge gate is none/);
  expect(reasonOf({ merge_gate: undefined })).toMatch(/no merge gate for it/);
  expect(reasonOf({ merge_gate: "held" })).toMatch(/merge gate is held/);
});

test("a failing check refuses the one-click even though the server's eligibility counts only the required checks", () => {
  const items = [{ name: "ci", state: "passing" }, { name: "lint", state: "failing", conclusion: "failure" }];
  expect(reasonOf({ checks: { items } })).toMatch(/1 check is failing/);
  expect(reasonOf({ checks: { items: [...items, { name: "docs", state: "failing" }] } })).toMatch(/2 checks are failing/);
  expect(canMerge(pr({ checks: { items: [{ name: "ci", state: "pending" }] } })).ok).toBe(true); // pending is the server's call: it is ineligible then
});

test("no PR record is not mergeable, and canMerge never changes what it is given", () => {
  for (const p of [null, undefined]) expect(canMerge(p)).toMatchObject({ ok: false, reason: expect.stringMatching(/no pull request recorded/) });
  const p = pr();
  const before = JSON.stringify(p);
  canMerge(p);
  expect(JSON.stringify(p)).toBe(before);
});

test("approve-merge's arguments carry the FULL head SHA, the approver and its github: identity, and no gate-off acknowledgement", () => {
  const args = approveMergeArgs({ runId: "run-abc.1", login: "ldangelo", headSha: SHA });
  expect(args).toEqual(["run", "approve-merge", "--id", "run-abc.1", "--approver", "ldangelo", "--identity", "github:ldangelo", "--head-sha", SHA]);
  expect(args).not.toContain("--acknowledge-gate-off");
  expect(args).not.toContain("--repo-id");
});

test("a PR of another repository is addressed with --repo-id, for both steps", () => {
  expect(approveMergeArgs({ runId: "run-1", login: "ldangelo", headSha: SHA, repoId: "docs" }).slice(-2)).toEqual(["--repo-id", "docs"]);
  expect(mergeArgs({ runId: "run-1", repoId: "docs" })).toEqual(["run", "merge", "--id", "run-1", "--repo-id", "docs"]);
  expect(mergeArgs({ runId: "run-1", repoId: null })).toEqual(["run", "merge", "--id", "run-1"]);
});

test("merge names only the run: the server builds the merge from the approval", () => {
  expect(mergeArgs({ runId: "run-abc.1" })).toEqual(["run", "merge", "--id", "run-abc.1"]);
});

test("the argument builders refuse what is not a run id, a login, a full SHA or a repository id", () => {
  const ok = { runId: "run-1", login: "ldangelo", headSha: SHA };
  for (const bad of [{ runId: "" }, { runId: "run 1" }, { runId: "$(id)" }, { runId: undefined }, { login: "" }, { login: "-x" }, { login: "a b" }, { login: undefined },
    { headSha: SHA.slice(0, 8) }, { headSha: undefined }, { repoId: "Docs" }, { repoId: "" }, { repoId: "a;b" }]) {
    expect(() => approveMergeArgs({ ...ok, ...bad })).toThrow(/refusing to build a merge command/);
  }
  expect(() => mergeArgs({ runId: "run 1" })).toThrow(/not a run id/);
  expect(() => mergeArgs({ runId: "run-1", repoId: "A" })).toThrow(/not a repository id/);
});

test("the arguments reach the CLI as positional parameters of the shell, never inside the shell's script", () => {
  const args = approveMergeArgs({ runId: "run-1", login: "ldangelo", headSha: SHA });
  const argv = foremanArgv(args);
  expect(argv.slice(0, 2)).toEqual(["sh", "-c"]);
  expect(argv[2]).toContain('exec foreman "$@"');
  expect(argv[2]).not.toContain(SHA);
  expect(argv[2]).not.toContain("approve-merge");
  expect(argv.slice(-args.length)).toEqual(args);
});

test("the GitHub login is what `gh api user --jq .login` prints, and nothing else", () => {
  expect(parseGhLogin("ldangelo\n")).toBe("ldangelo");
  expect(parseGhLogin("octo-cat")).toBe("octo-cat");
  expect(parseGhLogin("a")).toBe("a");
  for (const bad of ["", "\n", "-x", "x-", "a b", "gh: command not found", '{"login":"x"}', "x".repeat(40), "ldangelo\nother", null, undefined]) expect(parseGhLogin(bad)).toBeNull();
});

test("the confirmation names the PR, its base, the short head, its checks and what cannot be undone; the approval step names who approves", () => {
  const p = pr();
  const { title, detail } = mergePrompt(p, { step: "approve", login: "ldangelo", label: "fix foreman-x (run-1)", checks: "1 passing · 0 failing · 0 pending" });
  expect(title).toBe("Merge PR #12?");
  expect(detail).toContain("fix foreman-x (run-1): PR #12 into main, head 1a2b3c4d, checks 1 passing · 0 failing · 0 pending.");
  expect(detail).toContain("Approves it as github:ldangelo");
  expect(detail).toContain("squash merge on GitHub; this cannot be undone");
  expect(detail).not.toContain(SHA); // the short head, not the whole SHA
  // no checks summary given: the sentence has no checks clause rather than an empty one
  expect(mergePrompt(p, { step: "approve", login: "ldangelo", label: "" }).detail).toContain("PR #12 into main, head 1a2b3c4d. Approves it");
});

test("an already approved PR's confirmation says so and approves nothing", () => {
  const { detail } = mergePrompt(pr({ merge_gate: "approved" }), { step: "merge", login: "ldangelo", label: "" });
  expect(detail).toContain("already approved");
  expect(detail).toContain("squash merge on GitHub; this cannot be undone");
  expect(detail).not.toContain("github:ldangelo");
});

// What `foreman run --help` prints (to stderr, exit 1) on a foreman that has the merge verbs.
const USAGE = `foreman run: unknown subcommand "--help"

Usage:
  foreman run list [--status <status>] [--project-id <id>] [--limit <n>]
  foreman run get <id>
  foreman run cancel --id <run-id> [--reason <reason>]
  foreman run reset --id <run-id>
  foreman run approve-merge --id <run-id> --approver <name> --identity <github:login> --head-sha <sha> [--repo-id <repo-id>] [--acknowledge-gate-off]
  foreman run waive-evidence --id <run-id> --approver <name> --identity <github:login> --head-sha <sha> --waive <codes> --reason <text> [--repo-id <repo-id>]
  foreman run merge --id <run-id> [--repo-id <repo-id>]
  foreman run prs <id>
  foreman run submit --workflow <name> --prompt <text> --project-id <id> [--work-id <id>] [--backend <backend>]
`;
const without = (usage, verb) => usage.split("\n").filter((l) => !new RegExp(`^\\s*foreman run ${verb}( |$)`).test(l)).join("\n");

test("an installed foreman with both merge verbs passes the check", () => {
  expect(mergeVerbsCheck(USAGE)).toEqual({ ok: true });
});

test("a foreman that lacks a merge verb is told apart per verb, in the toast's words", () => {
  expect(mergeVerbsCheck(without(without(USAGE, "approve-merge"), "merge"))).toEqual({ ok: false, reason: "installed foreman lacks `run approve-merge` and `run merge`; update it" });
  expect(mergeVerbsCheck(without(USAGE, "approve-merge"))).toEqual({ ok: false, reason: "installed foreman lacks `run approve-merge`; update it" });
  expect(mergeVerbsCheck(without(USAGE, "merge"))).toEqual({ ok: false, reason: "installed foreman lacks `run merge`; update it" });
});

test("another verb that merely starts like a merge verb does not count", () => {
  const lookalike = `${without(without(USAGE, "approve-merge"), "merge")}  foreman run merge-all\n  foreman run approve-merge-now --id <run-id>\n`;
  expect(mergeVerbsCheck(lookalike).reason).toBe("installed foreman lacks `run approve-merge` and `run merge`; update it");
});

test("output that is not foreman's usage is not read as 'the verbs are missing'", () => {
  for (const text of ["", "sh: foreman: command not found", "foreman: HTTP 401: unauthorized", null, undefined]) {
    const r = mergeVerbsCheck(text);
    expect(r.ok).toBe(false);
    expect(r.reason).toMatch(/could not read the usage of the installed foreman/);
    expect(r.reason).not.toMatch(/lacks/);
  }
});

test("the server's refusal of the approver is shown with its text and an explanation of the allowlist", () => {
  const text = mergeErrorText('HTTP 422: {"error":":unauthorized_approver"}');
  expect(text).toContain("approver allowlist");
  expect(text).toContain(":unauthorized_approver");
});

test("the refusals a merge can meet get plain words in front of the server's own text", () => {
  const said = (body) => mergeErrorText(`HTTP 422: ${JSON.stringify(body)}`);
  expect(said({ error: '{:head_sha_mismatch, "aaa", "bbb"}' })).toMatch(/^the PR's head on GitHub is not the commit that was shown \(\{:head_sha_mismatch, "aaa", "bbb"\}\)$/);
  expect(said({ error: '{:head_moved_since_approval, "aaa", "bbb"}' })).toMatch(/voids the approval/);
  expect(said({ error: '{:evidence_ineligible, "aaa", ["failing"]}', detail: {} })).toMatch(/not eligible \(\{:evidence_ineligible/);
  expect(said({ error: ":merge_gate_already_approved" })).toMatch(/already approved/);
  expect(said({ error: ":pr_not_acceptable" })).toMatch(/gate is not approved/);
});

test("a refusal with its own message is shown as the server wrote it; one with only a code shows the code", () => {
  expect(mergeErrorText('HTTP 422: {"error":":gate_off_not_acknowledged","message":"this project has no required_checks"}')).toBe("this project has no required_checks");
  expect(mergeErrorText('HTTP 504: {"code":"command_timeout","retryable":true}')).toBe("command_timeout");
  expect(mergeErrorText("HTTP 502: <html>bad gateway</html>")).toBe("<html>bad gateway</html>");
});

test("an error that is not a server refusal is shown as the CLI said it, first line only", () => {
  expect(mergeErrorText('Post "http://127.0.0.1:4766/api/commands": dial tcp 127.0.0.1:4766: connect: connection refused')).toContain("connection refused");
  expect(mergeErrorText("first\nsecond")).toBe("first");
  expect(mergeErrorText("")).toBe("the foreman command failed");
  expect(mergeErrorText(undefined)).toBe("the foreman command failed");
});

test("a verb that changes the server worked when the CLI exited 0, whatever it printed: its answer is never parsed", async () => {
  const seen = [];
  execImpl = async (cmd, args, opts) => { seen.push({ cmd, args, opts }); return { code: 0, stdout: "this is not JSON", stderr: "" }; };
  await expect(foremanDo(["run", "merge", "--id", "run-1"], 45000)).resolves.toBeUndefined();
  expect(seen[0].opts).toEqual({ timeout: 45000 }); // the CLI is given as long as the caller said
  expect(seen[0].args.slice(-4)).toEqual(["run", "merge", "--id", "run-1"]);
  await expect(foreman(["run", "list"])).rejects.toThrow(); // while reading JSON from the same output is a failure
  expect(seen[1].opts).toEqual({ timeout: 15000 }); // reads keep their default
  execImpl = async () => ({ code: 0, stdout: "", stderr: "" });
});

test("foreman and foremanDo both throw the CLI's own error line, without its prefix, and name the exit code when it said nothing", async () => {
  execImpl = async () => ({ code: 1, stdout: "", stderr: 'foreman: HTTP 422: {"error":":unauthorized_approver"}\n' });
  await expect(foremanDo(["run", "approve-merge"])).rejects.toThrow('HTTP 422: {"error":":unauthorized_approver"}');
  await expect(foreman(["run", "list"])).rejects.toThrow('HTTP 422: {"error":":unauthorized_approver"}');
  execImpl = async () => ({ code: 3, stdout: "", stderr: "" });
  await expect(foremanDo(["run", "merge"])).rejects.toThrow("foreman exited 3");
  execImpl = async () => ({ code: 0, stdout: '{"runs":[]}', stderr: "" });
  expect(await foreman(["run", "list"])).toEqual({ runs: [] });
  execImpl = async () => ({ code: 0, stdout: "", stderr: "" });
});
