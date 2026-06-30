import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { getLastPiActivity } from "../commands/status.js";

describe("getLastPiActivity", () => {
  const tempDirs: string[] = [];
  let originalHome: string | undefined;

  function makeTempDir(): string {
    const dir = mkdtempSync(join(tmpdir(), "foreman-status-log-activity-"));
    tempDirs.push(dir);
    return dir;
  }

  beforeEach(() => {
    originalHome = process.env.HOME;
  });

  afterEach(() => {
    if (originalHome === undefined) delete process.env.HOME;
    else process.env.HOME = originalHome;
    for (const dir of tempDirs) rmSync(dir, { recursive: true, force: true });
    tempDirs.length = 0;
  });

  it("returns null when the log file is missing", async () => {
    process.env.HOME = makeTempDir();
    await expect(getLastPiActivity("run-missing")).resolves.toBeNull();
  });

  it("returns the most recent tool_call with a path hint", async () => {
    const home = makeTempDir();
    const logsDir = join(home, ".foreman", "logs");
    mkdirSync(logsDir, { recursive: true });
    writeFileSync(join(logsDir, "run-1.out"), [
      JSON.stringify({ type: "tool_call", name: "read", input: { path: "src/old.ts" } }),
      JSON.stringify({ type: "message_update", text: "ignore me" }),
      JSON.stringify({ type: "tool_call", name: "bash", input: { command: "npm test" } }),
      "",
    ].join("\n"));
    process.env.HOME = home;

    await expect(getLastPiActivity("run-1")).resolves.toBe("bash(npm test)");
  });

  it("uses the last supported hint field and truncates long values from the front", async () => {
    const home = makeTempDir();
    const logsDir = join(home, ".foreman", "logs");
    mkdirSync(logsDir, { recursive: true });
    const longPath = "/very/long/path/that/keeps/going/and/going/src/cli/commands/status.ts";
    writeFileSync(join(logsDir, "run-2.out"), JSON.stringify({ type: "tool_call", name: "read", input: { file_path: longPath } }) + "\n");
    process.env.HOME = home;

    const activity = await getLastPiActivity("run-2");
    expect(activity).toBe(`read(…${longPath.slice(-38)})`);
  });

  it("returns just the tool name when no hint field is present", async () => {
    const home = makeTempDir();
    const logsDir = join(home, ".foreman", "logs");
    mkdirSync(logsDir, { recursive: true });
    writeFileSync(join(logsDir, "run-3.out"), JSON.stringify({ type: "tool_call", name: "custom_tool", input: { other: true } }) + "\n");
    process.env.HOME = home;

    await expect(getLastPiActivity("run-3")).resolves.toBe("custom_tool");
  });

  it("skips malformed and non-tool lines while scanning backwards", async () => {
    const home = makeTempDir();
    const logsDir = join(home, ".foreman", "logs");
    mkdirSync(logsDir, { recursive: true });
    writeFileSync(join(logsDir, "run-4.out"), [
      JSON.stringify({ type: "tool_call", name: "grep", input: { pattern: "needle" } }),
      "not-json",
      JSON.stringify({ type: "assistant_message", text: "ignore" }),
      "",
    ].join("\n"));
    process.env.HOME = home;

    await expect(getLastPiActivity("run-4")).resolves.toBe("grep(needle)");
  });
});
