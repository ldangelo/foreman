import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { mkdtempSync, rmSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

vi.mock("../pi-sdk-runner.js", () => ({
  runWithPiSdk: vi.fn(),
}));

import { runWithPiSdk } from "../pi-sdk-runner.js";
import { createConfiguredPhaseRunner, createDefaultPhaseRunner, type PhaseRunnerRequest } from "../phase-runner.js";

const mockRunWithPiSdk = vi.mocked(runWithPiSdk);

function makeRequest(overrides?: Partial<PhaseRunnerRequest>): PhaseRunnerRequest {
  return {
    metadata: {
      phaseName: "developer",
      role: "developer",
      mode: "pipeline",
      runId: "run-123",
      projectId: "proj-123",
      seedId: "seed-123",
      seedTitle: "Smoke task",
      seedDescription: "Create test.txt",
      seedComments: "scenario: create",
      seedType: "smoke",
      seedLabels: ["workflow:smoke"],
      seedPriority: "P2",
      worktreePath: "/tmp/worktree",
      projectPath: "/tmp/project",
      workflowName: "smoke",
      targetBranch: "main",
      taskId: "task-1",
    },
    pi: {
      prompt: "Write DEVELOPER_REPORT.md",
      systemPrompt: "You are developer",
      cwd: "/tmp/worktree",
      model: "openai/gpt-5.2-chat-latest",
      allowedTools: ["Read", "Write"],
      customTools: [],
      logFile: "/tmp/run.log",
    },
    ...overrides,
  };
}

describe("phase-runner", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-phase-runner-"));
    mockRunWithPiSdk.mockReset();
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("default runner delegates directly to runWithPiSdk", async () => {
    mockRunWithPiSdk.mockResolvedValue({
      success: true,
      costUsd: 0,
      turns: 1,
      toolCalls: 0,
      toolBreakdown: {},
      tokensIn: 0,
      tokensOut: 0,
      outputText: "ok",
    });

    const runner = createDefaultPhaseRunner();
    const request = makeRequest();
    const result = await runner(request);

    expect(mockRunWithPiSdk).toHaveBeenCalledTimes(1);
    expect(mockRunWithPiSdk).toHaveBeenCalledWith(request.pi);
    expect(result.success).toBe(true);
  });

  it("loads a configured module runner and passes explicit metadata", async () => {
    const capturePath = join(tmpDir, "captured.json");
    const modulePath = join(tmpDir, "custom-runner.mjs");
    writeFileSync(modulePath, `
      import { writeFileSync } from "node:fs";
      export function createPhaseRunner(ctx) {
        return async (request) => {
          writeFileSync(ctx.config.optionsPath, JSON.stringify({ ctx, request }, null, 2));
          return {
            success: true,
            costUsd: 1.25,
            turns: 2,
            toolCalls: 3,
            toolBreakdown: { Write: 1 },
            tokensIn: 10,
            tokensOut: 20,
            outputText: "custom",
          };
        };
      }
    `, "utf-8");

    const runner = await createConfiguredPhaseRunner(
      {
        modulePath: "./custom-runner.mjs",
        optionsPath: capturePath,
      },
      tmpDir,
    );

    const request = makeRequest({
      metadata: {
        ...makeRequest().metadata,
        phaseName: "qa",
        role: "qa",
      },
    });
    const result = await runner(request);
    const captured = JSON.parse(readFileSync(capturePath, "utf-8"));

    expect(result.outputText).toBe("custom");
    expect(captured.ctx.projectRoot).toBe(tmpDir);
    expect(captured.request.metadata.phaseName).toBe("qa");
    expect(captured.request.metadata.seedId).toBe("seed-123");
    expect(captured.request.pi.prompt).toContain("DEVELOPER_REPORT");
  });

  it("throws when the configured module does not expose the requested factory export", async () => {
    const modulePath = join(tmpDir, "bad-runner.mjs");
    writeFileSync(modulePath, "export const nope = 1;\n", "utf-8");

    await expect(
      createConfiguredPhaseRunner(
        {
          modulePath,
          exportName: "createPhaseRunner",
        },
        tmpDir,
      ),
    ).rejects.toThrow(/must export function/);
  });
});
