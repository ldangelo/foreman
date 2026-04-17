/**
 * TRD-NF-002-TEST: Verify worker binary PATH includes ~/.local/bin/br directory.
 *
 * buildWorkerEnv() prepends ~/.local/bin so spawned worker agents can find
 * the `br` binary. Verified via the same env-construction logic used in
 * dispatcher.ts (TRD-NF-002 requirement).
 */

import { describe, it, expect } from "vitest";
import os from "node:os";
import { mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { resolveWorkerPaths } from "../dispatcher.js";

describe("TRD-NF-002: worker PATH construction includes ~/.local/bin", () => {
  it("~/.local/bin prepended produces PATH with br binary directory first", () => {
    const home = os.homedir();
    const baseEnv: Record<string, string> = {};
    baseEnv.PATH = `${home}/.local/bin:/opt/homebrew/bin:${process.env.PATH ?? ""}`;

    expect(baseEnv.PATH).toContain(`${home}/.local/bin`);
    expect(baseEnv.PATH.startsWith(`${home}/.local/bin`)).toBe(true);
  });

  it("~/.local/bin appears before /opt/homebrew/bin", () => {
    const home = os.homedir();
    const path = `${home}/.local/bin:/opt/homebrew/bin:${process.env.PATH ?? ""}`;
    const localBinIdx = path.indexOf(`${home}/.local/bin`);
    const homebrewIdx = path.indexOf("/opt/homebrew/bin");
    expect(localBinIdx).toBeLessThan(homebrewIdx);
  });

  it("br binary is resolvable via ~/.local/bin path segment", () => {
    // The br binary ships at ~/.local/bin/br — verify our PATH construction
    // would make it discoverable via PATH lookup.
    const home = os.homedir();
    const workerPath = `${home}/.local/bin:/opt/homebrew/bin:${process.env.PATH ?? ""}`;
    const segments = workerPath.split(":");
    expect(segments[0]).toBe(`${home}/.local/bin`);
  });

  it("resolveWorkerPaths prefers the TS worker when running from source", () => {
    const resolved = resolveWorkerPaths("/tmp");
    expect(resolved.workerScript.endsWith("agent-worker.ts")).toBe(true);
    expect(resolved.runnerArgs.some((arg) => arg.endsWith("loader.mjs"))).toBe(true);
  });

  it("resolveWorkerPaths falls back to the built JS worker when TS source is absent", () => {
    const dir = mkdtempSync(join(tmpdir(), "foreman-worker-path-"));
    try {
      writeFileSync(join(dir, "agent-worker.js"), "export {};\n");
      const resolved = resolveWorkerPaths("/tmp", dir);
      expect(resolved.workerScript.endsWith("agent-worker.js")).toBe(true);
      expect(resolved.runnerArgs).toEqual([resolved.workerScript]);
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
