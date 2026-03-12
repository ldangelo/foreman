import { describe, it, expect, beforeEach } from "vitest";
import { MockRuntime } from "../runtime-mock.js";
import { createRuntime, getAvailableRuntimes } from "../runtime.js";
import type { SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import type { AgentQueryOptions } from "../runtime.js";

// ── MockRuntime tests ────────────────────────────────────────────────────

describe("MockRuntime", () => {
  let mock: MockRuntime;

  beforeEach(() => {
    mock = new MockRuntime();
  });

  it("has name 'mock'", () => {
    expect(mock.name).toBe("mock");
  });

  it("yields no messages by default", async () => {
    const messages: SDKMessage[] = [];
    for await (const msg of mock.executeQuery({ prompt: "hello" })) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(0);
  });

  it("yields preset messages from setMessages()", async () => {
    const preset = [
      { type: "system", subtype: "init", apiKeySource: "env", cwd: "/tmp", tools: [], mcp_servers: [], model: "claude-sonnet-4-6", permissionMode: "bypassPermissions" } as unknown as SDKMessage,
    ];
    mock.setMessages(preset);

    const messages: SDKMessage[] = [];
    for await (const msg of mock.executeQuery({ prompt: "test" })) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(1);
    expect(messages[0]).toBe(preset[0]);
  });

  it("captures params passed to executeQuery()", async () => {
    const opts: AgentQueryOptions = {
      prompt: "implement feature X",
      options: { cwd: "/project", model: "claude-sonnet-4-6" },
    };

    // consume the generator
    // eslint-disable-next-line @typescript-eslint/no-unused-vars
    for await (const _ of mock.executeQuery(opts)) { /* drain */ }

    const captured = mock.getCapturedParams();
    expect(captured).toHaveLength(1);
    expect(captured[0].prompt).toBe("implement feature X");
    expect(captured[0].options?.cwd).toBe("/project");
  });

  it("accumulates captures across multiple calls", async () => {
    for await (const _ of mock.executeQuery({ prompt: "first" })) { /* drain */ }
    for await (const _ of mock.executeQuery({ prompt: "second" })) { /* drain */ }

    expect(mock.getCapturedParams()).toHaveLength(2);
    expect(mock.getCapturedParams()[0].prompt).toBe("first");
    expect(mock.getCapturedParams()[1].prompt).toBe("second");
  });

  it("reset() clears messages and captured params", async () => {
    mock.setMessages([{ type: "system" } as unknown as SDKMessage]);
    for await (const _ of mock.executeQuery({ prompt: "call" })) { /* drain */ }

    mock.reset();

    expect(mock.getCapturedParams()).toHaveLength(0);
    const messages: SDKMessage[] = [];
    for await (const msg of mock.executeQuery({ prompt: "after reset" })) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(0);
  });

  it("yields messages in order", async () => {
    const preset = [
      { type: "system", id: 1 } as unknown as SDKMessage,
      { type: "assistant", id: 2 } as unknown as SDKMessage,
      { type: "result", id: 3 } as unknown as SDKMessage,
    ];
    mock.setMessages(preset);

    const messages: SDKMessage[] = [];
    for await (const msg of mock.executeQuery({ prompt: "order test" })) {
      messages.push(msg);
    }
    expect(messages).toHaveLength(3);
    expect((messages[0] as any).id).toBe(1);
    expect((messages[1] as any).id).toBe(2);
    expect((messages[2] as any).id).toBe(3);
  });
});

// ── createRuntime factory tests ──────────────────────────────────────────

describe("createRuntime", () => {
  it("creates a MockRuntime for 'mock' selection", async () => {
    const runtime = await createRuntime("mock");
    expect(runtime.name).toBe("mock");
    expect(runtime).toBeInstanceOf(MockRuntime);
  });

  it("creates a ClaudeSDKRuntime for 'claude-code' selection", async () => {
    const { ClaudeSDKRuntime } = await import("../runtime-claude-sdk.js");
    const runtime = await createRuntime("claude-code");
    expect(runtime.name).toBe("claude-code");
    expect(runtime).toBeInstanceOf(ClaudeSDKRuntime);
  });

  it("throws for unknown runtime selection", async () => {
    await expect(createRuntime("unknown-runtime" as any)).rejects.toThrow(
      "Unknown runtime: unknown-runtime",
    );
  });
});

// ── getAvailableRuntimes tests ───────────────────────────────────────────

describe("getAvailableRuntimes", () => {
  it("returns an array containing claude-code and mock", () => {
    const runtimes = getAvailableRuntimes();
    expect(runtimes).toContain("claude-code");
    expect(runtimes).toContain("mock");
  });

  it("returns exactly two runtimes", () => {
    expect(getAvailableRuntimes()).toHaveLength(2);
  });
});
