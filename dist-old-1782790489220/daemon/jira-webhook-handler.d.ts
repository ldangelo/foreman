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
import type { FastifyRequest, FastifyReply } from "fastify";
import type { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import type { JiraProjectConfig } from "../lib/project-config.js";
import type { JiraIssue } from "./jira-poller.js";
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
/**
 * Verify Jira webhook signature using HMAC-SHA256.
 * Jira sends: X-Atlassian-Webhook-Signature-V2: <hex>
 * The signature is computed over the raw request body bytes.
 * Uses timing-safe comparison to prevent timing attacks.
 */
export declare function verifyJiraSignature(rawBody: Buffer, signature: string | undefined, secret: string): boolean;
/**
 * Extract status change from Jira webhook changelog.
 * Returns the previous and new status names if a status field changed.
 */
export declare function extractStatusChange(payload: JiraWebhookPayload): {
    from: string;
    to: string;
} | null;
/**
 * Generate a cryptographically random Jira webhook secret.
 */
export declare function generateJiraWebhookSecret(): string;
export type JiraWebhookHandler = (request: FastifyRequest<{
    Body: unknown;
}>, reply: FastifyReply) => Promise<void>;
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
export declare function createJiraWebhookHandler(ctx: JiraWebhookContext, config: JiraWebhookConfig): JiraWebhookHandler;
//# sourceMappingURL=jira-webhook-handler.d.ts.map