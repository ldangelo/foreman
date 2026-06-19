/**
 * Jira webhook handler for ForemanDaemon.
 *
 * Handles Jira Cloud webhook events with HMAC-SHA256 verification.
 * Detects status transitions and triggers Foreman workflows via JiraTriggerHandler.
 *
 * Jira webhook event: jira:issue_updated (with status change in changelog)
 * Jira sends signature in X-Atlassian-Webhook-Signature-V2 header.
 *
 * @module src/daemon/jira-webhook-handler
 */

import { createHmac, timingSafeEqual, randomBytes } from "node:crypto";
import type { FastifyRequest, FastifyReply } from "fastify";
import type { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import type { JiraProjectConfig } from "../lib/project-config.js";
import type { JiraIssue } from "./jira-poller.js";
import { JiraTriggerHandler } from "../orchestrator/jira-trigger-handler.js";

// ── Types ─────────────────────────────────────────────────────────────────────
export interface JiraWebhookContext {
  adapter: PostgresAdapter;
  /** Maps Jira project key → project config (can be async) */
  getProjectConfig: (projectKey: string) => Promise<JiraProjectConfig | undefined> | JiraProjectConfig | undefined;
}

export interface JiraWebhookPayload {
  webhookEvent: string;
  timestamp: number;
  issue: JiraIssue;
  changelog?: {
    id: string;
    items: Array<{
      field: string;
      from: string | null;
      fromString: string | null;
      to: string | null;
      toString: string | null;
    }>;
  };
  user?: {
    accountId: string;
    displayName: string;
  };
}

export interface JiraWebhookConfig {
  /** HMAC secret for verifying Jira webhook payloads (from webhookSecretEnvVar). */
  secret: string;
}

// ── HMAC Verification ─────────────────────────────────────────────────────────

/**
 * Verify Jira webhook signature using HMAC-SHA256.
 * Jira sends: X-Atlassian-Webhook-Signature-V2: <hex>
 * The signature is computed over the raw request body bytes.
 * Uses timing-safe comparison to prevent timing attacks.
 */
export function verifyJiraSignature(
  rawBody: Buffer,
  signature: string | undefined,
  secret: string,
): boolean {
  if (!signature || !secret) return false;
  // Strip "sha256=" prefix from Jira's signature
  const sigValue = signature.startsWith("sha256=")
    ? signature.slice(7)
    : signature;
  const expected = createHmac("sha256", secret)
    .update(rawBody)
    .digest("hex");
  try {
    return timingSafeEqual(
      Buffer.from(expected, "utf8"),
      Buffer.from(sigValue, "utf8"),
    );
  } catch {
    return false;
  }
}

// ── Status Change Detection ───────────────────────────────────────────────────

/**
 * Extract status change from Jira webhook changelog.
 * Returns the previous and new status names if a status field changed.
 */
export function extractStatusChange(
  payload: JiraWebhookPayload,
): { from: string; to: string } | null {
  if (!payload.changelog?.items) return null;

  for (const item of payload.changelog.items) {
    if (item.field === "status") {
      if (item.fromString && item.toString) {
        return { from: item.fromString, to: item.toString };
      }
    }
  }

  return null;
}

// ── Generate Secret ───────────────────────────────────────────────────────────

/**
 * Generate a cryptographically random Jira webhook secret.
 */
export function generateJiraWebhookSecret(): string {
  return randomBytes(32).toString("hex");
}

// ── Webhook Handler Factory ───────────────────────────────────────────────────

export type JiraWebhookHandler = (
  request: FastifyRequest<{ Body: unknown }>,
  reply: FastifyReply,
) => Promise<void>;

/**
 * Create a Jira webhook handler bound to the given context and config.
 *
 * On each valid webhook event:
 * 1. Verifies HMAC signature
 * 2. Parses Jira event
 * 3. Detects status change from changelog
 * 4. Checks if new status matches a startStatus in project config
 * 5. Creates task via JiraTriggerHandler
 */
export function createJiraWebhookHandler(
  ctx: JiraWebhookContext,
  config: JiraWebhookConfig,
): JiraWebhookHandler {
  return async (request, reply) => {
    const rawBody = request.body as unknown;
    const bodyBuffer = Buffer.from(JSON.stringify(rawBody));

    // Verify signature
    const signature = request.headers["x-atlassian-webhook-signature-v2"] as string | undefined;
    if (!verifyJiraSignature(bodyBuffer, signature, config.secret)) {
      request.log.warn("[jira-webhook] Invalid signature — rejecting");
      return reply.code(401).send({ error: "Invalid signature" });
    }

    const payload = rawBody as JiraWebhookPayload;
    const projectKey = payload.issue?.fields?.project?.key;

    if (!projectKey) {
      request.log.warn("[jira-webhook] Missing project key in payload");
      return reply.code(400).send({ error: "Missing project key" });
    }

    // Only handle jira:issue_updated events
    if (payload.webhookEvent !== "jira:issue_updated") {
      return reply.code(200).send({ received: true, ignored: true });
    }

    request.log.info(
      { event: payload.webhookEvent, issue: payload.issue?.key },
      "[jira-webhook] Received Jira event",
    );

    // Detect status change
    const statusChange = extractStatusChange(payload);
    if (!statusChange) {
      // No status change in changelog — acknowledge but skip
      return reply.code(200).send({ received: true, ignored: true });
    }
    // Look up project config
    const projectConfigResult = ctx.getProjectConfig(projectKey);
    const projectConfig = await Promise.resolve(projectConfigResult);
    if (!projectConfig) {
      request.log.info({ projectKey }, "[jira-webhook] Project not configured — skipping");
      return reply.code(200).send({ received: true, ignored: true });
    }
    // Check if transition is to a startStatus
    if (!projectConfig.startStatus.includes(statusChange.to)) {
      request.log.info(
        { issue: payload.issue.key, newStatus: statusChange.to },
        "[jira-webhook] Transition not to startStatus — skipping",
      );
      return reply.code(200).send({ received: true, ignored: true });
    }
    // Check if transitioning FROM a startStatus (should not trigger)
    if (projectConfig.startStatus.includes(statusChange.from)) {
      request.log.info(
        { issue: payload.issue.key, from: statusChange.from, to: statusChange.to },
        "[jira-webhook] Transition from startStatus to startStatus — skipping (already triggered)",
      );
      return reply.code(200).send({ received: true, ignored: true });
    }
    // Process the transition
    const jiraProjectId = projectKey;
    const handler = new JiraTriggerHandler(ctx.adapter, jiraProjectId);
    try {
      const result = await handler.handleTransition({
        issue: payload.issue,
        projectConfig,
        jiraProjectId,
        source: "webhook",
      });
      if (result.triggered) {
        request.log.info(
          { issue: payload.issue.key, taskId: result.taskId },
          "[jira-webhook] Triggered workflow successfully",
        );
        return reply.code(200).send({ received: true, triggered: true, taskId: result.taskId });
      } else {
        request.log.info(
          { issue: payload.issue.key, reason: result.reason },
          `[jira-webhook] Skipped: ${result.reason}`,
        );
        return reply.code(200).send({ received: true, triggered: false, reason: result.reason });
      }
    } catch (err) {
      request.log.error(
        { error: err instanceof Error ? err.message : String(err) },
        "[jira-webhook] Error processing webhook",
      );
      return reply.code(500).send({ error: "Internal error processing webhook" });
    }
  };
}