# PRD: Integrate Foreman with GitHub Issues (Epic)

**Document ID:** PRD-2026-011
**Version:** 1.0
**Created:** 2026-04-28
**Last Updated:** 2026-04-28
**Status:** Draft
**Epic ID:** GH-ISSUE-INT

---

## 1. Product Summary

### 1.1 Problem Statement

Foreman currently tracks tasks in a native Postgres store (`foreman task create`, `foreman run`) with optional fallback to beads_rust (`br`). While functional, this creates several friction points:

1. **Disconnected from GitHub-native workflows**: Issues/PRs on GitHub cannot be directly converted to Foreman tasks. Teams using GitHub Issues for project planning must manually duplicate work.
2. **No bi-directional sync**: Changes in Foreman don't reflect in GitHub and vice versa. Labels, assignees, milestones, and status updates require manual coordination.
3. **Orphaned GitHub Issues**: Features, bugs, and tasks tracked as GitHub Issues never make it into Foreman's pipeline, leading to forgotten work and missed deadlines.
4. **PR-to-Issue linking friction**: GitHub's powerful PR-to-Issue linking (`Fixes #123`, `Closes #456`) is unavailable when work originates in Foreman.

### 1.2 Solution

A first-class GitHub Issues integration that enables Foreman to:

1. **Import GitHub Issues as native tasks** — Pull Issues from any repository into Foreman's task store with full metadata preservation
2. **Bi-directional sync** — Keep Foreman tasks and GitHub Issues in sync: status changes in either system propagate to the other
3. **GitHub-first workflow** — Allow GitHub Issues to serve as the primary task source, with Foreman dispatching agents to GitHub-tracked work
4. **Automatic PR linking** — When Foreman creates branches from GitHub Issues, auto-link the branch to the Issue (via branch naming convention or explicit API calls)
5. **VCS backend abstraction** — Leverage the existing VCS abstraction layer (from PRD-2026-004) to plug in GitHub as a VCS backend

### 1.3 Value Proposition

- **Single source of truth**: GitHub Issues become the canonical task tracker; Foreman dispatches agents from the same backlog
- **No more duplication**: Eliminate the manual step of creating Foreman tasks from GitHub Issues
- **GitHub-native features**: PR-to-Issue linking, automated status via PR merges, label propagation, milestone tracking
- **Flexible deployment**: Teams can choose GitHub-native workflows or Foreman-native workflows (or both simultaneously)
- **Leverages existing work**: Builds on the VCS backend abstraction already planned in PRD-2026-004

---

## 2. User Analysis

### 2.1 Primary Users

| Persona | Description | Pain Point |
|---------|-------------|-------------|
| **GitHub-native Team** | Team using GitHub Issues exclusively for planning | Must manually mirror every Issue as a Foreman task |
| **Hybrid Workflow User** | Uses GitHub for public/async work, Foreman for agent dispatch | Sync issues between two systems; risk of divergence |
| **Open Source Maintainer** | Tracks issues on GitHub, wants AI agent assistance | Issues don't automatically become agent-dispatchable work |
| **Enterprise GitHub User** | Organization with GitHub Enterprise, strict VCS policies | Cannot use Foreman without GitHub integration as VCS backend |

### 2.2 User Journey

#### Journey A: GitHub-First Import

```
1. Team files GitHub Issue: "Add dark mode support" (#142)
2. >>> foreman issue import --repo owner/repo --issue 142 <<<
3. Foreman creates task task-142 with full GitHub metadata
4. Task title, description, labels, assignee synced
5. Agent dispatched to task → branch foreman/task-142 created
6. Branch auto-linked to GitHub Issue via commit convention
7. PR merged → GitHub Issue auto-closed (Fixes #142)
```

#### Journey B: Bi-directional Sync

```
1. Team creates task in Foreman: foreman task create "Refactor auth module"
2. >>> foreman issue sync --create --repo owner/repo <<<
3. GitHub Issue #156 created with task title, linked back to Foreman task
4. Developer updates Issue status on GitHub → Foreman task status updated
5. Foreman task priority changed → GitHub Issue updated
6. Both systems stay in sync automatically
```

