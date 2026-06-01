# TRD-2026-013: Jira Issue Monitor

**Document ID:** TRD-2026-013
**Version:** 1.1.0
**Status:** Draft
**Date:** 2026-06-01
**PRD Reference:** PRD-2026-013 (Jira Issue Monitor)
**Satisfies:** REQ-001 through REQ-020

---

## 1. System Architecture

### 1.1 Component Overview

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                         CLI Layer (src/cli/commands/)                         │
│   foreman sentinel --start | stop | status                                   │
│   foreman doctor (validates Jira config + connectivity)                       │
│   foreman jira configure | status                                            │
└──────────────────────────────┬──────────────────────────────────────────────┘
                               │
                    ~/.foreman/daemon.sock  (mode 0600)
                               │
┌──────────────────────────────▼──────────────────────────────────────────────┐
│                    ForemanDaemon (src/daemon/)                               │
│   - Fastify HTTP server + tRPC router                                        │
│   - Existing: projects, tasks, runs, events, messages routers                │
│   - NEW: jira router (poller lifecycle, webhook handler)                    │
│   - NEW: JiraIssuesPoller (background daemon process)                        │
│   - NEW: JiraWebhookHandler (real-time trigger endpoint)                    │
└──────────────────────────────▼──────────────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────────────┐
│                    PostgresAdapter (src/lib/db/)                            │
│   - Existing: projects, tasks, runs, events tables                          │
│   - NEW: jira_projects, jira_monitored_projects, jira_issue_states tables   │
└──────────────────────────────▼──────────────────────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────────────┐
│                    JiraApiClient (src/daemon/jira-api-client.ts)            │
│   - Basic Auth: base64(email:apiToken)                                      │
│   - REST API v3: /rest/api/3/search                                         │
│   - Rate limit handling with Retry-After header                             │
└──────────────────────────────┘
                               │
┌──────────────────────────────▼──────────────────────────────────────────────┐
│                    JiraTriggerHandler (src/orchestrator/jira-trigger-handler.ts) │
│   - Maps issues to workflows via issueTypeWorkflowMap                      │
│   - Checks uniqueness via externalId                                       │
│   - Dispatches to Dispatcher                                                │
└─────────────────────────────────────────────────────────────────────────────┘

┌──────────────────────────────────────────────────────────────────────────────┐
│                     Supporting Infrastructure                                 │
│  ProjectRegistry ──► ~/.foreman/projects.json                               │
│  JiraApiClient ────► Jira Cloud API (REST v3)                                │
│  JiraDebounceStore ──► PostgreSQL (jira_issue_states table)                │
│  WorktreeManager ──► ~/.foreman/worktrees/<project-id>/                     │
│  PoolManager ─────► Postgres connection pool (size=20)                      │
│  DaemonManager ───► ~/.foreman/daemon.pid                                    │
└──────────────────────────────────────────────────────────────────────────────┘
```

### 1.2 Component Responsibilities

| Component | Responsibility | Location | Change |
|-----------|---------------|----------|--------|
| `JiraApiClient` | Jira API calls: auth, search, rate limit handling | `src/daemon/jira-api-client.ts` | **New** |
| `JiraIssuesPoller` | Background polling loop, transition detection | `src/daemon/jira-poller.ts` | **New** |
| `JiraWebhookHandler` | Real-time webhook processing, signature validation | `src/daemon/jira-webhook-handler.ts` | **New** |
| `JiraDebounceStore` | Debounce state management via PostgreSQL | `src/daemon/jira-debounce-store.ts` | **New** |
| `JiraTriggerHandler` | Maps detected issues to workflows, uniqueness check | `src/orchestrator/jira-trigger-handler.ts` | **New** |
| `JiraTriggerEvent` | Event schema for observability | `src/orchestrator/jira-trigger-event.ts` | **New** |
| `ProjectConfig` | Extend for `issueTracker` block | `src/lib/project-config.ts` | **Extend** |
| `PostgresAdapter` | New tables for Jira state tracking | `src/lib/db/postgres-adapter.ts` | **Extend** |
| `TrpcRouter` | New jira router for daemon-side procedures | `src/daemon/router.ts` | **Extend** |
| `ForemanDaemon` | HTTP server + tRPC middleware | `src/daemon/index.ts` | — |
| `DaemonManager` | Daemon lifecycle | `src/lib/daemon-manager.ts` | — |
| `ProjectRegistry` | Project metadata | `src/lib/project-registry.ts` | — |

### 1.3 Data Flow: Poll-Based Detection

```
Every pollIntervalSeconds (default: 60s)
  │
  ├─► JiraIssuesPoller.pollAll()
  │    │
  │    ├─► For each registered project with Jira config:
  │    │    │
  │    │    ├─► JiraApiClient.search({
  │    │    │      project: config.projects[i].key,
  │    │    │      jql: `status IN ("In Progress", "To Do") AND updated >= "${lastPoll}"`
  │    │    │    })
  │    │    │
  │    │    ├─► For each issue in results:
  │    │    │    ├─► Get lastKnownStatus from jira_issue_states
  │    │    │    ├─► Check: isNewTransition? (now in startStatus && !wasInStartStatus)
  │    │    │    ├─► Update jira_issue_states.lastKnownStatus
  │    │    │    └─► If isNewTransition: → JiraTriggerHandler
  │    │    │
  │    │    └─► Update jira_projects.lastPollAt
  │    │
  │    └─► Persist lastPollAt to PostgresAdapter
  │
  └─► Log: "Jira poll complete: N projects, M transitions detected"
