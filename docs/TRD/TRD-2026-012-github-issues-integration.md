# TRD-2026-012: GitHub Issues Integration

**Document ID:** TRD-2026-012
**Version:** 1.0
**Status:** Draft
**Date:** 2026-04-28
**PRD Reference:** PRD-2026-011 (GitHub Issues Integration)
**Satisfies:** G-1 through G-9, FR-1 through FR-8

---

## Architecture Decision Record

### ADR-001: Extend GhCli for Issue Operations (replaces new GitHub SDK)

**Chosen approach:** Extend the existing `GhCli` class in `src/lib/gh-cli.ts` to support Issue CRUD operations via `gh api`. All GitHub API calls route through `GhCli.api()`.

**Rationale:** The existing `GhCli` class already handles authentication (PAT via `gh auth status`), repository cloning, and API calls. Adding Issue operations to the same class maintains consistency: credential management stays in one place, error handling is uniform, and the test suite is simpler. Introducing a new "GitHub SDK" would duplicate auth logic.

**Alternatives considered:**
- **New `@octokit/rest` package:** Rejected — adds a dependency that manages tokens separately from `gh`. Foreman should use `gh` for all GitHub operations to leverage OS keychain auth and token refresh.
- **New `GithubClient` class:** Rejected — same auth duplication as Octokit. The existing `GhCli` pattern is sufficient.

---

## 1. System Architecture

### 1.1 Component Overview

```
┌─────────────────────────────────────────────────────────────────────────┐
│                         CLI Layer (src/cli/commands/)                     │
│   foreman issue import | sync | create | view | update | webhook | dispatch│
│   foreman issue configure                                                │
└──────────────────────────────┬──────────────────────────────────────────┘
                               │
                    ~/.foreman/daemon.sock  (mode 0600)
                               │
┌──────────────────────────────▼──────────────────────────────────────────┐
│                    ForemanDaemon (src/daemon/)                             │
│   - Fastify HTTP server + tRPC router                                     │
│   - Existing: projects, tasks, runs, events, messages routers             │
│   - NEW: github router (issues, repos, webhooks)                          │
└──────────────────────────────────────────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────────┐
│                    PostgresAdapter (src/lib/db/)                          │
│   - Existing: projects, tasks, runs, events tables                         │
│   - NEW: github_repos, github_issue_sync, github_sync_events tables       │
└──────────────────────────────────────────────────────────────────────────┘
                                               │
                              ┌────────────────▼────────────────┐
                              │       GhCli (src/lib/gh-cli.ts) │
                              │  Extended: Issue CRUD, labels,   │
                              │  milestones, comments, links    │
                              └─────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────┐
│                     Supporting Infrastructure                             │
│  ProjectRegistry ──► ~/.foreman/projects.json                             │
│  GhCli ────────────► gh api | gh auth status | gh repo clone              │
│  WorktreeManager ─► ~/.foreman/worktrees/<project-id>/                    │
│  PoolManager ─────► Postgres connection pool (size=20)                    │
│  DaemonManager ───► ~/.foreman/daemon.pid                                  │
└──────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Component Responsibilities

| Component | Responsibility | Location | Change |
|-----------|---------------|----------|--------|
| `GhCli` | GitHub API via `gh api`, auth status. Extended for Issue CRUD, labels, milestones. | `src/lib/gh-cli.ts` | **Extend** |
| `PostgresAdapter` | Database operations. New methods for github_repos, github_issue_sync. | `src/lib/db/postgres-adapter.ts` | **Extend** |
| `TrpcRouter` | tRPC procedures. New github router: issue operations, webhook handlers. | `src/daemon/router.ts` | **Extend** |
| `TrpcClient` | CLI-side tRPC client. Existing client used unchanged. | `src/lib/trpc-client.ts` | — |
| `ForemanDaemon` | HTTP server + tRPC middleware. Runs unchanged. | `src/daemon/index.ts` | — |
| `DaemonManager` | Daemon lifecycle. No changes. | `src/lib/daemon-manager.ts` | — |
| `ProjectRegistry` | Project metadata. No changes. | `src/lib/project-registry.ts` | — |
| `WorktreeManager` | Worktree lifecycle. No changes. | `src/lib/worktree-manager.ts` | — |

### 1.3 Data Flow: Issue Import

```
foreman issue import --repo owner/repo --issue 142
  │
  ├─► TrpcClient.github.getIssue({ owner, repo, issueNumber: 142 }) → ForemanDaemon
  │
  ├─► GhCli.api("GET /repos/{owner}/{repo}/issues/{issue_number}") → GitHub API
  │
  ├─► GhCli.api("GET /repos/{owner}/{repo}/issues/{issue_number}/labels") → GitHub API
  │
  ├─► GhCli.api("GET /repos/{owner}/{repo}/milestones/{milestone_number}") → GitHub API
  │
  ├─► PostgresAdapter.createTask(projectId, {
  │       title: issue.title,
  │       description: issue.body,
  │       external_id: "github:{owner}/{repo}#{issue_number}",
  │       labels: issue.labels.map(l => "github:" + l.name),
  │       assignee: issue.assignees[0]?.login,
  │       milestone: issue.milestone?.title
  │    })
  │
  └─► console.log("Imported GitHub Issue #142 as task task-abc")
