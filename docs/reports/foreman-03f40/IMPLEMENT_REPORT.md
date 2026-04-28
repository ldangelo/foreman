# IMPLEMENT_REPORT.md — TRD-2026-012: GitHub Issues Integration

**Document ID:** TRD-2026-012
**Seed ID:** foreman-03f40
**Date:** 2026-04-28
**Status:** Sprint 0 + Sprint 1 Complete

---

## Executive Summary

Implemented **Sprint 0** (GitHub API Extension) and **Sprint 1** (Bulk Import + Filter-Based Import) of the GitHub Issues Integration epic (TRD-2026-012).

---

## Sprint 0 Completed Tasks

### TRD-002: Extend GhCli with Issue CRUD (4h) ✅

Added to `src/lib/gh-cli.ts`:

| Method | Description |
|--------|-------------|
| `getIssue(owner, repo, issueNumber)` | Fetch single issue by number |
| `listIssues(owner, repo, options?)` | List issues with filters (labels, milestone, assignee, state, since) |
| `createIssue(owner, repo, options)` | Create new issue |
| `updateIssue(owner, repo, issueNumber, options)` | Update existing issue |

### TRD-003: Add Label/Milestone/User Helpers (2h) ✅

| Method | Description |
|--------|-------------|
| `listLabels(owner, repo)` | List all repo labels |
| `listMilestones(owner, repo)` | List all repo milestones |
| `getUser(username)` | Get GitHub user info |

### TRD-004: Add Specialized Error Types (1h) ✅

| Error Class | Base | Properties |
|-------------|------|-------------|
| `GhRateLimitError` | `GhApiError` | `retryAfter: number` |
| `GhNotFoundError` | `GhApiError` | `resourcePath: string` |

### TRD-005: Rate Limit Handling (3h) ✅

- `api()` detects HTTP 403 with rate limit messages
- Extracts `retry-after` seconds from gh error output
- Throws `GhRateLimitError` with `retryAfter` value (defaults to 3600s)
- `GhNotFoundError` thrown for 404 responses

### TRD-007: Database Migration (3h) ✅

Created `src/lib/db/migrations/00000000000013-create-github-tables.ts`:

**`github_repos` table:** id, project_id, owner, repo, auth_type, auth_config, default_labels, auto_import, webhook_secret, webhook_enabled, sync_strategy, last_sync_at, created_at, updated_at + unique constraint on (project_id, owner, repo)

**`github_sync_events` table:** id, project_id, external_id, event_type, direction, github_payload, foreman_changes, conflict_detected, resolved_with, processed_at + indexes

**Tasks table extensions:** external_repo, github_issue_number, github_milestone, sync_enabled, last_sync_at + performance indexes

---

## Sprint 1 Completed Tasks

### TRD-008: PostgresAdapter GitHub CRUD (4h) ✅

Added types and methods to `src/lib/db/postgres-adapter.ts`:

| Type/Method | Description |
|------------|-------------|
| `GithubRepoRow` | Interface for github_repos table rows |
| `GithubSyncEventRow` | Interface for github_sync_events table rows |
| `UpsertGithubRepoInput` | Input type for upsert operations |
| `upsertGithubRepo(input)` | Insert/update repo config (idempotent ON CONFLICT) |
| `getGithubRepo(projectId, owner, repo)` | Get single repo config |
| `listGithubRepos(projectId)` | List all repos for a project |
| `deleteGithubRepo(id)` | Delete a repo config |
| `recordGithubSyncEvent(input)` | Record sync audit event |
| `listGithubSyncEvents(projectId, externalId?, limit?)` | List sync events |

Also extended `listTasks()` with `externalId` and `labels` filters.

Updated `createTask()` to insert new GitHub-specific columns.

### TRD-009: tRPC GitHub Router (3h) ✅

Added `githubRouter` to `src/daemon/router.ts`:

| Procedure | Type | Description |
|----------|------|-------------|
| `github.getIssue` | query | Fetch single GitHub issue |
| `github.listIssues` | query | List issues with filters |
| `github.listLabels` | query | List repository labels |
| `github.listMilestones` | query | List repository milestones |
| `github.getUser` | query | Get GitHub user info |
| `github.upsertRepo` | mutation | Configure a GitHub repo |
| `github.listRepos` | query | List repos for a project |
| `github.getRepo` | query | Get single repo config |
| `github.deleteRepo` | mutation | Delete repo config |
| `github.listSyncEvents` | query | List sync event audit log |

Registered `githubRouter` on `appRouter`.

### TRD-010: `foreman issue view` CLI (3h) ✅

`src/cli/commands/issue.ts` — `issue view --repo owner/repo --issue 142`

Shows issue details: state, author, dates, milestone, assignees, labels, body, URL.

### TRD-011: `foreman issue import` CLI (6h) ✅

`src/cli/commands/issue.ts` — `foreman issue import` with:

- `--issue N` — single issue import
- `--label`, `--milestone`, `--assignee` — bulk import with filters
- `--dry-run` — preview without creating tasks
- `--sync` — enable bi-directional sync flag on imported tasks

Idempotent: skips tasks already imported (by external_id check).

### TRD-012: PostgresAdapter GitHub Tests (4h) ✅

`src/lib/__tests__/postgres-adapter-github.test.ts` — 9 passing tests validating:
- Type shape for `GithubRepoRow` and `GithubSyncEventRow`
- All 6 new CRUD method functions exist on `PostgresAdapter`
- `auth_config` handles both `pat` and `app` auth types

---

## Files Modified/Created

| File | Change |
|------|--------|
| `src/lib/gh-cli.ts` | Extended: +GhRateLimitError +GhNotFoundError +Issue CRUD +Helpers +Rate limit detection |
| `src/lib/__tests__/gh-cli-issue.test.ts` | **Created:** 22 tests |
| `src/lib/db/migrations/00000000000013-create-github-tables.ts` | **Created** |
| `src/lib/db/postgres-adapter.ts` | Extended: +GithubRepoRow +GithubSyncEventRow +CRUD methods +listTasks filters +createTask GitHub cols |
| `src/lib/__tests__/postgres-adapter-github.test.ts` | **Created:** 9 tests |
| `src/daemon/router.ts` | Extended: +githubRouter +10 procedures |
| `src/cli/commands/issue.ts` | **Created:** issue view/list/import/configure/labels/milestones |
| `src/cli/index.ts` | **Modified:** +issueCommand registered |

---

## Type Check + Test Results

```
$ npx tsc --noEmit
# No errors

$ npx vitest run src/lib/__tests__/gh-cli-issue.test.ts \
    src/lib/__tests__/gh-cli.test.ts \
    src/lib/__tests__/postgres-adapter-github.test.ts

✓ 3 test files passed
✓ 51 tests passed
```

---

## What's Next (Sprint 2)

| Task | Description | Est |
|------|-------------|-----|
| TRD-022 | `github.syncIssues` tRPC procedure (create/push/pull/bidirectional) | 6h |
| TRD-023 | Conflict resolution (foreman-wins/github-wins/manual/last-write-wins) | 5h |
| TRD-025 | `foreman issue sync --create` (GitHub Issues for Foreman tasks) | 5h |
| TRD-026 | Record sync events in github_sync_events | 3h |
| TRD-028 | Sync command integration tests | 5h |

---

*Report generated: 2026-04-28*
