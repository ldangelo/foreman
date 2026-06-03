import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { getPiSdkEventError, getSandboxedPiResourcePaths, shouldSandboxPiExtensions } from "../pi-sdk-runner.js";

const tmpDirs: string[] = [];

afterEach(() => {
  for (const dir of tmpDirs.splice(0)) {
    rmSync(dir, { recursive: true, force: true });
  }
});

describe("shouldSandboxPiExtensions", () => {
  it("defaults Foreman Pi SDK sessions to extension sandboxing", () => {
    expect(shouldSandboxPiExtensions({})).toBe(true);
  });

  it("allows opting back into user Pi extensions", () => {
    expect(shouldSandboxPiExtensions({ FOREMAN_PI_EXTENSIONS: "user" })).toBe(false);
  });
});

describe("getPiSdkEventError", () => {
  it("treats SDK stopReason=error events as failures", () => {
    expect(getPiSdkEventError({
      type: "turn_end",
      stopReason: "error",
      errorMessage: "provider usage exhausted",
    } as never)).toBe("provider usage exhausted");
  });

  it("treats SDK errorMessage-only events as failures", () => {
    expect(getPiSdkEventError({
      type: "message_end",
      errorMessage: "provider failed",
    } as never)).toBe("provider failed");
  });
});

describe("getSandboxedPiResourcePaths", () => {
  it("allows only Ensemble resources plus Foreman send-mail skill", () => {
    const ensemblePiRoot = mkdtempSync(join(tmpdir(), "foreman-ensemble-pi-"));
    tmpDirs.push(ensemblePiRoot);
    mkdirSync(join(ensemblePiRoot, "extensions"));
    mkdirSync(join(ensemblePiRoot, "skills"));
    mkdirSync(join(ensemblePiRoot, "prompts"));

    const resources = getSandboxedPiResourcePaths({ FOREMAN_ENSEMBLE_PI_PATH: ensemblePiRoot });

    expect(resources.extensionPaths).toEqual([join(ensemblePiRoot, "extensions")]);
    expect(resources.skillPaths).toContain(join(ensemblePiRoot, "skills"));
    expect(resources.skillPaths.some((path) => path.endsWith("send-mail/SKILL.md"))).toBe(true);
    expect(resources.promptTemplatePaths).toEqual([join(ensemblePiRoot, "prompts")]);
  });
});