```

### 1.4 Data Flow: Bi-directional Sync

```
foreman issue sync --repo owner/repo --bidirectional
  │
  ├─► TrpcClient.github.listTasksWithExternalId({ projectId }) → tasks with external_id
  │
  ├─► For each task with external_id:
  │    ├─► GhCli.api("GET /repos/{owner}/{repo}/issues/{number}") → latest state
  │    └─► PostgresAdapter.updateTask(projectId, taskId, updates) → diff
  │
  ├─► For each GitHub issue without external_id match:
  │    ├─► PostgresAdapter.createTask(...) → create new Foreman task
  │
  ├─► PostgresAdapter.upsertGithubRepo({ owner, repo, ... }) → update last_sync_at
  │
  └─► console.log("Synced N tasks with GitHub Issues")
```

### 1.5 Data Flow: Webhook Processing

```
GitHub sends POST to http://foreman:3847/webhooks/github
  │
  ├─► ForemanDaemon receives webhook (raw body + signature headers)
  │
  ├─► Validate HMAC-SHA256 signature using repo's webhook_secret
  │
  ├─► Parse event_type from X-GitHub-Event header
  │
  ├─► Switch on event_type:
  │    ├─► issues.opened → create task, link to external_id
  │    ├─► issues.closed → update task status to 'merged'
  │    ├─► issues.labeled → update task labels (add github: prefix)
  │    └─► issues.unlabeled → update task labels (remove github: prefix)
  │
  ├─► PostgresAdapter.recordSyncEvent(...) → log webhook event
  │
  └─► Return 200 OK (acknowledge receipt)
```

### 1.6 Data Flow: Branch-to-Issue Linking

```
foreman run --task task-142
  │
  ├─► PostgresAdapter.getTask(projectId, taskId) → task with external_id
  │
  ├─► Extract GitHub issue number from external_id
  │
  ├─► WorktreeManager.create(projectId, seedId, branchName) → branch "foreman/task-142"
  │
  ├─► GhCli.api("POST /repos/{owner}/{repo}/issues/{number}/links", { ... })
  │    OR: branch naming convention "foreman/{issue_number}" auto-links
  │
  └─► First commit message includes: "Foreman task: task-142, Fixes #{issue_number}"
```

### 1.7 Technology Choices

| Concern | Choice | Rationale |
|---------|--------|-----------|
| GitHub API | `gh api` via extended GhCli | Required by PRD; uses OS keychain auth, no token management |
| Issue storage | Postgres (github_repos, github_issue_sync tables) | Consistent with existing tRPC/Postgres architecture |
| Webhook transport | Fastify route in ForemanDaemon | Existing daemon; no separate process needed |
| Webhook security | HMAC-SHA256 signature validation | Standard GitHub webhook security |
| Bi-directional sync | Webhook-first, polling fallback | Real-time via webhooks, offline resilience via polling |
| Conflict resolution | Last-write-wins (configurable per strategy) | Simple, predictable. PRDs specified strategies. |
| Rate limiting | Exponential backoff with Retry-After header | Standard GitHub API rate limit handling |

---

## 2. Database Schema Extensions

### 2.1 New Tables

```sql
-- github_repos: Repository configuration for GitHub integration
CREATE TABLE github_repos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  owner TEXT NOT NULL,
  repo TEXT NOT NULL,
  auth_type TEXT NOT NULL CHECK (auth_type IN ('pat', 'app')),
  auth_config JSONB NOT NULL,  -- encrypted PAT or GitHub App config
  default_labels TEXT[] DEFAULT '{}',
  auto_import BOOLEAN DEFAULT false,
  webhook_secret TEXT,
  webhook_enabled BOOLEAN DEFAULT false,
  sync_strategy TEXT DEFAULT 'github-wins' CHECK (sync_strategy IN ('foreman-wins', 'github-wins', 'manual', 'last-write-wins')),
  last_sync_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(project_id, owner, repo)
);

-- github_sync_events: Audit log for sync operations
CREATE TABLE github_sync_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  external_id TEXT NOT NULL,  -- "github:{owner}/{repo}#{number}"
  event_type TEXT NOT NULL,   -- 'issue_opened', 'issue_closed', 'sync_push', 'sync_pull'
  direction TEXT NOT NULL CHECK (direction IN ('to_github', 'from_github')),
  github_payload JSONB,
  foreman_changes JSONB,
  conflict_detected BOOLEAN DEFAULT false,
  resolved_with TEXT,  -- 'foreman', 'github', 'manual', null
  processed_at TIMESTAMPTZ DEFAULT now(),
  INDEX idx_github_sync_events_project (project_id),
  INDEX idx_github_sync_events_external_id (external_id)
);