```

### 1.4 Data Flow: Webhook-Based Detection

```
Jira sends POST to /webhooks/jira
  │
  ├─► JiraWebhookHandler.handleWebhook(req)
  │    │
  │    ├─► Validate X-Jira-Webhook-Signature using HMAC SHA-256 + webhookSecret
  │    │    └─► If invalid: return 401 Unauthorized
  │    │
  │    ├─► Parse webhook payload
  │    │    └─► Ignore if webhookEvent !== "jira:issue_updated"
  │    │
  │    ├─► Extract issueKey, newStatus from payload
  │    │
  │    ├─► Get project config for this Jira instance
  │    │
  │    ├─► Check: is newStatus in startStatus[]?
  │    │    └─► If not: return 200 OK (ignore)
  │    │
  │    ├─► Check: was issue previously in startStatus? (from jira_issue_states)
  │    │    └─► If was in startStatus: return 200 OK (already triggered or re-trigger not needed)
  │    │
  │    ├─► Update jira_issue_states
  │    │
  │    └─► → JiraTriggerHandler
  │
  └─► Return 200 OK
```

### 1.5 Data Flow: Trigger Execution

```
JiraTriggerHandler.process(issue, projectConfig)
  │
  ├─► Check uniqueness (REQ-012):
  │    ├─► Query tasks table for externalId = "jira:{issueKey}"
  │    └─► If exists: skip (already triggered)
  │
  ├─► Check debounce (REQ-006, REQ-019):
  │    ├─► JiraDebounceStore.isDebounced(jiraProjectId, issueKey, debounceWindowSeconds)
  │    │    └─► Query: SELECT EXISTS (SELECT 1 FROM jira_issue_states WHERE issue_key = ? AND last_triggered_at > NOW() - INTERVAL '60 seconds')
  │    └─► If debounced: skip
  │
  ├─► Map workflow (REQ-004):
  │    ├─► Get issueType from Jira issue
  │    ├─► Look up issueTypeWorkflowMap[issueType]
  │    └─► Default to "default" if not found
  │
  ├─► Create task (REQ-005):
  │    ├─► Dispatcher.createTask({
  │    │      title: "{issueKey}: {issueTitle}",
  │    │      type: mapped from issueTypeWorkflowMap,
  │    │      externalId: "jira:{issueKey}",
  │    │    })
  │    │
  │    └─► Dispatcher.dispatch(taskId, workflowName)
  │
  ├─► Set debounce:
  │    └─► UPDATE jira_issue_states SET last_triggered_at = NOW() WHERE issue_key = ?
  │
  ├─► Emit observability event (REQ-009):
  │    └─► Log: JiraTriggerEvent { type: "jira-trigger", source: "poll"|"webhook", ... }
  │
  └─► Return: { triggered: true, taskId, workflowName }
```

### 1.6 Technology Choices

| Concern | Choice | Rationale |
|---------|--------|-----------|
| Jira API | REST API v3 via `fetch` with Basic Auth | Standard Jira Cloud API, no SDK needed |
| Authentication | HTTP Basic Auth (base64(email:apiToken)) | Per REQ-001, env var for token |
| Polling | setInterval in sentinel process | Consistent with GitHubIssuesPoller pattern |
| Webhooks | Fastify route in ForemanDaemon | Existing daemon handles inbound HTTP |
| Webhook security | HMAC SHA-256 signature validation | Standard Jira webhook security |
| State persistence | PostgreSQL (all state including debounce) | Single source of truth, crash recovery |
| Debounce persistence | PostgreSQL (jira_issue_states table) | Uses last_triggered_at column, survives restarts |
| Rate limiting | Exponential backoff with Retry-After header | Per REQ-011, max 5 minutes |
| Workflow dispatch | Uses existing Dispatcher | Reuses existing Foreman pipeline |

---

## 2. Database Schema Extensions

### 2.1 New Tables

```sql
-- jira_projects: Jira instance configuration per Foreman project
CREATE TABLE jira_projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  project_id UUID NOT NULL REFERENCES projects(id) ON DELETE CASCADE,
  api_url TEXT NOT NULL,
  email TEXT NOT NULL,
  api_token_encrypted TEXT NOT NULL,  -- Encrypted API token
  poll_interval_seconds INTEGER DEFAULT 60,
  webhook_enabled BOOLEAN DEFAULT false,
  webhook_secret_encrypted TEXT,      -- Encrypted webhook secret
  last_poll_at TIMESTAMPTZ,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(project_id)
);

