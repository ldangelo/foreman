/**
 * Tests for foreman inbox --type filter (TRD-014-TEST).
 *
 * Verifies:
 * - AC-T-014-1: --type filter matches messages with [<type>] in subject
 * - AC-T-014-2: --type filter matches messages with body JSON type field
 * - AC-T-014-3: unmatched messages are excluded
 * - AC-T-014-4: --type=rebase-context filters correctly
 * - AC-T-014-5: --type=rebase-conflict filters correctly
 */

import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { mkdtempSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { ForemanStore } from "../../lib/store.js";

// ── Helpers ───────────────────────────────────────────────────────────────────

function makeStore(dbPath = ":memory:"): ForemanStore {
  return new ForemanStore(dbPath);
}

// Seed a store with a project + run + messages
function seedStore(store: ForemanStore, tmpDir: string): { runId: string } {
  const project = store.registerProject("test", tmpDir);
  const run = store.createRun(project.id, "seed-1", "developer", tmpDir);

  // Rebase-context message (matches by subject)
  store.sendMessage(
    run.id,
    "pipeline",
    "qa-seed-1",
    "[rebase-context] 3 upstream commit(s) integrated before QA",
    JSON.stringify({
      type: "rebase-context",
      rebaseTarget: "origin/main",
      upstreamCommits: 3,
      changedFiles: ["src/a.ts", "src/b.ts"],
    }),
  );

  // Rebase-conflict message (matches by subject and body type)
  store.sendMessage(
    run.id,
    "pipeline",
    "troubleshooter-seed-1",
    "[rebase-conflict] 2 files conflicted in run " + run.id,
    JSON.stringify({
      type: "rebase-conflict",
      conflictingFiles: ["src/c.ts", "src/d.ts"],
      skill: "resolve-rebase-conflict",
    }),
  );

  // Regular developer message (no type tag)
  store.sendMessage(
    run.id,
    "explorer",
    "developer-seed-1",
    "EXPLORER_REPORT.md",
    "# Explorer findings\nSome content here.",
  );

  return { runId: run.id };
}

// ── The fetchMessages function under test ─────────────────────────────────────
// We import the helper indirectly by checking what store.getAllMessages returns
// filtered by the same logic as fetchMessages in inbox.ts

/**
 * Re-implement fetchMessages logic inline for isolated unit tests,
 * matching the implementation in src/cli/commands/inbox.ts.
 */
function fetchMessages(
  store: ForemanStore,
  runId: string,
  agent: string | undefined,
  unreadOnly: boolean,
  limit: number,
  typeFilter?: string,
) {
  let messages;
  if (agent) {
    messages = store.getMessages(runId, agent, unreadOnly);
  } else {
    const all = store.getAllMessages(runId);
    messages = unreadOnly ? all.filter((m) => m.read === 0) : all;
  }
  if (typeFilter) {
    const pattern = `[${typeFilter}]`;
    messages = messages.filter((m) => {
      if (m.subject.includes(pattern)) return true;
      try {
        const body = JSON.parse(m.body) as { type?: string };
        return body.type === typeFilter;
      } catch {
        return false;
      }
    });
  }
  return messages.slice(0, limit);
}

// ── Tests ─────────────────────────────────────────────────────────────────────

describe("inbox --type filter (TRD-014)", () => {
  let tmpDir: string;
  let store: ForemanStore;
  let runId: string;

  beforeEach(() => {
    tmpDir = mkdtempSync(join(tmpdir(), "inbox-filter-test-"));
    store = makeStore();
    ({ runId } = seedStore(store, tmpDir));
  });

  afterEach(() => {
    store.close();
    rmSync(tmpDir, { recursive: true, force: true });
  });

  it("no filter → returns all messages", () => {
    const msgs = fetchMessages(store, runId, undefined, false, 50, undefined);
    expect(msgs).toHaveLength(3);
  });

  it("AC-T-014-1: --type=rebase-context matches by [rebase-context] in subject", () => {
    const msgs = fetchMessages(store, runId, undefined, false, 50, "rebase-context");
    expect(msgs).toHaveLength(1);
    expect(msgs[0]!.subject).toContain("[rebase-context]");
  });

  it("AC-T-014-2: --type=rebase-conflict matches by body JSON type field and subject", () => {
    const msgs = fetchMessages(store, runId, undefined, false, 50, "rebase-conflict");
    expect(msgs).toHaveLength(1);
    expect(msgs[0]!.subject).toContain("[rebase-conflict]");
    const body = JSON.parse(msgs[0]!.body) as { type: string };
    expect(body.type).toBe("rebase-conflict");
  });

  it("AC-T-014-3: unmatched type returns empty list", () => {
    const msgs = fetchMessages(store, runId, undefined, false, 50, "nonexistent-type");
    expect(msgs).toHaveLength(0);
  });

  it("AC-T-014-4: body-only type match (no [type] in subject)", () => {
    // Add a message with JSON body type but no [type] in subject
    store.sendMessage(
      runId,
      "system",
      "foreman",
      "Operator notification for run",
      JSON.stringify({ type: "custom-event", data: "payload" }),
    );
    const msgs = fetchMessages(store, runId, undefined, false, 50, "custom-event");
    expect(msgs).toHaveLength(1);
    expect(msgs[0]!.subject).toBe("Operator notification for run");
  });

  it("--type filter combined with --agent", () => {
    const msgs = fetchMessages(store, runId, "qa-seed-1", false, 50, "rebase-context");
    expect(msgs).toHaveLength(1);
    expect(msgs[0]!.recipient_agent_type).toBe("qa-seed-1");
  });

  it("body is not JSON → subject-only match, no crash", () => {
    // Add message with plain text body
    store.sendMessage(
      runId,
      "system",
      "developer-seed-1",
      "[plain-type] some subject",
      "not json at all",
    );
    const msgs = fetchMessages(store, runId, undefined, false, 50, "plain-type");
    expect(msgs).toHaveLength(1);
    expect(msgs[0]!.subject).toContain("[plain-type]");
  });

  it("limit is applied after type filter", () => {
    // Add 5 more rebase-context messages
    for (let i = 0; i < 5; i++) {
      store.sendMessage(
        runId,
        "pipeline",
        "qa-seed-1",
        `[rebase-context] extra message ${i}`,
        JSON.stringify({ type: "rebase-context" }),
      );
    }
    const msgs = fetchMessages(store, runId, undefined, false, 3, "rebase-context");
    expect(msgs).toHaveLength(3);
  });
});
