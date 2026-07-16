import { describe, expect, it } from "vitest";

import { resolveBoardCommandRoute } from "../commands/board.js";
import { resolveInboxDetailRoute, resolveInboxOverviewRoute, validateInboxDetailOptions } from "../commands/inbox.js";
import { shouldRouteStatusToSuperTui } from "../commands/status.js";

describe("super TUI command wrapper route decisions", () => {
  describe("status", () => {
    it("keeps --json on the scriptable JSON path instead of opening the cockpit", () => {
      expect(shouldRouteStatusToSuperTui({ json: true })).toBe(false);
      expect(shouldRouteStatusToSuperTui({ json: true, live: true })).toBe(false);
    });

    it("routes --live to the status cockpit when JSON output is not requested", () => {
      expect(shouldRouteStatusToSuperTui({ live: true })).toBe(true);
    });
  });

  describe("inbox", () => {
    it.each([
      { subcommand: "task", options: {}, expected: "detail" },
      { subcommand: "run", options: {}, expected: "detail" },
      { subcommand: "task", options: { interactive: true }, expected: "cockpit" },
      { subcommand: "run", options: { interactive: true }, expected: "cockpit" },
    ] as const)("routes inbox $subcommand detail through $expected for the selected id", ({ options, expected }) => {
      expect(resolveInboxDetailRoute(options)).toBe(expected);
    });

    it("rejects combining inbox report selection with follow mode", () => {
      expect(validateInboxDetailOptions({ follow: true, selectReport: true })).toContain("--follow and --select-report");
      expect(validateInboxDetailOptions({ follow: true })).toBeNull();
      expect(validateInboxDetailOptions({ selectReport: true })).toBeNull();
    });

    it.each([
      { name: "TTY overview with no explicit output mode", options: {}, stdoutIsTTY: true, expected: "cockpit" },
      { name: "explicitly non-interactive TTY overview", options: { nonInteractive: true }, stdoutIsTTY: true, expected: "scriptable" },
      { name: "TTY overview with a run filter", options: { run: "run-123" }, stdoutIsTTY: true, expected: "scriptable" },
      { name: "explicitly interactive overview with a run filter", options: { interactive: true, run: "run-123" }, stdoutIsTTY: true, expected: "cockpit" },
      { name: "non-TTY overview", options: {}, stdoutIsTTY: false, expected: "scriptable" },
    ] as const)("routes $name through $expected", ({ options, stdoutIsTTY, expected }) => {
      expect(resolveInboxOverviewRoute(options, stdoutIsTTY)).toBe(expected);
    });
  });

  describe("board", () => {
    it.each([
      { name: "TTY board without a filter", options: {}, stdoutIsTTY: true, expected: "cockpit" },
      { name: "non-TTY board", options: {}, stdoutIsTTY: false, expected: "legacy-board" },
      { name: "filtered board", options: { filter: "ready" }, stdoutIsTTY: true, expected: "legacy-board" },
      { name: "all-project board", options: { all: true }, stdoutIsTTY: true, expected: "legacy-board" },
    ] as const)("routes $name through $expected", ({ options, stdoutIsTTY, expected }) => {
      expect(resolveBoardCommandRoute(options, stdoutIsTTY)).toBe(expected);
    });
  });
});