#### Journey C: Full GitHub Integration

```
1. >>> foreman issue watch --repo owner/repo --milestone "v2.0" <<<
2. Foreman monitors GitHub webhooks for new/updated Issues
3. New Issue filed → Foreman task auto-created
4. Issue labeled "foreman:dispatch" → Agent auto-dispatched
5. Issue labeled "foreman:skip" → No agent, manual handling only
6. Real-time sync of all status changes
```

---

## 3. Goals & Non-Goals

### 3.1 Goals

| ID | Goal | Success Criteria |
|----|------|-----------------|
| G-1 | Import GitHub Issues as native Foreman tasks | `foreman issue import` creates task with title, description, labels, assignee, milestone |
| G-2 | Bi-directional status sync | Changes in Foreman reflect in GitHub within 5 seconds (webhook delivery target) |
| G-3 | Create GitHub Issues from Foreman tasks | `foreman issue sync --create` pushes task to GitHub as Issue |
| G-4 | Auto-link branches to Issues | Branch `foreman/task-142` auto-linked to Issue #142 via GitHub API |
| G-5 | PR-to-Issue close via merge | Merging PR with "Fixes #142" in description auto-closes Issue |
| G-6 | Webhook-driven real-time sync | Foreman daemon listens for GitHub webhooks, updates tasks on push events |
| G-7 | GitHub Actions integration | GitHub Actions workflow dispatches Foreman agents via CLI |
| G-8 | Label-based dispatch control | Issues labeled `foreman:dispatch` trigger auto-dispatch; `foreman:skip` ignores |
| G-9 | Authentication via GitHub App | Install GitHub App for organization-wide repo access without personal PATs |

### 3.2 Non-Goals

- **Full project management**: This is not a replacement for GitHub Projects (board view, timelines, etc.)
- **GitHub Actions orchestration**: We provide a CLI trigger for Actions, not a workflow engine
- **Two-way code sync**: This integrates task tracking, not code review or file sync
- **GitLab/Bitbucket support**: First-class GitHub only; other VCS backends deferred
- **Real-time collaborative editing**: Conflict resolution for concurrent edits (beyond "last write wins")
- **Offline operation**: Requires GitHub API access; offline mode syncs on reconnect
- **Bulk import/export**: Single-issue and filter-based import only initially

---

## 4. Functional Requirements

### FR-1: GitHub API Client

A typed GitHub API client for all Issue operations.

**Core capabilities:**
- Authenticate via Personal Access Token (PAT) or GitHub App JWT
- List Issues with filtering (label, milestone, assignee, state, since)
- Get single Issue with full metadata
- Create Issue with title, body, labels, assignees, milestone
- Update Issue (title, body, labels, assignees, milestone, state)
- Add/remove Issue labels
- Add Issue comments
- Link branch to Issue (via `head.ref` branch naming convention or ` POST /repos/{owner}/{repo}/issues/{issue_number}/links`)
- Get repository labels and milestones

**API endpoints used:**
```
GET  /repos/{owner}/{repo}/issues
GET  /repos/{owner}/{repo}/issues/{issue_number}
POST /repos/{owner}/{repo}/issues
PATCH /repos/{owner}/{repo}/issues/{issue_number}
GET  /repos/{owner}/{repo}/labels
GET  /repos/{owner}/{repo}/milestones
POST /repos/{owner}/{repo}/issues/{issue_number}/comments
```

**Acceptance Criteria:**
- AC-1.1: Authenticate with PAT stored in `GITHUB_TOKEN` env var
- AC-1.2: Authenticate with GitHub App installation JWT (for org-wide access)
- AC-1.3: List issues filtered by label(s), milestone, assignee, state (open/closed/all)
- AC-1.4: Retrieve full Issue metadata including timeline events
- AC-1.5: Create Issue with all supported fields
- AC-1.6: Update Issue with partial field updates
- AC-1.7: Handle GitHub API rate limits gracefully with retry-after support
- AC-1.8: Handle 404 errors (repo/issue not found) with clear error messages
- AC-1.9: Support GitHub Enterprise (custom `github.com` hostname)

