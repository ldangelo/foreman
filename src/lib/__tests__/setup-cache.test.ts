import { afterEach, describe, expect, it } from "vitest";
import {
  existsSync,
  mkdirSync,
  lstatSync,
  mkdtempSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  rmSync,
  writeFileSync,
} from "node:fs";
import { createHash } from "node:crypto";
import { join } from "node:path";
import { tmpdir } from "node:os";

import { runSetupWithCache } from "../setup.js";
import type { WorkflowSetupCache, WorkflowSetupStep } from "../workflow-loader.js";

function makeTempDir(prefix: string): string {
  return realpathSync(mkdtempSync(join(tmpdir(), prefix)));
}

function makeWorkspace(seed: string): string {
  const dir = makeTempDir(`foreman-setup-cache-${seed}-`);
  writeFileSync(join(dir, "package-lock.json"), JSON.stringify({ version: 1 }));
  return dir;
}

function cacheHashFor(worktreePath: string, keyFile: string): string {
  return createHash("sha256")
    .update(readFileSync(join(worktreePath, keyFile)))
    .digest("hex")
    .slice(0, 16);
}

const tempDirs: string[] = [];

afterEach(() => {
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

describe("runSetupWithCache", () => {
  it("keeps a valid non-empty cache hit and skips setup", async () => {
    const projectRoot = makeTempDir("foreman-setup-cache-project-");
    tempDirs.push(projectRoot);

    const cacheConfig: WorkflowSetupCache = {
      key: "package-lock.json",
      path: "node_modules",
    };

    const setupSteps: WorkflowSetupStep[] = [
      { command: "mkdir -p node_modules/.bin" },
      { command: "touch node_modules/.bin/vitest" },
      { command: "touch setup-ran.flag" },
    ];

    const workspace1 = makeWorkspace("hit-1");
    tempDirs.push(workspace1);
    await runSetupWithCache(workspace1, projectRoot, setupSteps, cacheConfig);

    const hash = cacheHashFor(workspace1, "package-lock.json");
    const cacheDir = join(projectRoot, ".foreman", "setup-cache", hash);

    expect(existsSync(join(cacheDir, ".complete"))).toBe(true);
    expect(existsSync(join(cacheDir, "node_modules", ".bin", "vitest"))).toBe(true);
    expect(lstatSync(join(workspace1, "node_modules")).isSymbolicLink()).toBe(true);
    expect(readlinkSync(join(workspace1, "node_modules"))).toBe(join(cacheDir, "node_modules"));

    const workspace2 = makeWorkspace("hit-2");
    tempDirs.push(workspace2);

    const secondSteps: WorkflowSetupStep[] = [
      { command: "mkdir -p node_modules/.bin" },
      { command: "touch node_modules/.bin/vitest" },
      { command: "touch should-not-run.flag" },
    ];

    await runSetupWithCache(workspace2, projectRoot, secondSteps, cacheConfig);

    expect(existsSync(join(workspace2, "should-not-run.flag"))).toBe(false);
    expect(lstatSync(join(workspace2, "node_modules")).isSymbolicLink()).toBe(true);
    expect(readlinkSync(join(workspace2, "node_modules"))).toBe(join(cacheDir, "node_modules"));
  });

  it("treats an empty cached directory with .complete as stale and repopulates it", async () => {
    const projectRoot = makeTempDir("foreman-setup-cache-project-");
    tempDirs.push(projectRoot);

    const cacheConfig: WorkflowSetupCache = {
      key: "package-lock.json",
      path: "node_modules",
    };

    const workspace = makeWorkspace("stale");
    tempDirs.push(workspace);

    const hash = cacheHashFor(workspace, "package-lock.json");
    const cacheDir = join(projectRoot, ".foreman", "setup-cache", hash);
    const cachedPath = join(cacheDir, "node_modules");

    mkdirSync(cachedPath, { recursive: true });
    writeFileSync(join(cacheDir, ".complete"), "stale");

    const setupSteps: WorkflowSetupStep[] = [
      { command: "mkdir -p node_modules/.bin" },
      { command: "touch node_modules/.bin/vitest" },
      { command: "touch setup-ran.flag" },
    ];

    await runSetupWithCache(workspace, projectRoot, setupSteps, cacheConfig);

    expect(existsSync(join(workspace, "setup-ran.flag"))).toBe(true);
    expect(lstatSync(join(workspace, "node_modules")).isSymbolicLink()).toBe(true);
    expect(readlinkSync(join(workspace, "node_modules"))).toBe(cachedPath);
    expect(existsSync(join(cachedPath, ".bin", "vitest"))).toBe(true);
    expect(existsSync(join(cacheDir, ".complete"))).toBe(true);
  });
});
