/**
 * Tests for the resolve-rebase-conflict skill (TRD-020-TEST).
 *
 * Verifies:
 * - AC-T-020-1: resolve-rebase-conflict.md prompt file exists
 * - AC-T-020-2: signal_rebase_resolved tool sends rebase-resolved mail to foreman
 * - AC-T-020-3: signal_rebase_resolved tool returns confirmation text
 * - AC-T-020-4: createSignalRebaseResolvedTool exports correctly from pi-sdk-tools.ts
 * - AC-T-020-5: prompt file contains required template placeholders
 */

import { describe, it, expect, vi } from "vitest";
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { createSignalRebaseResolvedTool } from "../pi-sdk-tools.js";
import type { ForemanStore } from "../../lib/store.js";
import type { SqliteMailClient } from "../../lib/sqlite-mail-client.js";

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const PROMPT_PATH = join(
  PROJECT_ROOT,
  "src/defaults/prompts/default/resolve-rebase-conflict.md",
);

function makeStore(): ForemanStore {
  return {} as unknown as ForemanStore;
}

function makeMailClient(overrides = {}): SqliteMailClient {
  return {
    sendMessage: vi.fn().mockResolvedValue(undefined),
    ...overrides,
  } as unknown as SqliteMailClient;
}

describe("resolve-rebase-conflict skill", () => {
  it("AC-T-020-1: prompt file exists at expected path", () => {
    expect(existsSync(PROMPT_PATH)).toBe(true);
  });

  it("AC-T-020-5: prompt contains required template placeholders", () => {
    const content = readFileSync(PROMPT_PATH, "utf-8");
    expect(content).toContain("{{runId}}");
    expect(content).toContain("{{rebaseTarget}}");
    expect(content).toContain("{{conflictingFiles}}");
    expect(content).toContain("{{upstreamDiff}}");
    expect(content).toContain("signal_rebase_resolved");
  });

  it("AC-T-020-4: createSignalRebaseResolvedTool returns a ToolDefinition", () => {
    const tool = createSignalRebaseResolvedTool(makeStore(), makeMailClient());
    expect(tool.name).toBe("signal_rebase_resolved");
    expect(tool.description).toBeTruthy();
    expect(typeof tool.execute).toBe("function");
  });

  it("AC-T-020-2: signal_rebase_resolved sends rebase-resolved mail to foreman", async () => {
    const mailClient = makeMailClient();
    const tool = createSignalRebaseResolvedTool(makeStore(), mailClient);

    const result = await tool.execute("call-1", {
      runId: "run-abc",
      resumePhase: "developer",
    }, undefined, undefined, {} as never);

    expect(mailClient.sendMessage).toHaveBeenCalledOnce();
    const [to, subject, body] = (mailClient.sendMessage as ReturnType<typeof vi.fn>).mock.calls[0] as [string, string, string];
    expect(to).toBe("foreman");
    expect(subject).toContain("[rebase-resolved]");
    expect(subject).toContain("run-abc");

    const parsed = JSON.parse(body) as { type: string; runId: string; resumePhase: string };
    expect(parsed.type).toBe("rebase-resolved");
    expect(parsed.runId).toBe("run-abc");
    expect(parsed.resumePhase).toBe("developer");

    void result;
  });

  it("AC-T-020-3: signal_rebase_resolved returns confirmation text", async () => {
    const tool = createSignalRebaseResolvedTool(makeStore(), makeMailClient());
    const result = await tool.execute("call-2", {
      runId: "run-xyz",
      resumePhase: "developer",
    }, undefined, undefined, {} as never);

    expect(result.content[0]).toBeDefined();
    const textContent = result.content[0] as { type: string; text: string };
    expect(textContent.text).toContain("run-xyz");
    expect(textContent.text.toLowerCase()).toContain("resume");
  });

  it("execute returns error text on mail failure (no throw)", async () => {
    const mailClient = makeMailClient({
      sendMessage: vi.fn().mockRejectedValue(new Error("DB locked")),
    });
    const tool = createSignalRebaseResolvedTool(makeStore(), mailClient);
    const result = await tool.execute("call-3", {
      runId: "run-fail",
      resumePhase: "developer",
    }, undefined, undefined, {} as never);

    const textContent = result.content[0] as { type: string; text: string };
    expect(textContent.text).toContain("Failed");
    expect(textContent.text).toContain("DB locked");
  });
});