### FR-2: Issue Import Command

`foreman issue import` — Import GitHub Issues as Foreman tasks.

**Command interface:**
```bash
foreman issue import [options]
  --repo <owner/repo>          # Required: target repository
  --issue <number>             # Import single Issue by number
  --filter <query>             # Import Issues matching filter
  --label <name>               # Filter by label (can repeat)
  --milestone <title>           # Filter by milestone title
  --assignee <username>         # Filter by assignee
  --state <open|closed|all>     # Filter by state (default: open)
  --since <ISO-date>           # Import Issues updated since date
  --sync                        # Enable bi-directional sync for imported issues
  --dry-run                     # Preview without creating tasks
  --auto                        # Skip confirmation prompt
```

**Data mapping:**

| GitHub Issue Field | Foreman Task Field |
|-------------------|---------------------|
| `number` | Stored in `external_id` as `github:{owner}/{repo}#{number}` |
| `title` | `title` |
| `body` (markdown) | `description` |
| `labels[].name` | `labels` (prefixed with `github:` to avoid collision) |
| `assignees[].login` | `assignee` (first assignee) |
| `milestone.title` | `milestone` |
| `state` | `status` (open → open, closed → merged/resolved) |
| `created_at` | `created_at` |
| `updated_at` | `updated_at` |

**Acceptance Criteria:**
- AC-2.1: Single Issue import creates task with full metadata mapping
- AC-2.2: Filter-based import creates multiple tasks (batch operation)
- AC-2.3: `external_id` stores GitHub reference for sync tracking
- AC-2.4: `dry-run` shows preview of what would be created
- AC-2.5: `--sync` flag enables bi-directional sync for imported tasks
- AC-2.6: Handles duplicate import (Issue already imported) gracefully — updates existing task
- AC-2.7: Preserves GitHub labels as `github:{label-name}` in Foreman labels
- AC-2.8: Maps milestone title to Foreman milestone field

### FR-3: Issue Sync Command

`foreman issue sync` — Create GitHub Issues from Foreman tasks and sync bidirectionally.

**Command interface:**
```bash
foreman issue sync [options]
  --repo <owner/repo>           # Required: target repository
  --task <task-id>              # Sync single task to GitHub Issue
  --filter <expression>         # Sync tasks matching filter
  --create                      # Create GitHub Issues for Foreman tasks without them
  --push                        # Push Foreman changes to GitHub (one-way)
  --pull                        # Pull GitHub changes to Foreman (one-way)
  --bidirectional               # Full bi-directional sync (default when --sync used)
  --dry-run                     # Preview without making changes
```

**Sync conflict resolution:**
- **Default**: Last-write-wins based on `updated_at` timestamp
- **Foreman wins**: `foreman issue sync --strategy foreman-wins`
- **GitHub wins**: `foreman issue sync --strategy github-wins`
- **Manual**: Prompt user for conflicts (`foreman issue sync --strategy manual`)

**Acceptance Criteria:**
- AC-3.1: `--create` creates GitHub Issues for all Foreman tasks without `external_id`
- AC-3.2: `--bidirectional` keeps both systems in sync on every change
- AC-3.3: `--push` only updates GitHub, never pulls changes
- AC-3.4: `--pull` only updates Foreman, never pushes changes
- AC-3.5: Conflict resolution respects `--strategy` flag
- AC-3.6: Sync records last sync timestamp to avoid redundant API calls
- AC-3.7: Preserves Foreman-only fields (priority, phase, agent) not mapped to GitHub

### FR-4: Webhook Handler

Foreman daemon webhook endpoint for real-time GitHub event processing.

