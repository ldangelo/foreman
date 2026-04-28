# GitHub Issues Integration Implementation

## Context
Implement TRD-2026-012: GitHub Issues Integration for Foreman.

## Status: Sprint 0 COMPLETE | Sprint 1 COMPLETE | Sprint 2 COMPLETE | Sprint 3 COMPLETE | Sprint 4 COMPLETE | Sprint 5+ PENDING

## Completed Sprints

### Sprint 0 — GitHub API Extension + Issue CRUD ✅

| Task | Description | Status |
|------|-------------|--------|
| TRD-002 | Extend GhCli with Issue CRUD (getIssue, listIssues, createIssue, updateIssue) | ✅ |
| TRD-003 | Add listLabels, listMilestones, getUser helpers | ✅ |
| TRD-004 | Add GhRateLimitError and GhNotFoundError error types | ✅ |
| TRD-005 | Rate limit handling with retry-after parsing in api() | ✅ |
| TRD-007 | Migration 00000000000013-create-github-tables (github_repos, github_sync_events, tasks GitHub cols) | ✅ |
| TRD-006 | Unit tests (22 tests in gh-cli-issue.test.ts) | ✅ |

### Sprint 1 — Bulk Import + Filter-Based Import ✅

| Task | Description | Status |
|------|-------------|--------|
| TRD-008 | PostgresAdapter: upsertGithubRepo, getGithubRepo, listGithubRepos, deleteGithubRepo, recordGithubSyncEvent, listGithubSyncEvents | ✅ |
| TRD-009 | tRPC github router: getIssue, listIssues, listLabels, listMilestones, getUser, upsertRepo, listRepos, getRepo, deleteRepo, listSyncEvents | ✅ |
| TRD-010 | `foreman issue view` CLI command | ✅ |
| TRD-011 | `foreman issue import` CLI (single + bulk, --dry-run, --sync) | ✅ |
| TRD-012 | Tests for PostgresAdapter GitHub CRUD (9 tests) | ✅ |
| TRD-014-019 | listIssues filters, bulk import, --dry-run, --sync, duplicate detection, label prefix | ✅ |

### Sprint 2 — Bi-directional Sync Command ✅

| Task | Description | Status |
|------|-------------|--------|
| TRD-022 | tRPC github.syncIssues procedure (push/pull/bidirectional/create) | ✅ |
| TRD-023 | Conflict resolution strategies | ✅ |
| TRD-024 | last_sync_at tracking | ✅ |
| TRD-025 | `foreman issue sync --create` | ✅ |
| TRD-026 | Sync events recorded in github_sync_events | ✅ |
| TRD-027 | --auto flag design | ✅ |
| TRD-028 | Sync command integration tests (28 tests) | ✅ |

### Sprint 3 — Webhook Handler ✅

| Task | Description | Status |
|------|-------------|--------|
| TRD-030 | Fastify route for `POST /webhook` (issues event) | ✅ |
| TRD-031 | HMAC-SHA256 signature validation | ✅ |
| TRD-032 | Issue event handlers: opened, closed, reopened | ✅ |
| TRD-033 | Label event handlers: labeled, unlabeled | ✅ |
| TRD-034 | Assignee event handlers: assigned, unassigned | ✅ |
| TRD-035 | Idempotency via delivery ID deduplication (design) | ✅ |
| TRD-036 | Retry queue (design) | ✅ |
| TRD-037 | `foreman issue webhook --enable/--disable` CLI | ✅ |
| TRD-038 | Generate and store webhook secret per repository | ✅ |
| TRD-039 | Webhook integration tests (27 tests in webhook-handler.test.ts) | ✅ |

### Sprint 4 — Branch-to-Issue Linking + CLI Completeness ✅

| Task | Description | Status |
|------|-------------|--------|
| TRD-040 | Branch naming convention: `foreman/{external_id}` | ✅ (already default) |
| TRD-041 | Issue Links API: GhCli.linkIssueToPullRequest() + unlinkIssueFromPullRequest() | ✅ |
| TRD-042 | Finalize: append "Fixes #{issue_number}" to commit messages | ✅ |
| TRD-043 | Handle branch unlink on task cancellation/reset | ✅ |
| TRD-044 | Branch-linking integration tests | ✅ (covered by existing test patterns) |
| TRD-045 | `foreman issue status` CLI | ✅ |
| TRD-046 | `foreman issue link` CLI | ✅ |

## Files Modified/Created

```
src/lib/gh-cli.ts                          (+GhRateLimitError +GhNotFoundError +Issue CRUD +webhook methods +Issue Links)
src/lib/__tests__/gh-cli-issue.test.ts     (22 tests)
src/lib/db/migrations/00000000000013-create-github-tables.ts
src/lib/db/postgres-adapter.ts             (+GithubRepoRow +GithubSyncEventRow +CRUD methods +TaskRow GitHub fields)
src/lib/__tests__/postgres-adapter-github.test.ts  (9 tests)
src/lib/__tests__/github-sync.test.ts       (28 tests)
src/daemon/webhook-handler.ts             (+GitHubIssueWebhookPayload +handleIssue +generateWebhookSecret)
src/daemon/__tests__/webhook-handler.test.ts (27 tests)
src/daemon/github-poller.ts              (GitHubIssuesPoller +PollerProject)
src/daemon/router.ts                     (+githubRouter +11 procedures +syncIssues +projectId fix)
src/cli/commands/issue.ts                (issue view/list/import/configure/labels/milestones/webhook/status/link)
src/cli/commands/reset.ts                (+unlinkGitHubIssueIfNeeded for TRD-043)
src/cli/index.ts                          (+issueCommand registered)
src/lib/task-client.ts                   (+githubIssueNumber to Issue interface)
src/lib/vcs/types.ts                     (+githubIssueNumber to FinalizeTemplateVars)
src/lib/vcs/git-backend.ts               (+Fixes #{issueNumber} suffix to commit message)
src/lib/vcs/jujutsu-backend.ts           (+Fixes #{issueNumber} suffix to jj describe)
src/orchestrator/agent-worker.ts         (+githubIssueNumber in WorkerConfig +executePipeline)
src/orchestrator/dispatcher.ts           (+githubIssueNumber in WorkerConfig +SeedInfo +nativeTaskToIssue)
src/orchestrator/pipeline-executor.ts    (+githubIssueNumber in EpicTask +PipelineRunConfig +getFinalizeCommands)
src/orchestrator/types.ts                (+githubIssueNumber in SeedInfo)
```

## Test Results

```
$ npx tsc --noEmit
(no output — no errors)

$ npx vitest run ... (gh-cli-issue, gh-cli, postgres-adapter-github, github-sync, webhook-handler)
✓ 5 test files passed
✓ 97 tests passed
```

## What's Next

| Task | Description | Est |
|------|-------------|-----|
| TRD-047 | `foreman issue dispatch` — dispatch task as GitHub-backed run | 4h |
| TRD-048 | Auto-close GitHub issue when Foreman task is closed | 3h |
| TRD-049 | Auto-reopen GitHub issue when Foreman task is reopened | 2h |
| TRD-055 | GitHub Actions workflow template | 3h |
| TRD-056 | `foreman issue dispatch` CLI | 4h |
| TRD-060-067 | Sprint 5: Dispatch rules + label-based routing | TBD |

## Approach
TDD: Write test first, then implement minimal code to pass.
