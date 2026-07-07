# PRD-2026-013: Jira Issue Monitor — External Issue Tracker Integration

**Document ID:** PRD-2026-013
**Version:** 1.2.0
**Status:** Draft
**Date:** 2026-06-01
**Scale Depth:** STANDARD
**Author:** Lead Agent (PRD Phase)
**Total Requirements:** 20
**Readiness Score:** 4.75 / 5.0 (Implementation Readiness Gate: PASS)

---

## PRD Health Summary

| Metric | Value |
|--------|-------|
| **Total Requirements** | 20 (REQ-001 through REQ-020) |
| **Must** | 9 |
| **Should** | 7 |
| **Could** | 4 |
| **Won't (this release)** | 0 |
| **AC Coverage** | 20/20 (100%) |
| **Risk Flags** | 2 |
| **Cross-Requirement Dependencies** | 10 |
| **Readiness Score** | 4.75 / 5.0 |

---

## 1. Executive Summary

### 1.1 Problem Statement

Foreman currently supports GitHub Issues integration (PRD-2026-011) but lacks the ability to monitor Jira projects for status transitions. Teams using Jira as their primary issue tracker must manually create Foreman tasks or use workarounds like GitHub Actions, resulting in poor visibility and limited workflow control.

### 1.2 Solution Overview

A Jira Issue Monitor daemon that:
1. Polls Jira projects at configurable intervals (target: <5 minute detection SLA)
2. Supports webhook-based real-time triggers for near-instant detection
3. Detects issues **transitioning into** configured `startStatus` values (not just currently in startStatus)
4. Maps issue types to Foreman workflows
5. Triggers workflow execution for matched issues (after checking uniqueness constraint)
6. Debounces rapid transitions to prevent duplicate triggers (persisted to disk for crash recovery)

### 1.3 Value Proposition

- **Automated workflow triggers**: Issues entering startStatus automatically kick off Foreman pipelines
- **Real-time detection**: Webhook support provides sub-second latency alongside polling
- **Visibility**: All triggered workflows visible in Foreman's existing monitoring (dashboard, status)
- **Workflow control**: Issue type → workflow mapping provides fine-grained control over execution
- **Crash resilience**: Persisted debounce state survives sentinel restarts

---

## 2. User Analysis

### 2.1 Primary Users

| Role | Description | Pain Point |
|------|-------------|------------|
| **Engineering Leads** | Manage task workflows across Jira projects | Manual task creation, limited visibility |
| **Developers** | Want automated pipeline triggers from issue status | No automatic workflow kickoff from Jira |
| **Project Managers** | Track sprint progress across issue trackers | Disconnected Jira status from Foreman execution |

### 2.2 Current Workflow

```
1. Jira issue enters "In Progress" status
2. Developer manually: foreman task create "JIRA-123: ..."
3. foreman run --task <id>
4. Track status separately in Jira vs Foreman
```

### 2.3 Desired Workflow

```
1. Jira issue enters "In Progress" status
2. Jira Monitor detects transition (via webhook or poll, <5s for webhook, <5min for polling)
3. Foreman creates task linked to JIRA-123
4. Mapped workflow auto-dispatched based on issue type
5. Status synced back to Jira on completion
```

---

## 3. Goals and Non-Goals

### 3.1 Goals

| ID | Goal | Success Metric |
|----|------|----------------|
| G-1 | Detect Jira issues transitioning to startStatus via webhooks (real-time) or polling (fallback) | Webhook: <5s latency; Poll: <5min SLA |
| G-2 | Map issue types to Foreman workflows | Epic→epic workflow, Task→default, Bug→smoke |
| G-3 | Trigger workflow execution automatically | Pipeline starts without manual foreman run |
| G-4 | Prevent duplicate triggers for same issue | Debounce window: 60s (configurable, persisted) |
| G-5 | Integrate with existing Foreman monitoring | Visible in dashboard, status, inbox |
| G-6 | Support multi-project monitoring | Single daemon monitors multiple Foreman projects |
| G-7 | Persist debounce state across restarts | Prevent duplicate triggers after crashes |

### 3.2 Non-Goals

- **Offline queue mode**: Monitor requires Jira API connectivity (online-only)
- **Bi-directional sync v1**: Jira status changes post-trigger don't affect Foreman
- **Jira write operations**: Monitor reads from Jira; Foreman doesn't update Jira
- **GitHub/Linear monitors**: Jira-only in this release
- **Custom field mapping**: Only standard issue fields (type, status, project)
- **Multiple Jira instances**: One Jira instance per Foreman project

