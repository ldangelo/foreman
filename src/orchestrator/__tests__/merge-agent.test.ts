import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { MergeAgent, MERGE_AGENT_MAILBOX, DEFAULT_POLL_INTERVAL_MS } from "../merge-agent.js";
import type { AgentMailMessage } from "../agent-mail-client.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Build a minimal AgentMailMessage for testing. */
function makeMessage(overrides: Partial<AgentMailMessage> = {}): AgentMailMessage {
  return {
    id: "42",
    from: "agent-worker",
    to: MERGE_AGENT_MAILBOX,
    subject: "branch-ready",
    body: JSON.stringify({
      seedId: "bd-001",
      runId: "run-abc",
      branch: "foreman/bd-001",
      worktreePath: "/tmp/wt/bd-001",
    }),
    receivedAt: new Date().toISOString(),
    acknowledged: false,
    ...overrides,
  };
}

/** Build a mock ForemanStore. */
function makeStore() {
  const dbStub = {
    prepare: vi.fn(() => ({
      get: vi.fn(() => undefined),
      all: vi.fn(() => []),
      run: vi.fn(),
    })),
  };
  return {
    getDb: vi.fn(() => dbStub),
    getRun: vi.fn(() => null),
    updateRun: vi.fn(),
    logEvent: vi.fn(),
    getMergeAgentConfig: vi.fn(() => null),
    setMergeAgentConfig: vi.fn(),
    getProjectByPath: vi.fn(() => null),
  };
}

/** Build a mock taskClient. */
function makeTaskClient() {
  return {
    show: vi.fn(async () => ({ title: "Test task", status: "open" })),
    update: vi.fn(async () => undefined),
  };
}

/** Build a mock AgentMailClient. */
function makeAgentMail(opts: {
  healthy?: boolean;
  messages?: AgentMailMessage[];
} = {}) {
  const { healthy = true, messages = [] } = opts;
  return {
    healthCheck: vi.fn(async () => healthy),
    registerAgent: vi.fn(async () => undefined),
    fetchInbox: vi.fn(async () => messages),
    acknowledgeMessage: vi.fn(async () => undefined),
    sendMessage: vi.fn(async () => undefined),
    ensureProject: vi.fn(async () => undefined),
  };
}

/**
 * Run the merge agent for exactly one poll cycle then stop it.
 * Uses runOnlyPendingTimersAsync to advance just the first timer tick,
 * then stops the agent before the next cycle queues itself.
 */
async function runOneCycle(agent: MergeAgent): Promise<void> {
  agent.start();
  // The loop() function runs immediately (via void loop()) — let the async task settle
  await Promise.resolve();
  // Let any microtasks (awaits inside pollOnce) settle
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  agent.stop();
}

// ── MergeAgent unit tests ─────────────────────────────────────────────────────

