import { beforeEach, describe, expect, it, vi } from "vitest";

const {
  createAgentSessionMock,
  getModelMock,
  appendFileMock,
} = vi.hoisted(() => ({
  createAgentSessionMock: vi.fn(),
  getModelMock: vi.fn(() => ({ provider: "minimax", id: "MiniMax-M2.7" })),
  appendFileMock: vi.fn(() => Promise.resolve()),
}));

vi.mock("@mariozechner/pi-coding-agent", () => ({
  createAgentSession: createAgentSessionMock,
  SessionManager: { inMemory: vi.fn(() => ({ kind: "session-manager" })) },
  SettingsManager: { inMemory: vi.fn(() => ({ kind: "settings-manager" })) },
  AuthStorage: { create: vi.fn(() => ({ kind: "auth-storage" })) },
  getAgentDir: vi.fn(() => "/tmp/pi-agent"),
  createReadTool: vi.fn((cwd: string) => ({ name: "Read", cwd })),
  createBashTool: vi.fn((cwd: string) => ({ name: "Bash", cwd })),
  createEditTool: vi.fn((cwd: string) => ({ name: "Edit", cwd })),
  createWriteTool: vi.fn((cwd: string) => ({ name: "Write", cwd })),
  createGrepTool: vi.fn((cwd: string) => ({ name: "Grep", cwd })),
  createFindTool: vi.fn((cwd: string) => ({ name: "Find", cwd })),
  createLsTool: vi.fn((cwd: string) => ({ name: "LS", cwd })),
}));

vi.mock("@mariozechner/pi-ai", () => ({
  getModel: getModelMock,
}));

vi.mock("node:fs/promises", () => ({
  appendFile: appendFileMock,
}));

import { runWithPiSdk } from "../pi-sdk-runner.js";

type SessionScenario = {
  success: boolean;
  errorMessage?: string;
  toolCalls?: number;
  tokensIn?: number;
  tokensOut?: number;
};

function makeSession(scenario: SessionScenario) {
  let subscriber: ((event: Record<string, unknown>) => void) | undefined;
  const prompt = vi.fn(async () => {
    subscriber?.({ type: "turn_start" });
    for (let index = 0; index < (scenario.toolCalls ?? 0); index++) {
      subscriber?.({ type: "tool_execution_start", toolName: "Read", args: { index } });
    }
    if (!scenario.success) {
      subscriber?.({
        type: "auto_retry_end",
        success: false,
        finalError: scenario.errorMessage ?? "Connection error.",
      });
      subscriber?.({
        type: "agent_end",
        success: false,
        message: scenario.errorMessage ?? "Connection error.",
      });
    } else {
      subscriber?.({ type: "agent_end", success: true });
    }
    subscriber?.({ type: "turn_end" });
  });

  return {
    subscribe: vi.fn((cb: (event: Record<string, unknown>) => void) => {
      subscriber = cb;
    }),
    prompt,
    getSessionStats: vi.fn(() => ({
      cost: 0,
      tokens: {
        input: scenario.tokensIn ?? 0,
        output: scenario.tokensOut ?? 0,
      },
    })),
    dispose: vi.fn(),
  };
}

describe("runWithPiSdk()", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("retries with a fresh session when the first attempt fails before any work starts", async () => {
    createAgentSessionMock
      .mockResolvedValueOnce({
        session: makeSession({
          success: false,
          errorMessage: "Connection error.",
          toolCalls: 0,
          tokensOut: 0,
        }),
      })
      .mockResolvedValueOnce({
        session: makeSession({
          success: true,
          toolCalls: 0,
          tokensOut: 12,
        }),
      });

    const result = await runWithPiSdk({
      cwd: "/tmp/worktree",
      model: "minimax/MiniMax-M2.7",
      prompt: "Reply with OK",
      systemPrompt: "",
      allowedTools: ["Read"],
      logFile: "/tmp/pi-sdk.log",
    });

    expect(result.success).toBe(true);
    expect(createAgentSessionMock).toHaveBeenCalledTimes(2);
    expect(appendFileMock).toHaveBeenCalledWith(
      "/tmp/pi-sdk.log",
      expect.stringContaining("retrying with fresh session attempt=2/2"),
    );
  });

  it("does not retry with a fresh session after tool activity has already occurred", async () => {
    createAgentSessionMock.mockResolvedValue({
      session: makeSession({
        success: false,
        errorMessage: "Connection error.",
        toolCalls: 1,
        tokensOut: 0,
      }),
    });

    const result = await runWithPiSdk({
      cwd: "/tmp/worktree",
      model: "minimax/MiniMax-M2.7",
      prompt: "Reply with OK",
      systemPrompt: "",
      allowedTools: ["Read"],
    });

    expect(result.success).toBe(false);
    expect(result.errorMessage).toBe("Connection error.");
    expect(createAgentSessionMock).toHaveBeenCalledTimes(1);
  });

  it("does not retry with a fresh session for non-retryable failures", async () => {
    createAgentSessionMock.mockResolvedValue({
      session: makeSession({
        success: false,
        errorMessage: "No API key found for \"minimax\".",
        toolCalls: 0,
        tokensOut: 0,
      }),
    });

    const result = await runWithPiSdk({
      cwd: "/tmp/worktree",
      model: "minimax/MiniMax-M2.7",
      prompt: "Reply with OK",
      systemPrompt: "",
      allowedTools: ["Read"],
    });

    expect(result.success).toBe(false);
    expect(result.errorMessage).toBe("No API key found for \"minimax\".");
    expect(createAgentSessionMock).toHaveBeenCalledTimes(1);
  });
});