---

## 4. Feature Areas

### 4.1 Feature Area 1: Jira Monitor Daemon

The background service that polls Jira and detects status transitions, plus webhook endpoint for real-time triggers.

### 4.2 Feature Area 2: Issue Tracker Configuration

Project-level configuration for Jira backend, status mappings, and workflow rules.

### 4.3 Feature Area 3: Workflow Trigger Integration

Connecting detected issues to Foreman's pipeline dispatch system.

### 4.4 Feature Area 4: Debouncing and Idempotency

Preventing duplicate triggers from rapid status changes, with persistent state for crash recovery.

### 4.5 Feature Area 5: Webhook Integration

Real-time Jira webhook handling for sub-second detection latency.

---

## 5. Functional Requirements

### REQ-001: Jira API Client

**Priority:** Must | **Complexity:** Medium | **Risk:** None

Foreman shall provide a typed Jira API client that authenticates via Basic Auth (email + API token) and performs issue queries.

**Authentication Method:**
- Uses HTTP Basic Auth: `Authorization: Basic base64(email:apiToken)`
- Email from config (`jira.email`), token from env var (`jira.apiTokenEnvVar`)
- Token read from `process.env[JIRA_API_TOKEN_ENV_VAR]` at runtime

**Acceptance Criteria:**
- AC-001-1: Given Jira credentials are configured (email + API token env var), when the monitor starts, then it authenticates successfully with the Jira Cloud API using Basic Auth.
- AC-001-2: Given a configured Jira project key, when polling, then the client fetches issues with status, type, and last updated timestamp via `/rest/api/3/search`.
- AC-001-3: Given a Jira API rate limit response (429), when polling fails, then the monitor backs off using the `Retry-After` header value (exponential backoff, max 5 minutes).
- AC-001-4: Given invalid Jira credentials, when the monitor attempts to poll, then it logs an authentication error (401/403) and halts polling for that project.

---

### REQ-002: Project-Level Issue Tracker Configuration

**Priority:** Must | **Complexity:** Medium | **Risk:** None

Each project shall support an `issueTracker` configuration block defining backend, status values, and workflow mapping.

**Configuration Schema:**
```yaml
issueTracker:
  backend: jira  # 'jira' | 'github' | 'linear' (extensible)
  jira:
    apiUrl: https://your-domain.atlassian.net  # One Jira instance per project
    email: user@example.com
    apiTokenEnvVar: JIRA_API_TOKEN  # env var name containing the API token
    pollIntervalSeconds: 60
    webhookEnabled: true  # Enable webhook for real-time detection
    webhookSecret: WEBHOOK_SECRET  # env var for webhook signature validation
    projects:
      - key: PROJ
        startStatus: ["To Do", "In Progress"]
        endStatus: ["Done", "Closed"]
        issueTypeWorkflowMap:
          epic: epic
          task: default
          bug: smoke
        debounceWindowSeconds: 60
```

**Project Key Normalization:**
- Project keys in config are normalized to uppercase before JQL queries
- `foreman doctor` validates keys against Jira's actual project list on startup
- Mismatched keys produce a clear error: "Project 'proj' not found. Available: PROJ, OTHER"

**Acceptance Criteria:**
- AC-002-1: Given a project with valid `issueTracker.jira` config, when the monitor daemon starts, then it loads the configuration and begins polling.
- AC-002-2: Given missing or malformed Jira config, when the project is registered, then Foreman logs a warning and skips polling for that project.
- AC-002-3: Given `apiTokenEnvVar: "JIRA_API_TOKEN"`, when resolving config, then the monitor reads from `process.env.JIRA_API_TOKEN`.
- AC-002-4: Given a project with multiple Jira projects configured, when polling, then the monitor fetches from each project.
- AC-002-5: Given `foreman doctor` is run with Jira config, when validating, then it lists available projects from Jira and reports mismatches.
- AC-002-6: Given `webhookEnabled: true`, when the daemon starts, then it registers the webhook endpoint.

---

### REQ-003: Status Transition Detection

**Priority:** Must | **Complexity:** Medium | **Risk:** [RISK: Clock skew between Jira and Foreman may cause missed transitions]

