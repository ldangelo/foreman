import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  ForemanInboxProcessor,
  FOREMAN_MAILBOX,
  DEFAULT_INBOX_POLL_INTERVAL_MS,
} from "../foreman-inbox-processor.js";
import { MERGE_AGENT_MAILBOX } from "../merge-agent.js";
import type { AgentMailMessage } from "../agent-mail-client.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

/** Build a minimal phase-complete AgentMailMessage for testing. */
function makePhaseCompleteMessage(overrides: Partial<AgentMailMessage> & {
  bodyOverrides?: Record<string, unknown>;
} = {}): AgentMailMessage {
  const { bodyOverrides, ...msgOverrides } = overrides;
  const defaultBody = {
    seedId: "bd-001",
    phase: "developer",
    runId: "run-abc",
    status: "complete",
    ...bodyOverrides,
  };
  return {
    id: "42",
    from: "pi-developer-bd-001",
    to: FOREMAN_MAILBOX,
    subject: "phase-complete",
    body: JSON.stringify(defaultBody),
    receivedAt: new Date().toISOString(),
    acknowledged: false,
    ...msgOverrides,
  };
}

/** Build a mock ForemanStore. */
function makeStore(runOverride?: {
  id: string;
  seed_id: string;
  worktree_path: string | null;
  status?: string;
}) {
  const defaultRun = runOverride ?? {
    id: "run-abc",
    seed_id: "bd-001",
    worktree_path: "/tmp/worktrees/bd-001",
    status: "completed",
  };
  // Ensure status defaults to "completed" so the run-status guard passes
  const run = { status: "completed", ...defaultRun };
  return {
    getRun: vi.fn((runId: string) => {
      if (runId === run.id) return run;
      return null;
    }),
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
    fetchInbox: vi.fn(async () => messages),
    acknowledgeMessage: vi.fn(async () => undefined),
    sendMessage: vi.fn(async () => undefined),
  };
}

/**
 * Run the processor for exactly one poll cycle then stop it.
 * Mirrors the pattern used in merge-agent.test.ts.
 */
async function runOneCycle(processor: ForemanInboxProcessor): Promise<void> {
  processor.start();
  // The loop() function runs immediately (via void loop()) — let the async tasks settle
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
  processor.stop();
}

// ── ForemanInboxProcessor unit tests ─────────────────────────────────────────