**Webhook events handled:**
| Event | Action | Foreman Response |
|-------|--------|------------------|
| `issues.opened` | new | Create task (if label matches dispatch criteria) |
| `issues.edited` | edited | Update task status/description |
| `issues.closed` | closed | Mark task as merged/resolved |
| `issues.reopened` | reopened | Reset task to open |
| `issues.labeled` | labeled | Update task labels |
| `issues.unlabeled` | unlabeled | Remove task label |
| `issues.assigned` | assigned | Update task assignee |
| `issues.unassigned` | unassigned | Clear task assignee |
| `issue_comment.created` | commented | Add comment to task (as note) |

**Webhook configuration:**
```bash
foreman issue webhook --repo owner/repo --enable
# Outputs: Webhook URL (https://foreman.example.com/webhooks/github)
# Foreman daemon must be accessible from internet (or use ngrok for local dev)
```

**Security:**
- Validate webhook signature (HMAC SHA-256)
- Whitelist allowed repositories
- Rate limit per source IP

**Acceptance Criteria:**
- AC-4.1: Webhook endpoint receives and validates GitHub webhook payloads
- AC-4.2: All listed events handled with correct Foreman task updates
- AC-4.3: Webhook signature validation rejects invalid payloads
- AC-4.4: Webhook can be enabled/disabled per repository
- AC-4.5: Duplicate events handled idempotently (same event processed twice = no change)
- AC-4.6: Failed webhook processing retried with exponential backoff

### FR-5: Branch-to-Issue Linking

Automatically link Foreman worktree branches to GitHub Issues.

**Linking mechanisms:**

1. **Branch naming convention** (default):
   - Branch `foreman/task-142` linked to Issue #142
   - Detected via `gh pr list --head foreman/task-142` or `gh issue view 142`

2. **GitHub Issue Links API**:
   ```bash
   POST /repos/{owner}/{repo}/issues/{issue_number}/links
   {
     "issue": { "number": 142 },
     "repository": { "full_name": "owner/repo" }
   }
   ```

3. **Commit message convention**:
   - Branch creation commits include "Closes #142" in first commit message
   - Finalize phase appends "Fixes #{issue_number}" to merge commit

**Acceptance Criteria:**
- AC-5.1: Branch naming convention auto-detected by `foreman run`
- AC-5.2: Issue Links API used when available (GitHub API support)
- AC-5.3: Commit messages include Issue reference for GitHub auto-close
- AC-5.4: Branch unlinked from Issue when task cancelled or reset
- AC-5.5: Works for both new Issues created via Foreman and pre-existing Issues

### FR-6: GitHub App Integration

Support GitHub App authentication for organization-wide repository access.

**GitHub App workflow:**
1. Admin installs GitHub App on organization
2. App granted access to specific repositories (or all)
3. Foreman uses App installation JWT for API calls
4. No personal PAT required; access revoked when App uninstalled

**Benefits:**
- Scoped access (no need for broad PAT permissions)
- Audit trail via GitHub App events
- Organization-wide installation without personal credentials

**Configuration:**
```bash
foreman issue configure --app                     # Start GitHub App setup
foreman issue configure --repo owner/repo          # Add repository to App access
foreman issue configure --list                    # Show configured repos
```

**Acceptance Criteria:**
- AC-6.1: Generate GitHub App manifest for one-click installation
- AC-6.2: Store App installation credentials securely (encrypted in Postgres)
- AC-6.3: Refresh installation tokens automatically before expiry
- AC-6.4: Per-repository access control via App permissions
- AC-6.5: CLI commands detect and use App auth over PAT when available

### FR-7: GitHub Actions Integration

Provide GitHub Actions workflow for dispatching Foreman agents.