-- jira_monitored_projects: Per-Jira-project monitoring config
CREATE TABLE jira_monitored_projects (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  jira_project_id UUID NOT NULL REFERENCES jira_projects(id) ON DELETE CASCADE,
  jira_project_key TEXT NOT NULL,  -- e.g., "PROJ"
  start_status TEXT[] NOT NULL,     -- e.g., ["In Progress", "To Do"]
  end_status TEXT[] NOT NULL,      -- e.g., ["Done", "Closed"]
  issue_type_workflow_map JSONB NOT NULL,  -- e.g., {"epic": "epic", "task": "default"}
  debounce_window_seconds INTEGER DEFAULT 60,
  created_at TIMESTAMPTZ DEFAULT now(),
  updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(jira_project_id, jira_project_key)
);

-- jira_issue_states: Tracks last known status per Jira issue, including debounce
CREATE TABLE jira_issue_states (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  jira_project_id UUID NOT NULL REFERENCES jira_projects(id) ON DELETE CASCADE,
  issue_key TEXT NOT NULL,  -- e.g., "PROJ-123"
  last_known_status TEXT NOT NULL,
  last_triggered_at TIMESTAMPTZ,  -- Used for debounce: if NOW() - last_triggered_at < debounce_window, skip
  last_updated_at TIMESTAMPTZ DEFAULT now(),
  UNIQUE(jira_project_id, issue_key)
);

-- Indexes for performance
CREATE INDEX idx_jira_projects_project ON jira_projects(project_id);
CREATE INDEX idx_jira_issue_states_key ON jira_issue_states(issue_key);
CREATE INDEX idx_jira_issue_states_updated ON jira_issue_states(last_updated_at);
CREATE INDEX idx_jira_issue_states_triggered ON jira_issue_states(last_triggered_at) 
  WHERE last_triggered_at IS NOT NULL;
```

### 2.2 Extend Existing Tables

```sql
-- Extend tasks table: add Jira-specific columns
ALTER TABLE tasks ADD COLUMN jira_issue_key TEXT;  -- e.g., "PROJ-123"
ALTER TABLE tasks ADD COLUMN jira_project_key TEXT;  -- e.g., "PROJ"

-- Unique constraint on external_id for Jira (part of existing schema)
-- External IDs follow format: jira:PROJECT-123
```

### 2.3 Debounce State (PostgreSQL)

Debounce state is stored in the `jira_issue_states` table using the `last_triggered_at` column. When a transition triggers a workflow, `last_triggered_at` is set to the current timestamp.

**Checking if debounced:**
```sql
-- Check if issue is within debounce window
SELECT EXISTS (
  SELECT 1 FROM jira_issue_states jis
  JOIN jira_monitored_projects jmp ON jis.jira_project_id = jmp.jira_project_id
  WHERE jis.issue_key = $1
    AND jis.last_triggered_at IS NOT NULL
    AND (NOW() - jis.last_triggered_at) < (jmp.debounce_window_seconds || ' seconds')::INTERVAL
) AS is_debounced;
```

**Setting debounce after trigger:**
```sql
UPDATE jira_issue_states 
SET last_triggered_at = NOW() 
WHERE jira_project_id = $1 AND issue_key = $2;
```

**Why PostgreSQL:**
- Single source of truth for all Jira state
- Survives sentinel crashes and restarts automatically
- No separate file sync or corruption handling needed
- Consistent with existing Foreman architecture

---

## 3. Module Specifications

### 3.1 JiraApiClient (src/daemon/jira-api-client.ts)

```typescript
interface JiraApiClientConfig {
  apiUrl: string;
  email: string;
  apiToken: string;  // Resolved from env var
  timeout?: number;  // Default: 30s
}

