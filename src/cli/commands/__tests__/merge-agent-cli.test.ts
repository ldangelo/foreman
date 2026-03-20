/**
 * TRD-032-TEST: Merge Agent CLI Tests
 *
 * Tests for the `foreman merge-agent` CLI commands:
 * 1. `merge-agent start` calls upsertMergeAgentConfig with enabled=1
 * 2. `merge-agent start --interval 60` sets interval_seconds=60
 * 3. `merge-agent stop` calls upsertMergeAgentConfig with enabled=0 and pid=null
 * 4. `merge-agent status` shows "not configured" when no config
 * 5. `merge-agent status` shows enabled/disabled state with pid
 * 6. createMergeAgentCommand factory creates a valid Command instance
 */

import { describe, it, expect, vi, beforeEach } from "vitest";
import { createMergeAgentCommand } from "../merge-agent.js";

// ── Helpers ────────────────────────────────────────────────────────────────────

function makeStore(configOverride: unknown = null) {
  const config = configOverride ?? {
    id: 1,
    project_id: "proj-1",
    interval_seconds: 30,
    enabled: 1,
    pid: 12345,
    created_at: new Date().toISOString(),
    updated_at: new Date().toISOString(),
  };

  return {
    upsertMergeAgentConfig: vi.fn().mockReturnValue(config),
    getMergeAgentConfig: vi.fn().mockReturnValue(config),
  };
}

async function runCommand(
  store: ReturnType<typeof makeStore>,
  projectId: string,
  args: string[],
): Promise<{ stdout: string; stderr: string }> {
  const stdoutLines: string[] = [];
  const stderrLines: string[] = [];

  const origLog = console.log;
  const origError = console.error;
  console.log = (...a: unknown[]) => stdoutLines.push(a.join(" "));
  console.error = (...a: unknown[]) => stderrLines.push(a.join(" "));

  try {
    const cmd = createMergeAgentCommand(store as never, projectId);
    await cmd.parseAsync(["node", "merge-agent", ...args]);
  } finally {
    console.log = origLog;
    console.error = origError;
  }

  return {
    stdout: stdoutLines.join("\n"),
    stderr: stderrLines.join("\n"),
  };
}

// ── Tests ──────────────────────────────────────────────────────────────────────

describe("foreman merge-agent start", () => {
  it("calls upsertMergeAgentConfig with enabled=1", async () => {
    const store = makeStore();
    await runCommand(store, "proj-1", ["start"]);

    expect(store.upsertMergeAgentConfig).toHaveBeenCalledWith(
      "proj-1",
      expect.objectContaining({ enabled: 1 }),
    );
  });

  it("uses default interval of 30 seconds", async () => {
    const store = makeStore();
    await runCommand(store, "proj-1", ["start"]);

    expect(store.upsertMergeAgentConfig).toHaveBeenCalledWith(
      "proj-1",
      expect.objectContaining({ interval_seconds: 30 }),
    );
  });

  it("respects --interval flag", async () => {
    const store = makeStore();
    await runCommand(store, "proj-1", ["start", "--interval", "60"]);

    expect(store.upsertMergeAgentConfig).toHaveBeenCalledWith(
      "proj-1",
      expect.objectContaining({ interval_seconds: 60 }),
    );
  });

  it("prints confirmation message", async () => {
    const store = makeStore();
    const { stdout } = await runCommand(store, "proj-1", ["start"]);
    expect(stdout).toContain("Merge agent configured");
  });
});

describe("foreman merge-agent stop", () => {
  it("calls upsertMergeAgentConfig with enabled=0 and pid=null", async () => {
    const store = makeStore();
    await runCommand(store, "proj-1", ["stop"]);

    expect(store.upsertMergeAgentConfig).toHaveBeenCalledWith(
      "proj-1",
      expect.objectContaining({ enabled: 0, pid: null }),
    );
  });

  it("prints disabled message", async () => {
    const store = makeStore();
    const { stdout } = await runCommand(store, "proj-1", ["stop"]);
    expect(stdout).toContain("disabled");
  });
});

describe("foreman merge-agent status", () => {
  it("shows 'not configured' when getMergeAgentConfig returns null", async () => {
    const store = makeStore(null);
    store.getMergeAgentConfig.mockReturnValue(null);
    const { stdout } = await runCommand(store, "proj-1", ["status"]);
    expect(stdout).toContain("not configured");
  });

  it("shows enabled status when config is enabled", async () => {
    const store = makeStore({
      id: 1,
      project_id: "proj-1",
      interval_seconds: 30,
      enabled: 1,
      pid: 99,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });
    const { stdout } = await runCommand(store, "proj-1", ["status"]);
    expect(stdout).toContain("enabled");
    expect(stdout).toContain("30");
  });

  it("shows disabled status when config.enabled is 0", async () => {
    const store = makeStore({
      id: 1,
      project_id: "proj-1",
      interval_seconds: 45,
      enabled: 0,
      pid: null,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });
    const { stdout } = await runCommand(store, "proj-1", ["status"]);
    expect(stdout).toContain("disabled");
  });

  it("shows pid when running", async () => {
    const store = makeStore({
      id: 1,
      project_id: "proj-1",
      interval_seconds: 30,
      enabled: 1,
      pid: 55555,
      created_at: new Date().toISOString(),
      updated_at: new Date().toISOString(),
    });
    const { stdout } = await runCommand(store, "proj-1", ["status"]);
    expect(stdout).toContain("55555");
  });
});

describe("createMergeAgentCommand factory", () => {
  it("creates a Command with name 'merge-agent'", () => {
    const store = makeStore();
    const cmd = createMergeAgentCommand(store as never, "proj-1");
    expect(cmd.name()).toBe("merge-agent");
  });

  it("has start, stop, and status subcommands", () => {
    const store = makeStore();
    const cmd = createMergeAgentCommand(store as never, "proj-1");
    const subNames = cmd.commands.map((c) => c.name());
    expect(subNames).toContain("start");
    expect(subNames).toContain("stop");
    expect(subNames).toContain("status");
  });
});
