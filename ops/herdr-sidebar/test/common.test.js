// Regression tests for the helpers in common.js that are pure (the module imports "herdr", which only exists
// inside the app, so it is stubbed here).
// Run: bun test ops/herdr-sidebar/test   (bun is not a devbox package and CI does not run this suite)
import { test, expect, mock } from "bun:test";

mock.module("herdr", () => ({ exec: async () => ({ code: 0, stdout: "", stderr: "" }), home: () => "/h", window: () => ({ platform: "macos" }) }));
const { beadId } = await import("../common.js");

test("beadId takes the bead id off a beads task id", () => {
  expect(beadId({ task_id: "beads:foreman:foreman-jzycy" })).toBe("foreman-jzycy");
  expect(beadId({ task_id: "beads:ensemble:br-bhj9" })).toBe("br-bhj9");
});

test("beadId keeps a dotted child bead whole", () => {
  expect(beadId({ task_id: "beads:foreman:foreman-vbfmo.1" })).toBe("foreman-vbfmo.1");
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
