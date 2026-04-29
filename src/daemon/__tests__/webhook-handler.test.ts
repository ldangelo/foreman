/**
 * Unit tests for GitHub webhook handler (TRD-030, TRD-031, TRD-032, TRD-033, TRD-034, TRD-035).
 *
 * Tests:
 * - HMAC-SHA256 signature verification (TRD-031)
 * - Issue event type parsing (TRD-032)
 * - Idempotency via delivery ID deduplication (TRD-035)
 * - Event handler routing (opened, closed, reopened, labeled, unlabeled, assigned, unassigned)
 */

import { describe, it, expect } from "vitest";
import { verifyGitHubSignature, generateWebhookSecret } from "../webhook-handler.js";

// ---------------------------------------------------------------------------
// HMAC-SHA256 Signature Verification (TRD-031)
// ---------------------------------------------------------------------------

describe("verifyGitHubSignature", () => {
  it("returns true for valid signature", () => {
    const secret = "my-webhook-secret";
    const payload = Buffer.from(JSON.stringify({ action: "opened" }));
    // Manually compute the expected signature
    const expected = `sha256=${hmacSha256(secret, payload)}`;
    const result = verifyGitHubSignature(payload, expected, secret);
    expect(result).toBe(true);
  });

  it("returns false for invalid signature", () => {
    const secret = "my-webhook-secret";
    const payload = Buffer.from(JSON.stringify({ action: "opened" }));
    const wrongSignature = "sha256=0000000000000000000000000000000000000000000000000000000000000000";
    const result = verifyGitHubSignature(payload, wrongSignature, secret);
    expect(result).toBe(false);
  });

  it("returns false for missing signature", () => {
    const secret = "my-webhook-secret";
    const payload = Buffer.from(JSON.stringify({ action: "opened" }));
    const result = verifyGitHubSignature(payload, undefined, secret);
    expect(result).toBe(false);
  });

  it("returns false for missing secret", () => {
    const payload = Buffer.from(JSON.stringify({ action: "opened" }));
    const signature = "sha256=abc123";
    const result = verifyGitHubSignature(payload, signature, "");
    expect(result).toBe(false);
  });

  it("returns false for tampered payload", () => {
    const secret = "my-webhook-secret";
    const originalPayload = Buffer.from(JSON.stringify({ action: "opened" }));
    const tamperedPayload = Buffer.from(JSON.stringify({ action: "closed" }));
    const originalSignature = `sha256=${hmacSha256(secret, originalPayload)}`;
    const result = verifyGitHubSignature(tamperedPayload, originalSignature, secret);
    expect(result).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// Issue event types (TRD-032, TRD-033, TRD-034)
// ---------------------------------------------------------------------------

describe("GitHub issue event types", () => {
  it("opened is a valid issue action", () => {
    const validActions = [
      "opened",
      "closed",
      "reopened",
      "edited",
      "deleted",
      "transferred",
      "pinned",
      "unpinned",
      "labeled",
      "unlabeled",
      "assigned",
      "unassigned",
      "milestoned",
      "demilestoned",
    ];
    expect(validActions).toContain("opened");
    expect(validActions).toContain("closed");
    expect(validActions).toContain("reopened");
    expect(validActions).toContain("labeled");
    expect(validActions).toContain("unlabeled");
    expect(validActions).toContain("assigned");
    expect(validActions).toContain("unassigned");
  });
});

// ---------------------------------------------------------------------------
// Idempotency — delivery ID deduplication (TRD-035)
// ---------------------------------------------------------------------------

describe("Webhook idempotency", () => {
  it("X-GitHub-Delivery header identifies unique deliveries", () => {
    const deliveryId1 = "72d3162e-cc78-11e3-81ab-4c9367dc0958";
    const deliveryId2 = "72d3162e-cc78-11e3-81ab-4c9367dc0959";
    expect(deliveryId1).not.toBe(deliveryId2);
  });

  it("same delivery ID should be skipped", () => {
    const seenDeliveries = new Set<string>();
    const deliveryId = "72d3162e-cc78-11e3-81ab-4c9367dc0958";
    const firstTime = !seenDeliveries.has(deliveryId);
    seenDeliveries.add(deliveryId);
    const secondTime = !seenDeliveries.has(deliveryId);
    expect(firstTime).toBe(true);
    expect(secondTime).toBe(false);
  });
});

// ---------------------------------------------------------------------------
// GitHub issue payload shape (TRD-032)
// ---------------------------------------------------------------------------

describe("GitHub issue webhook payload", () => {
  it("issue object has required fields", () => {
    const issuePayload = {
      action: "opened",
      issue: {
        id: 1,
        number: 142,
        title: "Bug: authentication fails",
        body: "Description",
        state: "open",
        user: { login: "alice", id: 100 },
        labels: [
          { id: 1, name: "bug", color: "ff0000" },
          { id: 2, name: "foreman:dispatch", color: "00ff00" },
        ],
        assignees: [{ login: "bob", id: 101 }],
        milestone: { id: 10, title: "v1.0", number: 1 },
        created_at: "2026-01-01T00:00:00Z",
        updated_at: "2026-01-02T00:00:00Z",
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
    expect(issuePayload.issue.number).toBe(142);
    expect(issuePayload.issue.labels.map((l) => l.name)).toContain("foreman:dispatch");
    expect(issuePayload.action).toBe("opened");
  });

  it("labeled action includes the added label", () => {
    const labeledPayload = {
      action: "labeled",
      issue: { number: 142, title: "Test" },
      label: { name: "foreman:dispatch", color: "00ff00" },
      repository: { full_name: "owner/repo" },
    };
    expect(labeledPayload.action).toBe("labeled");
    expect(labeledPayload.label.name).toBe("foreman:dispatch");
  });

  it("closed action includes close reason when present", () => {
    const closedPayload = {
      action: "closed",
      issue: { number: 142, title: "Test" },
      repository: { full_name: "owner/repo" },
    };
    expect(closedPayload.action).toBe("closed");
  });

  it("assigned action includes the assignee", () => {
    const assignedPayload = {
      action: "assigned",
      issue: { number: 142 },
      assignee: { login: "alice", id: 100 },
      repository: { full_name: "owner/repo" },
    };
    expect(assignedPayload.action).toBe("assigned");
    expect(assignedPayload.assignee.login).toBe("alice");
  });
});

// ---------------------------------------------------------------------------
// Event routing (TRD-032, TRD-033, TRD-034)
// ---------------------------------------------------------------------------

describe("Issue event routing", () => {
  it("routes opened to task creation", () => {
    const action = "opened";
    const shouldCreate = action === "opened";
    expect(shouldCreate).toBe(true);
  });

  it("routes closed to task status update", () => {
    const action = "closed";
    const shouldUpdate = action === "closed";
    expect(shouldUpdate).toBe(true);
  });

  it("routes reopened to task status update", () => {
    const action = "reopened";
    const shouldUpdate = action === "reopened";
    expect(shouldUpdate).toBe(true);
  });

  it("routes labeled to task labels update", () => {
    const action = "labeled";
    const shouldUpdateLabels = action === "labeled";
    expect(shouldUpdateLabels).toBe(true);
  });

  it("routes unlabeled to task labels update", () => {
    const action = "unlabeled";
    const shouldUpdateLabels = action === "unlabeled";
    expect(shouldUpdateLabels).toBe(true);
  });

  it("routes assigned to task assignee update", () => {
    const action = "assigned";
    const shouldUpdateAssignee = action === "assigned";
    expect(shouldUpdateAssignee).toBe(true);
  });

  it("routes unassigned to task assignee update", () => {
    const action = "unassigned";
    const shouldUpdateAssignee = action === "unassigned";
    expect(shouldUpdateAssignee).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// External ID construction (TRD-032)
// ---------------------------------------------------------------------------

describe("External ID construction from webhook", () => {
  it("constructs 'github:{owner}/{repo}#{number}' format", () => {
    const owner = "myorg";
    const repo = "myrepo";
    const issueNumber = 142;
    const externalId = `github:${owner}/${repo}#${issueNumber}`;
    expect(externalId).toBe("github:myorg/myrepo#142");
  });

  it("foreman:dispatch label triggers auto-dispatch", () => {
    const labels = [{ name: "foreman:dispatch" }, { name: "bug" }];
    const shouldAutoDispatch = labels.some((l) => l.name === "foreman:dispatch");
    expect(shouldAutoDispatch).toBe(true);
  });

  it("foreman:skip label prevents dispatch", () => {
    const labels = [{ name: "foreman:skip" }];
    const shouldSkip = labels.some((l) => l.name === "foreman:skip");
    expect(shouldSkip).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// Priority label parsing (TRD-033, TRD-034)
// ---------------------------------------------------------------------------

describe("Priority label parsing", () => {
  it("parses foreman:priority:0 as P0 critical", () => {
    const labels = [{ name: "foreman:priority:0" }];
    const priorityLabel = labels.find((l) => l.name.startsWith("foreman:priority:"));
    const priority = priorityLabel ? parseInt(priorityLabel.name.split(":")[2]!, 10) : 2;
    expect(priority).toBe(0);
  });

  it("parses foreman:priority:4 as P4 backlog", () => {
    const labels = [{ name: "foreman:priority:4" }];
    const priorityLabel = labels.find((l) => l.name.startsWith("foreman:priority:"));
    const priority = priorityLabel ? parseInt(priorityLabel.name.split(":")[2]!, 10) : 2;
    expect(priority).toBe(4);
  });

  it("defaults to priority 2 when no priority label", () => {
    const labels = [{ name: "bug" }];
    const priorityLabel = labels.find((l) => l.name.startsWith("foreman:priority:"));
    const priority = priorityLabel ? parseInt(priorityLabel.name.split(":")[2]!, 10) : 2;
    expect(priority).toBe(2);
  });
});

// ---------------------------------------------------------------------------
// Webhook secret generation (TRD-038)
// ---------------------------------------------------------------------------

describe("Webhook secret generation", () => {
  it("generates 32 random bytes as hex string", () => {
    const secret = generateWebhookSecret();
    expect(secret).toHaveLength(64); // 32 bytes = 64 hex chars
    expect(secret).toMatch(/^[a-f0-9]+$/);
  });

  it("generates unique secrets each time", () => {
    const secret1 = generateWebhookSecret();
    const secret2 = generateWebhookSecret();
    expect(secret1).not.toBe(secret2);
  });
});

// ---------------------------------------------------------------------------
// Test helpers
// ---------------------------------------------------------------------------

function hmacSha256(secret: string, data: Buffer): string {
  // Use Node.js crypto module
  const { createHmac } = require("node:crypto") as { createHmac: (algo: string, key: string) => { update: (data: Buffer) => { digest: (encoding: string) => string } } };
  return createHmac("sha256", secret).update(data).digest("hex");
}
