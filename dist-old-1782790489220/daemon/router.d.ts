import type { inferRouterContext } from "@trpc/server";
import type { FastifyRequest, FastifyReply } from "fastify";
import { PostgresAdapter } from "../lib/db/postgres-adapter.js";
import { GhCli } from "../lib/gh-cli.js";
import { ProjectRegistry } from "../lib/project-registry.js";
import { type PrState } from "../lib/pr-state.js";
export interface Context {
    /** Fastify request object for access to headers, socket, etc. */
    req: FastifyRequest;
    res: FastifyReply;
    /** PostgresAdapter instance scoped to this request. */
    adapter: PostgresAdapter;
    /** GitHub CLI wrapper. */
    gh: GhCli;
    /** Project registry (JSON + Postgres dual-write). */
    registry: ProjectRegistry;
    /** Current project ID (from X-Project-Id header or FOREMAN_PROJECT_ID env var). */
    projectId?: string;
}
export declare function createContext({ req, res, }: {
    req: FastifyRequest;
    res: FastifyReply;
}): Promise<Context>;
export type ContextFn = typeof createContext;
export type RouterContext = inferRouterContext<AppRouter>;
export declare const appRouter: import("@trpc/server").TRPCBuiltRouter<{
    ctx: Context;
    meta: object;
    errorShape: import("@trpc/server").TRPCDefaultErrorShape;
    transformer: false;
}, import("@trpc/server").TRPCDecorateCreateRouterOptions<{
    projects: import("@trpc/server").TRPCBuiltRouter<{
        ctx: Context;
        meta: object;
        errorShape: import("@trpc/server").TRPCDefaultErrorShape;
        transformer: false;
    }, import("@trpc/server").TRPCDecorateCreateRouterOptions<{
        /**
         * List all projects with health status.
         * GET /trpc/projects.list
         *
         * Returns projects from the daemon-backed registry source of truth, enriched
         * with health status.
         * Tasks counts (running, ready, needs human) come from the task store.
         */
        list: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                status?: "active" | "paused" | "archived" | undefined;
                search?: string | undefined;
            } | undefined;
            output: {
                id: string;
                name: string;
                path: string;
                githubUrl: string;
                defaultBranch: string;
                status: "active" | "paused" | "archived";
                lastSyncAt: string | null;
                createdAt: string;
                healthy: boolean;
            }[];
            meta: object;
        }>;
        /**
         * Get a single project by ID.
         * GET /trpc/projects.get
         */
        get: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                id: string;
            };
            output: import("../lib/project-registry.js").ProjectRecord | null;
            meta: object;
        }>;
        /**
         * Get aggregate task counts for a project.
         * GET /trpc/projects.stats
         */
        stats: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
            };
            output: {
                tasks: {
                    backlog: number;
                    ready: number;
                    inProgress: number;
                    approved: number;
                    merged: number;
                    closed: number;
                    total: number;
                };
                runs: {
                    active: number;
                    pending: number;
                };
            };
            meta: object;
        }>;
        /**
         * List tasks needing human attention for a project.
         * GET /trpc/projects.listNeedsHuman
         */
        listNeedsHuman: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
            };
            output: import("../lib/db/postgres-adapter.js").TaskRow[];
            meta: object;
        }>;
        /**
         * Add a project from a GitHub URL.
         * POST /trpc/projects.add
         *
         * Steps:
         * 1. Verify gh auth (throws if not authenticated)
         * 2. Fetch repo metadata (owner, repo, default branch, visibility)
         * 3. Generate stable project ID: <normalized-name>-<hex5>
         * 4. Create ~/.foreman/projects/ directory if absent
         * 5. Clone repo to ~/.foreman/projects/<project-id>/
         * 6. Write to Postgres (idempotent: fails if path already exists)
         *
         * @throws GhNotInstalledError if gh is not installed
         * @throws GhNotAuthenticatedError if gh is not logged in
         * @throws GhCloneError if clone fails
         * @throws GhApiError if repo metadata fetch fails
         */
        add: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                githubUrl: string;
                name?: string | undefined;
                defaultBranch?: string | undefined;
                status?: "active" | "paused" | "archived" | undefined;
            };
            output: {
                id: string;
                name: string;
                path: string;
                github_url: string;
                default_branch: string;
                status: "active" | "paused" | "archived";
                created_at: string;
                updated_at: string;
                last_sync_at: string | null;
            };
            meta: object;
        }>;
        /**
         * Update a project.
         * POST /trpc/projects.update
         */
        update: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                id: string;
                updates: {
                    name?: string | undefined;
                    path?: string | undefined;
                    status?: "active" | "paused" | "archived" | undefined;
                    jira?: {
                        apiUrl?: string | undefined;
                        email?: string | undefined;
                        apiToken?: string | undefined;
                        pollIntervalSeconds?: number | undefined;
                        webhookEnabled?: boolean | undefined;
                        webhookSecretEnvVar?: string | undefined;
                        projects?: {
                            key: string;
                            startStatus: string[];
                            issueTypeWorkflowMap: Record<string, string>;
                            endStatus?: string[] | undefined;
                            debounceWindowSeconds?: number | undefined;
                        }[] | undefined;
                    } | undefined;
                };
            };
            output: import("../lib/project-registry.js").ProjectRecord;
            meta: object;
        }>;
        /**
         * Remove (archive) a project.
         * POST /trpc/projects.remove
         *
         * Guards against removing a project with active (pending/running) tasks
         * unless force=true.
         */
        remove: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                id: string;
                force?: boolean | undefined;
            };
            output: {
                removed: boolean;
            };
            meta: object;
        }>;
        /**
         * Sync a project: run git fetch and update lastSyncAt in both JSON and Postgres.
         * POST /trpc/projects.sync
         */
        sync: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                id: string;
            };
            output: import("../lib/project-registry.js").ProjectRecord;
            meta: object;
        }>;
    }>>;
    tasks: import("@trpc/server").TRPCBuiltRouter<{
        ctx: Context;
        meta: object;
        errorShape: import("@trpc/server").TRPCDefaultErrorShape;
        transformer: false;
    }, import("@trpc/server").TRPCDecorateCreateRouterOptions<{
        /**
         * List tasks for a project.
         * GET /trpc/tasks.list
         */
        list: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                status?: ("failed" | "stuck" | "merged" | "conflict" | "closed" | "explorer" | "developer" | "qa" | "reviewer" | "finalize" | "backlog" | "ready" | "in-progress" | "review" | "blocked")[] | undefined;
                runId?: string | undefined;
                limit?: number | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").TaskRow[];
            meta: object;
        }>;
        /**
         * Get a single task by ID.
         * GET /trpc/tasks.get
         */
        get: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                taskId: string;
            };
            output: import("../lib/db/postgres-adapter.js").TaskRow | null;
            meta: object;
        }>;
        /**
         * Create a new task.
         * POST /trpc/tasks.create
         */
        create: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                id?: string | undefined;
                title?: string | undefined;
                description?: string | undefined;
                type?: "task" | "bug" | "feature" | "story" | "epic" | "chore" | "docs" | "question" | undefined;
                priority?: number | undefined;
                status?: "failed" | "stuck" | "merged" | "conflict" | "closed" | "explorer" | "developer" | "qa" | "reviewer" | "finalize" | "backlog" | "ready" | "in-progress" | "review" | "blocked" | undefined;
                externalId?: string | undefined;
                branch?: string | undefined;
                createdAt?: string | undefined;
                updatedAt?: string | undefined;
                approvedAt?: string | undefined;
                closedAt?: string | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").TaskRow;
            meta: object;
        }>;
        /**
         * Append a note to a task.
         * POST /trpc/tasks.addNote
         */
        addNote: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                taskId: string;
                author: string;
                body: string;
                runId?: string | null | undefined;
                phase?: string | null | undefined;
                kind?: "qa" | "progress" | "review" | "failure" | "manual" | "system" | "issue" | "blocker" | "final" | undefined;
                metadata?: Record<string, unknown> | null | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").TaskNoteRow;
            meta: object;
        }>;
        /**
         * List task notes.
         * GET /trpc/tasks.listNotes
         */
        listNotes: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                taskId: string;
                limit?: number | undefined;
                newestFirst?: boolean | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").TaskNoteRow[];
            meta: object;
        }>;
        /**
         * Update a task's fields.
         * POST /trpc/tasks.update
         */
        update: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                taskId: string;
                updates: {
                    title?: string | undefined;
                    description?: string | undefined;
                    type?: "task" | "bug" | "feature" | "story" | "epic" | "chore" | "docs" | "question" | undefined;
                    priority?: number | undefined;
                    status?: "failed" | "stuck" | "merged" | "conflict" | "closed" | "explorer" | "developer" | "qa" | "reviewer" | "finalize" | "backlog" | "ready" | "in-progress" | "review" | "blocked" | undefined;
                    branch?: string | undefined;
                    external_id?: string | undefined;
                };
            };
            output: import("../lib/db/postgres-adapter.js").TaskRow | null;
            meta: object;
        }>;
        /**
         * Delete a task.
         * POST /trpc/tasks.delete
         */
        delete: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                taskId: string;
            };
            output: {
                deleted: boolean;
                taskId: string;
            };
            meta: object;
        }>;
        /**
         * Claim a task for a run.
         * Uses SELECT ... FOR UPDATE to prevent concurrent claims.
         * POST /trpc/tasks.claim
         */
        claim: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                taskId: string;
                runId: string;
            };
            output: {
                claimed: boolean;
                taskId: string;
            };
            meta: object;
        }>;
        /**
         * Approve a backlog task: transition to 'ready'.
         * POST /trpc/tasks.approve
         */
        approve: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                taskId: string;
            };
            output: import("../lib/db/postgres-adapter.js").TaskRow | null;
            meta: object;
        }>;
        close: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                taskId: string;
            };
            output: import("../lib/db/postgres-adapter.js").TaskRow | null;
            meta: object;
        }>;
        /**
         * Reset a task back to 'ready' state (clears run_id).
         * POST /trpc/tasks.reset
         */
        reset: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                taskId: string;
            };
            output: import("../lib/db/postgres-adapter.js").TaskRow | null;
            meta: object;
        }>;
        /**
         * Retry a failed/stuck task: transition to 'ready'.
         * POST /trpc/tasks.retry
         */
        retry: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                taskId: string;
            };
            output: import("../lib/db/postgres-adapter.js").TaskRow | null;
            meta: object;
        }>;
        addDependency: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                fromTaskId: string;
                toTaskId: string;
                type?: "blocks" | "parent-child" | undefined;
            };
            output: {
                added: boolean;
            };
            meta: object;
        }>;
        listDependencies: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                taskId: string;
                direction?: "outgoing" | "incoming" | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").TaskDependencyRow[];
            meta: object;
        }>;
        removeDependency: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                fromTaskId: string;
                toTaskId: string;
                type?: "blocks" | "parent-child" | undefined;
            };
            output: {
                removed: boolean;
            };
            meta: object;
        }>;
        /**
         * Get the current GitHub PR state for a task.
         * GET /trpc/tasks.getPrState
         *
         * Returns the PR state including:
         * - status: "none" | "open" | "merged" | "closed" | "error"
         * - url: GitHub PR URL if exists
         * - number: PR number if exists
         * - headSha: PR head SHA at creation/merge time
         * - currentHeadSha: Current branch HEAD SHA
         * - isStale: True if PR merged but branch head changed
         * - summary: Human-readable summary for display
         */
        getPrState: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                taskId: string;
            };
            output: PrState;
            meta: object;
        }>;
    }>>;
    runs: import("@trpc/server").TRPCBuiltRouter<{
        ctx: Context;
        meta: object;
        errorShape: import("@trpc/server").TRPCDefaultErrorShape;
        transformer: false;
    }, import("@trpc/server").TRPCDecorateCreateRouterOptions<{
        /**
         * Create a new pipeline run.
         * POST /trpc/runs.create
         */
        create: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                beadId: string;
                runNumber: number;
                branch: string;
                commitSha?: string | undefined;
                trigger?: "pr" | "push" | "manual" | "schedule" | "bead" | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").PipelineRunRow;
            meta: object;
        }>;
        /**
         * List runs for a project.
         * GET /trpc/runs.list
         */
        list: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                beadId?: string | undefined;
                status?: "pending" | "running" | "success" | "failure" | "cancelled" | "skipped" | undefined;
                limit?: number | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").PipelineRunRow[];
            meta: object;
        }>;
        /**
         * List active (pending/running) runs for a project.
         * GET /trpc/runs.listActive
         */
        listActive: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                beadId?: string | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").RunRow[];
            meta: object;
        }>;
        /**
         * Get a single run by ID.
         * GET /trpc/runs.get
         */
        get: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                runId: string;
            };
            output: import("../lib/db/postgres-adapter.js").PipelineRunRow;
            meta: object;
        }>;
        /**
         * Get run progress (currentPhase, lastActivity, tool calls, etc.) as JSON.
         * GET /trpc/runs.getProgress
         */
        getProgress: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                runId: string;
            };
            output: any;
            meta: object;
        }>;
        /**
         * Update run status (used by sentinel/pipeline to transition state).
         * POST /trpc/runs.updateStatus
         */
        updateStatus: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                runId: string;
                status: "pending" | "running" | "success" | "failure" | "cancelled" | "skipped";
                startedAt?: string | undefined;
                finishedAt?: string | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").PipelineRunRow;
            meta: object;
        }>;
        /**
         * Finalize a run: set status + finishedAt atomically.
         * POST /trpc/runs.finalize
         */
        finalize: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                runId: string;
                status: "pending" | "running" | "success" | "failure" | "cancelled" | "skipped";
                finishedAt?: string | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").PipelineRunRow;
            meta: object;
        }>;
        /**
         * Record a pipeline event.
         * POST /trpc/runs.logEvent
         */
        logEvent: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                runId: string;
                eventType: "run:queued" | "run:started" | "run:success" | "run:failure" | "run:cancelled" | "task:claimed" | "task:approved" | "task:rejected" | "task:reset" | "bead:synced" | "bead:conflict";
                taskId?: string | undefined;
                payload?: Record<string, unknown> | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").PipelineEventRow;
            meta: object;
        }>;
        /**
         * List events for a run.
         * GET /trpc/runs.listEvents
         */
        listEvents: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                runId: string;
            };
            output: import("../lib/db/postgres-adapter.js").PipelineEventRow[];
            meta: object;
        }>;
        /**
         * Append a message chunk to a run.
         * POST /trpc/runs.sendMessage
         */
        sendMessage: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                runId: string;
                stream: "stdout" | "stderr" | "system";
                chunk: string;
                lineNumber: number;
                stepKey?: string | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").MessageRow;
            meta: object;
        }>;
        /**
         * List messages for a run, optionally filtered by step.
         * GET /trpc/runs.listMessages
         */
        listMessages: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                runId: string;
                stepKey?: string | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").MessageRow[];
            meta: object;
        }>;
    }>>;
    mail: import("@trpc/server").TRPCBuiltRouter<{
        ctx: Context;
        meta: object;
        errorShape: import("@trpc/server").TRPCDefaultErrorShape;
        transformer: false;
    }, import("@trpc/server").TRPCDecorateCreateRouterOptions<{
        send: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                runId: string;
                senderAgentType: string;
                recipientAgentType: string;
                subject: string;
                body: string;
            };
            output: import("../lib/db/postgres-adapter.js").AgentMessageRow;
            meta: object;
        }>;
        list: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                runId: string;
                agentType?: string | undefined;
                unreadOnly?: boolean | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").AgentMessageRow[];
            meta: object;
        }>;
        listGlobal: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                limit?: number | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").AgentMessageRow[];
            meta: object;
        }>;
        markRead: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                messageId: string;
            };
            output: boolean;
            meta: object;
        }>;
        markAllRead: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                runId: string;
                agentType: string;
            };
            output: {
                updated: boolean;
            };
            meta: object;
        }>;
        delete: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                messageId: string;
            };
            output: boolean;
            meta: object;
        }>;
    }>>;
    github: import("@trpc/server").TRPCBuiltRouter<{
        ctx: Context;
        meta: object;
        errorShape: import("@trpc/server").TRPCDefaultErrorShape;
        transformer: false;
    }, import("@trpc/server").TRPCDecorateCreateRouterOptions<{
        /**
         * Get a single GitHub issue.
         * GET /repos/{owner}/{repo}/issues/{issue_number}
         */
        getIssue: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                owner: string;
                repo: string;
                issueNumber: number;
            };
            output: import("../lib/gh-cli.js").GitHubIssue;
            meta: object;
        }>;
        /**
         * List issues for a repository with optional filters.
         * GET /repos/{owner}/{repo}/issues
         */
        listIssues: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                owner: string;
                repo: string;
                labels?: string | undefined;
                milestone?: string | undefined;
                assignee?: string | undefined;
                state?: "open" | "closed" | "all" | undefined;
                since?: string | undefined;
            };
            output: import("../lib/gh-cli.js").GitHubIssue[];
            meta: object;
        }>;
        /**
         * List repository labels.
         * GET /repos/{owner}/{repo}/labels
         */
        listLabels: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                owner: string;
                repo: string;
            };
            output: import("../lib/gh-cli.js").GitHubLabel[];
            meta: object;
        }>;
        /**
         * List repository milestones.
         * GET /repos/{owner}/{repo}/milestones
         */
        listMilestones: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                owner: string;
                repo: string;
            };
            output: import("../lib/gh-cli.js").GitHubMilestone[];
            meta: object;
        }>;
        /**
         * Get a GitHub user.
         * GET /users/{username}
         */
        getUser: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                username: string;
            };
            output: import("../lib/gh-cli.js").GitHubUser;
            meta: object;
        }>;
        /**
         * Configure a GitHub repository for a project.
         * POST/PUT github_repos (upsert)
         */
        upsertRepo: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                owner: string;
                repo: string;
                authType?: "pat" | "app" | undefined;
                authConfig?: Record<string, unknown> | undefined;
                defaultLabels?: string[] | undefined;
                autoImport?: boolean | undefined;
                webhookSecret?: string | undefined;
                webhookEnabled?: boolean | undefined;
                syncStrategy?: "foreman-wins" | "github-wins" | "manual" | "last-write-wins" | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").GithubRepoRow;
            meta: object;
        }>;
        /**
         * List configured GitHub repos for a project.
         */
        listRepos: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
            };
            output: import("../lib/db/postgres-adapter.js").GithubRepoRow[];
            meta: object;
        }>;
        /**
         * Get a single GitHub repo configuration.
         */
        getRepo: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                owner: string;
                repo: string;
            };
            output: import("../lib/db/postgres-adapter.js").GithubRepoRow;
            meta: object;
        }>;
        /**
         * Delete a GitHub repo configuration.
         */
        deleteRepo: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                repoId: string;
            };
            output: {
                success: boolean;
            };
            meta: object;
        }>;
        /**
         * List sync events for a project.
         */
        listSyncEvents: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId: string;
                externalId?: string | undefined;
                limit?: number | undefined;
            };
            output: import("../lib/db/postgres-adapter.js").GithubSyncEventRow[];
            meta: object;
        }>;
        /**
         * Bi-directionally sync GitHub issues with Foreman tasks.
         *
         * Modes:
         * - `push`: Push Foreman task changes to GitHub issues
         * - `pull`: Pull GitHub issue changes to Foreman tasks
         * - `bidirectional`: Both directions
         * - `create`: Create GitHub issues from Foreman tasks without external_id
         */
        syncIssues: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId: string;
                owner: string;
                repo: string;
                mode: "push" | "create" | "pull" | "bidirectional";
                strategy?: "foreman-wins" | "github-wins" | "manual" | "last-write-wins" | undefined;
                auto?: boolean | undefined;
            };
            output: {
                mode: "push" | "create" | "pull" | "bidirectional";
                strategy: "foreman-wins" | "github-wins" | "manual" | "last-write-wins";
                pushed: number;
                pulled: number;
                created: number;
                conflicts: number;
            };
            meta: object;
        }>;
    }>>;
    jira: import("@trpc/server").TRPCBuiltRouter<{
        ctx: Context;
        meta: object;
        errorShape: import("@trpc/server").TRPCDefaultErrorShape;
        transformer: false;
    }, import("@trpc/server").TRPCDecorateCreateRouterOptions<{
        /**
         * Configure Jira monitoring for the current project.
         * POST /trpc/jira.configure
         */
        configure: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                apiUrl: string;
                email: string;
                apiToken: string;
                projects: {
                    key: string;
                    startStatus: string[];
                    issueTypeWorkflowMap: Record<string, string>;
                    endStatus?: string[] | undefined;
                    debounceWindowSeconds?: number | undefined;
                }[];
                projectId?: string | undefined;
                webhookEnabled?: boolean | undefined;
                webhookSecretEnvVar?: string | undefined;
                pollIntervalSeconds?: number | undefined;
            };
            output: {
                success: boolean;
            };
            meta: object;
        }>;
        /**
         * Get Jira monitor status for the current project.
         * GET /trpc/jira.getStatus
         */
        getStatus: import("@trpc/server").TRPCQueryProcedure<{
            input: {
                projectId?: string | undefined;
            };
            output: {
                monitoredIssues: number;
                triggeredToday: number;
                lastError?: string;
                configured: boolean;
                projects: number;
                lastPoll: string | undefined;
                webhookEnabled: boolean;
            };
            meta: object;
        }>;
        /**
         * Test Jira API connection.
         * GET /trpc/jira.testConnection
         */
        testConnection: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                apiUrl: string;
                email: string;
                apiToken: string;
            };
            output: {
                connected: boolean;
                error: string;
                projects?: undefined;
            } | {
                connected: boolean;
                projects: {
                    key: string;
                    name: string;
                }[];
                error?: undefined;
            };
            meta: object;
        }>;
        /**
         * Enable webhook for real-time Jira triggers.
         * POST /trpc/jira.enableWebhook
         */
        enableWebhook: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                webhookSecret: string;
                projectId?: string | undefined;
            };
            output: {
                webhookUrl: string;
            };
            meta: object;
        }>;
        /**
         * Disable webhook for Jira triggers.
         * POST /trpc/jira.disableWebhook
         */
        disableWebhook: import("@trpc/server").TRPCMutationProcedure<{
            input: {
                projectId?: string | undefined;
            };
            output: {
                success: boolean;
            };
            meta: object;
        }>;
    }>>;
}>>;
export type AppRouter = typeof appRouter;
//# sourceMappingURL=router.d.ts.map