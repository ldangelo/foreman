# PRD-2026-003: Agent Mail-Driven Phase Transitions and Externalized Configuration

**Document ID:** PRD-2026-003
**Version:** 1.2
**Status:** Draft (v1.2)
**Date:** 2026-03-21
**Author:** Product Management
**Stakeholders:** Engineering (Foreman maintainers), Foreman operators, Prompt engineers, Team leads
**Requirements:** 26 (REQ-001 through REQ-026)

---

## Version History

| Version | Date | Author | Changes |
|---------|------|--------|---------|
| 1.0 | 2026-03-21 | Product Management | Initial draft covering Agent Mail read transport (Part 1) and externalized prompts/workflow config (Part 2) |
| 1.1 | 2026-03-21 | Product Management | Added REQ-023 (Explorer report read path); added REQ-024 (workflow-phase cross-validation); added REQ-025 (finalize enforcement); added REQ-026 (stale message filtering via runId). Clarified retry semantics when Reviewer absent (REQ-012). Specified Reproducer failure behavior as markStuck (REQ-015). Specified AbortController timeout mechanism (REQ-022). Clarified nested `{{#if}}` as greedy match (REQ-008). Closed OQ-2 (finalize enforcement). Total: 26 requirements, 109 ACs. |
| 1.2 | 2026-03-21 | Product Management | Updated AC-019-2: empty workflow arrays are now rejected by finalize enforcement (REQ-025) rather than passed through. Resolves conflict between AC-019-2 and REQ-025. |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [Problem Statement](#2-problem-statement)
3. [Goals and Non-Goals](#3-goals-and-non-goals)
4. [User Personas](#4-user-personas)
5. [Current State Analysis](#5-current-state-analysis)
6. [Solution Overview](#6-solution-overview)
7. [Functional Requirements -- Part 1: Agent Mail as Primary Report Transport](#7-functional-requirements----part-1-agent-mail-as-primary-report-transport)
8. [Functional Requirements -- Part 2: Externalized Prompts and Workflow Config](#8-functional-requirements----part-2-externalized-prompts-and-workflow-config)
9. [Non-Functional Requirements](#9-non-functional-requirements)
10. [Implementation Strategy](#10-implementation-strategy)
11. [Risks and Mitigations](#11-risks-and-mitigations)
12. [Acceptance Criteria Summary](#12-acceptance-criteria-summary)
13. [Success Metrics](#13-success-metrics)
14. [Release Plan](#14-release-plan)
15. [Open Questions](#15-open-questions)

---

## 1. Executive Summary

Foreman's agent pipeline already sends inter-phase reports as Agent Mail messages (Explorer report to Developer inbox, QA feedback to Developer inbox, QA report to Reviewer inbox). However, the pipeline still **reads** phase outputs exclusively from disk files (`EXPLORER_REPORT.md`, `QA_REPORT.md`, `REVIEW.md`). This PRD closes that gap: Agent Mail inbox reads become the primary transport for inter-phase report content, with disk files retained as an automatic fallback when Agent Mail is unavailable.

Additionally, Foreman's phase system prompts are hardcoded as TypeScript template literals in `roles.ts`, and the pipeline phase sequence is hardcoded in `agent-worker.ts`. This PRD externalizes both: prompts move to user-editable markdown files in `~/.foreman/prompts/`, phase mechanical config (model, budget, tools) moves to `~/.foreman/phases.json`, and pipeline phase sequences move to `~/.foreman/workflows.json` keyed by seed type (feature, bug, chore, docs). This enables prompt engineers to tune agent behavior and team leads to define custom workflows without rebuilding TypeScript.

The two parts are independently shippable. Part 1 requires approximately 60 lines of new code plus targeted modifications. Part 2 introduces three new loader modules and a config seeding step in `foreman init`.

---

## 2. Problem Statement

### 2.1 Agent Mail Sends Without Reads

Every pipeline phase already sends its report as an Agent Mail message to the next phase's inbox. The messages are arriving but never consumed -- the pipeline reads exclusively from disk. This means Agent Mail provides no actual transport value today; it is write-only overhead. The investment in Agent Mail integration (PRD-2026-002) is not paying off until the read path is wired up.

### 2.2 Reviewer Retry Gap

When the Reviewer triggers a Developer retry, its findings are passed through a local JavaScript variable -- never into the Developer's Agent Mail inbox. This is the only phase transition that lacks a corresponding Agent Mail send, creating an asymmetry in the message flow that complicates observability and future automation.

### 2.3 `acknowledgeMessage()` Registry Bug

`fetchInbox()` resolves logical role names (e.g., `"developer-bd-abc1"`) to their registered Agent Mail names via `this.agentRegistry`. `acknowledgeMessage()` does not. This means any code that reads from an inbox and then acknowledges the message will fail silently on the acknowledge step, leaving messages in an unacknowledged state indefinitely.

### 2.4 Hardcoded Prompts

Phase system prompts are TypeScript template literals in `roles.ts` (`explorerPrompt()`, `developerPrompt()`, `qaPrompt()`, `reviewerPrompt()`). Changing a single line of a prompt requires editing TypeScript source, rebuilding the project, and redeploying. There is no way for an operator or prompt engineer to customize phase behavior without access to the source code.

### 2.5 Hardcoded Pipeline Sequence

The phase sequence (Explorer -> Developer <-> QA -> Reviewer -> Finalize) is hardcoded in `agent-worker.ts`. All seed types follow the same sequence regardless of their nature. Bugs run through Explorer (unnecessary for known issues), chores run through QA and Reviewer (unnecessary for configuration changes), and there is no way to define a Reproducer phase for bugs without modifying TypeScript source.

### 2.6 Hardcoded Phase Mechanical Config

Phase configuration (model, budget, allowed tools) is defined in `ROLE_CONFIGS` within `roles.ts`. While environment variable overrides exist (`FOREMAN_EXPLORER_MODEL` etc.), there is no single configuration file that an operator can review and edit to understand or change the complete phase setup.

---

## 3. Goals and Non-Goals

### 3.1 Goals

1. **Make Agent Mail the primary read path** for inter-phase report content (Explorer report, QA feedback, Reviewer findings), with disk files as automatic fallback.
2. **Close the Reviewer send gap** by sending Reviewer findings to the Developer inbox on retry, matching the pattern already established by QA feedback sends.
3. **Fix `acknowledgeMessage()` registry resolution** so it matches `fetchInbox()` behavior, enabling reliable message acknowledgment.
4. **Externalize phase prompts** to user-editable markdown files in `~/.foreman/prompts/` with `{{variable}}` and `{{#if var}}...{{/if}}` template syntax.
5. **Externalize phase config** (model, budget, tools) to `~/.foreman/phases.json`.
6. **Externalize pipeline phase sequences** to `~/.foreman/workflows.json`, keyed by seed type, enabling different workflows for bugs vs features vs chores.
7. **Seed defaults on `foreman init`** so operators have working config files to customize from day one.
8. **Maintain full backward compatibility** -- absent config files fall back to built-in TypeScript defaults; absent or down Agent Mail falls back to disk reads.

### 3.2 Non-Goals

- **Changing the Agent Mail send paths**: All existing sends (Explorer report, QA feedback, QA report, phase-complete events) are already implemented and remain unchanged.
- **Adding new Agent Mail server features**: No new Agent Mail API endpoints are required. Only the existing `fetchInbox` and `acknowledgeMessage` client methods are used.
- **Removing disk-file reports**: `EXPLORER_REPORT.md`, `QA_REPORT.md`, `REVIEW.md` continue to be written for backward compatibility and debugging.
- **Modifying SQLite schema**: No database changes are required for either part.
- **Changing `foreman status` or `foreman monitor`**: Both commands continue to work unchanged.
- **Implementing a full template engine**: Only `{{variable}}` substitution and `{{#if var}}...{{/if}}` conditionals are supported. No nesting, no loops, no partials.
- **Removing `roles.ts` prompt functions**: The existing TypeScript functions are retained as fallback defaults. No deletions.

---

## 4. User Personas

### 4.1 Foreman Operator (Primary)

A DevOps or senior engineer who runs `foreman run` to dispatch agents. Benefits from Agent Mail transport providing more reliable inter-phase communication with automatic fallback. Benefits from customizable workflows that match team processes -- bugs skip Explorer, chores skip QA and Reviewer. Currently frustrated by one-size-fits-all pipeline sequences and inability to tune agent prompts without code changes.

### 4.2 Prompt Engineer (Primary)

An engineer or AI specialist who tunes agent behavior by editing prompt files. Wants to iterate on phase prompts without rebuilding TypeScript -- edit `~/.foreman/prompts/developer.md`, re-run `foreman run`, and see the effect immediately. Uses `{{variable}}` placeholders to inject task-specific context and `{{#if}}` conditionals to include/exclude sections based on pipeline state (e.g., feedback context on retry).

### 4.3 Team Lead (Secondary)

Defines custom workflows in `~/.foreman/workflows.json` to match team processes. Wants bugs to run through a Reproducer phase instead of Explorer, chores to skip QA and Reviewer, and docs tasks to go straight to Developer and Finalize. Benefits from a single JSON file that documents and controls the entire workflow configuration.

---

## 5. Current State Analysis

### 5.1 Agent Mail Message Flow (What Already Works)

| Phase Transition | Subject | From -> To | Status |
|---|---|---|---|
| Explorer -> Developer | `"Explorer Report"` | worker -> `developer-{seedId}` | Sends only; Developer reads from disk |
| QA -> Developer (fail) | `"QA Feedback - Retry N"` | worker -> `developer-{seedId}` | Sends only; Developer reads from disk |
| QA -> Reviewer (pass) | `"QA Report"` | worker -> `reviewer-{seedId}` | Sends only; Reviewer reads from disk |
| Phase completion | `"phase-complete"` | worker -> `foreman` | Working end-to-end |
| Reviewer -> Developer | *(not implemented)* | *(local variable only)* | Gap -- no send at all |

### 5.2 Pipeline Phase Configuration (What Exists)

| Component | Current Location | Customizable? |
|---|---|---|
| Phase prompts | `roles.ts` -- TypeScript template literals | No (requires rebuild) |
| Phase model/budget/tools | `roles.ts` -- `ROLE_CONFIGS` object | Partially (env var overrides for model only) |
| Pipeline phase sequence | `agent-worker.ts` -- hardcoded in `runPipeline()` | No |
| Phase prompt variables | Passed as function arguments to `explorerPrompt()` etc. | No |

### 5.3 Key Integration Points

| Component | File | Relevance |
|---|---|---|
| `fetchInbox()` | `agent-mail-client.ts` | Already resolves logical role names via `agentRegistry` |
| `acknowledgeMessage()` | `agent-mail-client.ts` | Does NOT resolve logical role names (bug) |
| `sendMailText()` | `agent-worker.ts` | Fire-and-forget mail helper used by all phase sends |
| `readReport()` | `agent-worker.ts` | Disk-based report reader (will become fallback) |
| `explorerPrompt()` et al. | `roles.ts` | Template literal functions (will become fallback defaults) |
| `ROLE_CONFIGS` | `roles.ts` | Phase config map (will become fallback defaults) |
| `runPipeline()` | `agent-worker.ts` | Hardcoded phase sequence (will use workflow loader) |
| `buildRoleConfigs()` | `roles.ts` | Config builder with env var overrides (will use phase config loader) |

---

## 6. Solution Overview

### 6.1 Architecture Decision: Option A (Message-Triggered Sequential)

Four architectural options were evaluated for Part 1:

| | **Option A (chosen)** | Option B (Daemons) | Option C (Central SM) | Option D (Threads) |
|---|---|---|---|---|
| New code (lines) | ~60 | ~800+ | ~500+ | ~200+ |
| New processes | 0 | 4 daemons | 0 | 0 |
| Schema changes | none | `pipeline_state` | new table | none |
| Phase transition latency | 0 ms | 0 ms | up to 30 s/phase | 0 ms |
| Backward compat (no mail) | Full (disk fallback) | None | None | None |
| `foreman status` unchanged | Yes | Needs update | Needs update | Yes |
| Requires new Agent Mail API | No | No | No | Yes (`fetchThread`) |

**Why Option A:** The sequential `await`-chain in `runPipeline()` stays unchanged. No new processes. No SQLite schema changes. Disk files remain as fallback. The entire Part 1 change is ~60 lines of new code plus targeted read-path modifications.

### 6.2 Part 1: Message Flow After Implementation

```
Explorer --- sdk.query() -------------------------------------------------->
  +-- sendMailText -> "developer-{seedId}"  "Explorer Report"        [already done]
  +-- writes EXPLORER_REPORT.md                                       [kept as fallback]

Developer <-- feedbackContext from prior QA or Review message (or null on first run)
  +-- writes implementation files

QA --- sdk.query() -------------------------------------------------------->
  [FAIL] +-- sendMailText -> "developer-{seedId}"  "QA Feedback - Retry N"  [already done]
  [PASS] +-- sendMailText -> "reviewer-{seedId}"   "QA Report"              [already done]

Developer (retry) <-- fetchLatestPhaseMessage("developer-{seedId}", "QA Feedback")   [NEW read]
                  <-- fallback: QA_REPORT.md on disk

Reviewer --- sdk.query() -------------------------------------------------->
  [issues] +-- sendMailText -> "developer-{seedId}"  "Review Findings"      [NEW send]
  +-- sendMailText -> "foreman"  "Review Complete"                           [already done]

Developer (retry) <-- fetchLatestPhaseMessage("developer-{seedId}", "Review Findings") [NEW read]
                  <-- fallback: local reviewFeedback variable

Finalize --> sends "branch-ready" to refinery                               [already done]
```

### 6.3 Part 2: Externalized Configuration Layout

```
~/.foreman/
  prompts/
    explorer.md       <-- system prompt for Explorer phase
    developer.md      <-- system prompt for Developer phase (supports {{variables}})
    qa.md             <-- system prompt for QA phase
    reviewer.md       <-- system prompt for Reviewer phase
    reproducer.md     <-- system prompt for Reproducer phase (bug workflow)
  phases.json         <-- model, budget, tools per phase
  workflows.json      <-- phase sequence per seed type
```

### 6.4 Template Variable System

Prompt markdown files use `{{variableName}}` placeholders. Missing variables render as empty string, never as literal `{{...}}`.

| Variable | Available in phases | Description |
|---|---|---|
| `{{seedId}}` | all | Bead/seed ID (e.g. `bd-abc1`) |
| `{{seedTitle}}` | all | One-line title of the task |
| `{{seedDescription}}` | explorer, developer, reviewer | Full task description |
| `{{seedComments}}` | explorer, developer, reviewer | Comments from the bead |
| `{{feedbackContext}}` | developer | QA or Reviewer findings injected on retry |
| `{{hasExplorerReport}}` | developer | `"true"` or `"false"` |

Conditional blocks use `{{#if variable}}...{{/if}}` (simple truthy check, no nesting):

```markdown
{{#if feedbackContext}}
## Prior Feedback

{{feedbackContext}}
{{/if}}
```

### 6.5 Workflow Configuration

Defines which phases run for each seed type. Unknown types fall back to `"feature"`.

```json
{
  "feature": ["explorer", "developer", "qa", "reviewer", "finalize"],
  "bug":     ["reproducer", "developer", "qa", "finalize"],
  "chore":   ["developer", "finalize"],
  "docs":    ["developer", "finalize"]
}
```

### 6.6 Phase Configuration

Replaces `buildRoleConfigs()` / `ROLE_CONFIGS` in `roles.ts`. Environment variable overrides (`FOREMAN_EXPLORER_MODEL` etc.) still take precedence.

```json
{
  "explorer": {
    "model": "claude-haiku-4-5-20251001",
    "maxBudgetUsd": 1.00,
    "allowedTools": ["Glob", "Grep", "Read", "Write"],
    "reportFile": "EXPLORER_REPORT.md",
    "promptFile": "explorer.md"
  },
  "developer": {
    "model": "claude-sonnet-4-6",
    "maxBudgetUsd": 5.00,
    "allowedTools": ["Agent", "Bash", "Edit", "Glob", "Grep", "Read", "TaskOutput", "TaskStop", "TodoWrite", "WebFetch", "WebSearch", "Write"],
    "reportFile": "DEVELOPER_REPORT.md",
    "promptFile": "developer.md"
  },
  "qa": {
    "model": "claude-sonnet-4-6",
    "maxBudgetUsd": 3.00,
    "allowedTools": ["Bash", "Edit", "Glob", "Grep", "Read", "TodoWrite", "Write"],
    "reportFile": "QA_REPORT.md",
    "promptFile": "qa.md"
  },
  "reviewer": {
    "model": "claude-sonnet-4-6",
    "maxBudgetUsd": 2.00,
    "allowedTools": ["Glob", "Grep", "Read", "Write"],
    "reportFile": "REVIEW.md",
    "promptFile": "reviewer.md"
  },
  "reproducer": {
    "model": "claude-sonnet-4-6",
    "maxBudgetUsd": 1.50,
    "allowedTools": ["Bash", "Glob", "Grep", "Read", "Write"],
    "reportFile": "REPRODUCER_REPORT.md",
    "promptFile": "reproducer.md"
  }
}
```

---

## 7. Functional Requirements -- Part 1: Agent Mail as Primary Report Transport

### REQ-001: `acknowledgeMessage()` Registry Resolution Fix (P0)

Fix `acknowledgeMessage()` in `agent-mail-client.ts` to resolve logical role names through `this.agentRegistry`, matching the existing behavior of `fetchInbox()`. Without this fix, messages fetched from an inbox using a logical role name cannot be acknowledged, leaving them in an unacknowledged state.

- AC-001-1: Given a logical role name (e.g., `"developer-bd-abc1"`), when `acknowledgeMessage(roleName, messageId)` is called, then the method resolves the role name through `this.agentRegistry` before making the API call, matching `fetchInbox()` behavior.
- AC-001-2: Given a role name that is NOT in the agent registry, when `acknowledgeMessage()` is called, then the raw role name is passed through unchanged (graceful fallback).
- AC-001-3: Given the fix is applied, when `fetchLatestPhaseMessage()` reads and acknowledges a message, then the acknowledge succeeds without error for registered agents.

### REQ-002: `fetchLatestPhaseMessage()` Helper (P0)

Implement a module-scope helper function in `agent-worker.ts` that reads the most recent unacknowledged message from an Agent Mail inbox whose subject starts with a given prefix, acknowledges it, and returns the message body. The function must be intentionally non-throwing -- any failure returns `null` and the caller falls back to disk.

- AC-002-1: Given `client` is not null, when `fetchLatestPhaseMessage(client, inboxRole, subjectPrefix)` is called and a matching unacknowledged message exists, then the function returns `message.body` and calls `acknowledgeMessage()`.
- AC-002-2: Given `client` is not null, when no message matches the subject prefix, then the function returns `null`.
- AC-002-3: Given `client` is not null, when all matching messages are already acknowledged, then the function returns `null`.
- AC-002-4: Given `client` is not null and multiple messages match the subject prefix, when `fetchLatestPhaseMessage()` is called, then it returns the body of the most recent message (sorted by `receivedAt` descending).
- AC-002-5: Given `client` is `null` (Agent Mail not configured), when `fetchLatestPhaseMessage()` is called, then it returns `null` immediately without making any API calls.
- AC-002-6: Given `client.fetchInbox()` throws an error, when `fetchLatestPhaseMessage()` is called, then the error is caught, logged as non-fatal, and `null` is returned.
- AC-002-7: Given `client.acknowledgeMessage()` throws an error after a successful fetch, when the acknowledge fails, then the message body is still returned (acknowledge failure is non-fatal).

### REQ-003: QA Feedback Read Path via Agent Mail (P0)

Update the Dev<->QA retry loop in `runPipeline()` so that after `runPhase("qa")` returns, the QA feedback is read from the Developer's Agent Mail inbox first, falling back to the `QA_REPORT.md` disk file when Agent Mail is unavailable or the message is missing.

- AC-003-1: Given Agent Mail is available and a `"QA Feedback"` message exists in the Developer inbox, when the QA phase completes with a FAIL verdict, then `fetchLatestPhaseMessage()` reads the message body and it is used as `feedbackContext` for the Developer retry.
- AC-003-2: Given Agent Mail is unavailable (client is null or server is down), when the QA phase completes with a FAIL verdict, then `readReport(worktreePath, "QA_REPORT.md")` is used as the fallback, and the pipeline continues without error.
- AC-003-3: Given Agent Mail is available but no matching message exists (e.g., message was already acknowledged or send failed), when the QA phase completes, then the disk fallback is used transparently.
- AC-003-4: Given the QA feedback is read from Agent Mail, when the verdict is parsed via `parseVerdict()`, then the result is identical to parsing the equivalent disk file content.

### REQ-004: Reviewer Findings Send to Developer Inbox (P1)

When the Reviewer triggers a Developer retry, send the extracted review findings to the Developer's Agent Mail inbox as a `"Review Findings"` message. This closes the only phase transition that lacks a corresponding Agent Mail send.

- AC-004-1: Given the Reviewer verdict is FAIL (or PASS with issues) and `devRetries < MAX_DEV_RETRIES`, when the retry block executes, then `sendMailText(agentMailClient, "developer-{seedId}", "Review Findings", reviewFeedback)` is called.
- AC-004-2: Given `reviewReport` is null or empty, when the retry block executes, then no Agent Mail message is sent (guard against sending empty content).
- AC-004-3: Given Agent Mail is unavailable, when the send fails silently (fire-and-forget), then the pipeline continues using the local `reviewFeedback` variable as before.

### REQ-005: Reviewer Findings Read Path via Agent Mail (P1)

Update the Reviewer->Developer feedback path so that review findings are read from the Developer's Agent Mail inbox first, falling back to the local `reviewFeedback` variable.

- AC-005-1: Given Agent Mail is available and a `"Review Findings"` message exists in the Developer inbox, when the Developer retry is prepared, then `fetchLatestPhaseMessage()` reads the message body and it is used as the feedback context.
- AC-005-2: Given Agent Mail is unavailable or no matching message exists, when the Developer retry is prepared, then the local `reviewFeedback` variable (extracted from the disk-based `REVIEW.md`) is used as fallback.
- AC-005-3: Given the review findings are read from Agent Mail, when they are passed to `developerPrompt()`, then the prompt renders identically to the disk-based path.

### REQ-006: Backward Compatibility -- Zero Regression Without Agent Mail (P0)

The entire Agent Mail read path must be transparent when Agent Mail is unavailable. No errors, no warnings, no behavior changes.

- AC-006-1: Given `agentMailClient` is `null` (Agent Mail not configured), when the full pipeline runs (Explorer -> Developer <-> QA -> Reviewer -> Finalize), then every phase completes successfully using disk-file reads, with no Agent Mail-related log messages.
- AC-006-2: Given Agent Mail server is running but goes down mid-pipeline, when a `fetchLatestPhaseMessage()` call fails, then the error is caught, logged as non-fatal at debug level, and the disk fallback is used seamlessly.
- AC-006-3: Given no Agent Mail configuration exists, when `foreman status` and `foreman monitor` are invoked, then they display identical output to the current implementation.

### REQ-007: Part 1 Unit Tests (P0)

Comprehensive unit tests for `fetchLatestPhaseMessage()` covering all edge cases.

- AC-007-1: Given a mock `AgentMailClient` returning a matching unacknowledged message, when `fetchLatestPhaseMessage()` is called, then it returns the message body and calls `acknowledgeMessage()` with the correct arguments.
- AC-007-2: Given a mock client returning messages with non-matching subjects, when called, then it returns `null`.
- AC-007-3: Given a mock client returning only acknowledged messages, when called, then it returns `null`.
- AC-007-4: Given a mock client returning two messages with the same subject prefix but different `receivedAt` timestamps, when called, then it returns the body of the more recent message.
- AC-007-5: Given `client` is `null`, when called, then it returns `null` immediately with zero mock interactions.
- AC-007-6: Given a mock client where `fetchInbox()` throws, when called, then it returns `null` and logs a non-fatal warning.
- AC-007-7: Given a mock client where `acknowledgeMessage()` throws after a successful fetch, when called, then it returns the message body anyway (non-fatal acknowledge failure).

### REQ-023: Explorer Report Read Path via Agent Mail (P0)

Read the Explorer report from the Developer's Agent Mail inbox first, falling back to `EXPLORER_REPORT.md` on disk when Agent Mail is unavailable or the message is missing. The Explorer report is already sent to `developer-{seedId}` with subject `"Explorer Report"` — this requirement adds the corresponding read path.

- AC-023-1: Given Agent Mail is available and an `"Explorer Report"` message exists in the Developer inbox, when the Developer phase is about to start, then `fetchLatestPhaseMessage()` reads the message body and it is used as the Explorer report context for the Developer.
- AC-023-2: Given Agent Mail is unavailable (client is null or server is down), when the Developer phase is about to start, then `readReport(worktreePath, "EXPLORER_REPORT.md")` is used as the fallback, and the pipeline continues without error.
- AC-023-3: Given Agent Mail is available but no matching `"Explorer Report"` message exists, when the Developer phase starts, then the disk fallback is used transparently.
- AC-023-4: Given the Explorer report is read from Agent Mail, when it is used to set `hasExplorerReport` and populate context for `developerPrompt()`, then the behavior is identical to reading the same content from disk.

---

## 8. Functional Requirements -- Part 2: Externalized Prompts and Workflow Config

### REQ-008: Prompt Loader Utility (P1)

Implement `src/lib/prompt-loader.ts` that loads a phase prompt from `~/.foreman/prompts/{phase}.md`, falling back to the built-in default from `roles.ts` if the file is absent. The loader substitutes `{{variable}}` placeholders and processes `{{#if var}}...{{/if}}` conditional blocks.

- AC-008-1: Given `~/.foreman/prompts/explorer.md` exists with `{{seedId}}` and `{{seedTitle}}` placeholders, when `loadPrompt("explorer", { seedId: "bd-abc1", seedTitle: "Fix login" }, fallback)` is called, then the returned string has all placeholders replaced with their values.
- AC-008-2: Given a prompt file containing `{{#if feedbackContext}}...{{/if}}`, when `feedbackContext` is undefined or empty string, then the entire conditional block (including content) is omitted from the output.
- AC-008-3: Given a prompt file containing `{{#if feedbackContext}}...{{/if}}`, when `feedbackContext` is a non-empty string, then the block content is included with the `{{#if}}` and `{{/if}}` markers removed.
- AC-008-4: Given `~/.foreman/prompts/explorer.md` does NOT exist, when `loadPrompt("explorer", vars, fallback)` is called, then the `fallback` string is used as the template and variable substitution is still applied.
- AC-008-5: Given a prompt file with `{{unknownVariable}}`, when the variable is not in the provided variables map, then the placeholder is replaced with an empty string (not left as literal `{{unknownVariable}}`).
- AC-008-6: Given a prompt file with leading/trailing whitespace after rendering, when the template is processed, then the result is trimmed.
- AC-008-7: Given a prompt file with nested `{{#if a}}...{{#if b}}...{{/if}}...{{/if}}` blocks, when the template is rendered, then the regex uses greedy matching on the outermost `{{#if}}...{{/if}}` pair. Inner `{{#if}}` tags are treated as literal text within the outer block's content. This is documented as unsupported but non-breaking behavior.

### REQ-009: Phase Config Loader (P1)

Implement `src/lib/phase-config-loader.ts` that reads `~/.foreman/phases.json`, validates the schema, and falls back to `ROLE_CONFIGS` from `roles.ts` if the file is absent or invalid. Environment variable overrides (`FOREMAN_EXPLORER_MODEL` etc.) continue to take precedence over this file.

- AC-009-1: Given `~/.foreman/phases.json` exists with valid JSON matching the expected schema, when `loadPhaseConfigs()` is called, then it returns the parsed phase configuration map.
- AC-009-2: Given `~/.foreman/phases.json` does NOT exist, when `loadPhaseConfigs()` is called, then it returns `ROLE_CONFIGS` from `roles.ts` as the default.
- AC-009-3: Given `~/.foreman/phases.json` contains invalid JSON (parse error), when `loadPhaseConfigs()` is called, then it logs a warning with the error message and returns `ROLE_CONFIGS`.
- AC-009-4: Given `~/.foreman/phases.json` is valid JSON but missing a required field (e.g., `model` absent from the `explorer` entry), when `loadPhaseConfigs()` is called, then it logs a warning identifying the invalid field and returns `ROLE_CONFIGS` for the entire file.
- AC-009-5: Given `FOREMAN_EXPLORER_MODEL` env var is set, when phase config is loaded from `phases.json`, then the env var value takes precedence over the `model` field in the JSON file.

### REQ-010: Phase Config Schema Validation (P2)

Implement `validatePhaseConfig()` within the phase config loader that validates each phase entry has the required fields with correct types.

- AC-010-1: Given a phase entry, when validation runs, then it checks for: `model` (string), `maxBudgetUsd` (number), `allowedTools` (string array), `reportFile` (string), `promptFile` (string).
- AC-010-2: Given a phase entry with an extra unrecognized field, when validation runs, then the extra field is ignored (no error).
- AC-010-3: Given a phase entry with `maxBudgetUsd` as a string instead of a number, when validation runs, then the entry fails validation with a descriptive error message.
- AC-010-4: Given validation fails for any phase entry, when the error is logged, then the warning message identifies the phase name and the specific field that failed.

### REQ-011: Workflow Config Loader (P1)

Implement `src/lib/workflow-config-loader.ts` that reads `~/.foreman/workflows.json` and provides `getWorkflow(seedType)` to return the phase sequence for a given seed type. Falls back to built-in defaults when the file is absent or invalid.

- AC-011-1: Given `~/.foreman/workflows.json` exists with valid JSON, when `loadWorkflows()` is called, then it returns the parsed workflow map.
- AC-011-2: Given `~/.foreman/workflows.json` does NOT exist, when `loadWorkflows()` is called, then it returns the built-in `DEFAULT_WORKFLOWS` map.
- AC-011-3: Given `~/.foreman/workflows.json` contains invalid JSON, when `loadWorkflows()` is called, then it logs a warning and returns `DEFAULT_WORKFLOWS`.
- AC-011-4: Given a seed with `type = "bug"`, when `getWorkflow("bug")` is called, then it returns `["reproducer", "developer", "qa", "finalize"]`.
- AC-011-5: Given a seed with `type = "unknown"` (not in workflows), when `getWorkflow("unknown")` is called, then it falls back to the `"feature"` workflow: `["explorer", "developer", "qa", "reviewer", "finalize"]`.
- AC-011-6: Given a custom workflow file with a user-defined type `"spike": ["explorer", "finalize"]`, when `getWorkflow("spike")` is called, then it returns `["explorer", "finalize"]`.

### REQ-012: Wire Loaders into `runPipeline()` (P1)

Replace the hardcoded phase sequence and `ROLE_CONFIGS` reference in `agent-worker.ts` with the loaded configs from the three loader modules.

- AC-012-1: Given a seed with `type = "feature"`, when `runPipeline()` executes, then it runs phases `["explorer", "developer", "qa", "reviewer", "finalize"]` from the workflow config.
- AC-012-2: Given a seed with `type = "bug"`, when `runPipeline()` executes, then it runs phases `["reproducer", "developer", "qa", "finalize"]` -- skipping Explorer and Reviewer.
- AC-012-3: Given a seed with `type = "chore"`, when `runPipeline()` executes, then it runs phases `["developer", "finalize"]` -- skipping Explorer, QA, and Reviewer.
- AC-012-4: Given `~/.foreman/prompts/explorer.md` exists, when the Explorer phase runs, then `loadPrompt("explorer", vars, explorerPrompt(...))` provides the external prompt with the built-in `explorerPrompt()` as fallback.
- AC-012-5: Given `~/.foreman/phases.json` exists with a custom model for the Explorer phase, when the Explorer phase runs, then the custom model from `phases.json` is used (subject to env var override).
- AC-012-6: Given no external config files exist (`~/.foreman/prompts/`, `phases.json`, `workflows.json` all absent), when `runPipeline()` executes, then the pipeline behaves identically to the current hardcoded implementation.
- AC-012-7: Given a workflow that includes `"qa"` but omits `"reviewer"` (e.g., bug workflow), when QA passes, then the pipeline proceeds to the next phase in the workflow sequence (typically `"finalize"`). The Dev↔QA retry loop still runs on QA FAIL up to `MAX_DEV_RETRIES`.
- AC-012-8: Given a workflow that omits both `"qa"` and `"reviewer"` (e.g., chore workflow: `["developer", "finalize"]`), when the Developer phase completes, then the pipeline proceeds directly to Finalize with no retry loop.

### REQ-013: `foreman init` Config Seeding (P2)

Extend `foreman init` to copy bundled default configuration files to `~/.foreman/` if they do not already exist, giving operators a starting point for customization.

- AC-013-1: Given `~/.foreman/phases.json` does NOT exist, when `foreman init` runs, then the bundled default `phases.json` is copied to `~/.foreman/phases.json` and a confirmation message is printed.
- AC-013-2: Given `~/.foreman/workflows.json` does NOT exist, when `foreman init` runs, then the bundled default `workflows.json` is copied to `~/.foreman/workflows.json` and a confirmation message is printed.
- AC-013-3: Given `~/.foreman/prompts/` does NOT exist, when `foreman init` runs, then the bundled default prompt files (`explorer.md`, `developer.md`, `qa.md`, `reviewer.md`, `reproducer.md`) are copied to `~/.foreman/prompts/` and a confirmation message is printed.
- AC-013-4: Given `~/.foreman/phases.json` already exists, when `foreman init` runs, then the existing file is NOT overwritten (preserves user customizations).
- AC-013-5: Given the bundled defaults, when they are shipped with the package, then they reside in `src/defaults/` (phases.json, workflows.json, prompts/*.md) and are included in the npm package.

### REQ-014: Bundled Default Files (P1)

Create the canonical default configuration files that serve as both the bundled defaults for `foreman init` and the reference for the built-in TypeScript fallbacks.

- AC-014-1: Given `src/defaults/phases.json`, when it is read, then it contains the same configuration as the current `ROLE_CONFIGS` in `roles.ts` (matching models, budgets, tools, report files).
- AC-014-2: Given `src/defaults/workflows.json`, when it is read, then it contains the four default workflows: feature, bug, chore, docs.
- AC-014-3: Given `src/defaults/prompts/explorer.md`, when it is rendered with the standard variables, then it produces output equivalent to the current `explorerPrompt()` function.
- AC-014-4: Given `src/defaults/prompts/developer.md`, when it is rendered with `feedbackContext` present, then it includes the feedback section; when `feedbackContext` is absent, then the section is omitted (matching `developerPrompt()` behavior).
- AC-014-5: Given all five prompt files (`explorer.md`, `developer.md`, `qa.md`, `reviewer.md`, `reproducer.md`), when they use template variables, then every `{{variable}}` maps to the documented variable table in Section 6.4.

### REQ-015: Reproducer Phase for Bug Workflow (P3)

Support a Reproducer phase that runs instead of Explorer for bug-type seeds, validating that the reported bug is reproducible before Developer begins fixing it.

- AC-015-1: Given a seed with `type = "bug"`, when the workflow config maps bugs to `["reproducer", "developer", "qa", "finalize"]`, then the Reproducer phase runs first using `~/.foreman/prompts/reproducer.md` and the `reproducer` entry from `phases.json`.
- AC-015-2: Given the Reproducer phase, when it completes, then it writes `REPRODUCER_REPORT.md` to the worktree and sends the report to the Developer inbox via Agent Mail.
- AC-015-3: Given the Reproducer prompt template, when it is rendered, then it includes `{{seedId}}`, `{{seedTitle}}`, and `{{seedDescription}}` for context about the bug to reproduce.
- AC-015-4: Given the Reproducer phase fails to reproduce the bug (agent reports inability to reproduce or the phase errors), when the failure is detected, then the pipeline stops and the seed is marked as stuck with a note indicating reproduction failed. The seed does NOT proceed to Developer and does NOT auto-reset to open.

### REQ-016: Part 2 Unit Tests (P1)

Comprehensive unit tests for the three loader modules.

- AC-016-1: Given `loadPrompt()` with a file that exists and all variables present, when called, then it returns the fully rendered markdown.
- AC-016-2: Given `loadPrompt()` with a file containing an `{{#if feedbackContext}}` block and `feedbackContext` absent, when called, then the block is omitted.
- AC-016-3: Given `loadPrompt()` with no file present, when called, then it returns the rendered fallback string.
- AC-016-4: Given `loadWorkflows()` with a valid file, when called, then it returns the parsed workflow map.
- AC-016-5: Given `loadWorkflows()` with no file, when called, then it returns `DEFAULT_WORKFLOWS`.
- AC-016-6: Given `loadWorkflows()` with invalid JSON, when called, then it warns and returns `DEFAULT_WORKFLOWS`.
- AC-016-7: Given `getWorkflow("bug")`, when called, then it returns `["reproducer", "developer", "qa", "finalize"]`.
- AC-016-8: Given `getWorkflow("unknown")`, when called, then it falls back to the `"feature"` workflow.
- AC-016-9: Given `loadPhaseConfigs()` with a valid file, when called, then it returns the parsed phase map.
- AC-016-10: Given `loadPhaseConfigs()` with a file missing a required field, when called, then it warns and returns `ROLE_CONFIGS`.

### REQ-024: Workflow-Phase Cross-Validation (P1)

When `runPipeline()` loads workflow and phase configs, it must cross-validate that every phase name in the workflow exists in the phase config. This prevents runtime failures from typos or missing phase definitions.

- AC-024-1: Given `workflows.json` contains a phase name `"reproducer"` and `phases.json` has a `"reproducer"` entry, when `runPipeline()` starts, then validation passes and the pipeline proceeds.
- AC-024-2: Given `workflows.json` contains a phase name `"reproducer"` but `phases.json` has NO `"reproducer"` entry AND the phase has no built-in fallback in `ROLE_CONFIGS`, when `runPipeline()` starts, then a validation error is raised before any agent is spawned. The error message identifies the unknown phase name and the workflow it appears in.
- AC-024-3: Given the special phase name `"finalize"`, when cross-validation runs, then `"finalize"` is always considered valid (it is implemented directly in `runPipeline()` and does not require a `phases.json` entry).
- AC-024-4: Given cross-validation fails, when the error is raised, then the seed is marked as failed with a descriptive error message and no agent phases are executed.

### REQ-025: Finalize Phase Enforcement (P1)

Every workflow must end with `"finalize"` as its last phase. Without finalize, the agent's work would never be committed or pushed. Workflow validation rejects any workflow that does not end with `"finalize"`.

- AC-025-1: Given a workflow `["explorer", "developer", "qa", "reviewer", "finalize"]`, when validation runs, then it passes (finalize is last).
- AC-025-2: Given a workflow `["developer", "qa"]` (missing finalize), when validation runs, then a validation error is raised identifying the workflow and the missing finalize phase.
- AC-025-3: Given a workflow `["developer", "finalize", "reviewer"]` (finalize is not last), when validation runs, then a validation error is raised indicating finalize must be the last phase.
- AC-025-4: Given validation is applied, when `loadWorkflows()` returns the workflow map, then all workflows in the map are validated before `runPipeline()` proceeds.

### REQ-026: Stale Message Filtering via Run ID (P1)

Messages sent between pipeline phases must include the `runId` to prevent a new pipeline run from reading stale messages left by a previous crashed run. `fetchLatestPhaseMessage()` must filter by `runId` in addition to subject prefix.

- AC-026-1: Given `sendMailText()` sends a QA Feedback message, when the message is constructed, then the subject or body includes the current `runId` (e.g., subject: `"QA Feedback - Retry 1 [run:abc123]"` or body includes a `runId` field).
- AC-026-2: Given `fetchLatestPhaseMessage()` is called, when it filters messages, then it only considers messages whose `runId` matches the current pipeline's `runId`, in addition to the subject prefix filter.
- AC-026-3: Given a stale unacknowledged message from a previous crashed run (different `runId`), when the new pipeline run calls `fetchLatestPhaseMessage()`, then the stale message is NOT returned and the disk fallback is used instead.
- AC-026-4: Given the `runId` filtering mechanism, when backward compatibility is considered, then messages without a `runId` (sent by older Foreman versions) are skipped by `fetchLatestPhaseMessage()` and the disk fallback is used.

---

## 9. Non-Functional Requirements

### REQ-017: Zero Regression Without Agent Mail Server (P0)

When the Agent Mail server is unavailable (not running, network unreachable, or `agentMailClient` is null), the pipeline must complete identically to the current disk-based implementation.

- AC-017-1: Given Agent Mail is not configured, when the full pipeline runs for a feature seed, then all phases complete successfully using disk-file reads, with zero errors or warnings related to Agent Mail.
- AC-017-2: Given Agent Mail goes down after Explorer sends its report but before Developer reads it, when the Developer phase starts, then `fetchLatestPhaseMessage()` returns `null` and the disk file `EXPLORER_REPORT.md` is read instead.

### REQ-018: Zero Regression Without Config Files (P0)

When `~/.foreman/prompts/`, `~/.foreman/phases.json`, or `~/.foreman/workflows.json` are absent, the pipeline must behave identically to the current hardcoded implementation.

- AC-018-1: Given no external config files exist in `~/.foreman/`, when `runPipeline()` executes for a feature seed, then the pipeline uses built-in TypeScript defaults and produces identical behavior to the current implementation.
- AC-018-2: Given `~/.foreman/prompts/developer.md` exists but `~/.foreman/prompts/explorer.md` does not, when the pipeline runs, then the Developer phase uses the external prompt and the Explorer phase uses the built-in fallback -- mixing is supported per-phase.

### REQ-019: Invalid Config Resilience (P0)

Invalid configuration files must log warnings but never crash the process.

- AC-019-1: Given `~/.foreman/phases.json` contains a JSON syntax error, when `loadPhaseConfigs()` is called, then a warning is logged to stderr identifying the file and parse error, and built-in defaults are returned.
- AC-019-2: Given `~/.foreman/workflows.json` contains valid JSON but with an empty array for a workflow (`"feature": []`), when `loadWorkflows()` validates the workflow map, then finalize enforcement (REQ-025) rejects the empty array with a validation error since it does not end with `"finalize"`, and the built-in `DEFAULT_WORKFLOWS` are returned instead. *(v1.2: Updated to align with REQ-025 finalize enforcement — empty arrays are validation errors, not passthrough cases.)*
- AC-019-3: Given `~/.foreman/prompts/explorer.md` contains malformed template syntax (e.g., unclosed `{{#if`), when `loadPrompt()` processes it, then the malformed syntax passes through as literal text rather than crashing.

### REQ-020: No SQLite Schema Changes (P0)

Neither Part 1 nor Part 2 requires any changes to the SQLite database schema.

- AC-020-1: Given the full implementation of both parts, when `src/lib/store.ts` is reviewed, then zero lines are added, modified, or removed.
- AC-020-2: Given an existing Foreman installation with a populated SQLite database, when the new version is deployed, then no migration is required.

### REQ-021: Existing CLI Commands Unchanged (P0)

`foreman status` and `foreman monitor` continue to work identically with no visible changes.

- AC-021-1: Given the full implementation of both parts, when `foreman status` is invoked, then its output format, content sources (SQLite), and refresh behavior are unchanged.
- AC-021-2: Given the full implementation of both parts, when `foreman monitor` is invoked, then its polling loop, health checks, and output are unchanged.

### REQ-022: Performance (P1)

The Agent Mail read path and config loading must not introduce meaningful latency.

- AC-022-1: Given Agent Mail is available, when `fetchLatestPhaseMessage()` is called, then the round-trip (fetch + acknowledge) completes within 500ms on localhost.
- AC-022-2: Given `loadPrompt()`, `loadPhaseConfigs()`, and `loadWorkflows()`, when called at pipeline start, then all three complete within 50ms total (filesystem reads, no network).
- AC-022-3: Given Agent Mail is unreachable (connection timeout), when `fetchLatestPhaseMessage()` is called, then it returns `null` within 5 seconds. The timeout is enforced via `AbortController` with `AbortSignal.timeout(5000)` passed as the `signal` option to the underlying HTTP fetch call (Node 18+ standard Web API).

---

## 10. Implementation Strategy

### 10.1 Part 1 Implementation Steps

| Step | Description | File(s) | Type |
|------|-------------|---------|------|
| 1 | Fix `acknowledgeMessage()` registry resolution | `src/orchestrator/agent-mail-client.ts` | Modify (1 line) |
| 2 | Add `fetchLatestPhaseMessage()` helper | `src/orchestrator/agent-worker.ts` | Modify (~25 lines) |
| 3 | Update QA verdict resolution to read from inbox first | `src/orchestrator/agent-worker.ts` | Modify (~8 lines) |
| 4 | Send Reviewer findings to Developer inbox | `src/orchestrator/agent-worker.ts` | Modify (~5 lines) |
| 5 | Update Reviewer feedback read path | `src/orchestrator/agent-worker.ts` | Modify (~8 lines) |
| 6 | Add unit tests | `src/orchestrator/__tests__/agent-worker-mail.test.ts` | Create |

**Files unchanged by Part 1:** `roles.ts`, `dispatcher.ts`, `store.ts`, `foreman-inbox-processor.ts`

### 10.2 Part 2 Implementation Steps

| Step | Description | File(s) | Type |
|------|-------------|---------|------|
| 7 | Prompt loader utility | `src/lib/prompt-loader.ts` | Create |
| 8 | Phase config loader | `src/lib/phase-config-loader.ts` | Create |
| 9 | Workflow config loader | `src/lib/workflow-config-loader.ts` | Create |
| 10 | Wire loaders into `runPipeline()` | `src/orchestrator/agent-worker.ts` | Modify |
| 11 | `foreman init` config seeding | `src/cli/commands/init.ts` | Modify |
| 12 | Startup validation | `src/lib/phase-config-loader.ts` | Part of step 8 |
| 13 | Bundled default files | `src/defaults/phases.json`, `src/defaults/workflows.json`, `src/defaults/prompts/*.md` | Create |
| 14 | Unit tests for loaders | `src/lib/__tests__/prompt-loader.test.ts`, `src/lib/__tests__/workflow-config-loader.test.ts`, `src/lib/__tests__/phase-config-loader.test.ts` | Create |

**Files unchanged by Part 2:** `roles.ts` (prompt functions and `ROLE_CONFIGS` kept as fallback defaults -- no deletions)

### 10.3 Verification Plan

```bash
# Build + type check
npm run build && npx tsc --noEmit

# Part 1 tests
npm test -- agent-worker-mail

# Part 2 tests
npm test -- prompt-loader workflow-config-loader phase-config-loader

# Full test suite
npm test

# Part 1: Integration smoke test (requires Agent Mail server)
foreman run --seed <seed-id>
# Watch logs for:
#   [agent-mail] Fetched "QA Feedback - Retry 1" from inbox "developer-{seedId}"
#   [agent-mail] Fetched "Review Findings" from inbox "developer-{seedId}"

# Part 1: Backward compat test (stop Agent Mail server)
foreman run --seed <seed-id>
# Pipeline completes normally using disk fallback -- no errors

# Part 2: Seed defaults
foreman init
# Verify: ~/.foreman/phases.json, workflows.json, prompts/*.md created

# Part 2: Custom prompt test
# Edit ~/.foreman/prompts/explorer.md, re-run, verify custom text in session log

# Part 2: Bug workflow test
foreman run --seed <bug-seed-id>
# Verify: logs show ["reproducer", "developer", "qa", "finalize"]

# Part 2: Validation test
# Corrupt ~/.foreman/phases.json, run foreman
# Should warn and fall back to built-in defaults -- no crash
```

---

## 11. Risks and Mitigations

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| Agent Mail messages lost or delayed | Low | Medium | Disk fallback is automatic; `fetchLatestPhaseMessage()` returns `null` on any failure |
| Unacknowledged messages accumulate | Low | Low | REQ-001 fixes acknowledge; messages are fetched with `limit: 20` and filtered by subject |
| Custom prompts produce worse agent output | Medium | Medium | Built-in defaults remain the fallback; `foreman init` seeds known-good prompts; operators can reset by deleting prompt files |
| `workflows.json` misconfiguration skips critical phases | Medium | High | Built-in defaults for unknown seed types; documentation warns about omitting QA/Reviewer; future validation could enforce required phases |
| Template rendering produces unexpected output | Low | Medium | Simple `{{var}}` and `{{#if}}` only -- no complex engine; missing vars render as empty string; fallback to built-in prompt on any issue |
| `phases.json` sets dangerously high budgets | Low | Medium | Env var overrides still take precedence; operators must explicitly edit the file; default values match current `ROLE_CONFIGS` |
| Race condition between Agent Mail send and read | Low | Low | Sends happen during the previous phase; reads happen at the start of the next phase; sequential `await`-chain guarantees ordering |
| Config file permissions on shared systems | Low | Low | `~/.foreman/` is user-owned; `foreman init` creates with user-default permissions |

---

## 12. Acceptance Criteria Summary

| REQ | Description | AC Count | Priority |
|-----|-------------|----------|----------|
| REQ-001 | `acknowledgeMessage()` registry resolution fix | 3 | P0 |
| REQ-002 | `fetchLatestPhaseMessage()` helper | 7 | P0 |
| REQ-003 | QA feedback read path via Agent Mail | 4 | P0 |
| REQ-004 | Reviewer findings send to Developer inbox | 3 | P1 |
| REQ-005 | Reviewer findings read path via Agent Mail | 3 | P1 |
| REQ-006 | Backward compatibility -- zero regression without Agent Mail | 3 | P0 |
| REQ-007 | Part 1 unit tests | 7 | P0 |
| REQ-008 | Prompt loader utility | 7 | P1 |
| REQ-009 | Phase config loader | 5 | P1 |
| REQ-010 | Phase config schema validation | 4 | P2 |
| REQ-011 | Workflow config loader | 6 | P1 |
| REQ-012 | Wire loaders into `runPipeline()` | 8 | P1 |
| REQ-013 | `foreman init` config seeding | 5 | P2 |
| REQ-014 | Bundled default files | 5 | P1 |
| REQ-015 | Reproducer phase for bug workflow | 4 | P3 |
| REQ-016 | Part 2 unit tests | 10 | P1 |
| REQ-017 | Zero regression without Agent Mail server | 2 | P0 |
| REQ-018 | Zero regression without config files | 2 | P0 |
| REQ-019 | Invalid config resilience | 3 | P0 |
| REQ-020 | No SQLite schema changes | 2 | P0 |
| REQ-021 | Existing CLI commands unchanged | 2 | P0 |
| REQ-022 | Performance | 3 | P1 |
| REQ-023 | Explorer report read path via Agent Mail | 4 | P0 |
| REQ-024 | Workflow-phase cross-validation | 4 | P1 |
| REQ-025 | Finalize phase enforcement | 4 | P1 |
| REQ-026 | Stale message filtering via run ID | 4 | P1 |
| **Total** | | **109** | |

---

## 13. Success Metrics

| Metric | Current Baseline | Target | Measurement |
|--------|-----------------|--------|-------------|
| Agent Mail transport utilization | 0% (write-only, reads from disk) | 90% of phase transitions read from inbox | Ratio of `[agent-mail] Fetched` log lines to total phase transitions over 30 days |
| Disk fallback activation rate | 100% (all reads from disk) | <10% (only when Agent Mail is down) | Ratio of disk-file reads to total phase reads |
| Prompt customization adoption | 0% (no external prompts) | 30% of operators customize at least one prompt | Survey of active Foreman installations |
| Custom workflow adoption | 0% (hardcoded sequence) | 50% of operators define at least one custom workflow | Presence of `~/.foreman/workflows.json` in installations |
| Pipeline configuration time | N/A (requires code change) | <5 minutes to customize prompts/workflows | Time from editing config to seeing effect in next `foreman run` |
| Bug workflow efficiency | All bugs run full 5-phase pipeline | Bugs run 4-phase pipeline (skip Explorer) | Average phase count for bug seeds |
| Zero regression rate | N/A | 100% backward compat when config absent | Pipeline success rate without any `~/.foreman/` config files |

---

## 14. Release Plan

### Phase 1: Agent Mail Read Transport (Part 1)

**Timeline:** 1-2 days
**Scope:** Steps 1-6 (acknowledgeMessage fix, fetchLatestPhaseMessage, QA read path, Reviewer send+read, tests)
**Dependencies:** Existing Agent Mail client in `agent-mail-client.ts`, existing send paths
**Gate:** All unit tests pass; backward compat test passes with Agent Mail server stopped; integration test passes with Agent Mail running

### Phase 2: Config Loaders and Bundled Defaults (Part 2 core)

**Timeline:** 2-3 days
**Scope:** Steps 7-10, 13-14 (prompt loader, phase config loader, workflow loader, wire into runPipeline, bundled defaults, tests)
**Dependencies:** Phase 1 not required (independent)
**Gate:** All loader unit tests pass; pipeline runs identically without any `~/.foreman/` config files; pipeline uses external config when files are present; invalid config logs warning and falls back

### Phase 3: Init Seeding and Validation (Part 2 UX)

**Timeline:** 1 day
**Scope:** Steps 11-12 (foreman init config seeding, startup validation)
**Dependencies:** Phase 2 complete
**Gate:** `foreman init` creates all config files; existing files are not overwritten; validation catches malformed `phases.json`

### Phase 4: Reproducer Phase (Part 2 extension)

**Timeline:** 1 day
**Scope:** Step 15 (Reproducer phase prompt, phase config entry, integration with bug workflow)
**Dependencies:** Phase 2 complete
**Gate:** Bug seeds run through Reproducer -> Developer -> QA -> Finalize; Reproducer writes report and sends to Developer inbox

### Rollout Strategy

1. **Alpha:** Ship Part 1 first -- Agent Mail read transport with disk fallback. Zero config changes required by operators.
2. **Beta:** Ship Part 2 core -- loaders are active but all behavior defaults to built-in when no config files exist. Zero visible change for operators who have not run `foreman init`.
3. **GA:** Ship Part 2 UX -- `foreman init` seeds config files. Document customization in README. Announce custom workflows for bugs/chores.

---

## 15. Open Questions

| # | Question | Owner | Status |
|---|----------|-------|--------|
| 1 | Should `fetchLatestPhaseMessage()` fetch more than 20 messages (current limit) to handle high-traffic inboxes? | Engineering | Open |
| 2 | Should workflow validation enforce that `"finalize"` is always the last phase in any workflow? | Product | **Closed** — Yes, enforced via REQ-025. Workflows must end with `"finalize"`. |
| 3 | Should the prompt loader support `{{> partial}}` includes for shared prompt sections across phases? | Engineering | Open -- deferred to future iteration |
| 4 | Should `~/.foreman/prompts/` support subdirectories for prompt versioning (e.g., `prompts/v2/developer.md`)? | Product | Open |
| 5 | Should `phases.json` support per-phase `maxTurns` and `maxTokens` fields in addition to `maxBudgetUsd`? | Engineering | Open -- depends on Pi integration timeline from PRD-2026-002 |
| 6 | Should the Reproducer phase report be sent to both Developer and QA inboxes, or only Developer? | Product | Open |