**Example workflow (`.github/workflows/foreman-dispatch.yml`):**
```yaml
name: Dispatch to Foreman
on:
  issues:
    types: [labeled]
  workflow_dispatch:
    inputs:
      task_id:
        description: 'Task ID to dispatch'
        required: true

jobs:
  dispatch:
    if: github.event.label.name == 'foreman:dispatch'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Install Foreman
        run: npm install -g @oftheangels/foreman
      - name: Dispatch Agent
        run: foreman run --task ${{ github.event.issue.number }}
        env:
          ANTHROPIC_API_KEY: ${{ secrets.ANTHROPIC_API_KEY }}
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

**CLI trigger:**
```bash
foreman issue dispatch --repo owner/repo --issue 142
# Equivalent: gh workflow run foreman-dispatch.yml -f task_id=142
```

**Acceptance Criteria:**
- AC-7.1: GitHub Actions workflow template provided in `foreman init`
- AC-7.2: `--dispatch` flag triggers Foreman agent from GitHub context
- AC-7.3: GitHub context (issue number, repo) passed to Foreman
- AC-7.4: Status check on PR shows Foreman agent status
- AC-7.5: Workflow dispatch respects `--max-agents` limit

### FR-8: Dispatch Label Control

Label-based rules control which Issues trigger agent dispatch.

**Label conventions:**
| Label | Behavior |
|-------|----------|
| `foreman:dispatch` | Issue imported → Agent auto-dispatched |
| `foreman:skip` | Issue imported → No auto-dispatch |
| `foreman:priority:0` | P0 priority (critical) |
| `foreman:priority:1` | P1 priority (high) |
| `foreman:priority:2` | P2 priority (medium) |
| `foreman:priority:3` | P3 priority (low) |
| `foreman:priority:4` | P4 priority (backlog) |
| `foreman:needs-triage` | Issue needs human review before dispatch |

**Webhook triggers:**
- New Issue with `foreman:dispatch` label → Auto-import + dispatch
- Label added (`foreman:dispatch`) → Import + dispatch
- Label removed (`foreman:dispatch`) → Cancel pending dispatch

**Acceptance Criteria:**
- AC-8.1: `foreman:dispatch` label triggers auto-dispatch
- AC-8.2: `foreman:skip` label prevents auto-dispatch
- AC-8.3: Priority labels map to Foreman priority scale (0-4)
- AC-8.4: `foreman:needs-triage` pauses dispatch pending human review
- AC-8.5: Label changes in GitHub reflected in Foreman within webhook latency
- AC-8.6: Default behavior (no labels) configurable in `foreman.toml`

---

## 5. Non-Functional Requirements

### 5.1 Performance

| Metric | Target |
|--------|--------|
| Issue import latency | < 2 seconds per Issue |
| Bi-directional sync latency | < 5 seconds (webhook delivery target) |
| Webhook processing time | < 500ms per event |
| GitHub API rate limit handling | Exponential backoff, max 1 retry |

### 5.2 Security

| Requirement | Implementation |
|-------------|----------------|
| Token storage | Encrypted in Postgres, never in plaintext logs |
| Webhook signature | HMAC SHA-256 validation |
| GitHub App credentials | Encrypted at rest, JWT-based auth |
| Scope minimization | Request only `issues:write`, `issues:read`, `repo` |

### 5.3 Reliability

| Requirement | Implementation |
|-------------|----------------|
| Graceful degradation | PAT fallback if GitHub App unavailable |
| Offline resilience | Queue sync operations, process on reconnect |
| Idempotent operations | Duplicate webhook events handled safely |
| Audit trail | All sync operations logged with timestamps |

### 5.4 Scalability

| Scenario | Limit |
|----------|-------|
| Repositories per installation | Unlimited (via GitHub App) |
| Issues per repository | Unlimited (pagination) |
| Concurrent webhook handlers | 10 (configurable) |
| Sync queue depth | 1000 events |

---

## 6. User Interface

### 6.1 CLI Commands Summary

| Command | Description |
|---------|-------------|
| `foreman issue import` | Import GitHub Issues as Foreman tasks |
| `foreman issue sync` | Bi-directional sync between Foreman and GitHub |
| `foreman issue create` | Create a new GitHub Issue from Foreman task |
| `foreman issue view` | View GitHub Issue details |
| `foreman issue update` | Update GitHub Issue from Foreman task |
| `foreman issue webhook` | Configure webhook endpoint |
| `foreman issue dispatch` | Trigger agent dispatch from GitHub context |
| `foreman issue configure` | Set up GitHub App authentication |

### 6.2 Configuration File

`~/.foreman/github.toml`:
```toml
[auth]
# Option 1: Personal Access Token
token = "${GITHUB_TOKEN}"  # env var reference

