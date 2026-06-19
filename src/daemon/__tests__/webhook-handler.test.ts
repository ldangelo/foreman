/**
 * Unit tests for GitHub webhook handler.
 */

import { describe, it, expect, vi } from "vitest";
import {
  createWebhookHandler,
  generateWebhookSecret,
  verifyGitHubSignature,
} from "../webhook-handler.js";

function hmacSha256(secret: string, data: Buffer): string {
  const { createHmac } = require("node:crypto") as {
    createHmac: (algo: string, key: string) => { update: (data: Buffer) => { digest: (encoding: string) => string } };
  };
  return createHmac("sha256", secret).update(data).digest("hex");
}

function makeIssuePayload(labelNames: string[]) {
  return {
    action: "opened",
    issue: {
      id: 1,
      number: 142,
      title: "Issue title",
      body: "Issue body",
      state: "open",
      user: { login: "alice", id: 100 },
      labels: labelNames.map((name, idx) => ({ id: idx + 1, name, color: "ffffff" })),
      assignees: [],
      milestone: null,
      created_at: "2026-01-01T00:00:00Z",
      updated_at: "2026-01-01T00:00:00Z",
      closed_at: null,
      url: "https://api.github.com/repos/owner/repo/issues/142",
      html_url: "https://github.com/owner/repo/issues/142",
    },
    repository: {
      id: 1,
      full_name: "owner/repo",
      clone_url: "https://github.com/owner/repo.git",
    },
  };
}

function makeRequest(payload: unknown, secret: string) {
  const body = payload as Record<string, unknown>;
  const raw = Buffer.from(JSON.stringify(body));
  return {
    body,
    headers: {
      "x-hub-signature-256": `sha256=${hmacSha256(secret, raw)}`,
      "x-github-event": "issues",
    },
    log: {
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
    },
  } as const;
}

function makeReply() {
  return {
    code: vi.fn().mockReturnThis(),
    send: vi.fn().mockResolvedValue(undefined),
  };
}

function makeContext(repoConfig: { auto_import: boolean; default_labels: string[] }) {
  return {
    adapter: {
      getGithubRepo: vi.fn().mockResolvedValue({
        id: "repo-1",
        project_id: "proj-1",
        owner: "owner",
        repo: "repo",
        auth_type: "pat",
        auth_config: {},
        default_labels: repoConfig.default_labels,
        auto_import: repoConfig.auto_import,
        webhook_secret: null,
        webhook_enabled: true,
        sync_strategy: "github-wins",
        last_sync_at: null,
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
      }),
      upsertGithubRepo: vi.fn().mockImplementation(async (input) => ({
        id: "repo-1",
        project_id: input.projectId,
        owner: input.owner,
        repo: input.repo,
        auth_type: "pat",
        auth_config: {},
        default_labels: repoConfig.default_labels,
        auto_import: repoConfig.auto_import,
        webhook_secret: null,
        webhook_enabled: true,
        sync_strategy: "github-wins",
        last_sync_at: null,
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-01T00:00:00Z",
      })),
      listTasks: vi.fn().mockResolvedValue([]),
      createTask: vi.fn().mockResolvedValue({ id: "task-1" }),
      recordGithubSyncEvent: vi.fn().mockResolvedValue(undefined),
      updateTaskGitHubFields: vi.fn().mockResolvedValue(undefined),
    },
    registry: {
      list: vi.fn().mockResolvedValue([
        { id: "proj-1", name: "proj", path: "/tmp/proj", status: "active", githubUrl: "https://github.com/owner/repo" },
      ]),
    },
  } as const;
}

describe("verifyGitHubSignature", () => {
  it("returns true for valid signature", () => {
    const secret = "my-webhook-secret";
    const payload = Buffer.from(JSON.stringify({ action: "opened" }));
    const expected = `sha256=${hmacSha256(secret, payload)}`;
    expect(verifyGitHubSignature(payload, expected, secret)).toBe(true);
  });

  it("returns false for invalid signature", () => {
    const secret = "my-webhook-secret";
    const payload = Buffer.from(JSON.stringify({ action: "opened" }));
    expect(
      verifyGitHubSignature(
        payload,
        "sha256=0000000000000000000000000000000000000000000000000000000000000000",
        secret,
      ),
    ).toBe(false);
  });
});

describe("Webhook issue-opened import semantics", () => {
  it("skips task creation when auto_import is disabled", async () => {
    const secret = "test-secret";
    const ctx = makeContext({ auto_import: false, default_labels: [] });
    const handler = createWebhookHandler(ctx as never, { secret, foremanLabel: "foreman" });
    const request = makeRequest(makeIssuePayload(["foreman"]), secret);
    const reply = makeReply();

    await handler(request as never, reply as never);

    expect(ctx.adapter.createTask).not.toHaveBeenCalled();
    expect(ctx.adapter.recordGithubSyncEvent).not.toHaveBeenCalled();
    expect(reply.code).toHaveBeenCalledWith(200);
  });

  it("creates ready tasks for the configured foreman label", async () => {
    const secret = "test-secret";
    const ctx = makeContext({ auto_import: true, default_labels: ["github:docs"] });
    const handler = createWebhookHandler(ctx as never, { secret, foremanLabel: "foreman" });
    const request = makeRequest(makeIssuePayload(["foreman"]), secret);
    const reply = makeReply();

    await handler(request as never, reply as never);

    expect(ctx.adapter.createTask).toHaveBeenCalledWith(
      "proj-1",
      expect.objectContaining({
        status: "ready",
        externalId: "github:owner/repo#142",
        labels: expect.arrayContaining(["github:foreman", "github:docs"]),
      }),
    );
    expect(ctx.adapter.recordGithubSyncEvent).toHaveBeenCalledTimes(1);
    expect(reply.code).toHaveBeenCalledWith(200);
  });

  it("creates ready tasks for foreman:dispatch", async () => {
    const secret = "test-secret";
    const ctx = makeContext({ auto_import: true, default_labels: [] });
    const handler = createWebhookHandler(ctx as never, { secret, foremanLabel: "foreman" });
    const request = makeRequest(makeIssuePayload(["foreman:dispatch"]), secret);
    const reply = makeReply();

    await handler(request as never, reply as never);

    expect(ctx.adapter.createTask).toHaveBeenCalledWith(
      "proj-1",
      expect.objectContaining({ status: "ready" }),
    );
  });

  it("skips task creation when foreman:skip is present", async () => {
    const secret = "test-secret";
    const ctx = makeContext({ auto_import: true, default_labels: [] });
    const handler = createWebhookHandler(ctx as never, { secret, foremanLabel: "foreman" });
    const request = makeRequest(makeIssuePayload(["foreman", "foreman:skip"]), secret);
    const reply = makeReply();

    await handler(request as never, reply as never);

    expect(ctx.adapter.createTask).not.toHaveBeenCalled();
    expect(ctx.adapter.recordGithubSyncEvent).not.toHaveBeenCalled();
    expect(reply.code).toHaveBeenCalledWith(200);
  });
});

describe("Webhook secret generation", () => {
  it("generates 32 random bytes as hex string", () => {
    const secret = generateWebhookSecret();
    expect(secret).toHaveLength(64);
    expect(secret).toMatch(/^[a-f0-9]+$/);
  });
});