interface JiraIssue {
  key: string;           // e.g., "PROJ-123"
  fields: {
    summary: string;
    status: { name: string };
    issuetype: { name: string };
    project: { key: string };
    updated: string;  // ISO 8601
  };
}

class JiraApiClient {
  constructor(config: JiraApiClientConfig);
  
  // Authenticate - validates credentials
  async authenticate(): Promise<void>;
  
  // Search issues with JQL
  async search(jql: string, options?: { maxResults?: number }): Promise<JiraIssue[]>;
  
  // Get single issue
  async getIssue(issueKey: string): Promise<JiraIssue>;
  
  // Get available projects for this Jira instance
  async listProjects(): Promise<Array<{ key: string; name: string }>>;
  
  // Handle rate limit
  async handleRateLimit(retryAfterSeconds: number): Promise<void>;
}
```

### 3.2 JiraIssuesPoller (src/daemon/jira-poller.ts)

```typescript
interface JiraPollerConfig {
  pollIntervalMs: number;  // Default: 60000
  jiraConfig: JiraApiClientConfig;
  monitoredProjects: JiraProjectConfig[];
  onTransition: (issue: JiraIssue, config: JiraProjectConfig) => Promise<void>;
}

class JiraIssuesPoller {
  private client: JiraApiClient;
  private state: Map<string, IssueState>;  // In-memory, synced to DB
  private interval: ReturnType<typeof setInterval> | null;
  
  constructor(config: JiraPollerConfig);
  
  // Start polling
  start(): void;
  
  // Stop polling
  stop(): void;
  
  // Single poll cycle
  async pollOnce(): Promise<PollResult>;
  
  // Internal: detect transitions
  private async detectTransitions(project: JiraProjectConfig): Promise<JiraIssue[]>;
  
  // Internal: load state from DB
  private async loadState(): Promise<void>;
  
  // Internal: persist state to DB
  private async saveState(): Promise<void>;
}

interface IssueState {
  lastKnownStatus: string;
  lastTriggeredAt?: number;
}
```

### 3.3 JiraWebhookHandler (src/daemon/jira-webhook-handler.ts)

```typescript
interface JiraWebhookPayload {
  webhookEvent: string;  // "jira:issue_updated"
  issue: {
    key: string;
    fields: {
      status: { name: string };
      issuetype: { name: string };
      summary: string;
      project: { key: string };
    };
  };
  changelog?: {
    items: Array<{ field: string; fromString: string; toString: string }>;
  };
}

class JiraWebhookHandler {
  private config: JiraWebhookHandlerConfig;
  
  constructor(config: JiraWebhookHandlerConfig);
  
  // Handle incoming webhook
  async handle(req: Request): Promise<Response>;
  
  // Validate webhook signature
  private validateSignature(payload: string, signature: string): boolean;
  
  // Process the webhook event
  private async processEvent(payload: JiraWebhookPayload): Promise<void>;
  
  // Check if this is a status transition to startStatus
  private isTransitionToStartStatus(
    payload: JiraWebhookPayload,
    config: JiraProjectConfig
  ): { isTransition: boolean; previousStatus?: string };
}
```

### 3.4 JiraDebounceStore (src/daemon/jira-debounce-store.ts)

**Note:** All debounce state is stored in PostgreSQL (`jira_issue_states` table). No JSON file is used.

```typescript
interface JiraDebounceStore {
  // Check if an issue is currently debounced
  // Uses jira_issue_states.last_triggered_at to determine if within debounce window
  async isDebounced(
    jiraProjectId: string,
    issueKey: string,
    debounceWindowSeconds: number
  ): Promise<boolean>;
  
  // Set debounce: updates last_triggered_at in jira_issue_states
  async setDebounced(
    jiraProjectId: string,
    issueKey: string,
    debounceWindowSeconds: number
  ): Promise<void>;
  
  // Clean up expired debounce entries (removes last_triggered_at for entries older than window)
  async cleanup(debounceWindowSeconds: number): Promise<number>;  // Returns count of cleaned entries
}
```

### 3.5 JiraTriggerHandler (src/orchestrator/jira-trigger-handler.ts)

```typescript
interface TriggerContext {
  issue: JiraIssue;
  projectConfig: JiraProjectConfig;
  jiraInstanceId: string;
  source: "poll" | "webhook";
}

class JiraTriggerHandler {
  constructor(dispatcher: Dispatcher, debounceStore: JiraDebounceStore);
  
  // Process a detected transition
  async handleTransition(context: TriggerContext): Promise<TriggerResult>;
  
  // Check uniqueness - returns true if already exists
  private async isAlreadyTriggered(externalId: string): Promise<boolean>;
  