describe("ForemanInboxProcessor", () => {
  let agentMail: ReturnType<typeof makeAgentMail>;
  let store: ReturnType<typeof makeStore>;
  const projectPath = "/tmp/test-project";

  beforeEach(() => {
    agentMail = makeAgentMail();
    store = makeStore();
  });

  afterEach(() => {
    vi.restoreAllMocks();
  });

  // ── Lifecycle ────────────────────────────────────────────────────────────

  it("reports isRunning() correctly", () => {
    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
    );
    expect(processor.isRunning()).toBe(false);
    processor.start();
    expect(processor.isRunning()).toBe(true);
    processor.stop();
    expect(processor.isRunning()).toBe(false);
  });

  it("throws if start() is called when already running", () => {
    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
    );
    processor.start();
    expect(() => processor.start()).toThrow("already running");
    processor.stop();
  });

  it("exports DEFAULT_INBOX_POLL_INTERVAL_MS as 30000", () => {
    expect(DEFAULT_INBOX_POLL_INTERVAL_MS).toBe(30_000);
  });

  // ── phase-complete with status=complete ──────────────────────────────────

  it("translates phase-complete (status=complete) into branch-ready and acknowledges", async () => {
    const msg = makePhaseCompleteMessage();
    agentMail = makeAgentMail({ messages: [msg] });
    store = makeStore({
      id: "run-abc",
      seed_id: "bd-001",
      worktree_path: "/tmp/worktrees/bd-001",
      status: "completed",
    });

    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
    );
    await runOneCycle(processor);

    // Should send branch-ready to the refinery mailbox
    expect(agentMail.sendMessage).toHaveBeenCalledOnce();
    const call0 = agentMail.sendMessage.mock.calls[0] as unknown as [
      string,
      string,
      string,
    ];
    const [to, subject, body] = call0;
    expect(to).toBe(MERGE_AGENT_MAILBOX);
    expect(subject).toBe("branch-ready");
    const parsed = JSON.parse(body) as {
      seedId: string;
      runId: string;
      branch: string;
      worktreePath?: string;
    };
    expect(parsed.seedId).toBe("bd-001");
    expect(parsed.runId).toBe("run-abc");
    expect(parsed.branch).toBe("foreman/bd-001");
    expect(parsed.worktreePath).toBe("/tmp/worktrees/bd-001");

    // Should acknowledge the original message
    expect(agentMail.acknowledgeMessage).toHaveBeenCalledOnce();
    expect(agentMail.acknowledgeMessage).toHaveBeenCalledWith(
      FOREMAN_MAILBOX,
      42,
    );
  });

  it("derives branch name as foreman/<seedId>", async () => {
    const msg = makePhaseCompleteMessage({
      bodyOverrides: { seedId: "bd-999", runId: "run-xyz" },
    });
    agentMail = makeAgentMail({ messages: [msg] });
    store = makeStore({ id: "run-xyz", seed_id: "bd-999", worktree_path: null, status: "completed" });

    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
    );
    await runOneCycle(processor);

    const call0b = agentMail.sendMessage.mock.calls[0] as unknown as [
      string,
      string,
      string,
    ];
    const [, , body] = call0b;
    const parsed = JSON.parse(body) as { branch: string };
    expect(parsed.branch).toBe("foreman/bd-999");
  });

  // ── phase-complete with status=error ────────────────────────────────────

  it("acknowledges without sending branch-ready when status=error", async () => {
    const msg = makePhaseCompleteMessage({
      bodyOverrides: { status: "error" },
    });
    agentMail = makeAgentMail({ messages: [msg] });

    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
    );
    await runOneCycle(processor);

    expect(agentMail.sendMessage).not.toHaveBeenCalled();
    expect(agentMail.acknowledgeMessage).toHaveBeenCalledOnce();
    expect(agentMail.acknowledgeMessage).toHaveBeenCalledWith(
      FOREMAN_MAILBOX,
      42,
    );
  });

  // ── Already-acknowledged messages ────────────────────────────────────────

  it("skips already-acknowledged messages", async () => {
    const msg = makePhaseCompleteMessage({ acknowledged: true });
    agentMail = makeAgentMail({ messages: [msg] });

    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
    );
    await runOneCycle(processor);

    expect(agentMail.sendMessage).not.toHaveBeenCalled();
    expect(agentMail.acknowledgeMessage).not.toHaveBeenCalled();
  });

  // ── Run not found ────────────────────────────────────────────────────────

  it("acknowledges without sending branch-ready when run is not found", async () => {
    const msg = makePhaseCompleteMessage({
      bodyOverrides: { runId: "run-does-not-exist" },
    });
    agentMail = makeAgentMail({ messages: [msg] });
    // Store returns null for all runIds by default when id doesn't match
    store = makeStore({ id: "some-other-run", seed_id: "bd-001", worktree_path: null });

    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
    );
    await runOneCycle(processor);

    expect(agentMail.sendMessage).not.toHaveBeenCalled();
    expect(agentMail.acknowledgeMessage).toHaveBeenCalledOnce();
    expect(agentMail.acknowledgeMessage).toHaveBeenCalledWith(
      FOREMAN_MAILBOX,
      42,
    );
  });

  // ── Agent Mail unavailable ───────────────────────────────────────────────

  it("skips poll cycle when Agent Mail is not healthy", async () => {
    const msg = makePhaseCompleteMessage();
    agentMail = makeAgentMail({ healthy: false, messages: [msg] });

    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
    );
    await runOneCycle(processor);

    expect(agentMail.fetchInbox).not.toHaveBeenCalled();
    expect(agentMail.sendMessage).not.toHaveBeenCalled();
    expect(agentMail.acknowledgeMessage).not.toHaveBeenCalled();
  });

  // ── Malformed message body ───────────────────────────────────────────────

  it("acknowledges without crashing on malformed JSON body", async () => {
    const msg = makePhaseCompleteMessage({ body: "not-valid-json" });
    agentMail = makeAgentMail({ messages: [msg] });

    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
    );
    await runOneCycle(processor);

    expect(agentMail.sendMessage).not.toHaveBeenCalled();
    expect(agentMail.acknowledgeMessage).toHaveBeenCalledOnce();
  });

  // ── Non-phase-complete messages are ignored ──────────────────────────────

  it("ignores messages with a subject other than phase-complete", async () => {
    const msg = makePhaseCompleteMessage({ subject: "agent-error" });
    agentMail = makeAgentMail({ messages: [msg] });

    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
    );
    await runOneCycle(processor);

    expect(agentMail.sendMessage).not.toHaveBeenCalled();
    expect(agentMail.acknowledgeMessage).not.toHaveBeenCalled();
  });

  // ── start() with custom interval ────────────────────────────────────────

  it("accepts a custom interval via start(intervalMs)", () => {
    const processor = new ForemanInboxProcessor(
      agentMail as never,
      store as never,
      projectPath,
      60_000,
    );
    // start with override
    processor.start(5_000);
    expect(processor.isRunning()).toBe(true);
    processor.stop();
  });
});
