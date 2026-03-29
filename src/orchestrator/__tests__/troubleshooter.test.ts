/**
 * Tests for the troubleshooter agent infrastructure.
 *
 * Validates:
 *   - troubleshooter role config exists in ROLE_CONFIGS
 *   - troubleshooter tools (get_run_status, close_bead) are correctly structured
 *   - troubleshooter.md prompt exists and contains required sections
 *   - default.yaml onFailure block is valid and parseable
 *   - WorkflowConfig.onFailure field is supported by validateWorkflowConfig
 *   - getTroubleshooterBudget() returns a positive value
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import {
  mkdtempSync,
  rmSync,
  readFileSync,
  existsSync,
} from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ROLE_CONFIGS, buildRoleConfigs } from "../roles.js";
import { createGetRunStatusTool, createCloseBeadTool, createSendMailTool } from "../pi-sdk-tools.js";
import { validateWorkflowConfig, loadWorkflowConfig } from "../../lib/workflow-loader.js";
import { getTroubleshooterBudget } from "../../lib/config.js";
import type { ForemanStore } from "../../lib/store.js";
import type { SqliteMailClient } from "../../lib/sqlite-mail-client.js";

// ── Constants ─────────────────────────────────────────────────────────────────

const PROJECT_ROOT = join(import.meta.dirname, "..", "..", "..");
const TROUBLESHOOTER_PROMPT = join(PROJECT_ROOT, "src", "defaults", "prompts", "default", "troubleshooter.md");
const DEFAULT_WORKFLOW = join(PROJECT_ROOT, "src", "defaults", "workflows", "default.yaml");

// ── Fixtures ─────────────────────────────────────────────────────────────────

function makeStore(runData?: {
  id: string;
  seed_id: string;
  status: string;
  started_at?: string;
  completed_at?: string;
}): ForemanStore {
  return {
    getRun: vi.fn().mockReturnValue(runData
      ? {
          id: runData.id,
          project_id: "proj-1",
          seed_id: runData.seed_id,
          agent_type: "pipeline",
          session_key: null,
          worktree_path: "/tmp/test",
          status: runData.status,
          started_at: runData.started_at ?? "2025-01-01T00:00:00Z",
          completed_at: runData.completed_at ?? null,
          created_at: "2025-01-01T00:00:00Z",
          progress: null,
        }
      : null),
    getRunProgress: vi.fn().mockReturnValue({
      currentPhase: "finalize",
      costUsd: 1.23,
      turns: 45,
      toolCalls: 120,
      lastActivity: "2025-01-01T12:00:00Z",
    }),
  } as unknown as ForemanStore;
}

function makeMailClient(): SqliteMailClient {
  return {
    sendMessage: vi.fn().mockResolvedValue(undefined),
    fetchInbox: vi.fn().mockResolvedValue([]),
  } as unknown as SqliteMailClient;
}

// ── ROLE_CONFIGS: troubleshooter ─────────────────────────────────────────────

describe("ROLE_CONFIGS: troubleshooter", () => {
  it("has a troubleshooter config", () => {
    expect(ROLE_CONFIGS.troubleshooter).toBeDefined();
  });

  it("troubleshooter uses sonnet model by default", () => {
    expect(ROLE_CONFIGS.troubleshooter.model).toBe("anthropic/claude-sonnet-4-6");
  });

  it("troubleshooter produces TROUBLESHOOT_REPORT.md", () => {
    expect(ROLE_CONFIGS.troubleshooter.reportFile).toBe("TROUBLESHOOT_REPORT.md");
  });

  it("troubleshooter has limited budget (≤ $2.00)", () => {
    expect(ROLE_CONFIGS.troubleshooter.maxBudgetUsd).toBeGreaterThan(0);
    expect(ROLE_CONFIGS.troubleshooter.maxBudgetUsd).toBeLessThanOrEqual(2.00);
  });

  it("troubleshooter maxTurns is controlled via workflow YAML (not role config)", () => {
    // maxTurns is intentionally NOT in role configs — it's set via default.yaml onFailure.maxTurns
    // Role configs follow the existing pattern (no maxTurns, per roles.test.ts invariant)
    expect(ROLE_CONFIGS.troubleshooter).not.toHaveProperty("maxTurns");
  });

  it("troubleshooter allows Bash for git/test operations", () => {
    expect(ROLE_CONFIGS.troubleshooter.allowedTools).toContain("Bash");
  });

  it("troubleshooter allows Edit for applying fixes", () => {
    expect(ROLE_CONFIGS.troubleshooter.allowedTools).toContain("Edit");
  });

  it("troubleshooter allows Read for artifact inspection", () => {
    expect(ROLE_CONFIGS.troubleshooter.allowedTools).toContain("Read");
  });

  it("troubleshooter has acceptEdits permissionMode", () => {
    expect(ROLE_CONFIGS.troubleshooter.permissionMode).toBe("acceptEdits");
  });

  it("buildRoleConfigs() returns troubleshooter config", () => {
    const configs = buildRoleConfigs();
    expect(configs.troubleshooter).toBeDefined();
    expect(configs.troubleshooter.role).toBe("troubleshooter");
  });
});

// ── getTroubleshooterBudget ───────────────────────────────────────────────────

describe("getTroubleshooterBudget", () => {
  it("returns a positive number by default", () => {
    expect(getTroubleshooterBudget()).toBeGreaterThan(0);
  });

  it("defaults to $1.50", () => {
    const OLD = process.env.FOREMAN_TROUBLESHOOTER_BUDGET_USD;
    delete process.env.FOREMAN_TROUBLESHOOTER_BUDGET_USD;
    try {
      expect(getTroubleshooterBudget()).toBe(1.50);
    } finally {
      if (OLD !== undefined) process.env.FOREMAN_TROUBLESHOOTER_BUDGET_USD = OLD;
    }
  });
});

// ── createGetRunStatusTool ────────────────────────────────────────────────────

describe("createGetRunStatusTool", () => {
  it("creates a tool with name get_run_status", () => {
    const tool = createGetRunStatusTool(makeStore());
    expect(tool.name).toBe("get_run_status");
  });

  it("has a description mentioning why a run failed", () => {
    const tool = createGetRunStatusTool(makeStore());
    expect(tool.description).toContain("failed");
  });

  it("returns run info when run exists", async () => {
    const store = makeStore({
      id: "run-123",
      seed_id: "bd-abc",
      status: "stuck",
    });
    const tool = createGetRunStatusTool(store);
    const result = await tool.execute("call-1", { runId: "run-123" }, undefined, undefined, {} as never);
    const text = (result.content[0] as { type: string; text: string }).text;
    const info = JSON.parse(text) as Record<string, unknown>;
    expect(info.runId).toBe("run-123");
    expect(info.seedId).toBe("bd-abc");
    expect(info.status).toBe("stuck");
    expect(info.currentPhase).toBe("finalize");
    expect(info.costUsd).toBe(1.23);
  });

  it("returns not-found message when run does not exist", async () => {
    const store = makeStore(undefined);
    const tool = createGetRunStatusTool(store);
    const result = await tool.execute("call-1", { runId: "run-missing" }, undefined, undefined, {} as never);
    const text = (result.content[0] as { type: string; text: string }).text;
    expect(text).toContain("not found");
  });

  it("returns error text when store throws", async () => {
    const brokenStore = {
      getRun: vi.fn().mockImplementation(() => { throw new Error("db error"); }),
      getRunProgress: vi.fn().mockReturnValue(null),
    } as unknown as ForemanStore;
    const tool = createGetRunStatusTool(brokenStore);
    const result = await tool.execute("call-1", { runId: "run-1" }, undefined, undefined, {} as never);
    const text = (result.content[0] as { type: string; text: string }).text;
    expect(text).toContain("Failed to get run status");
    expect(text).toContain("db error");
  });

  it("has promptGuidelines mentioning get_run_status", () => {
    const tool = createGetRunStatusTool(makeStore());
    const guidelines = tool.promptGuidelines ?? [];
    expect(guidelines.join("\n")).toContain("get_run_status");
  });
});

// ── createCloseBeadTool ───────────────────────────────────────────────────────

describe("createCloseBeadTool", () => {
  let tmpDir: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "foreman-troubleshooter-test-"));
  });

  afterEach(() => {
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("creates a tool with name close_bead", () => {
    const tool = createCloseBeadTool(tmpDir);
    expect(tool.name).toBe("close_bead");
  });

  it("has a description mentioning complete", () => {
    const tool = createCloseBeadTool(tmpDir);
    expect(tool.description.toLowerCase()).toContain("complete");
  });

  it("has promptGuidelines cautioning only-close-if-complete", () => {
    const tool = createCloseBeadTool(tmpDir);
    const guidelines = tool.promptGuidelines ?? [];
    expect(guidelines.join("\n")).toContain("Only close");
  });

  it("returns error text when br command fails", async () => {
    // br binary won't exist in test env — should return a failure message
    const tool = createCloseBeadTool("/nonexistent/path");
    const result = await tool.execute("call-1", { seedId: "bd-test", reason: "work done" }, undefined, undefined, {} as never);
    const text = (result.content[0] as { type: string; text: string }).text;
    expect(text).toContain("Failed to close bead");
  });
});

// ── troubleshooter.md prompt ──────────────────────────────────────────────────

describe("troubleshooter.md prompt", () => {
  it("exists at src/defaults/prompts/default/troubleshooter.md", () => {
    expect(existsSync(TROUBLESHOOTER_PROMPT)).toBe(true);
  });

  it("contains template variables for seedId and runId", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    expect(content).toContain("{{seedId}}");
    expect(content).toContain("{{runId}}");
  });

  it("contains failure mode routing instructions", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    // Must cover key failure modes
    expect(content).toContain("test-failed");
    expect(content).toContain("rebase_conflict");
    expect(content).toContain("push_failed");
    expect(content).toContain("nothing_to_commit");
  });

  it("contains TROUBLESHOOT_REPORT.md artifact instruction", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    expect(content).toContain("TROUBLESHOOT_REPORT.md");
  });

  it("contains send_mail tool reference for lifecycle mail", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    expect(content).toContain("send_mail");
  });

  it("contains get_run_status tool reference", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    expect(content).toContain("get_run_status");
  });

  it("contains close_bead tool reference", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    expect(content).toContain("close_bead");
  });

  it("references escalation path for unresolvable failures", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    expect(content.toLowerCase()).toContain("escalat");
  });

  it("references RESOLVED keyword for outcome detection", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    expect(content).toContain("RESOLVED");
  });

  it("contains maxRetries template variable for budget limit", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    expect(content).toContain("{{maxRetries}}");
  });

  it("references failureContext template variable", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    expect(content).toContain("{{failureContext}}");
  });

  it("documents no-force-push guardrail", () => {
    const content = readFileSync(TROUBLESHOOTER_PROMPT, "utf-8");
    expect(content.toLowerCase()).toContain("force");
    expect(content.toLowerCase()).toContain("guardrail");
  });
});

// ── default.yaml onFailure block ──────────────────────────────────────────────

describe("default.yaml: onFailure block", () => {
  it("default.yaml contains an onFailure section", () => {
    const content = readFileSync(DEFAULT_WORKFLOW, "utf-8");
    expect(content).toContain("onFailure");
  });

  it("default.yaml onFailure references troubleshooter.md", () => {
    const content = readFileSync(DEFAULT_WORKFLOW, "utf-8");
    expect(content).toContain("troubleshooter.md");
  });

  it("default.yaml onFailure has a maxTurns limit", () => {
    const content = readFileSync(DEFAULT_WORKFLOW, "utf-8");
    // Should have maxTurns: 20 (or similar) in the onFailure block
    expect(content).toMatch(/maxTurns:\s*\d+/);
  });

  it("validateWorkflowConfig parses onFailure block", () => {
    const raw = {
      name: "test",
      phases: [{ name: "finalize", builtin: true }],
      onFailure: {
        name: "troubleshooter",
        prompt: "troubleshooter.md",
        models: { default: "sonnet" },
        maxTurns: 20,
        artifact: "TROUBLESHOOT_REPORT.md",
      },
    };
    const config = validateWorkflowConfig(raw, "test");
    expect(config.onFailure).toBeDefined();
    expect(config.onFailure!.name).toBe("troubleshooter");
    expect(config.onFailure!.prompt).toBe("troubleshooter.md");
    expect(config.onFailure!.maxTurns).toBe(20);
    expect(config.onFailure!.artifact).toBe("TROUBLESHOOT_REPORT.md");
  });

  it("validateWorkflowConfig accepts workflow without onFailure (optional)", () => {
    const raw = {
      name: "test",
      phases: [{ name: "finalize", builtin: true }],
    };
    const config = validateWorkflowConfig(raw, "test");
    expect(config.onFailure).toBeUndefined();
  });

  it("validateWorkflowConfig throws when onFailure.name is missing", async () => {
    const raw = {
      name: "test",
      phases: [{ name: "finalize", builtin: true }],
      onFailure: {
        prompt: "troubleshooter.md",
        maxTurns: 20,
      },
    };
    const { WorkflowConfigError } = await import("../../lib/workflow-loader.js");
    expect(() => validateWorkflowConfig(raw, "test")).toThrow(WorkflowConfigError);
  });

  it("loadWorkflowConfig loads default.yaml with onFailure block", () => {
    const config = loadWorkflowConfig("default", PROJECT_ROOT);
    expect(config.onFailure).toBeDefined();
    expect(config.onFailure!.name).toBe("troubleshooter");
  });
});

// ── agent-worker.ts: troubleshooter integration ───────────────────────────────

describe("agent-worker.ts: troubleshooter integration", () => {
  const WORKER_SRC = join(PROJECT_ROOT, "src", "orchestrator", "agent-worker.ts");

  it("imports createGetRunStatusTool and createCloseBeadTool", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain("createGetRunStatusTool");
    expect(source).toContain("createCloseBeadTool");
  });

  it("defines runTroubleshooterPhase function", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain("runTroubleshooterPhase");
  });

  it("dispatches troubleshooter from onPipelineComplete on failure", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    // Check that the troubleshooter is dispatched from within the failure branch
    expect(source).toContain("troubleshooterEnabled");
    expect(source).toContain("troubleshooterResolved");
  });

  it("checks workflowConfig.onFailure to enable troubleshooter", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain("workflowConfig.onFailure");
  });

  it("has PIPELINE RECOVERED log message for resolved failures", () => {
    const source = readFileSync(WORKER_SRC, "utf-8");
    expect(source).toContain("PIPELINE RECOVERED");
  });
});