  // Check debounce using JiraDebounceStore
  private async isDebounced(
    jiraProjectId: string,
    issueKey: string,
    debounceWindowSeconds: number
  ): Promise<boolean>;
  
  // Map issue type to workflow
  private mapWorkflow(issueType: string, config: JiraProjectConfig): string;
  
  // Create and dispatch task
  private async createAndDispatch(
    issue: JiraIssue,
    workflowName: string,
    externalId: string
  ): Promise<{ taskId: string; workflowName: string }>;
  
  // Emit observability event
  private emitEvent(result: TriggerResult, context: TriggerContext): void;
}

interface TriggerResult {
  triggered: boolean;
  reason?: string;
  taskId?: string;
  workflowName?: string;
  externalId: string;
}
```

### 3.6 JiraTriggerEvent (src/orchestrator/jira-trigger-event.ts)

```typescript
interface JiraTriggerEvent {
  type: "jira-trigger";
  timestamp: string;          // ISO 8601
  source: "poll" | "webhook";
  projectKey: string;
  issueId: string;
  workflowName: string;
  externalId: string;
}

// Observable via:
// - Foreman dashboard status
// - foreman status --verbose
// - foreman inbox --watch
// - Sentinel logs (INFO level)
```

---

## 4. API Specifications

### 4.1 Webhook Endpoint

```
POST /webhooks/jira

Headers:
  X-Jira-Webhook-Signature: <HMAC SHA-256 signature>
  Content-Type: application/json

Body:
{
  "webhookEvent": "jira:issue_updated",
  "timestamp": "2026-06-01T12:00:00.000Z",
  "issue": {
    "key": "PROJ-123",
    "fields": {
      "summary": "Fix login bug",
      "status": { "name": "In Progress" },
      "issuetype": { "name": "Bug" },
      "project": { "key": "PROJ" }
    }
  },
  "changelog": {
    "items": [
      { "field": "status", "fromString": "To Do", "toString": "In Progress" }
    ]
  }
}

Response:
  200 OK - Event processed (or ignored if not a startStatus transition)
  401 Unauthorized - Invalid signature
  500 Internal Server Error - Processing failed
```

### 4.2 tRPC Procedures (jira router)

```typescript
// jira.configure - Save Jira config for a project
jira.configure({
  projectId: string,
  apiUrl: string,
  email: string,
  apiTokenEnvVar: string,
  projects: Array<{
    key: string,
    startStatus: string[],
    endStatus: string[],
    issueTypeWorkflowMap: Record<string, string>,
    debounceWindowSeconds?: number
  }>,
  webhookEnabled?: boolean,
  webhookSecretEnvVar?: string
}): Promise<{ success: boolean }>

// jira.testConnection - Validate Jira connectivity
jira.testConnection({
  apiUrl: string,
  email: string,
  apiTokenEnvVar: string
}): Promise<{ connected: boolean, projects?: Array<{key: string, name: string}> }>

// jira.getStatus - Get monitor status for a project
jira.getStatus({
  projectId: string
}): Promise<{
  configured: boolean,
  projects: number,
  lastPoll?: string,
  webhookEnabled: boolean
}>

// jira.enableWebhook - Enable webhook for real-time triggers
jira.enableWebhook({
  projectId: string,
  webhookSecret: string
}): Promise<{ webhookUrl: string }>

// jira.disableWebhook - Disable webhook
jira.disableWebhook({
  projectId: string
}): Promise<{ success: boolean }>
```

---

## 5. CLI Commands

### 5.1 foreman jira configure

```bash
# Configure Jira monitoring for current project
foreman jira configure \
  --api-url https://your-domain.atlassian.net \
  --email user@example.com \
  --api-token-env JIRA_API_TOKEN \
  --project PROJ \
  --start-status "To Do" "In Progress" \
  --end-status "Done" "Closed" \
  --issue-type-workflow epic=epic task=default bug=smoke

# Options:
#   --api-url           Jira Cloud URL (required)
#   --email             Jira account email (required)
#   --api-token-env     Env var name containing API token (required)
#   --project           Jira project key (required, can repeat for multi-project)
#   --start-status      Status values that trigger workflow (required)
#   --end-status        Status values that complete the workflow (optional)
#   --issue-type-workflow  Map issue type to workflow (required)
#   --debounce-seconds  Debounce window (default: 60)
#   --webhook-enabled    Enable webhook support
#   --webhook-secret-env Webhook secret env var
#   --poll-interval      Poll interval in seconds (default: 60)
```

### 5.2 foreman jira status

```bash
# Show Jira monitor status
foreman jira status

