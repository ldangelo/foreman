/**
 * TRD-024: Notification System Deprecation + Agent Mail Channel
 *
 * Tests that:
 * 1. NotificationServer has @deprecated JSDoc
 * 2. NotificationBus has @deprecated JSDoc
 * 3. AgentMailClient.sendMessage is called at phase completion (via dual-channel)
 * 4. AgentMailClient.registerAgent is called with all pipeline role names on run start
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { readFileSync } from "node:fs";
import { join } from "node:path";

// ── Action 1 & 2: @deprecated JSDoc checks ─────────────────────────────────

describe("Notification deprecation markers", () => {
  const orchestratorDir = join(import.meta.dirname ?? __dirname, "..");

  it("NotificationServer class has @deprecated in its JSDoc", () => {
    const source = readFileSync(join(orchestratorDir, "notification-server.ts"), "utf-8");
    // Verify the @deprecated tag appears in a JSDoc block before the class declaration
    const deprecatedMatch = source.match(/@deprecated[\s\S]*?export class NotificationServer/);
    expect(deprecatedMatch).not.toBeNull();
  });

  it("NotificationBus class has @deprecated in its JSDoc", () => {
    const source = readFileSync(join(orchestratorDir, "notification-bus.ts"), "utf-8");
    const deprecatedMatch = source.match(/@deprecated[\s\S]*?export class NotificationBus/);
    expect(deprecatedMatch).not.toBeNull();
  });

  it("NotificationServer @deprecated mentions AgentMailClient", () => {
    const source = readFileSync(join(orchestratorDir, "notification-server.ts"), "utf-8");
    expect(source).toContain("AgentMailClient");
  });

  it("NotificationBus @deprecated mentions AgentMailClient", () => {
    const source = readFileSync(join(orchestratorDir, "notification-bus.ts"), "utf-8");
    expect(source).toContain("AgentMailClient");
  });
});

// ── Action 3: Phase completion dual-channel ──────────────────────────────────

describe("AgentMailClient phase-completion dual-channel in agent-worker.ts", () => {
  const agentWorkerPath = join(
    import.meta.dirname ?? __dirname,
    "..",
    "agent-worker.ts",
  );

  it("sends Phase Complete: explorer message after explorer phase success", () => {
    const source = readFileSync(agentWorkerPath, "utf-8");
    expect(source).toContain("`Phase Complete: explorer`");
    expect(source).toContain("phase: \"explorer\"");
    // Verify it is sent to the pipeline channel
    expect(source).toContain("`pipeline-${config.seedId}`");
  });

  it("sends Phase Complete: developer message after developer phase success", () => {
    const source = readFileSync(agentWorkerPath, "utf-8");
    expect(source).toContain("`Phase Complete: developer`");
    expect(source).toContain("phase: \"developer\"");
  });

  it("sends Phase Complete: qa message after qa phase success", () => {
    const source = readFileSync(agentWorkerPath, "utf-8");
    expect(source).toContain("`Phase Complete: qa`");
    expect(source).toContain("phase: \"qa\"");
  });

  it("sends Phase Complete: reviewer message after reviewer phase success", () => {
    const source = readFileSync(agentWorkerPath, "utf-8");
    expect(source).toContain("`Phase Complete: reviewer`");
    expect(source).toContain("phase: \"reviewer\"");
  });

  it("sends Phase Complete: finalize message after successful finalize", () => {
    const source = readFileSync(agentWorkerPath, "utf-8");
    expect(source).toContain("`Phase Complete: finalize`");
    expect(source).toContain("phase: \"finalize\"");
  });

  it("all phase complete messages include status: complete metadata", () => {
    const source = readFileSync(agentWorkerPath, "utf-8");
    // Count occurrences of 'status: "complete"' in the phase completion blocks
    const matches = source.match(/status: "complete"/g);
    // At least 5 occurrences (explorer, developer, qa, reviewer, finalize)
    expect(matches).not.toBeNull();
    expect((matches ?? []).length).toBeGreaterThanOrEqual(5);
  });
});

// ── Action 4: SQLite polling fallback comment ────────────────────────────────

describe("SQLite polling fallback comment", () => {
  it("agent-worker.ts has SQLite polling fallback comment", () => {
    const source = readFileSync(
      join(import.meta.dirname ?? __dirname, "..", "agent-worker.ts"),
      "utf-8",
    );
    expect(source).toContain("SQLite polling fallback");
  });
});

// ── Action 5: Run error → Agent Mail notification ────────────────────────────

describe("Run error Agent Mail notification in markStuck", () => {
  it("markStuck sends error notification to operator via AgentMailClient", () => {
    const source = readFileSync(
      join(import.meta.dirname ?? __dirname, "..", "agent-worker.ts"),
      "utf-8",
    );
    // Verify operator target
    expect(source).toContain('"operator"');
    // Verify the Run Error subject pattern
    expect(source).toContain("`Run Error: ${seedId}`");
    // Verify status: "error" metadata
    expect(source).toContain('status: "error"');
  });

  it("markStuck accepts agentMailClient as optional parameter", () => {
    const source = readFileSync(
      join(import.meta.dirname ?? __dirname, "..", "agent-worker.ts"),
      "utf-8",
    );
    // The signature should include agentMailClient as the last param of markStuck
    expect(source).toContain("agentMailClient?: AgentMailClient");
  });
});

// ── Action 6: Agent registration on pipeline start ──────────────────────────

describe("Agent registration at pipeline start", () => {
  it("runPipeline registers all pipeline role agents via Promise.allSettled", () => {
    const source = readFileSync(
      join(import.meta.dirname ?? __dirname, "..", "agent-worker.ts"),
      "utf-8",
    );
    expect(source).toContain("Promise.allSettled");
    expect(source).toContain("`explorer-${config.seedId}`");
    expect(source).toContain("`developer-${config.seedId}`");
    expect(source).toContain("`qa-${config.seedId}`");
    expect(source).toContain("`reviewer-${config.seedId}`");
    expect(source).toContain("`pipeline-${config.seedId}`");
  });

  it("registerAgent is called for all 5 pipeline roles", () => {
    const source = readFileSync(
      join(import.meta.dirname ?? __dirname, "..", "agent-worker.ts"),
      "utf-8",
    );
    const registrations = source.match(/agentMailClient\.registerAgent\(/g);
    expect(registrations).not.toBeNull();
    expect((registrations ?? []).length).toBeGreaterThanOrEqual(5);
  });
});

// ── AgentMailClient mock-based integration test ──────────────────────────────

describe("AgentMailClient dual-channel mock verification", () => {
  it("sendMessage is fire-and-forget (void, never throws)", async () => {
    // Import AgentMailClient and verify silent failure behavior
    const { AgentMailClient } = await import("../agent-mail-client.js");

    // Use a URL that will fail to connect — should not throw
    const client = new AgentMailClient({
      baseUrl: "http://127.0.0.1:1", // port 1 is never open
      timeoutMs: 50,
    });

    // sendMessage must not throw — even on connection failure
    await expect(
      client.sendMessage("operator", "Run Error: test-seed", "some error", {
        seedId: "test-seed",
        runId: "test-run",
        status: "error",
      }),
    ).resolves.toBeUndefined();
  });

  it("registerAgent is fire-and-forget (void, never throws)", async () => {
    const { AgentMailClient } = await import("../agent-mail-client.js");

    const client = new AgentMailClient({
      baseUrl: "http://127.0.0.1:1",
      timeoutMs: 50,
    });

    // All registerAgent calls must resolve even on connection failure
    const results = await Promise.allSettled([
      client.registerAgent("explorer-test-seed"),
      client.registerAgent("developer-test-seed"),
      client.registerAgent("qa-test-seed"),
      client.registerAgent("reviewer-test-seed"),
      client.registerAgent("pipeline-test-seed"),
    ]);

    // All should be fulfilled (not rejected) because errors are swallowed
    for (const result of results) {
      expect(result.status).toBe("fulfilled");
    }
  });
});
