/**
 * GitHub webhook handler for ForemanDaemon.
 *
 * Handles:
 * - push events: record bead:synced events and rebase active worktrees (TRD-063)
 * - pull_request events: record bead:synced when PR is closed+merged
 *
 * HMAC-SHA256 verification uses the webhook secret from FOREMAN_WEBHOOK_SECRET.
 *
 * @module src/daemon/webhook-handler
 */
import type { FastifyRequest, FastifyReply } from "fastify";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import { ProjectRegistry } from "../lib/project-registry.js";
export interface WebhookContext {
    adapter: PostgresAdapter;
    registry: ProjectRegistry;
}
export interface GitHubPushPayload {
    ref: string;
    forced: boolean;
    repository: {
        clone_url: string;
        full_name: string;
    };
    pusher: {
        name: string;
    };
}
export interface GitHubPrPayload {
    action: string;
    pull_request: {
        merged: boolean;
        number: number;
        title: string;
        base: {
            ref: string;
            sha: string;
        };
        head: {
            ref: string;
            sha: string;
        };
    };
    repository: {
        full_name: string;
    };
}
/**
 * Verify GitHub webhook signature using HMAC-SHA256.
 * GitHub sends: X-Hub-Signature-256: sha256=<hex>
 * Uses timing-safe comparison to prevent timing attacks.
 */
export declare function verifyGitHubSignature(rawBody: Buffer, signature: string | undefined, secret: string): boolean;
/** Extract branch name from a git ref string (e.g. "refs/heads/main" → "main"). */
export declare function extractBranchFromRef(ref: string): string;
/**
 * Generate a cryptographically random webhook secret.
 * Used when enabling webhooks for a repository.
 */
export declare function generateWebhookSecret(): string;
export type WebhookHandler = (request: FastifyRequest<{
    Body: unknown;
}>, reply: FastifyReply) => Promise<void>;
export interface WebhookConfig {
    /** HMAC secret for verifying GitHub webhook payloads. */
    secret: string;
    /**
     * Label that triggers automatic task dispatch from GitHub issues.
     * Issues with this label (or "foreman:dispatch") are imported as "ready" status.
     *
     * Default: "foreman" (for backward compatibility)
     * If null or empty, issues are imported as "backlog" (no auto-dispatch).
     */
    foremanTag?: string;
    /** @deprecated Use foremanTag instead. Kept for backward compatibility. */
    foremanLabel?: string;
}
/**
 * Create a webhook handler bound to the given context and config.
 */
export declare function createWebhookHandler(ctx: WebhookContext, config: WebhookConfig): WebhookHandler;
export interface GitHubIssueWebhookPayload {
    action: string;
    issue: {
        id: number;
        number: number;
        title: string;
        body: string | null;
        state: "open" | "closed";
        user: {
            login: string;
            id: number;
        };
        labels: Array<{
            id: number;
            name: string;
            color: string;
        }>;
        assignees: Array<{
            login: string;
            id: number;
        }>;
        milestone: {
            id: number;
            title: string;
            number: number;
        } | null;
        created_at: string;
        updated_at: string;
        closed_at: string | null;
        url: string;
        html_url: string;
    };
    repository: {
        id: number;
        full_name: string;
        clone_url: string;
    };
    label?: {
        name: string;
        color: string;
    };
    assignee?: {
        login: string;
        id: number;
    };
}
//# sourceMappingURL=webhook-handler.d.ts.map