-- Extend tasks table (already exists, add columns via migration):
ALTER TABLE tasks ADD COLUMN external_repo TEXT;  -- "owner/repo" from GitHub
ALTER TABLE tasks ADD COLUMN github_issue_number INTEGER;  -- Issue number only
ALTER TABLE tasks ADD COLUMN github_milestone TEXT;
ALTER TABLE tasks ADD COLUMN sync_enabled BOOLEAN DEFAULT false;
ALTER TABLE tasks ADD COLUMN last_sync_at TIMESTAMPTZ;

-- Unique constraint on external_id (already exists, but ensure not null for synced tasks)
-- Note: external_id already exists in tasks table (from earlier TRD)
```

### 2.2 Indexes

```sql
-- Performance indexes for sync operations
CREATE INDEX idx_github_repos_project ON github_repos(project_id);
CREATE INDEX idx_tasks_external_repo ON tasks(external_repo) WHERE external_repo IS NOT NULL;
CREATE INDEX idx_tasks_github_issue ON tasks(external_repo, github_issue_number) 
  WHERE external_repo IS NOT NULL AND github_issue_number IS NOT NULL;
```

---

## 3. Master Task List

### Sprint 0: GitHub API Extension + Issue CRUD

**Goal:** Extend GhCli for Issue operations. Implement `foreman issue import` and `foreman issue view`.

| TRD-001 | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-002 | Extend GhCli: add `getIssue()`, `listIssues()`, `createIssue()`, `updateIssue()` methods | 4h | FR-1 | AC-1.3, AC-1.4, AC-1.5, AC-1.6 |
| TRD-003 | Extend GhCli: add `listLabels()`, `listMilestones()`, `getUser()` helpers | 2h | FR-1 | AC-1.3 |
| TRD-004 | Add gh-api error types: `GhRateLimitError`, `GhNotFoundError` | 1h | FR-1 | AC-1.7, AC-1.8 |
| TRD-005 | Add rate limit handling: parse `X-RateLimit-Remaining`, implement retry with backoff | 3h | FR-1 | AC-1.7 |
| TRD-006 | Write GhCli Issue extension unit tests (mock gh api) | 4h | FR-1 | AC-1.7, AC-1.8 |
| TRD-007 | Add `github_repos` and `github_sync_events` table migrations | 3h | FR-1, FR-2 | AC-1.9 |
| TRD-008 | Extend PostgresAdapter: `upsertGithubRepo()`, `getGithubRepo()`, `listGithubRepos()` | 4h | FR-2 | AC-2.3 |
| TRD-009 | Add tRPC github router stub to TrpcRouter: `github.getIssue`, `github.listIssues` | 3h | FR-1 | AC-1.3, AC-1.4 |
| TRD-010 | Implement `foreman issue view --repo owner/repo --issue 142` CLI command | 3h | FR-1 | AC-1.4 |
| TRD-011 | Implement `foreman issue import --repo owner/repo --issue 142` CLI command | 6h | FR-2 | AC-2.1, AC-2.3, AC-2.7 |
| TRD-012 | Write import command integration tests | 4h | FR-2 | AC-2.1, AC-2.4 |

---

### Sprint 1: Bulk Import + Filter-Based Import

**Goal:** Support filter-based import (by label, milestone, assignee, state). `dry-run` preview.

| TRD-013 | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-014 | Extend GhCli: add `listIssues()` with filter parameters (label, milestone, assignee, state, since) | 4h | FR-2 | AC-1.3, AC-2.2 |
| TRD-015 | Implement `foreman issue import --filter --label bug --state open` for bulk import | 6h | FR-2 | AC-2.2, AC-2.4, AC-2.5 |
| TRD-016 | Implement `--dry-run` flag: preview what would be imported without creating tasks | 3h | FR-2 | AC-2.4 |
| TRD-017 | Implement `--sync` flag: enable bi-directional sync for imported tasks | 3h | FR-3 | AC-2.5 |
| TRD-018 | Handle duplicate import: Issue already imported → update existing task | 3h | FR-2 | AC-2.6 |
| TRD-019 | Preserve GitHub labels as `github:{label-name}` in Foreman labels | 2h | FR-2 | AC-2.7 |
| TRD-020 | Write bulk import integration tests | 4h | FR-2 | AC-2.2, AC-2.4, AC-2.6 |

---

### Sprint 2: Bi-directional Sync Command

**Goal:** `foreman issue sync` with create, push, pull, and bidirectional modes.

| TRD-021 | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-022 | Implement tRPC `github.syncIssues` procedure: handle push/pull/bidirectional | 6h | FR-3 | AC-3.2, AC-3.3, AC-3.4 |
| TRD-023 | Implement conflict resolution strategies: `--strategy foreman-wins/github-wins/manual/last-write-wins` | 5h | FR-3 | AC-3.5 |
| TRD-024 | Track last sync timestamp per task to avoid redundant API calls | 3h | FR-3 | AC-3.6 |
| TRD-025 | Implement `foreman issue sync --create`: create GitHub Issues for Foreman tasks without external_id | 5h | FR-3 | AC-3.1 |
| TRD-026 | Record sync events in `github_sync_events` table for audit trail | 3h | FR-3 | AC-3.6 |
| TRD-027 | Implement `--auto` flag: skip confirmation prompts | 2h | FR-2 | — |
| TRD-028 | Write sync command integration tests (mock GitHub API) | 5h | FR-3 | AC-3.2, AC-3.5, AC-3.6 |

---

### Sprint 3: Webhook Handler

**Goal:** Real-time sync via GitHub webhooks. Handle all Issue lifecycle events.

| TRD-029 | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-030 | Add Fastify route for webhook: `POST /webhooks/github` | 3h | FR-4 | AC-4.1 |
| TRD-031 | Implement HMAC-SHA256 signature validation | 3h | FR-4 | AC-4.3 |
| TRD-032 | Implement issue event handlers: opened, edited, closed, reopened | 4h | FR-4 | AC-4.2 |
| TRD-033 | Implement label event handlers: labeled, unlabeled | 3h | FR-4 | AC-4.2, AC-8.5 |
| TRD-034 | Implement assignee event handlers: assigned, unassigned | 2h | FR-4 | AC-4.2 |
| TRD-035 | Implement idempotency: skip duplicate webhook events | 3h | FR-4 | AC-4.5 |
| TRD-036 | Implement retry queue: failed webhook processing with exponential backoff | 3h | FR-4 | AC-4.6 |
| TRD-037 | Implement `foreman issue webhook --repo owner/repo --enable/--disable` | 4h | FR-4 | AC-4.4 |
| TRD-038 | Generate and store webhook secret per repository | 2h | FR-4 | AC-4.3 |
| TRD-039 | Write webhook integration tests (mock GitHub payload signatures) | 4h | FR-4 | AC-4.1, AC-4.3, AC-4.5 |

---

### Sprint 4: Branch-to-Issue Linking

**Goal:** Auto-link Foreman branches to GitHub Issues. PR auto-close via commit convention.

| TRD-040 | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-041 | Implement branch naming convention: `foreman/{external_id}` links to Issue | 3h | FR-5 | AC-5.1 |
| TRD-042 | Implement Issue Links API: `POST /repos/{owner}/{repo}/issues/{issue_number}/links` | 4h | FR-5 | AC-5.2 |
| TRD-043 | Update finalize phase: append "Fixes #{issue_number}" to merge commit message | 4h | FR-5 | AC-5.3 |
| TRD-044 | Handle branch unlink on task cancellation/reset | 2h | FR-5 | AC-5.4 |
| TRD-045 | Write branch-linking integration tests | 3h | FR-5 | AC-5.1, AC-5.2, AC-5.3 |

---

### Sprint 5: GitHub App Integration

**Goal:** GitHub App authentication for organization-wide repository access.

| TRD-046 | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-047 | Implement GitHub App JWT generation for installation access | 4h | FR-6 | AC-6.2 |
| TRD-048 | Implement App installation token refresh before expiry | 3h | FR-6 | AC-6.3 |
| TRD-049 | Store App credentials encrypted in `github_repos.auth_config` | 3h | FR-6 | AC-6.2 |
| TRD-050 | Implement `foreman issue configure --app`: generate GitHub App manifest | 4h | FR-6 | AC-6.1 |
| TRD-051 | Implement App auth detection: use App over PAT when available | 2h | FR-6 | AC-6.5 |
| TRD-052 | Implement per-repository access control via App permissions | 3h | FR-6 | AC-6.4 |
| TRD-053 | Write GitHub App integration tests | 4h | FR-6 | AC-6.2, AC-6.3, AC-6.5 |

---

### Sprint 6: GitHub Actions Integration

**Goal:** GitHub Actions workflow for dispatching Foreman agents. `foreman issue dispatch` CLI trigger.

| TRD-054 | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-055 | Create GitHub Actions workflow template: `.github/workflows/foreman-dispatch.yml` | 3h | FR-7 | AC-7.1 |
| TRD-056 | Implement `foreman issue dispatch --repo owner/repo --issue 142` CLI command | 4h | FR-7 | AC-7.2, AC-7.3 |
| TRD-057 | Add status check on PR: Foreman agent status visible in GitHub PR checks | 3h | FR-7 | AC-7.4 |
| TRD-058 | Implement `--max-agents` limit enforcement in dispatch | 2h | FR-7 | AC-7.5 |
| TRD-059 | Write dispatch command integration tests | 3h | FR-7 | AC-7.2, AC-7.5 |

---

### Sprint 7: Label-Based Dispatch Control

**Goal:** `foreman:dispatch`, `foreman:skip`, `foreman:priority:*` labels control agent dispatch.

| TRD-060 | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-061 | Implement dispatch label detection: `foreman:dispatch` triggers auto-dispatch | 4h | FR-8 | AC-8.1 |
| TRD-062 | Implement skip label: `foreman:skip` prevents auto-dispatch | 2h | FR-8 | AC-8.2 |
| TRD-063 | Implement priority label mapping: `foreman:priority:0-4` → Foreman priority scale | 3h | FR-8 | AC-8.3 |
| TRD-064 | Implement `foreman:needs-triage` label: pauses dispatch pending human review | 3h | FR-8 | AC-8.4 |
| TRD-065 | Implement webhook-triggered auto-dispatch: new Issue with `foreman:dispatch` label | 4h | FR-8 | AC-8.1, AC-8.5 |
| TRD-066 | Implement label removal handling: remove `foreman:dispatch` → cancel pending dispatch | 3h | FR-8 | AC-8.5 |
| TRD-067 | Implement default behavior config: no labels → configurable default | 2h | FR-8 | AC-8.6 |
| TRD-068 | Write label-based dispatch integration tests | 4h | FR-8 | AC-8.1, AC-8.2, AC-8.3, AC-8.5 |

---

### Sprint 8: GitHub Enterprise Support + Polish

**Goal:** GitHub Enterprise (custom hostname) support. Configuration file. Doctor update.

| TRD-069 | Description | Est | Satisfies | Validates ACs |
|---------|------------|-----|----------|---------------|
| TRD-070 | Add GitHub Enterprise support: configurable `github.com` hostname | 3h | FR-1 | AC-1.9 |
| TRD-071 | Create `~/.foreman/github.toml` configuration file | 4h | FR-1, FR-2 | — |
| TRD-072 | Update `foreman doctor`: check gh auth, webhook endpoint reachability, rate limit status | 4h | NFR | — |
| TRD-073 | Implement graceful degradation: PAT fallback if GitHub App unavailable | 3h | NFR | — |
| TRD-074 | Add `--auto` flag support to all sync commands | 2h | FR-2 | — |
| TRD-075 | Performance test: 100 concurrent sync operations < 500ms p95 | 3h | NFR | — |

---

## 4. Test Tasks

For every implementation task, a corresponding TEST task is generated. Tests are co-located with implementation in `src/lib/__tests__/` and `src/cli/__tests__/`.

| Test Task | Verifies | Depends |
|-----------|----------|---------|
| TRD-002-TEST | GhCli.getIssue() returns parsed Issue, throws GhApiError on 404 | TRD-002 |
| TRD-003-TEST | GhCli.listLabels() and listMilestones() work | TRD-003 |
| TRD-004-TEST | GhRateLimitError and GhNotFoundError thrown correctly | TRD-004 |
| TRD-005-TEST | Rate limit headers parsed; retry with exponential backoff | TRD-005 |
| TRD-006-TEST | GhCli Issue operations via mocked `gh api` | TRD-006 |
| TRD-007-TEST | github_repos and github_sync_events migrations run successfully | TRD-007 |
| TRD-008-TEST | upsertGithubRepo/getGithubRepo/listGithubRepos CRUD round-trip | TRD-008 |
| TRD-009-TEST | tRPC github.getIssue and github.listIssues procedures | TRD-009 |
| TRD-010-TEST | `foreman issue view` renders Issue details correctly | TRD-010 |
| TRD-011-TEST | `foreman issue import --issue 142` creates mapped task | TRD-011 |
| TRD-012-TEST | Import command with mock GitHub API | TRD-012 |
| TRD-014-TEST | listIssues() with filters (label, milestone, assignee, state, since) | TRD-014 |
| TRD-015-TEST | Bulk import creates multiple tasks from filtered GitHub Issues | TRD-015 |
| TRD-016-TEST | `--dry-run` shows preview without creating tasks | TRD-016 |
| TRD-017-TEST | `--sync` flag enables bi-directional sync | TRD-017 |
| TRD-018-TEST | Duplicate import updates existing task, doesn't create duplicate | TRD-018 |
| TRD-019-TEST | GitHub labels prefixed with "github:" in Foreman task labels | TRD-019 |
| TRD-020-TEST | Bulk import integration with real GhCli (mocked gh api) | TRD-020 |
| TRD-022-TEST | `github.syncIssues` tRPC procedure handles push/pull/bidirectional | TRD-022 |
| TRD-023-TEST | Conflict resolution strategies produce correct outcomes | TRD-023 |
| TRD-024-TEST | last_sync_at updated correctly; redundant syncs avoided | TRD-024 |
| TRD-025-TEST | `--create` creates GitHub Issues for Foreman tasks without external_id | TRD-025 |
| TRD-026-TEST | Sync events recorded in github_sync_events table | TRD-026 |
| TRD-027-TEST | `--auto` flag skips confirmation prompts | TRD-027 |
| TRD-028-TEST | Sync command end-to-end with mock GitHub API | TRD-028 |
| TRD-030-TEST | Webhook endpoint receives and validates GitHub payloads | TRD-030 |
| TRD-031-TEST | Invalid HMAC signatures rejected with 401 | TRD-031 |
| TRD-032-TEST | issues.opened/edited/closed/reopened events update tasks correctly | TRD-032 |
| TRD-033-TEST | issues.labeled/unlabeled events update task labels | TRD-033 |
| TRD-034-TEST | issues.assigned/unassigned events update task assignee | TRD-034 |
| TRD-035-TEST | Duplicate webhook events produce same state (idempotent) | TRD-035 |
| TRD-036-TEST | Failed webhook events retried with exponential backoff | TRD-036 |
| TRD-037-TEST | `foreman issue webhook --enable` registers webhook with GitHub | TRD-037 |
| TRD-038-TEST | Webhook secret generated and stored per repository | TRD-038 |
| TRD-039-TEST | Webhook end-to-end with mock GitHub payload + signature | TRD-039 |
| TRD-041-TEST | Branch `foreman/task-142` linked to Issue #142 | TRD-041 |
| TRD-042-TEST | Issue Links API used for explicit linking | TRD-042 |
| TRD-043-TEST | Merge commit message includes "Fixes #{issue_number}" | TRD-043 |
| TRD-044-TEST | Branch unlinked on task cancellation/reset | TRD-044 |
| TRD-045-TEST | Branch-linking integration tests | TRD-045 |
| TRD-047-TEST | App JWT generated correctly for installation | TRD-047 |
| TRD-048-TEST | Installation tokens refreshed before expiry | TRD-048 |
| TRD-049-TEST | App credentials encrypted in auth_config | TRD-049 |
| TRD-050-TEST | `foreman issue configure --app` generates valid manifest | TRD-050 |
| TRD-051-TEST | App auth used over PAT when both available | TRD-051 |
| TRD-052-TEST | Per-repo access control enforced via App permissions | TRD-052 |
| TRD-053-TEST | GitHub App integration with mocked App operations | TRD-053 |
| TRD-055-TEST | Actions workflow template deploys correctly | TRD-055 |
| TRD-056-TEST | `foreman issue dispatch` triggers agent from GitHub context | TRD-056 |
| TRD-057-TEST | PR status checks show Foreman agent status | TRD-057 |
| TRD-058-TEST | `--max-agents` limit enforced in dispatch | TRD-058 |
| TRD-059-TEST | Dispatch command with mocked GitHub context | TRD-059 |
| TRD-061-TEST | `foreman:dispatch` label triggers auto-dispatch | TRD-061 |
| TRD-062-TEST | `foreman:skip` label prevents auto-dispatch | TRD-062 |
| TRD-063-TEST | Priority labels map to Foreman priority 0-4 correctly | TRD-063 |
| TRD-064-TEST | `foreman:needs-triage` pauses dispatch pending human review | TRD-064 |
| TRD-065-TEST | Webhook-triggered auto-dispatch on `foreman:dispatch` label | TRD-065 |
| TRD-066-TEST | Label removal cancels pending dispatch | TRD-066 |
| TRD-067-TEST | Default behavior configurable when no labels | TRD-067 |
| TRD-068-TEST | Label-based dispatch with mock webhook events | TRD-068 |
| TRD-070-TEST | GitHub Enterprise hostname configurable and works | TRD-070 |
| TRD-071-TEST | github.toml parsed and applied to all commands | TRD-071 |
| TRD-072-TEST | `foreman doctor` checks gh auth, webhook reachability, rate limits | TRD-072 |
| TRD-073-TEST | PAT fallback used when App unavailable | TRD-073 |
| TRD-074-TEST | `--auto` supported on all sync commands | TRD-074 |
| TRD-075-TEST | 100 concurrent syncs < 500ms p95 | TRD-075 |

**Total implementation tasks:** 75
**Total test tasks:** 75
**Total tasks:** 150

---

## 5. Sprint Planning

### Sprint 0: GitHub API Extension (13 days, 24h)
- TRD-002 through TRD-012
- Goal: GhCli supports Issue CRUD. `foreman issue view` and `foreman issue import --issue 142` work.
- **Critical path gate:** `foreman issue import --repo owner/repo --issue 142` creates task with full GitHub metadata mapping.

### Sprint 1: Bulk Import (17 days, 21h)
- TRD-014 through TRD-020
- Goal: Filter-based import (by label, milestone, assignee, state). `dry-run` preview. `--sync` flag.
- **Critical path gate:** `foreman issue import --repo owner/repo --label bug` imports all open Issues with `bug` label.

### Sprint 2: Bi-directional Sync (19 days, 24h)
- TRD-022 through TRD-028
- Goal: `foreman issue sync` with all modes (create, push, pull, bidirectional). Conflict resolution.
- **Critical path gate:** `foreman issue sync --bidirectional` keeps Foreman tasks and GitHub Issues in sync.

### Sprint 3: Webhook Handler (20 days, 26h)
- TRD-030 through TRD-039
- Goal: Real-time sync via GitHub webhooks. All Issue lifecycle events handled.
- **Critical path gate:** `foreman issue webhook --enable` → GitHub Issue update → Foreman task updated within 5 seconds.

### Sprint 4: Branch-to-Issue Linking (12 days, 16h)
- TRD-041 through TRD-045
- Goal: Foreman branches auto-linked to GitHub Issues. PR merge auto-closes Issue.
- **Critical path gate:** `foreman run --task task-142` → branch `foreman/task-142` → PR with "Fixes #142" → Issue #142 closed.

### Sprint 5: GitHub App Integration (16 days, 19h)
- TRD-047 through TRD-053
- Goal: GitHub App authentication. Organization-wide repo access. App installation flow.
- **Critical path gate:** `foreman issue configure --app` → App manifest → install → use App auth over PAT.

### Sprint 6: GitHub Actions Integration (12 days, 15h)
- TRD-055 through TRD-059
- Goal: Actions workflow template. `foreman issue dispatch` CLI. PR status checks.
- **Critical path gate:** `foreman issue dispatch --repo owner/repo --issue 142` triggers Foreman agent from GitHub context.

### Sprint 7: Label-Based Dispatch Control (18 days, 22h)
- TRD-061 through TRD-068
- Goal: `foreman:dispatch`/`foreman:skip` labels. Priority labels. Webhook-triggered auto-dispatch.
- **Critical path gate:** Add `foreman:dispatch` label to GitHub Issue → Foreman task created + agent dispatched.

### Sprint 8: GitHub Enterprise + Polish (14 days, 19h)
- TRD-070 through TRD-075
- Goal: GitHub Enterprise support. `github.toml` config. `foreman doctor` updates. Performance validated.
- **Critical path gate:** All commands work with custom GitHub Enterprise hostname.

---

## 6. Acceptance Criteria Traceability

| PRD Requirement | Implementation Tasks | Test Tasks | AC Reference |
|----------------|---------------------|------------|-------------|
| **FR-1: GitHub API Client** | TRD-002, TRD-003, TRD-004, TRD-005, TRD-007, TRD-009 | TRD-002-TEST, TRD-003-TEST, TRD-004-TEST, TRD-005-TEST, TRD-006-TEST, TRD-007-TEST, TRD-009-TEST | AC-1.1–AC-1.9 |
| **FR-2: Issue Import Command** | TRD-011, TRD-012, TRD-014, TRD-015, TRD-016, TRD-017, TRD-018, TRD-019, TRD-020 | TRD-010-TEST, TRD-011-TEST, TRD-012-TEST, TRD-014-TEST, TRD-015-TEST, TRD-016-TEST, TRD-017-TEST, TRD-018-TEST, TRD-019-TEST, TRD-020-TEST | AC-2.1–AC-2.8 |
| **FR-3: Issue Sync Command** | TRD-022, TRD-023, TRD-024, TRD-025, TRD-026, TRD-027, TRD-028 | TRD-022-TEST, TRD-023-TEST, TRD-024-TEST, TRD-025-TEST, TRD-026-TEST, TRD-027-TEST, TRD-028-TEST | AC-3.1–AC-3.7 |
| **FR-4: Webhook Handler** | TRD-030, TRD-031, TRD-032, TRD-033, TRD-034, TRD-035, TRD-036, TRD-037, TRD-038, TRD-039 | TRD-030-TEST, TRD-031-TEST, TRD-032-TEST, TRD-033-TEST, TRD-034-TEST, TRD-035-TEST, TRD-036-TEST, TRD-037-TEST, TRD-038-TEST, TRD-039-TEST | AC-4.1–AC-4.6 |
| **FR-5: Branch-to-Issue Linking** | TRD-041, TRD-042, TRD-043, TRD-044, TRD-045 | TRD-041-TEST, TRD-042-TEST, TRD-043-TEST, TRD-044-TEST, TRD-045-TEST | AC-5.1–AC-5.5 |
| **FR-6: GitHub App Integration** | TRD-047, TRD-048, TRD-049, TRD-050, TRD-051, TRD-052, TRD-053 | TRD-047-TEST, TRD-048-TEST, TRD-049-TEST, TRD-050-TEST, TRD-051-TEST, TRD-052-TEST, TRD-053-TEST | AC-6.1–AC-6.5 |
| **FR-7: GitHub Actions Integration** | TRD-055, TRD-056, TRD-057, TRD-058, TRD-059 | TRD-055-TEST, TRD-056-TEST, TRD-057-TEST, TRD-058-TEST, TRD-059-TEST | AC-7.1–AC-7.5 |
| **FR-8: Dispatch Label Control** | TRD-061, TRD-062, TRD-063, TRD-064, TRD-065, TRD-066, TRD-067, TRD-068 | TRD-061-TEST, TRD-062-TEST, TRD-063-TEST, TRD-064-TEST, TRD-065-TEST, TRD-066-TEST, TRD-067-TEST, TRD-068-TEST | AC-8.1–AC-8.6 |
| **NFR: GitHub Enterprise** | TRD-070 | TRD-070-TEST | AC-1.9 |
| **NFR: Configuration** | TRD-071, TRD-072, TRD-073 | TRD-071-TEST, TRD-072-TEST, TRD-073-TEST | — |
| **NFR: Performance** | TRD-075 | TRD-075-TEST | — |

**Traceability check:** 11/11 requirement groups covered. All ACs mapped to implementation + test tasks.

---

## 7. Design Readiness Gate

| Dimension | Score | Notes |
|-----------|-------|-------|
| Architecture completeness | 4/5 | Extends existing GhCli, PostgresAdapter, and tRPC router. No new patterns introduced. Webhook handled in ForemanDaemon (no new process). |
| Task coverage | 5/5 | Every FR has implementation + test tasks. 100% coverage. |
| Dependency clarity | 4/5 | Sprint 0 must complete before Sprint 1 (GhCli extension is foundation). Sprint 3 (webhook) depends on Sprint 0-2 (API client ready). |
| Estimate confidence | 3/5 | Issue CRUD operations well-understood. Webhook implementation straightforward (standard GitHub pattern). GitHub App has more uncertainty. |
| **Overall** | **4.0** | **PASS — proceed to implementation** |

**Design concerns to monitor:**
1. **GitHub App setup flow:** TRD-050 (App manifest generation) may require research on GitHub App manifest format. Validate before Sprint 5.
2. **Webhook secret generation:** TRD-038 must use cryptographically secure random bytes. Use `crypto.randomBytes(32)` from Node.js.
3. **Rate limit handling:** TRD-005 must track `X-RateLimit-Remaining` across all GhCli API calls. Consider a shared rate limit state object.
4. **Label prefix collision:** TRD-019 uses `github:` prefix for imported labels. Verify no collision with existing Foreman label conventions.

---

## 8. Implementation Readiness

**Recommended startup:** Sprint 0 begins with TRD-002 (GhCli Issue extension) → TRD-007 (migrations) → TRD-008 (PostgresAdapter extensions) → TRD-011 (import command).

**Sprint 0 test-first sequence:**
1. Write TRD-011-TEST first (end-to-end import)
2. Implement GhCli Issue methods to make the test pass
3. Add PostgresAdapter methods
4. Wire tRPC procedures
5. Wire CLI command

**Dependencies on existing TRD-2026-011:**
- `ForemanDaemon` in `src/daemon/index.ts` already exists — webhook route added in TRD-030
- `TrpcRouter` in `src/daemon/router.ts` already exists — github router added in TRD-009
- `PostgresAdapter` in `src/lib/db/postgres-adapter.ts` already exists — github methods added in TRD-008
- `GhCli` in `src/lib/gh-cli.ts` already exists — Issue methods added in TRD-002, TRD-003

**File changes summary:**
| File | Change |
|------|--------|
| `src/lib/gh-cli.ts` | Extend: Issue CRUD, labels, milestones, comments, links |
| `src/lib/db/postgres-adapter.ts` | Extend: github_repos, github_sync_events CRUD |
| `src/daemon/router.ts` | Extend: github router with issue/sync/webhook procedures |
| `src/lib/trpc-client.ts` | No change (procedures added to router) |
| `src/lib/db/migrations/` | New: github_repos, github_sync_events tables |
| `src/cli/commands/` | New: `issue.ts` with import/sync/create/view/update/webhook/dispatch subcommands |

---

## 9. Configuration File

`~/.foreman/github.toml`:
```toml
[auth]
# Option 1: Personal Access Token (via gh auth)
token = "${GITHUB_TOKEN}"  # env var reference

