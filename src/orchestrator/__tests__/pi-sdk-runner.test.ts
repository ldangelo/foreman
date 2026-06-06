import { mkdirSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { getPiSdkEventError, getSandboxedPiResourcePaths, shouldSandboxPiExtensions, type StreamEvent } from "../pi-sdk-runner.js";

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

describe("StreamEvent type", () => {
  it("accepts valid text event structure", () => {
    const event: StreamEvent = {
      type: "text",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
      delta: "Hello",
    };
    expect(event.type).toBe("text");
    expect(event.delta).toBe("Hello");
  });

  it("accepts valid toolCall event structure", () => {
    const event: StreamEvent = {
      type: "toolCall",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
      toolName: "Read",
      args: { path: "/tmp/test.txt" },
    };
    expect(event.type).toBe("toolCall");
    expect(event.toolName).toBe("Read");
    expect(event.args).toEqual({ path: "/tmp/test.txt" });
  });

  it("accepts valid turnStart event structure", () => {
    const event: StreamEvent = {
      type: "turnStart",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
    };
    expect(event.type).toBe("turnStart");
    expect(event.iteration).toBe(1);
  });

  it("accepts valid turnEnd event structure with token info", () => {
    const event: StreamEvent = {
      type: "turnEnd",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
      tokensIn: 100,
      tokensOut: 200,
    };
    expect(event.type).toBe("turnEnd");
    expect(event.tokensIn).toBe(100);
    expect(event.tokensOut).toBe(200);
  });

  it("accepts valid turnEnd event structure without token info", () => {
    const event: StreamEvent = {
      type: "turnEnd",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
    };
    expect(event.type).toBe("turnEnd");
    expect(event.tokensIn).toBeUndefined();
  });

  it("accepts valid agentEnd event structure", () => {
    const event: StreamEvent = {
      type: "agentEnd",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
      success: true,
      message: "Done",
    };
    expect(event.type).toBe("agentEnd");
    expect(event.success).toBe(true);
    expect(event.message).toBe("Done");
  });

  it("accepts agentEnd event with success=false", () => {
    const event: StreamEvent = {
      type: "agentEnd",
      iteration: 1,
      timestamp: "2024-01-01T00:00:00.000Z",
      success: false,
      message: "Agent encountered an error",
    };
    expect(event.type).toBe("agentEnd");
    expect(event.success).toBe(false);
  });
});
