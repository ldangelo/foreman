---

## Appendix B: Jira-Sentinel Lifecycle Integration

This section documents how Foreman transitions Jira issues when Sentinel picks up work.

### Overview

When Sentinel is configured with Jira, it can transition issues through your workflow stages:
- **claim()** — Move from ready status to in-progress
- **release()** — Move back to ready or close

This happens automatically when Sentinel detects existing issues (instead of creating new ones).

### Lifecycle Detection

Foreman auto-detects your project's workflow stages from Jira's status categories:

| Jira Status Category | Maps To | Examples |
|---------------------|---------|----------|
| `new` | start statuses | "To Do", "Open", "Backlog", "Ready" |
| `indeterminate` | in-progress statuses | "In Progress", "In Review", "QA Testing", "Code Review" |
| `done` | done statuses | "Done", "Closed", "Resolved" |

**Auto-detection behavior:**
1. On first use, JiraTaskClient calls `GET /rest/api/3/project/{projectKey}/statuses`
2. Statuses are grouped by their `statusCategory.key`
3. The mapping is cached to avoid repeated API calls

**Fallback defaults** (if API call fails):
```typescript
{
  startStatuses: ["To Do", "Open", "Backlog", "Ready", "Ready for Development"],
  inProgressStatuses: ["In Progress", "In Review", "QA", "Testing", "Code Review"],
  doneStatuses: ["Done", "Closed", "Resolved"]
}
```

### Claiming Issues

When Sentinel finds an existing open issue with matching title:

```
1. Fetch available transitions: GET /rest/api/3/issue/{issueKey}/transitions
2. Find transition to in-progress status
3. Execute transition: POST /rest/api/3/issue/{issueKey}/transitions { transition: { id } }
4. Return updated issue with new status
```

**Fallback behavior:**
- If no transition to in-progress exists, find any non-done transition
- If no transitions available (terminal state), return issue as-is
- Errors are logged but don't halt Sentinel

### Configuration

**Project config (`~/.foreman/projects/{id}/config.yaml`):**
```yaml
issueTracker:
  backend: jira
  jira:
    apiUrl: https://your-company.atlassian.net
    email: bot@your-company.com
    apiToken: $JIRA_API_TOKEN  # or actual token (encrypted at rest)
    projects:
      - key: ENG
        # Optional: override auto-detected lifecycle stages
        # lifecycle:
        #   startStatuses: ["To Do", "Ready"]
        #   inProgressStatuses: ["In Progress", "In Review", "QA"]
        #   doneStatuses: ["Done", "Closed"]
```

**For explicit lifecycle config:**
```yaml
issueTracker:
  backend: jira
  jira:
    apiUrl: https://your-company.atlassian.net
    email: bot@your-company.com
    apiToken: $JIRA_API_TOKEN
    projects:
      - key: ENG
        lifecycle:
          startStatuses: ["Ready", "Refinement Needed"]
          inProgressStatuses: ["In Development", "In Review", "QA", "Staging"]
          doneStatuses: ["Done", "Closed", "Won't Fix"]
```

### API Methods

**JiraApiClient new methods:**

```typescript
// Get all valid statuses for a project (grouped by issue type)
getProjectStatuses(projectKey: string): Promise<JiraProjectStatus[]>

// Get available transitions for an issue
getIssueTransitions(issueKey: string): Promise<JiraTransition[]>
```

**JiraTaskClient new methods:**

```typescript
// Claim an issue — transition from start to in-progress
claim(id: string): Promise<Issue>

// Release an issue — move back to start or close
release(id: string, close?: boolean): Promise<Issue>
```

### Sentinel Behavior

When Sentinel detects test failures:

```
1. Search for existing issue with matching title
   └── list({ status: "open", label: "kind:sentinel" })
   
2. If found:
   ├── Log: "Found existing issue {id} for {title}"
   └── If claim() available: call claim() to transition to in-progress
   └── Log new status after claim
   
3. If not found:
   └── Create new issue via create()
```

**Example logs:**
```
[sentinel] Found existing issue PROJ-123 for "[Sentinel] Test failures on feature/test @ abc12345"
[sentinel] Claimed issue — now status: in review
```

### Status Category Mapping

Jira's status categories map to lifecycle stages:

| Category Key | Description | Lifecycle Stage |
|-------------|-------------|----------------|
| `new` | Work hasn't started yet | start |
| `indeterminate` | Work is in progress | in-progress |
| `done` | Work is complete | done |

For status names that don't have a category (custom statuses), Foreman falls back to name-based heuristics:

```typescript
// Name-based fallbacks (case-insensitive, partial match)
startPatterns: ["to do", "open", "backlog", "ready"]
inProgressPatterns: ["progress", "review", "testing", "qa"]
donePatterns: ["done", "closed", "resolved"]
```

### Transition Logic

**claim() algorithm:**
1. Get lifecycle config (auto-detected or explicit)
2. Fetch transitions: `GET /issue/{id}/transitions`
3. Filter transitions where `to.name` matches in-progress status
4. Execute first match
5. If no in-progress transition, find any non-done transition
6. If no transitions, return issue unchanged (already in terminal state)

**release(close=false) algorithm:**
1. Get lifecycle config
2. Fetch transitions
3. Find transition to start status
4. Execute if found, otherwise return unchanged

**release(close=true) algorithm:**
1. Get lifecycle config
2. Fetch transitions
3. Find transition to done status
4. Execute if found, otherwise return unchanged