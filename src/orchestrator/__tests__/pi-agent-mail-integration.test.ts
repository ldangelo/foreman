/**
 * Integration tests for PiRpcSpawnStrategy → Agent Mail message flow.
 *
 * These tests spawn a fake "pi" script that emits Pi-style JSONL to stdout,
 * then verify that a `phase-complete` or `agent-error` message arrives in the
 * foreman's Agent Mail inbox.
 *
 * The tests use a live Agent Mail server at http://localhost:8766.
 * They are skipped automatically when the server is not reachable,
 * so they are safe to run in CI (will just be skipped).
 *
 * To run against a live server:
 *   npx vitest run src/orchestrator/__tests__/pi-agent-mail-integration.test.ts
 */

import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { mkdtemp, writeFile, chmod, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { PiRpcSpawnStrategy } from "../pi-rpc-spawn-strategy.js";
import { AgentMailClient } from "../agent-mail-client.js";
import type { WorkerConfig } from "../dispatcher.js";

const AGENT_MAIL_URL = "http://localhost:8766";
const PROJECT_PATH = process.cwd();
const POLL_INTERVAL_MS = 500;
const POLL_MAX_RETRIES = 20; // 10 seconds total

// Check reachability once at suite level
let serverReachable = false;
let tempDir: string | null = null;

beforeAll(async () => {
  try {
    const res = await fetch(`${AGENT_MAIL_URL}/health`, {
      signal: AbortSignal.timeout(2000),
    });
    serverReachable = res.ok;
  } catch {
    serverReachable = false;
  }

  // Create a temp dir for the fake pi scripts
  tempDir = await mkdtemp(join(tmpdir(), "foreman-pi-test-"));
});

afterAll(async () => {
  // Clean up FOREMAN_PI_BIN override
  delete process.env.FOREMAN_PI_BIN;

  if (tempDir) {
    try {
      await rm(tempDir, { recursive: true, force: true });
    } catch {
      // Non-fatal cleanup failure
    }
  }
});

function skipIfOffline(): boolean {
  if (!serverReachable) {
    return true;
  }
  return false;
}

/**
 * Write a fake `pi` Node.js script to a temp dir and make it executable.
 * Returns the path to the directory containing the script.
 *
 * The script accepts `--mode rpc` args, reads stdin to EOF (without blocking),
 * emits Pi-style JSONL events to stdout, and exits with the given exit code.
 *
 * @param scriptDir - Directory to write the script into
 * @param agentEndSuccess - Whether agent_end should have success=true
 */
async function writeFakePiScript(
  scriptDir: string,
  agentEndSuccess: boolean,
): Promise<void> {
  const scriptPath = join(scriptDir, "pi");

  const agentEndLine = JSON.stringify({
    type: "agent_end",
    success: agentEndSuccess,
    message: agentEndSuccess ? "completed successfully" : "simulated failure",
  });

  const scriptContent = `#!/usr/bin/env node
// Fake "pi" binary for integration testing.
// Reads stdin until EOF, emits Pi-style JSONL to stdout, then exits.

process.stdin.resume();
process.stdin.on("data", () => { /* ignore */ });
process.stdin.on("end", () => {
  // Emit Pi lifecycle events
  const lines = [
    JSON.stringify({ type: "agent_start" }),
    JSON.stringify({ type: "turn_start", turn: 1 }),
    JSON.stringify({ type: "turn_end", turn: 1, usage: { input_tokens: 100, output_tokens: 50 } }),
    ${JSON.stringify(agentEndLine)},
  ];
  for (const line of lines) {
    process.stdout.write(line + "\\n");
  }
  process.exit(${agentEndSuccess ? 0 : 1});
});
`;

  await writeFile(scriptPath, scriptContent, "utf-8");
  await chmod(scriptPath, 0o755);
}

/**
 * Build a minimal WorkerConfig for testing.
 * Uses the provided seedId so we can uniquely identify messages in the inbox.
 */
function buildTestConfig(seedId: string): WorkerConfig {
  return {
    runId: `run-${seedId}`,
    projectId: "integration-test-project",
    seedId,
    seedTitle: "Integration test task",
    seedDescription: "Fake task for pi-agent-mail integration test",
    model: "claude-sonnet-4-6",
    worktreePath: PROJECT_PATH,
    projectPath: PROJECT_PATH,
    prompt: "Do nothing — this is a test.",
    env: {
      // Pass through PATH and HOME so the fake pi script's #!/usr/bin/env node works
      PATH: process.env.PATH ?? "/usr/bin:/bin",
      HOME: process.env.HOME ?? "/tmp",
      // Ensure agent mail points at the test server
      FOREMAN_AGENT_MAIL_URL: AGENT_MAIL_URL,
      // Phase must be set so PiRpcSpawnStrategy picks the right config
      FOREMAN_PHASE: "developer",
    },
  };
}

/**
 * Poll the foreman's Agent Mail inbox until a message with the given
 * subject and a body containing seedId arrives, or until the timeout.
 *
 * Returns the matching message, or null if not found within the timeout.
 */
async function pollForMessage(
  client: AgentMailClient,
  subject: string,
  seedId: string,
): Promise<{ subject: string; body: string } | null> {
  for (let attempt = 0; attempt < POLL_MAX_RETRIES; attempt++) {
    const messages = await client.fetchInbox("foreman", { limit: 50 });
    const match = messages.find(
      (m) => m.subject === subject && m.body.includes(seedId),
    );
    if (match) {
      return { subject: match.subject, body: match.body };
    }
    // Wait before next poll
    await new Promise<void>((resolve) => setTimeout(resolve, POLL_INTERVAL_MS));
  }
  return null;
}

describe("PiRpcSpawnStrategy → Agent Mail integration", () => {
  it("emits phase-complete when fake pi reports agent_end success=true", async () => {
    if (skipIfOffline()) return;

    const seedId = `integration-test-${Date.now()}`;

    // Write a fake pi script that succeeds
    await writeFakePiScript(tempDir!, true);

    // Set up Agent Mail client to observe the foreman inbox
    const client = new AgentMailClient({ baseUrl: AGENT_MAIL_URL });
    await client.ensureProject(PROJECT_PATH);

    // Verify foreman is registered (ensureProject registers it)
    expect(client.resolveAgentName("foreman")).not.toBeNull();

    // Point FOREMAN_PI_BIN at our fake script so resolvePiBinary() uses it
    process.env.FOREMAN_PI_BIN = join(tempDir!, "pi");

    // Spawn — returns immediately, background task runs asynchronously
    const config = buildTestConfig(seedId);
    const strategy = new PiRpcSpawnStrategy();
    await strategy.spawn(config);

    // Poll foreman inbox for the phase-complete message
    const message = await pollForMessage(client, "phase-complete", seedId);

    expect(message).not.toBeNull();
    expect(message?.subject).toBe("phase-complete");

    // Body should contain the seedId and status=complete
    const body = JSON.parse(message!.body) as Record<string, unknown>;
    expect(body["seedId"]).toBe(seedId);
    expect(body["status"]).toBe("complete");
    expect(body["phase"]).toBe("developer");
  }, 30_000); // 30s timeout for this test

  it("emits agent-error when fake pi reports agent_end success=false", async () => {
    if (skipIfOffline()) return;

    const seedId = `integration-test-err-${Date.now()}`;

    // Write a fake pi script that fails
    await writeFakePiScript(tempDir!, false);

    // Set up Agent Mail client to observe the foreman inbox
    const client = new AgentMailClient({ baseUrl: AGENT_MAIL_URL });
    await client.ensureProject(PROJECT_PATH);

    expect(client.resolveAgentName("foreman")).not.toBeNull();

    process.env.FOREMAN_PI_BIN = join(tempDir!, "pi");

    const config = buildTestConfig(seedId);
    const strategy = new PiRpcSpawnStrategy();
    await strategy.spawn(config);

    // Poll foreman inbox for the agent-error message
    const message = await pollForMessage(client, "agent-error", seedId);

    expect(message).not.toBeNull();
    expect(message?.subject).toBe("agent-error");

    const body = JSON.parse(message!.body) as Record<string, unknown>;
    expect(body["seedId"]).toBe(seedId);
    expect(body["status"]).toBe("error");
    expect(body["phase"]).toBe("developer");
  }, 30_000);
});