# Option 2: GitHub App
app_id = "${GITHUB_APP_ID}"
app_private_key = "${GITHUB_APP_PRIVATE_KEY}"
installation_id = "${GITHUB_APP_INSTALLATION_ID}"

[defaults]
default_repo = "owner/repo"
default_labels = ["foreman:dispatch"]
auto_sync = true
conflict_strategy = "github-wins"  # foreman-wins | github-wins | manual

[webhook]
listen_host = "0.0.0.0"
listen_port = 3001
secret = "${FOREMAN_WEBHOOK_SECRET}"

[[repos]]
owner = "myorg"
repo = "myrepo"
labels = ["foreman:dispatch", "foreman:skip"]
auto_import = true
```

---

## 7. Acceptance Criteria

### 7.1 Core Integration

- [ ] AC-1.x: GitHub API client authenticates and performs all CRUD operations
- [ ] AC-2.x: Single Issue import creates mapped Foreman task
- [ ] AC-3.x: Bi-directional sync keeps both systems aligned
- [ ] AC-4.x: Webhook endpoint processes GitHub events in real-time
- [ ] AC-5.x: Branches auto-linked to Issues via naming convention

### 7.2 Authentication

- [ ] AC-6.x: GitHub App setup flow completes successfully
- [ ] AC-6.x: App tokens refresh automatically
- [ ] PAT fallback works when App unavailable

### 7.3 GitHub Actions

- [ ] AC-7.x: Workflow template deploys and triggers dispatch
- [ ] AC-7.x: Dispatch respects concurrency limits

### 7.4 Label-Based Dispatch

- [ ] AC-8.x: `foreman:dispatch` label triggers auto-import and dispatch
- [ ] AC-8.x: Priority labels map correctly to Foreman scale
- [ ] AC-8.x: Label changes propagate within webhook latency

### 7.5 Test Scenarios

| Scenario | Steps | Expected Result |
|----------|-------|-----------------|
| Import single Issue | `foreman issue import --repo owner/repo --issue 142` | Task task-142 created with GitHub metadata |
| Bulk import by label | `foreman issue import --repo owner/repo --label bug` | All open Issues with `bug` label imported |
| Create Issue from task | `foreman issue create --task task-abc --repo owner/repo` | GitHub Issue #156 created, linked to task |
| Sync on Issue close | Close Issue #142 on GitHub | Foreman task status updated to merged |
| Auto-dispatch on label | Add `foreman:dispatch` label to Issue | Task imported + agent dispatched |
| Webhook real-time | Update Issue on GitHub | Foreman task updated within 5 seconds |
| Conflict resolution | Edit both Issue and task | Last-write-wins (default) or per strategy |
| PR auto-close | Merge PR with "Fixes #142" | Issue #142 closed, task marked merged |

---

## 8. Technical Considerations

### 8.1 Dependencies

- **Existing VCS abstraction** (PRD-2026-004): Leverages VCS backend interface for GitHub-specific operations
- **Postgres store**: All sync metadata stored in existing Foreman Postgres schema
- **Pi SDK**: No changes required; agents run identically in GitHub-originated tasks

### 8.2 Data Model Extensions

```sql
-- New table: GitHub repository configuration
CREATE TABLE github_repos (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  owner TEXT NOT NULL,
  repo TEXT NOT NULL,
  auth_type TEXT NOT NULL CHECK (auth_type IN ('pat', 'app')),
  auth_config JSONB NOT NULL,  -- encrypted token/app config
  default_labels TEXT[],
  auto_import BOOLEAN DEFAULT false,
  webhook_secret TEXT,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now()
);

