// Regression tests for the helpers in common.js that are pure (the module imports "herdr", which only exists
// inside the app, so it is stubbed here).
// Run: bun test ops/herdr-sidebar/test   (bun is not a devbox package and CI does not run this suite)
import { test, expect, mock } from "bun:test";

mock.module("herdr", () => ({ exec: async () => ({ code: 0, stdout: "", stderr: "" }), home: () => "/h", window: () => ({ platform: "macos" }) }));
const { beadId, clearRuns, countCleared, hideCleared, isClearable, parseCleared, pruneCleared } = await import("../common.js");

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
