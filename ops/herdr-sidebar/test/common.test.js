// Regression tests for the helpers in common.js that are pure (the module imports "herdr", which only exists
// inside the app, so it is stubbed here).
// Run: bun test ops/herdr-sidebar/test   (bun is not a devbox package and CI does not run this suite)
import { test, expect, mock } from "bun:test";

let execImpl = async () => ({ code: 0, stdout: "", stderr: "" }); // what the stubbed exec() answers; a test sets it
mock.module("herdr", () => ({ exec: (...a) => execImpl(...a), home: () => "/h", window: () => ({ platform: "macos" }) }));
const { approveBody, approvePrompt, approveTask, beadId, clearRuns, countCleared, findApprovable, hideCleared, isApprovable, isClearable, isResettable, parseCleared, pruneCleared, resetPrompt } = await import("../common.js");

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