-- Extend tasks table with GitHub reference
ALTER TABLE tasks ADD COLUMN external_id TEXT UNIQUE;
ALTER TABLE tasks ADD COLUMN external_repo TEXT;
ALTER TABLE tasks ADD COLUMN github_issue_number INTEGER;
ALTER TABLE tasks ADD COLUMN github_milestone TEXT;
ALTER TABLE tasks ADD COLUMN last_sync_at TIMESTAMPTZ;
ALTER TABLE tasks ADD COLUMN sync_enabled BOOLEAN DEFAULT false;

-- New table: sync event log
CREATE TABLE github_sync_events (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  task_id UUID REFERENCES tasks(id),
  external_id TEXT NOT NULL,
  event_type TEXT NOT NULL,  -- issue_opened, issue_closed, etc.
  payload JSONB,
  processed_at TIMESTAMPTZ DEFAULT now()
);
```

### 8.3 API Rate Limiting Strategy

1. **Track remaining requests**: Store `X-RateLimit-Remaining` from responses
2. **Exponential backoff**: Retry with `Retry-After` header value
3. **Request coalescing**: Batch multiple reads where possible
4. **Cached metadata**: Cache labels, milestones, users to reduce API calls
5. **Configurable limits**: Allow org-level rate limit override

### 8.4 Error Handling

| Error | Handling |
|-------|----------|
| 401 Unauthorized | Prompt to refresh token/App installation |
| 403 Forbidden | Check App permissions, suggest re-install |
| 404 Not Found | Mark sync as failed, notify user |
| 422 Validation Error | Log details, skip invalid field |
| 451 Unavailable | Repo transfer/rename; update reference |
| Rate limited | Exponential backoff, notify if persistent |

---

## 9. Implementation Phases

### Phase 1: Foundation (MVP)
- GitHub API client (basic CRUD)
- Issue import command (single + filter)
- PAT authentication
- Branch-to-Issue linking

### Phase 2: Bi-directional Sync
- Sync command (create, push, pull, bidirectional)
- Conflict resolution strategies
- Last sync timestamp tracking

### Phase 3: Real-time Webhooks
- Webhook endpoint in Foreman daemon
- Event handlers for all Issue events
- Signature validation

### Phase 4: GitHub App & GitHub Actions
- GitHub App manifest and setup flow
- GitHub Actions workflow template
- Dispatch trigger command

### Phase 5: Advanced Features
- Label-based auto-dispatch rules
- Milestone-aware sprint mapping
- Advanced filtering and search
- Organization-wide configuration

---

## 10. Open Questions

| Question | Discussion |
|----------|------------|
| Should closed Issues re-import on `--state all`? | Consider: Re-import shows historical work but may clutter active queue |
| How to handle Issue reassignment? | Option: Update Foreman assignee, or create note/comment |
| GitHub Projects integration? | Deferred; not in scope for this epic |
| What happens if GitHub App is uninstalled? | Graceful fallback to PAT if configured; warning notification |
| Sync frequency for polling fallback? | Configurable (default: 60 seconds), lower for critical repos |

---

## 11. Appendix

### A. GitHub Issue API Reference

Primary endpoints used:
- `GET /repos/{owner}/{repo}/issues` — List repository issues
- `GET /repos/{owner}/{repo}/issues/{issue_number}` — Get single issue
- `POST /repos/{owner}/{repo}/issues` — Create issue
- `PATCH /repos/{owner}/{repo}/issues/{issue_number}` — Update issue
- `GET /repos/{owner}/{repo}/labels` — List repository labels
- `GET /repos/{owner}/{repo}/milestones` — List repository milestones

### B. Webhook Event Types

GitHub webhook events subscribed:
- `issues` — All issue lifecycle events
- `issue_comment` — Comment events on issues
- `pull_request` — For PR-to-Issue linking (optional)

### C. Related PRDs

- **PRD-2026-004**: VCS Backend Abstraction — Required foundation for GitHub integration
- **PRD-2026-002**: Pi Agent Mail RPC Migration — Inter-agent messaging (used for sync notifications)

---

**Document Status**: Draft — Awaiting stakeholder review
**Next Step**: Stakeholder review → TRD creation → Implementation