# Output:
# Jira Monitor: Active
# Projects monitored: 2 (PROJ, OTHER)
# Last poll: 2026-06-01 12:00:00
# Webhook: Enabled (endpoint: /webhooks/jira)
```

### 5.3 foreman doctor (Jira validation)

```bash
# Validate Jira config
foreman doctor

# Jira section output:
# [JIRA] Checking configuration... OK
# [JIRA] Testing API connectivity... Connected
# [JIRA] Validating project keys... OK (PROJ, OTHER found)
# [JIRA] Webhook endpoint... Configured (reachable)
```

---

## 6. Master Task List

### Sprint 0: Core Infrastructure

**Goal:** Establish Jira API client, configuration schema, and basic polling.

| TRD-001 | Extend ProjectConfig for `issueTracker` block | 4h | REQ-002 | AC-002-1, AC-002-2 |
| TRD-002 | Create `JiraApiClient` class with Basic Auth | 6h | REQ-001 | AC-001-1, AC-001-2, AC-001-4 |
| TRD-003 | Add rate limit handling with Retry-After | 3h | REQ-001, REQ-011 | AC-001-3, AC-011-2, AC-011-3 |
| TRD-004 | Create database migrations: `jira_projects`, `jira_monitored_projects`, `jira_issue_states` | 4h | REQ-002 | AC-002-1 |
| TRD-005 | Implement `JiraDebounceStore` with PostgreSQL (no JSON file) | 4h | REQ-019 | AC-019-1, AC-019-2, AC-019-3 |
| TRD-006 | Write unit tests for JiraApiClient (mock fetch) | 4h | REQ-001 | AC-001-1, AC-001-4 |
| TRD-007 | Write unit tests for JiraDebounceStore | 3h | REQ-019 | AC-019-1, AC-019-3 |
| TRD-008 | Implement `foreman jira configure` CLI command | 5h | REQ-002, REQ-013 | AC-002-1, AC-002-3, AC-013-1 |
| TRD-009 | Implement `foreman doctor` Jira validation | 4h | REQ-013 | AC-002-5, AC-013-3, AC-013-4 |

---

### Sprint 1: Polling Infrastructure

**Goal:** Implement background polling, transition detection, and trigger execution.

| TRD-010 | Create `JiraIssuesPoller` class with setInterval loop | 6h | REQ-007 | AC-007-1, AC-007-2 |
| TRD-011 | Implement `detectTransitions()` with lastKnownStatus tracking | 5h | REQ-003 | AC-003-1, AC-003-2, AC-003-4, AC-003-5 |
| TRD-012 | Implement `JiraTriggerHandler` with uniqueness check | 5h | REQ-005, REQ-012 | AC-005-2, AC-005-3, AC-012-1, AC-012-3 |
| TRD-013 | Implement workflow mapping via issueTypeWorkflowMap | 3h | REQ-004 | AC-004-1, AC-004-2, AC-004-3 |
| TRD-014 | Implement debounce checking in trigger handler (PostgreSQL) | 3h | REQ-006, REQ-019 | AC-006-1, AC-006-2, AC-006-3 |
| TRD-015 | Integrate poller with sentinel lifecycle (start/stop) | 4h | REQ-008 | AC-008-1, AC-008-2, AC-008-3 |
| TRD-016 | Persist lastPollAt and issue state to database | 4h | REQ-003, REQ-008 | AC-003-4 |
| TRD-017 | Write integration tests for polling + trigger flow | 5h | REQ-003, REQ-005 | AC-003-1, AC-005-1, AC-005-4 |
| TRD-018 | Implement `foreman jira status` CLI command | 3h | REQ-009 | AC-009-2 |

---

### Sprint 2: Webhook Support

**Goal:** Add real-time webhook detection alongside polling.

| TRD-019 | Create `JiraWebhookHandler` with Fastify route | 5h | REQ-020 | AC-020-1 |
| TRD-020 | Implement HMAC SHA-256 signature validation | 3h | REQ-020 | AC-020-2 |
| TRD-021 | Handle `jira:issue_updated` events with status change detection | 4h | REQ-003, REQ-020 | AC-003-1, AC-020-3 |
| TRD-022 | Integrate webhook handler with JiraTriggerHandler | 3h | REQ-005, REQ-020 | AC-020-1, AC-020-3 |
| TRD-023 | Add webhook registration CLI: `foreman jira enable-webhook` | 4h | REQ-020 | AC-020-4 |
| TRD-024 | Implement idempotency: webhook vs poll duplicate prevention | 3h | REQ-020 | AC-020-3 |
| TRD-025 | Write webhook handler unit tests | 4h | REQ-020 | AC-020-1, AC-020-2 |
| TRD-026 | End-to-end test: simulate Jira webhook → trigger workflow | 4h | REQ-003, REQ-005, REQ-020 | AC-003-1, AC-005-1 |

---

### Sprint 3: Observability and Polish

**Goal:** Complete observability, error handling, and graceful shutdown.

| TRD-027 | Implement `JiraTriggerEvent` schema and emission | 3h | REQ-009 | AC-009-1 |
| TRD-028 | Add observability to sentinel dashboard | 3h | REQ-009 | AC-009-2 |
| TRD-029 | Implement graceful shutdown with state persistence | 4h | REQ-014 | AC-014-1, AC-014-2 |
| TRD-030 | Add error recovery and CRITICAL alert logging | 3h | REQ-011 | AC-011-1, AC-011-3 |
| TRD-031 | Validate externalId uniqueness before task creation | 2h | REQ-012 | AC-012-1, AC-012-2 |
| TRD-032 | Add `foreman doctor` webhook endpoint check | 2h | REQ-020 | AC-020-4 |
| TRD-033 | Write comprehensive integration tests for all flows | 6h | All REQs | All ACs |
| TRD-034 | Performance test: 10 projects, 100 concurrent transitions | 3h | REQ-018 | AC-018-1, AC-018-2 |

---

## 7. Acceptance Criteria Validation Matrix

| REQ | AC | TRD Tasks | Test Scenario |
|-----|-----|----------|---------------|
| REQ-001 | AC-001-1 | TRD-002 | Configure Jira → Monitor starts → Auth succeeds |
| REQ-001 | AC-001-2 | TRD-002 | Poll configured project → Issues fetched with status/type |
| REQ-001 | AC-001-3 | TRD-003 | Hit rate limit → Back off → Retry |
| REQ-001 | AC-001-4 | TRD-006 | Invalid creds → Auth fails → Log error |
| REQ-002 | AC-002-1 | TRD-001, TRD-004 | Valid config → Monitor starts |
| REQ-002 | AC-002-2 | TRD-001 | Missing config → Warning logged |
| REQ-002 | AC-002-3 | TRD-008 | Env var reference → Token resolved |
| REQ-002 | AC-002-4 | TRD-010 | Multi-project → All polled |
| REQ-002 | AC-002-5 | TRD-009 | Doctor → Lists projects → Reports mismatches |
| REQ-002 | AC-002-6 | TRD-019 | Webhook enabled → Endpoint registered |
| REQ-003 | AC-003-1 | TRD-011 | Backlog → In Progress → Detected |
| REQ-003 | AC-003-2 | TRD-011 | Stays in startStatus → No re-trigger |
| REQ-003 | AC-003-3 | TRD-011 | startStatus → endStatus → No trigger |
| REQ-003 | AC-003-4 | TRD-016 | Already in startStatus → No trigger |
| REQ-003 | AC-003-5 | TRD-011 | Update but no status change → No trigger |
| REQ-004 | AC-004-1 | TRD-013 | Epic → epic workflow |
| REQ-004 | AC-004-2 | TRD-013 | Unknown type → default workflow |
| REQ-004 | AC-004-3 | TRD-013 | Invalid workflow → Log error → default |
| REQ-005 | AC-005-1 | TRD-012 | Transition → Task created with title |
| REQ-005 | AC-005-2 | TRD-012 | Transition → externalId set |
| REQ-005 | AC-005-3 | TRD-012 | Transition → Dispatcher called |
| REQ-005 | AC-005-4 | TRD-017 | Dispatched → Pipeline runs normally |
| REQ-006 | AC-006-1 | TRD-014 | Rapid transitions → One trigger |
| REQ-006 | AC-006-2 | TRD-014 | Window expires → New trigger |
| REQ-006 | AC-006-3 | TRD-014 | debounceWindow=0 → No debounce |
| REQ-007 | AC-007-1 | TRD-010 | Poll interval 30s → Polls every 30s |
| REQ-007 | AC-007-2 | TRD-010 | Long poll → Skip next, run after |
| REQ-007 | AC-007-3 | TRD-010 | ENV override → Poll uses ENV value |
| REQ-008 | AC-008-1 | TRD-015 | sentinel --start → Poller starts |
| REQ-008 | AC-008-2 | TRD-015 | sentinel --stop → Poller stops cleanly |
| REQ-008 | AC-008-3 | TRD-016 | Restart → Resumes from persisted timestamp |
| REQ-008 | AC-008-4 | TRD-009 | Doctor with Jira → Validates connectivity |
| REQ-009 | AC-009-1 | TRD-027 | Trigger → Event emitted with all fields |
| REQ-009 | AC-009-2 | TRD-018 | Poll completes → Dashboard shows status |
| REQ-009 | AC-009-3 | TRD-030 | Poll fails → ERROR logged |
| REQ-012 | AC-012-1 | TRD-031 | Already triggered → No duplicate task |
| REQ-012 | AC-012-2 | TRD-031 | Jira delete → Workflow continues |
| REQ-012 | AC-012-3 | TRD-012 | Trigger → Uniqueness check first |
| REQ-013 | AC-013-1 | TRD-001 | Missing apiUrl → Clear error |
| REQ-013 | AC-013-2 | TRD-001 | Invalid workflow → Clear error |
| REQ-013 | AC-013-3 | TRD-009 | Doctor → Reports connected/failed |
| REQ-013 | AC-013-4 | TRD-009 | Invalid key → Lists available |
| REQ-014 | AC-014-1 | TRD-029 | SIGTERM → State persisted → Clean exit |
| REQ-014 | AC-014-2 | TRD-029 | Restart → State restored |
| REQ-016 | AC-016-1 | TRD-022, TRD-026 | Webhook received → Triggered within 5s |
| REQ-016 | AC-016-2 | TRD-017 | Poll SLA → Triggered within 5min |
| REQ-019 | AC-019-1 | TRD-005 | Shutdown → Debounce persisted to PostgreSQL |
| REQ-019 | AC-019-2 | TRD-005 | Crash → Restart → Debounce restored from PostgreSQL |
| REQ-019 | AC-019-3 | TRD-005 | Cleanup → Expired entries cleared |
| REQ-020 | AC-020-1 | TRD-019, TRD-022 | Valid webhook → Triggered within 5s |
| REQ-020 | AC-020-2 | TRD-020 | Invalid signature → 401 |
| REQ-020 | AC-020-3 | TRD-024 | Webhook + poll → No duplicate |
| REQ-020 | AC-020-4 | TRD-023, TRD-032 | Doctor → Webhook reachable |

---

## 8. File Structure

```
src/daemon/
  jira-api-client.ts          # JiraApiClient class
  jira-poller.ts             # JiraIssuesPoller class
  jira-webhook-handler.ts     # JiraWebhookHandler class
  jira-debounce-store.ts     # JiraDebounceStore class (PostgreSQL-based)
  jira-config-validator.ts    # Config validation helpers
  jira-router.ts             # tRPC jira procedures
  __tests__/
    jira-api-client.test.ts
    jira-poller.test.ts
    jira-webhook-handler.test.ts
    jira-debounce-store.test.ts