# Option 2: GitHub App
app_id = "${GITHUB_APP_ID}"
app_private_key = "${GITHUB_APP_PRIVATE_KEY}"
installation_id = "${GITHUB_APP_INSTALLATION_ID}"

[defaults]
default_repo = "owner/repo"
default_labels = ["foreman:dispatch"]
auto_sync = true
conflict_strategy = "github-wins"  # foreman-wins | github-wins | manual | last-write-wins

[webhook]
listen_host = "0.0.0.0"
listen_port = 3847
secret = "${FOREMAN_WEBHOOK_SECRET}"

[[repos]]
owner = "myorg"
repo = "myrepo"
labels = ["foreman:dispatch", "foreman:skip"]
auto_import = true
sync_strategy = "github-wins"

[enterprise]
hostname = "github.mycompany.com"
api_base_url = "https://github.mycompany.com/api/v3"
```

---

## 10. CLI Commands Summary

| Command | Description |
|---------|-------------|
| `foreman issue view --repo owner/repo --issue 142` | View GitHub Issue details |
| `foreman issue import --repo owner/repo --issue 142` | Import single Issue as Foreman task |
| `foreman issue import --repo owner/repo --label bug` | Bulk import Issues by label |
| `foreman issue import --repo owner/repo --filter --dry-run` | Preview import without creating tasks |
| `foreman issue sync --repo owner/repo --bidirectional` | Full bi-directional sync |
| `foreman issue sync --repo owner/repo --create` | Create GitHub Issues for Foreman tasks |
| `foreman issue sync --repo owner/repo --strategy github-wins` | Sync with conflict strategy |
| `foreman issue create --repo owner/repo --task task-abc` | Create GitHub Issue from Foreman task |
| `foreman issue webhook --repo owner/repo --enable` | Enable webhook for repository |
| `foreman issue webhook --repo owner/repo --disable` | Disable webhook for repository |
| `foreman issue dispatch --repo owner/repo --issue 142` | Dispatch agent from GitHub context |
| `foreman issue configure --app` | Set up GitHub App authentication |
| `foreman issue configure --list` | List configured repositories |

---

*See also:*
- [[PRD-2026-011: GitHub Issues Integration]]
- [[TRD-2026-011: Multi-Project Orchestrator]]
- [[GhCli in src/lib/gh-cli.ts]]
- [[PostgresAdapter in src/lib/db/postgres-adapter.ts]]

*Tags:* #trd #github #issues #integration #foreman