The monitor shall detect issues that **transition into** configured `startStatus` values. A trigger occurs only when an issue changes TO a startStatus from a non-startStatus value.

**Key Behavior:**
- The monitor tracks `lastKnownStatus` per issue
- A trigger only occurs when status *changes* to a startStatus value
- Issues already in startStatus (at monitor startup or from prior polls) do NOT trigger
- Issues updated but still in the same status do NOT trigger

**Acceptance Criteria:**
- AC-003-1: Given an issue in "Backlog" status and `startStatus: ["In Progress"]`, when the issue transitions to "In Progress", then the monitor detects this on the next poll or webhook event.
- AC-003-2: Given an issue already in `startStatus` from a prior poll, when it remains in `startStatus`, then the monitor does NOT re-trigger (already seen, no status change).
- AC-003-3: Given an issue in `startStatus` that transitions to `endStatus`, when the next poll runs, then the monitor does NOT trigger (already completed).
- AC-003-4: Given an issue already in `startStatus` at monitor startup, when the monitor first polls, then it does NOT trigger (existing state, not a new transition).
- AC-003-5: Given an issue is updated (description change) while already in startStatus, when polled, then the monitor does NOT trigger (no status change).

---

### REQ-004: Issue Type to Workflow Mapping

**Priority:** Must | **Complexity:** Low | **Risk:** None

The monitor shall map Jira issue types to Foreman workflows using the configured `issueTypeWorkflowMap`.

**Acceptance Criteria:**
- AC-004-1: Given an issue of type "epic" and `issueTypeWorkflowMap.epic: epic`, when the issue transitions to startStatus, then the monitor triggers the `epic` workflow.
- AC-004-2: Given an issue type with no explicit mapping, when triggered, then the monitor defaults to the `default` workflow.
- AC-004-3: Given an issue type mapped to a non-existent workflow, when triggered, then the monitor logs an error and falls back to `default`.

---

### REQ-005: Workflow Trigger Execution

