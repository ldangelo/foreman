/**
 * Tests for Doctor.checkAgentMailLiveness()
 *
 * Verifies:
 * - Returns pass when AgentMail service is reachable (healthCheck → true)
 * - Returns fail when AgentMail service is unreachable (healthCheck → false)
 * - Fail message includes startup instructions matching foreman run output
 * - Fail message includes the configured URL / port
 * - AGENT_MAIL_URL env var is reflected in pass/fail messages
 * - checkSystem() includes the Agent Mail check (already wired in)
 */

import { describe, it, expect, vi, afterEach } from "vitest";
import { mkdtempSync, rmSync, realpathSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";

// ── Hoisted mocks ──────────────────────────────────────────────────────────

const { mockHealthCheck } = vi.hoisted(() => {
  const mockHealthCheck = vi.fn().mockResolvedValue(false);
  return { mockHealthCheck };
});

vi.mock("../../orchestrator/agent-mail-client.js", async (importOriginal) => {
  const actual = await importOriginal<typeof import("../../orchestrator/agent-mail-client.js")>();
  return {
    ...actual,
    AgentMailClient: class MockAgentMailClient {
      healthCheck = mockHealthCheck;
    },
  };
});

// Also mock fs/promises so binary checks don't hit the real filesystem
vi.mock("node:fs/promises", async (importOriginal) => {
  const actual = await importOriginal<typeof import("node:fs/promises")>();
  return {
    ...actual,
    access: vi.fn().mockResolvedValue(undefined),
    stat: vi.fn().mockResolvedValue({}),
    rm: vi.fn().mockResolvedValue(undefined),
  };
});

// ── Helpers ────────────────────────────────────────────────────────────────

const tempDirs: string[] = [];

function makeTempDir(): string {
  const dir = realpathSync(mkdtempSync(join(tmpdir(), "foreman-doctor-agentmail-")));
  tempDirs.push(dir);
  return dir;
}

afterEach(() => {
  vi.clearAllMocks();
  vi.unstubAllEnvs();
  for (const dir of tempDirs) {
    rmSync(dir, { recursive: true, force: true });
  }
  tempDirs.length = 0;
});

// ── checkAgentMailLiveness() — pass ───────────────────────────────────────

describe("Doctor.checkAgentMailLiveness() — service reachable", () => {
  it("returns pass status when healthCheck returns true", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(true);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    expect(result.status).toBe("pass");
    store.close();
  });

  it("pass result name mentions 'Agent Mail'", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(true);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    expect(result.name).toMatch(/Agent Mail/i);
    store.close();
  });

  it("pass message contains the reachable URL", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(true);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    // Should contain some URL-like content
    expect(result.message).toMatch(/http/i);
    store.close();
  });

  it("pass message includes the AGENT_MAIL_URL env var when set", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(true);
    vi.stubEnv("AGENT_MAIL_URL", "http://localhost:9999");

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    expect(result.status).toBe("pass");
    expect(result.message).toContain("9999");
    store.close();
  });
});

// ── checkAgentMailLiveness() — fail ───────────────────────────────────────

describe("Doctor.checkAgentMailLiveness() — service unreachable", () => {
  it("returns fail status when healthCheck returns false", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(false);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    expect(result.status).toBe("fail");
    store.close();
  });

  it("fail result name mentions 'Agent Mail'", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(false);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    expect(result.name).toMatch(/Agent Mail/i);
    store.close();
  });

  it("fail message mentions mcp_agent_mail serve startup command", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(false);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    // details should include startup instructions mirroring what foreman run shows
    const fullText = `${result.message} ${result.details ?? ""}`;
    expect(fullText).toContain("mcp_agent_mail");
    store.close();
  });

  it("fail message includes the port from the default URL", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");
    const { DEFAULT_AGENT_MAIL_CONFIG } = await import("../../orchestrator/agent-mail-client.js");

    mockHealthCheck.mockResolvedValueOnce(false);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    const expectedPort = DEFAULT_AGENT_MAIL_CONFIG.baseUrl.split(":").pop() ?? "8766";
    const fullText = `${result.message} ${result.details ?? ""}`;
    expect(fullText).toContain(expectedPort);
    store.close();
  });

  it("fail message mentions AGENT_MAIL_URL env var as a configuration option", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(false);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    const fullText = `${result.message} ${result.details ?? ""}`;
    expect(fullText).toContain("AGENT_MAIL_URL");
    store.close();
  });

  it("fail message mentions agent-mail.json config file", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(false);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    const fullText = `${result.message} ${result.details ?? ""}`;
    expect(fullText).toContain("agent-mail.json");
    store.close();
  });

  it("fail message includes the configured AGENT_MAIL_URL when env var is set", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(false);
    vi.stubEnv("AGENT_MAIL_URL", "http://localhost:7788");

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    expect(result.status).toBe("fail");
    const fullText = `${result.message} ${result.details ?? ""}`;
    expect(fullText).toContain("7788");
    store.close();
  });

  it("fail message tells user that foreman run will exit until resolved", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(false);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const result = await doctor.checkAgentMailLiveness();

    // Message should explain the impact — foreman run won't work
    expect(result.message).toMatch(/foreman run/);
    store.close();
  });
});

// ── checkSystem() integration ──────────────────────────────────────────────

describe("Doctor.checkSystem() — Agent Mail included", () => {
  it("checkSystem() includes the Agent Mail liveness result", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(true);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const results = await doctor.checkSystem();
    const names = results.map((r) => r.name);

    expect(names.some((n) => /agent mail/i.test(n))).toBe(true);
    store.close();
  });

  it("checkSystem() propagates fail status when Agent Mail is unreachable", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(false);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const results = await doctor.checkSystem();
    const agentMailResult = results.find((r) => /agent mail/i.test(r.name));

    expect(agentMailResult).toBeDefined();
    expect(agentMailResult!.status).toBe("fail");
    store.close();
  });

  it("checkSystem() propagates pass status when Agent Mail is reachable", async () => {
    const { Doctor } = await import("../../orchestrator/doctor.js");
    const { ForemanStore } = await import("../../lib/store.js");

    mockHealthCheck.mockResolvedValueOnce(true);

    const tmp = makeTempDir();
    const store = new ForemanStore(join(tmp, "test.db"));
    const doctor = new Doctor(store, tmp);

    const results = await doctor.checkSystem();
    const agentMailResult = results.find((r) => /agent mail/i.test(r.name));

    expect(agentMailResult).toBeDefined();
    expect(agentMailResult!.status).toBe("pass");
    store.close();
  });
});
