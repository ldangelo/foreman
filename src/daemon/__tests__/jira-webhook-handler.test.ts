/**
 * Unit tests for Jira webhook handler.
 *
 * Tests:
 * - Signature verification (HMAC-SHA256)
 * - Status change extraction from changelog
 * - Rejects invalid signatures
 * - Skips non-status changes
 * - Skips transitions from startStatus (idempotency)
 */

import { createHmac } from "node:crypto";
import { describe, it, expect } from "vitest";
import {
  verifyJiraSignature,
  extractStatusChange,
  generateJiraWebhookSecret,
  type JiraWebhookPayload,
} from "../jira-webhook-handler.js";

// ── Payload fixture builder ───────────────────────────────────────────────────

function makePayload(overrides: Partial<JiraWebhookPayload> = {}): JiraWebhookPayload {
  return {
    webhookEvent: "jira:issue_updated",
    timestamp: Date.now(),
    issue: {
      key: "PROJ-1",
      fields: {
        summary: "Test Issue",
        status: { name: "In Progress" },
        issuetype: { name: "Task" },
        project: { key: "PROJ" },
        updated: "2026-06-01T12:00:00Z",
      },
    },
    changelog: {
      id: "12345",
      items: [
        {
          field: "status",
          from: "To Do",
          fromString: "To Do",
          to: "In Progress",
          toString: "In Progress",
        },
      ],
    },
    ...overrides,
  };
}

// ── verifyJiraSignature tests ─────────────────────────────────────────────────

describe("verifyJiraSignature", () => {
  const secret = "test-secret";

  it("returns true for valid signature", () => {
    const body = Buffer.from(JSON.stringify({ test: "data" }));
    const signature = `sha256=${createHmac("sha256", secret).update(body).digest("hex")}`;
    expect(verifyJiraSignature(body, signature, secret)).toBe(true);
  });

  it("returns false for invalid signature", () => {
    const body = Buffer.from(JSON.stringify({ test: "data" }));
    expect(verifyJiraSignature(body, "sha256=invalid", secret)).toBe(false);
  });

  it("returns false when signature is missing", () => {
    const body = Buffer.from(JSON.stringify({ test: "data" }));
    expect(verifyJiraSignature(body, undefined, secret)).toBe(false);
  });

  it("returns false when secret is empty", () => {
    const body = Buffer.from(JSON.stringify({ test: "data" }));
    expect(verifyJiraSignature(body, "sha256=abc", "")).toBe(false);
  });
});

// ── extractStatusChange tests ────────────────────────────────────────────────

describe("extractStatusChange", () => {
  it("extracts status from changelog items", () => {
    const payload = makePayload();
    expect(extractStatusChange(payload)).toEqual({ from: "To Do", to: "In Progress" });
  });

  it("returns null when no changelog", () => {
    expect(extractStatusChange(makePayload({ changelog: undefined }))).toBeNull();
  });

  it("returns null when no items", () => {
    expect(extractStatusChange(makePayload({ changelog: { id: "123", items: [] } }))).toBeNull();
  });

  it("returns null when field is not status", () => {
    const payload = makePayload({
      changelog: {
        id: "12345",
        items: [
          { field: "summary", from: "Old", fromString: "Old", to: "New", toString: "New" },
        ],
      },
    });
    expect(extractStatusChange(payload)).toBeNull();
  });

  it("returns null when status values are missing", () => {
    const payload = makePayload({
      changelog: {
        id: "12345",
        items: [
          { field: "status", from: null, fromString: null, to: null, toString: null },
        ],
      },
    });
    expect(extractStatusChange(payload)).toBeNull();
  });

  it("returns the first status change when multiple items", () => {
    const payload = makePayload({
      changelog: {
        id: "12345",
        items: [
          { field: "priority", from: "M", fromString: "M", to: "H", toString: "H" },
          { field: "status", from: "To Do", fromString: "To Do", to: "In Progress", toString: "In Progress" },
        ],
      },
    });
    expect(extractStatusChange(payload)).toEqual({ from: "To Do", to: "In Progress" });
  });
});

// ── generateJiraWebhookSecret tests ──────────────────────────────────────────

describe("generateJiraWebhookSecret", () => {
  it("generates a 64-character hex string", () => {
    const secret = generateJiraWebhookSecret();
    expect(secret).toMatch(/^[a-f0-9]{64}$/);
  });

  it("generates unique secrets on each call", () => {
    const s1 = generateJiraWebhookSecret();
    const s2 = generateJiraWebhookSecret();
    expect(s1).not.toBe(s2);
  });
});