**Priority:** Must | **Complexity:** Medium | **Risk:** [RISK: Triggering workflows requires tight integration with Foreman's dispatch system]

The monitor shall create a Foreman task and dispatch a workflow for each detected transition, **after checking REQ-012's uniqueness constraint**.

**Workflow:**
1. Detect status transition (REQ-003) — via poll or webhook
2. Apply workflow mapping (REQ-004)
3. Check uniqueness constraint (REQ-012) — if externalId exists, skip
4. Create Foreman task with externalId
5. Dispatch workflow

**Acceptance Criteria:**
- AC-005-1: Given a detected Jira issue transition, when triggering, then the monitor creates a task with title "JIRA-123: <issue title>" and type from issue type mapping.
- AC-005-2: Given a detected transition, when triggering, then the monitor passes the Jira external ID (`jira:PROJECT-123`) as the task's `externalId`.
- AC-005-3: Given a detected transition, when triggering, then the monitor calls the dispatcher with the mapped workflow name.
- AC-005-4: Given a successfully dispatched workflow, when complete, then the pipeline proceeds exactly as if `foreman run` was called manually.

---

### REQ-006: Debounce Mechanism

**Priority:** Should | **Complexity:** Low | **Risk:** None

The monitor shall debounce rapid transitions on the same Jira issue within a configurable window (default: 60 seconds). Debounce state is persisted to disk for crash recovery.

**Acceptance Criteria:**
- AC-006-1: Given the same Jira issue enters startStatus twice within 60 seconds, when the second poll detects it, then only one workflow trigger occurs.
- AC-006-2: Given a debounce window of 60 seconds expires, when the issue re-enters startStatus (status changed away and back), then a new workflow is triggered.
- AC-006-3: Given `debounceWindowSeconds` is configurable per project, when set to 0, then no debouncing is applied.

---

### REQ-007: Poll Interval Configuration

**Priority:** Should | **Complexity:** Low | **Risk:** None

The monitor shall support configurable poll intervals (default: 60 seconds, minimum: 30 seconds).

**Acceptance Criteria:**
- AC-007-1: Given `pollIntervalSeconds: 30` in config, when the monitor runs, then it polls every 30 seconds.
- AC-007-2: Given a poll takes longer than the interval, when the next poll is due, then the monitor skips the missed cycle and runs when the previous completes.
- AC-007-3: Given the environment variable `FOREMAN_JIRA_POLL_INTERVAL_MS`, when set, then it overrides the configured interval.

---

### REQ-008: Daemon Lifecycle Management

**Priority:** Should | **Complexity:** Medium | **Risk:** None

The monitor daemon shall integrate with Foreman's sentinel/daemon system for lifecycle management.

**Acceptance Criteria:**
- AC-008-1: Given `foreman sentinel --start` is called, when Jira monitoring is configured for any project, then the Jira monitor starts automatically.
- AC-008-2: Given `foreman sentinel --stop` is called, when the Jira monitor is running, then it cleanly stops polling and persists last poll timestamp.
- AC-008-3: Given the sentinel restarts after a crash, when it reinitializes, then it resumes polling from the persisted timestamp (no missed transitions during downtime).
- AC-008-4: Given `foreman doctor` is run, when Jira config is present, then it validates Jira API connectivity and reports status.

---

### REQ-009: Monitoring and Observability

**Priority:** Should | **Complexity:** Medium | **Risk:** None

The monitor shall emit observability events for pipeline visibility.

**Event Schema:**
```typescript
interface JiraTriggerEvent {
  type: "jira-trigger";      // event discriminator
  timestamp: string;          // ISO 8601
  source: "poll" | "webhook"; // detection method
  projectKey: string;         // e.g., "PROJ"
  issueId: string;            // e.g., "PROJ-123"
  workflowName: string;       // e.g., "default"
  externalId: string;         // e.g., "jira:PROJ-123"
}
```

**Acceptance Criteria:**
- AC-009-1: Given a transition is detected and triggered, when the event emits, then it includes `type: "jira-trigger"`, `timestamp`, `source`, `projectKey`, `issueId`, `workflowName`, `externalId`.
- AC-009-2: Given a poll cycle completes, when the sentinel dashboard is open, then it shows "Jira: N issues monitored, last poll: HH:MM:SS".
- AC-009-3: Given a poll fails due to Jira API error, when the sentinel logs, then it logs at ERROR level with the Jira error message.

---

### REQ-010: Multi-Project Support

**Priority:** Could | **Complexity:** Medium | **Risk:** None

The monitor shall support monitoring multiple Foreman projects, each with independent Jira configurations.

**Acceptance Criteria:**
- AC-010-1: Given two Foreman projects with Jira configs, when the sentinel starts, then both projects' Jira monitors run concurrently.
- AC-010-2: Given a project's Jira config changes at runtime, when the monitor detects the change, then it reloads the config without restart.

---

### REQ-011: Error Recovery and Rate Limiting

**Priority:** Should | **Complexity:** Medium | **Risk:** None

The monitor shall handle transient failures and rate limits gracefully without stopping the polling loop.

**Rate Limit Handling:**
- Detect `Retry-After` header from Jira 429 responses
- Initial backoff: 30 seconds
- Exponential backoff: double each retry
- Maximum backoff: 5 minutes
- Log at WARN level with retry schedule

**Acceptance Criteria:**
- AC-011-1: Given a Jira API timeout during polling, when it occurs, then the monitor logs the error, backs off, and retries on the next interval.
- AC-011-2: Given Jira returns a 429 with `Retry-After: 60`, when encountered, then the monitor waits 60 seconds before retrying.
- AC-011-3: Given the monitor encounters 5 consecutive failures, when it fails, then it logs a CRITICAL alert and continues with exponential backoff (max 5 minutes).
- AC-011-4: Given a successful poll occurs after backoff, when the next poll runs, then the backoff timer resets to initial (30 seconds).

---

### REQ-012: External ID Uniqueness

**Priority:** Must | **Complexity:** Low | **Risk:** None

The monitor shall ensure Jira external IDs are unique and prevent duplicate task creation.

**Prerequisite for REQ-005:** Before creating a task, the trigger handler MUST check if the externalId already exists.

**Acceptance Criteria:**
- AC-012-1: Given an issue `jira:PROJECT-123` was already triggered, when the same issue transitions to startStatus again (outside debounce), then the monitor does NOT create a new task.
- AC-012-2: Given an issue is deleted from Jira but a workflow already started, when the monitor polls, then the workflow continues unaffected (fire-and-forget after trigger).
- AC-012-3: Given REQ-005 is triggered, when creating a task, then REQ-012 uniqueness check runs first — only proceeds if externalId is not already in use.

---

### REQ-013: Configuration Validation

**Priority:** Must | **Complexity:** Low | **Risk:** None

The monitor shall validate configuration at startup and report all errors clearly.

**Acceptance Criteria:**
- AC-013-1: Given `issueTracker.backend: jira` with missing `jira.apiUrl`, when config loads, then Foreman reports "Jira config missing required field: apiUrl".
- AC-013-2: Given `issueTypeWorkflowMap` references a workflow that doesn't exist, when config loads, then Foreman reports "Workflow 'epic' not found in available workflows".
- AC-013-3: Given valid Jira config, when `foreman doctor` runs, then it tests Jira API connectivity and reports "Jira: Connected" or "Jira: Authentication Failed".
- AC-013-4: Given a project key that doesn't exist in Jira, when `foreman doctor` runs, then it reports "Project 'proj' not found. Available: PROJ, OTHER" (case-normalized).

---

### REQ-014: Graceful Shutdown

**Priority:** Could | **Complexity:** Low | **Risk:** None

The monitor shall shut down gracefully on SIGTERM/SIGINT, persisting state.

**Acceptance Criteria:**
- AC-014-1: Given the sentinel receives SIGTERM, when it shuts down, then the Jira monitor persists all state (debounce, last poll timestamps) and exits cleanly.
- AC-014-2: Given the sentinel restarts, when it resumes, then it uses the persisted state to avoid missed transitions and duplicate triggers.

---

### REQ-015: Jira API Version Support

**Priority:** Should | **Complexity:** Low | **Risk:** None

The monitor shall support Jira Cloud API v3 (current) with compatibility for v2.

**Acceptance Criteria:**
- AC-015-1: Given Jira Cloud (standard), when polling, then the monitor uses `/rest/api/3/search` endpoint.
- AC-015-2: Given a self-hosted Jira Data Center instance, when configured with custom `apiUrl`, then the monitor works with its API version.

---

### REQ-016: Detection Latency

**Priority:** Must | **Complexity:** Low

The monitor shall detect Jira status transitions within 5 minutes via polling, or within 5 seconds via webhook.

**Acceptance Criteria:**
- AC-016-1: Given an issue transitions to startStatus at T=0 via webhook, when the webhook is received, then the workflow is triggered within 5 seconds.
- AC-016-2: Given an issue transitions to startStatus at T=0 via polling (webhooks disabled), when the monitor's next poll runs by T+5min, then the workflow is triggered by T+5min.

---

### REQ-017: Resource Usage

**Priority:** Should | **Complexity:** Low

The monitor shall have minimal resource footprint (CPU < 1%, memory < 50MB per monitored project).

**Acceptance Criteria:**
- AC-017-1: Given 5 Jira projects monitored, when polling every 60 seconds, then total CPU usage remains below 2% on a modern laptop.
- AC-017-2: Given the monitor runs for 24 hours, when memory is checked, then it remains stable (no leaks).

---

### REQ-018: Scalability

**Priority:** Could | **Complexity:** Medium

The monitor shall scale to handle 10+ Jira projects per sentinel instance.

**Acceptance Criteria:**
- AC-018-1: Given 10 Jira projects configured, when polling, then the monitor completes all polls within 30 seconds (parallel or efficient sequential).
- AC-018-2: Given 100 issues transition simultaneously across projects, when the monitor processes them, then no issue is missed and no trigger is duplicated.

---

### REQ-019: Debounce State Persistence

**Priority:** Must | **Complexity:** Medium | **Risk:** None

The monitor shall persist debounce state to disk so it survives sentinel restarts and prevents duplicate triggers after crashes.

**Acceptance Criteria:**
- AC-019-1: Given a debounce window is active for issue "PROJ-123" at sentinel shutdown, when the sentinel restarts, then the debounce state is loaded and the issue is still debounced.
- AC-019-2: Given the sentinel crashes mid-debounce window, when it restarts, then no duplicate trigger occurs for the same issue within the original debounce window.
- AC-019-3: Given debounce state is persisted to `~/.foreman/jira-debounce.json`, when the file is corrupted, then the monitor logs a warning and resets debounce state, proceeding without blocking triggers.

---

### REQ-020: Webhook Trigger Support

**Priority:** Must | **Complexity:** Medium | **Risk:** [RISK: Webhook endpoint requires inbound network access]

The monitor shall support Jira webhooks for real-time status transition detection, complementing the polling mechanism.

**Webhook Endpoint:**
- `POST /webhooks/jira` — receives Jira webhook events
- Validates signature using `webhookSecret` from config
- Processes `jira:issue_updated` events with status changes

**Security:**
- Validates `X-Jira-Webhook-Signature` header using HMAC SHA-256
- Rejects requests with invalid or missing signatures
- Rate limits per source IP to prevent abuse

**Acceptance Criteria:**
- AC-020-1: Given a Jira webhook with valid signature containing an issue status transition to startStatus, when received, then the monitor triggers the workflow within 5 seconds.
- AC-020-2: Given a Jira webhook with invalid signature, when received, then the monitor rejects the request with 401 Unauthorized and logs a security warning.
- AC-020-3: Given webhooks are enabled and a status transition occurs, when the webhook is received before the next poll, then only the webhook triggers (no duplicate from poll).
- AC-020-4: Given `foreman doctor` is run, when webhooks are configured, then it tests webhook endpoint connectivity and reports "Webhook: Configured" or "Webhook: Unreachable".

---

## 6. Non-Functional Requirements

NFRs are covered in REQ-016 (Detection Latency), REQ-017 (Resource Usage), and REQ-018 (Scalability).

---

## 7. Dependency Map

| REQ | Depends On | Blocked By | Notes |
|-----|------------|------------|-------|
| REQ-003 | REQ-001, REQ-002 | — | Status detection requires API client + config |
| REQ-004 | REQ-002 | — | Mapping defined in project config |
| REQ-005 | REQ-003, REQ-004, REQ-012 | — | Trigger requires detection + mapping + uniqueness check |
| REQ-006 | REQ-005, REQ-019 | — | Debounce applies to triggers; state persisted per REQ-019 |
| REQ-008 | REQ-002 | — | Lifecycle integrated with sentinel |
| REQ-009 | REQ-005 | — | Observability events emitted on trigger |
| REQ-012 | REQ-005 | — | Uniqueness checked at trigger time (prerequisite) |
| REQ-013 | REQ-002 | — | Validation at config load time |
| REQ-014 | REQ-006, REQ-019 | — | Shutdown persists debounce state |
| REQ-015 | REQ-001 | — | API version uses API client |
| REQ-016 | REQ-003, REQ-020 | — | Latency targets for both polling and webhooks |
| REQ-020 | REQ-002, REQ-003 | — | Webhook handler uses transition detection logic |

**Implementation Clusters:**
1. **Core Infrastructure**: REQ-001, REQ-002, REQ-013 (API client, config, validation)
2. **Detection & Trigger**: REQ-003, REQ-004, REQ-005, REQ-012 (core monitoring logic)
3. **Reliability**: REQ-006, REQ-007, REQ-011, REQ-014, REQ-019 (debounce, intervals, errors, shutdown, persistence)
4. **Integration**: REQ-008, REQ-009, REQ-010, REQ-015 (sentinel, observability, multi-project, API version)
5. **Webhooks**: REQ-020 (real-time trigger support)

---

## 8. Technical Approach

### 8.1 Module Structure

```
src/daemon/
  jira-poller.ts          # JiraIssuesPoller class (mirrors GitHubIssuesPoller)
  jira-api-client.ts      # JiraApiClient for authentication + queries
  jira-webhook-handler.ts # JiraWebhookHandler for real-time triggers
  jira-config-validator.ts # Config schema + validation
  jira-debounce-store.ts  # Persisted debounce state
  __tests__/
    jira-poller.test.ts
    jira-api-client.test.ts
    jira-webhook-handler.test.ts

src/lib/
  project-config.ts       # Add issueTracker config block
  jira-external-id.ts    # External ID formatting: jira:PROJECT-123

src/orchestrator/
  jira-trigger-handler.ts # Maps detected issues to workflow dispatch
  jira-trigger-event.ts   # Event schema definition
```

### 8.2 Configuration Schema (Extension to ProjectConfig)

```typescript
interface JiraConfig {
  apiUrl: string;
  email: string;
  apiTokenEnvVar: string; // e.g., "JIRA_API_TOKEN"
  pollIntervalSeconds?: number; // default: 60
  webhookEnabled?: boolean; // default: false
  webhookSecretEnvVar?: string; // e.g., "JIRA_WEBHOOK_SECRET"
  projects: JiraProjectConfig[];
}

interface JiraProjectConfig {
  key: string; // normalized to uppercase
  startStatus: string[];
  endStatus: string[];
  issueTypeWorkflowMap: Record<string, string>;
  debounceWindowSeconds?: number; // default: 60
}

interface ProjectConfig {
  // ... existing fields ...
  issueTracker?: {
    backend: "jira" | "github" | "linear";
    jira?: JiraConfig;
  };
}
```

### 8.3 Polling Strategy with Transition Detection

```typescript
// Pseudocode for transition detection
interface IssueState {
  key: string;           // e.g., "PROJ-123"
  lastKnownStatus: string;
  lastTriggeredAt?: number;
}

async function detectTransitions(
  project: JiraProjectConfig,
  lastPoll: Date,
  state: Map<string, IssueState>
): Promise<JiraIssue[]> {
  const jql = buildJql(project, lastPoll);
  const issues = await jiraClient.search(jql);
  
  return issues.filter(issue => {
    const currentStatus = issue.status.name;
    const previousState = state.get(issue.key);
    const wasInStartStatus = previousState 
      ? project.startStatus.includes(previousState.lastKnownStatus)
      : false;
    const isNowInStartStatus = project.startStatus.includes(currentStatus);
    
    // Trigger if: now in startStatus AND (wasn't before OR no prior state)
    const isNewTransition = isNowInStartStatus && !wasInStartStatus;
    
    // Update state
    state.set(issue.key, {
      key: issue.key,
      lastKnownStatus: currentStatus,
      lastTriggeredAt: isNewTransition ? Date.now() : previousState?.lastTriggeredAt
    });
    
    return isNewTransition;
  });
}

function buildJql(project: JiraProjectConfig, since: Date): string {
  const statusClause = project.startStatus.map(s => `status = "${s}"`).join(" OR ");
  return `project = ${project.key.toUpperCase()} AND (${statusClause}) AND updated >= "${since.toISOString()}"`;
}
```

### 8.4 Event Schema

```typescript
interface JiraTriggerEvent {
  type: "jira-trigger";      // event discriminator
  timestamp: string;          // ISO 8601
  source: "poll" | "webhook"; // detection method
  projectKey: string;         // e.g., "PROJ"
  issueId: string;            // e.g., "PROJ-123"
  workflowName: string;       // e.g., "default"
  externalId: string;         // e.g., "jira:PROJ-123"
}
```

### 8.5 Debounce State Persistence

```typescript
// Debounce state stored in ~/.foreman/jira-debounce.json
interface DebounceEntry {
  issueKey: string;      // e.g., "PROJ-123"
  triggeredAt: number;   // Unix timestamp
  expiresAt: number;     // triggeredAt + debounceWindowSeconds
}

interface DebounceStore {
  entries: Map<string, DebounceEntry>;
  save(): Promise<void>;
  load(): Promise<void>;
  isDebounced(issueKey: string): boolean;
  setDebounced(issueKey: string, windowSeconds: number): void;
  cleanup(): void; // Remove expired entries
}
```

### 8.6 Webhook Handler

```typescript
// POST /webhooks/jira
async function handleJiraWebhook(req: Request): Promise<Response> {
  const signature = req.headers.get("X-Jira-Webhook-Signature");
  const secret = process.env[JIRA_WEBHOOK_SECRET_ENV_VAR];
  
  // Validate signature
  if (!validateSignature(req.body, signature, secret)) {
    return new Response("Unauthorized", { status: 401 });
  }
  
  const event = JSON.parse(req.body);
  if (event.webhookEvent !== "jira:issue_updated") {
    return new Response("OK", { status: 200 }); // Ignore non-update events
  }
  
  const statusChange = event.issue.fields.status;
  const issueKey = event.issue.key;
  
  // Use same transition detection logic as polling
  // Check if new status is in startStatus and wasn't before
  await processTransition(issueKey, statusChange);
  
  return new Response("OK", { status: 200 });
}

function validateSignature(body: string, signature: string, secret: string): boolean {
  const expected = crypto.createHmac("sha256", secret)
    .update(body)
    .digest("base64");
  return signature === expected;
}
```

---

## 9. Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|-----|-------------|----------|------------|----------|
| REQ-001 | Jira API Client (Basic Auth) | Must | Medium | 4 |
| REQ-002 | Project-Level Issue Tracker Config | Must | Medium | 6 |
| REQ-003 | Status Transition Detection | Must | Medium | 5 |
| REQ-004 | Issue Type to Workflow Mapping | Must | Low | 3 |
| REQ-005 | Workflow Trigger Execution | Must | Medium | 4 |
| REQ-006 | Debounce Mechanism | Should | Low | 3 |
| REQ-007 | Poll Interval Configuration | Should | Low | 3 |
| REQ-008 | Daemon Lifecycle Management | Should | Medium | 4 |
| REQ-009 | Monitoring and Observability | Should | Medium | 3 |
| REQ-010 | Multi-Project Support | Could | Medium | 2 |
| REQ-011 | Error Recovery and Rate Limiting | Should | Medium | 4 |
| REQ-012 | External ID Uniqueness | Must | Low | 3 |
| REQ-013 | Configuration Validation | Must | Low | 4 |
| REQ-014 | Graceful Shutdown | Could | Low | 2 |
| REQ-015 | Jira API Version Support | Should | Low | 2 |
| REQ-016 | Detection Latency | Must | Low | 2 |
| REQ-017 | Resource Usage | Should | Low | 2 |
| REQ-018 | Scalability | Could | Medium | 2 |
| REQ-019 | Debounce State Persistence | Must | Medium | 3 |
| REQ-020 | Webhook Trigger Support | Must | Medium | 4 |

**Total: 20 requirements, 67 acceptance criteria**

---

## 10. Resolved Issues Summary

The following issues were identified and resolved during adversarial review:

| # | Issue | Resolution |
|---|-------|------------|
| 1 | Ambiguous authentication method | Specified Basic Auth (email + API token) with env var reference |
| 2 | Unclear transition detection behavior | Clarified: only new transitions trigger, not existing startStatus issues |
| 3 | Updated-but-unchanged status false positives | Added `lastKnownStatus` tracking per issue |
| 4 | Ambiguous observability event schema | Defined explicit `JiraTriggerEvent` interface with `source` field |
| 5 | REQ-005 vs REQ-012 contradiction | Specified REQ-012 as prerequisite check for REQ-005 |
| 6 | Unclear rate limit handling | Added explicit Retry-After + exponential backoff (max 5 min) |
| 7 | Project key case sensitivity | Specified uppercase normalization + doctor validation |
| 8 | Debounce state not persisted | Added REQ-019: Debounce State Persistence |
| 9 | Webhook support missing | Added REQ-020: Webhook Trigger Support |

*(Issues 1-7 resolved during initial PRD creation; issues 8-9 resolved during refinement)*

---

## 11. Open Questions

**All resolved:**
1. ~~Should debounce state be persisted across sentinel restarts?~~ → **Yes, persist**
2. ~~Should multiple Jira instances per project be supported?~~ → **No, single instance per project**
3. ~~Should webhooks be added alongside polling?~~ → **Yes, add webhooks**

---

## 12. References

- [PRD-2026-011: GitHub Issues Integration](./PRD-2026-011-github-issues-integration.md) — Similar pattern for GitHub
- [PRD-2026-012: Inbox Tabular View](./PRD-2026-012-inbox-tabular-view.md) — Recent PRD for style reference
- [Workflow YAML Reference](../workflow-yaml-reference.md) — Workflow configuration
- [VcsBackend Interface Reference](../guides/vcs-backend-interface.md) — Backend abstraction pattern

---

## Changelog

| Version | Date | Changes |
|---------|------|---------|
| 1.0.0 | 2026-06-01 | Initial draft — 18 requirements covering Jira API client, config, detection, trigger, debounce, observability |
| 1.1.0 | 2026-06-01 | Adversarial review: clarified transition detection, added lastKnownStatus tracking, defined event schema, added rate limit handling, specified project key normalization |
| 1.2.0 | 2026-06-01 | Refinement: resolved Open Questions — added REQ-019 (Debounce State Persistence), REQ-020 (Webhook Trigger Support), added Readiness Score to frontmatter, streamlined resolved issues section |

---

## Implementation Readiness Gate

| Dimension | Score (1-5) | Notes |
|-----------|-------------|-------|
| **Completeness** | 5 | All feature areas covered, 20 requirements, 67 ACs |
| **Testability** | 5 | Every Must/Should has verifiable ACs in Given/When/Then format |
| **Clarity** | 5 | Requirements are user-observable; event schema defined; all open questions resolved |
| **Feasibility** | 4 | Mirrors existing GitHubIssuesPoller pattern; webhook requires inbound network access |

**Average Score: 4.75 / 5.0 — PASS** ✓