src/lib/
  project-config.ts          # Extend ProjectConfig for issueTracker
  db/
    migrations/
      00000000000018-create-jira-tables.sql  # All Jira tables including debounce

src/orchestrator/
  jira-trigger-handler.ts    # JiraTriggerHandler class
  jira-trigger-event.ts      # JiraTriggerEvent interface

src/cli/commands/
  jira.ts                    # foreman jira configure | status
  doctor.ts                  # Extend for Jira validation

src/daemon/
  router.ts                  # Extend with jira router
  webhook-handler.ts         # Add /webhooks/jira route
```

---

## 9. Dependencies

| Dependency | Purpose | Version |
|------------|---------|---------|
| `node-fetch` or built-in `fetch` | HTTP calls to Jira API | Node 20+ |
| `crypto` (built-in) | HMAC SHA-256 for webhook signature | Node built-in |
| `fastify` | HTTP server (existing) | ^4.x |
| `@trpc/server` | tRPC (existing) | ^10.x |
| `postgres` | Database (existing) | ^3.x |

---

## 10. Risks and Mitigations

| Risk | Impact | Likelihood | Mitigation |
|------|--------|------------|------------|
| Jira API downtime | Monitor fails to detect transitions | Low | REQ-011: Exponential backoff, CRITICAL alerts |
| Clock skew | Missed transitions | Medium | Poll `updated >= lastPoll` catches late updates |
| Webhook unreachable | Only polling fallback | Medium | Polling is always active; webhooks are enhancement |
| Duplicate triggers | Resource waste | Low | REQ-006: Debounce (PostgreSQL), REQ-012: Uniqueness check |
| Token expiration | Auth failures | Low | Jira API tokens don't expire by default |
| Database unavailable | State tracking fails | Low | Poll continues, state tracked on next successful poll |

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-06-01 | Initial TRD — 34 tasks covering Jira API client, polling, webhooks, trigger execution, observability, and testing |
| 1.1.0 | 2026-06-01 | Fix inconsistency: debounce persistence now always uses PostgreSQL (jira_issue_states table), removed JSON file reference |