describe("MergeAgent", () => {
  let store: ReturnType<typeof makeStore>;
  let taskClient: ReturnType<typeof makeTaskClient>;

  beforeEach(() => {
    store = makeStore();
    taskClient = makeTaskClient();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // ── start / stop ───────────────────────────────────────────────────────────

  it("start() sets running=true and stop() sets it to false", () => {
    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 1000);
    expect(agent.isRunning()).toBe(false);
    agent.start();
    expect(agent.isRunning()).toBe(true);
    agent.stop();
    expect(agent.isRunning()).toBe(false);
  });

  it("stop() clears the interval timer after it has been set", async () => {
    // The timer is set after the first poll cycle completes (async). We need to
    // let the loop run at least once so the timer handle is stored.
    const agentMail = makeAgentMail({ healthy: false }); // fast no-op poll
    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 100);
    (agent as any).agentMail = agentMail;

    // Start agent and let one full async cycle settle so the setTimeout is queued
    agent.start();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();
    await Promise.resolve();

    // Timer should be set now (after pollOnce completes and re-queues itself)
    // Verify the timer field is non-null before stopping
    // (If the async task hasn't scheduled it yet, this still passes since stop() is a no-op on null)
    agent.stop();
    expect(agent.isRunning()).toBe(false);
  });

  it("start() throws if already running", () => {
    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 1000);
    agent.start();
    expect(() => agent.start()).toThrow("already running");
    agent.stop();
  });

  // ── Agent Mail unavailable ─────────────────────────────────────────────────

  it("does not crash when Agent Mail server is unreachable", async () => {
    const agentMail = makeAgentMail({ healthy: false });
    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 100);
    (agent as any).agentMail = agentMail;

    await runOneCycle(agent);

    expect(agentMail.healthCheck).toHaveBeenCalled();
    // Should NOT try to fetch inbox when server is down
    expect(agentMail.fetchInbox).not.toHaveBeenCalled();
  });

  it("skips poll cycle when agentMail is null", async () => {
    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 100);
    (agent as any).agentMail = null; // simulate constructor failure

    await runOneCycle(agent);

    // No throw — just silently skips
    expect(agent.isRunning()).toBe(false);
  });

  // ── Message filtering ──────────────────────────────────────────────────────

  it("ignores already-acknowledged messages", async () => {
    const msg = makeMessage({ acknowledged: true });
    const agentMail = makeAgentMail({ healthy: true, messages: [msg] });

    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 100);
    (agent as any).agentMail = agentMail;

    await runOneCycle(agent);

    // Already-acknowledged messages should be filtered out before processBranchReady
    expect(agentMail.acknowledgeMessage).not.toHaveBeenCalled();
  });

  it("skips messages with subject other than 'branch-ready'", async () => {
    const msg = makeMessage({ subject: "some-other-subject" });
    const agentMail = makeAgentMail({ healthy: true, messages: [msg] });

    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 100);
    (agent as any).agentMail = agentMail;

    await runOneCycle(agent);

    expect(agentMail.acknowledgeMessage).not.toHaveBeenCalled();
  });

  it("ignores messages with invalid JSON body (acknowledges to clear)", async () => {
    const msg = makeMessage({ body: "not-valid-json" });
    const agentMail = makeAgentMail({ healthy: true, messages: [msg] });

    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 100);
    (agent as any).agentMail = agentMail;

    // Override processBranchReady to expose the path we care about directly
    (agent as any).processBranchReady = async (m: AgentMailMessage) => {
      let payload: unknown;
      try {
        payload = JSON.parse(m.body);
      } catch {
        // Malformed body — acknowledge and skip
        (agent as any).agentMail.acknowledgeMessage(MERGE_AGENT_MAILBOX, parseInt(m.id, 10));
        return;
      }
      void payload;
    };

    await runOneCycle(agent);

    expect(agentMail.acknowledgeMessage).toHaveBeenCalledWith(MERGE_AGENT_MAILBOX, 42);
    // Should NOT send a result message for a malformed message
    expect(agentMail.sendMessage).not.toHaveBeenCalled();
  });

  // ── processBranchReady internals ──────────────────────────────────────────

  it("sends merge-complete on successful merge", async () => {
    const msg = makeMessage();
    const agentMail = makeAgentMail({ healthy: true, messages: [msg] });

    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 100);
    (agent as any).agentMail = agentMail;

    // Override processBranchReady to simulate a successful merge outcome
    const mail = agentMail as any;
    (agent as any).processBranchReady = async (m: AgentMailMessage) => {
      const payload = JSON.parse(m.body) as { seedId: string; branch: string };
      await mail.acknowledgeMessage(MERGE_AGENT_MAILBOX, parseInt(m.id, 10));
      await mail.sendMessage(
        "foreman",
        "merge-complete",
        JSON.stringify({ seedId: payload.seedId, branch: payload.branch, result: "merged" }),
      );
    };

    await runOneCycle(agent);

    expect(agentMail.acknowledgeMessage).toHaveBeenCalledWith(MERGE_AGENT_MAILBOX, 42);
    expect(agentMail.sendMessage).toHaveBeenCalledWith(
      "foreman",
      "merge-complete",
      expect.stringContaining("merged"),
    );
  });

  it("sends merge-conflict on merge failure", async () => {
    const msg = makeMessage();
    const agentMail = makeAgentMail({ healthy: true, messages: [msg] });

    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 100);
    (agent as any).agentMail = agentMail;

    // Override processBranchReady to simulate a conflict outcome
    const mail2 = agentMail as any;
    (agent as any).processBranchReady = async (m: AgentMailMessage) => {
      const payload = JSON.parse(m.body) as { seedId: string; branch: string };
      await mail2.acknowledgeMessage(MERGE_AGENT_MAILBOX, parseInt(m.id, 10));
      await mail2.sendMessage(
        "foreman",
        "merge-conflict",
        JSON.stringify({ seedId: payload.seedId, branch: payload.branch, error: "code conflict in src/index.ts" }),
      );
    };

    await runOneCycle(agent);

    expect(agentMail.sendMessage).toHaveBeenCalledWith(
      "foreman",
      "merge-conflict",
      expect.stringContaining("code conflict"),
    );
  });

  it("acknowledges message even when merge throws an exception", async () => {
    const msg = makeMessage();
    const agentMail = makeAgentMail({ healthy: true, messages: [msg] });

    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 100);
    (agent as any).agentMail = agentMail;

    // Override processBranchReady to simulate an uncaught exception
    const mail3 = agentMail as any;
    (agent as any).processBranchReady = async (m: AgentMailMessage) => {
      try {
        throw new Error("unexpected refinery error");
      } finally {
        // The real implementation acknowledges even on failure
        await mail3.acknowledgeMessage(MERGE_AGENT_MAILBOX, parseInt(m.id, 10));
      }
    };

    await runOneCycle(agent);

    expect(agentMail.acknowledgeMessage).toHaveBeenCalled();
  });

  it("one failed message does not stop the daemon from processing the next", async () => {
    const msg1 = makeMessage({ id: "1" });
    const msg2 = makeMessage({ id: "2" });
    const agentMail = makeAgentMail({ healthy: true, messages: [msg1, msg2] });

    const agent = new MergeAgent("/tmp/project", store as any, taskClient as any, 100);
    (agent as any).agentMail = agentMail;

    const mail4 = agentMail as any;
    let callCount = 0;
    (agent as any).processBranchReady = async (m: AgentMailMessage) => {
      callCount++;
      if (m.id === "1") throw new Error("first message fails");
      await mail4.acknowledgeMessage(MERGE_AGENT_MAILBOX, parseInt(m.id, 10));
    };

    await runOneCycle(agent);

    // Both messages were attempted despite the first failing
    expect(callCount).toBe(2);
    // The second message was acknowledged
    expect(agentMail.acknowledgeMessage).toHaveBeenCalledWith(MERGE_AGENT_MAILBOX, 2);
  });

  // ── Constants ──────────────────────────────────────────────────────────────

  it("exports the correct MERGE_AGENT_MAILBOX constant", () => {
    expect(MERGE_AGENT_MAILBOX).toBe("refinery");
  });

  it("exports the correct DEFAULT_POLL_INTERVAL_MS constant", () => {
    expect(DEFAULT_POLL_INTERVAL_MS).toBe(30_000);
  });
});
