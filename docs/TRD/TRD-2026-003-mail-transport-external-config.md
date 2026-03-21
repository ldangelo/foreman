# TRD-2026-003: Agent Mail Read Transport and Externalized Configuration

**Document ID:** TRD-2026-003
**Version:** 1.0
**Status:** Draft
**Date:** 2026-03-21
**PRD Reference:** PRD-2026-003 v1.1
**Author:** Tech Lead (AI-assisted)

---

## Version History

| Version | Date       | Author    | Changes       |
|---------|------------|-----------|---------------|
| 1.0     | 2026-03-21 | Tech Lead | Initial draft: 21 implementation tasks + 21 test tasks (42 total) covering all 26 PRD requirements (109 ACs) |

---

## Table of Contents

1. [Executive Summary](#1-executive-summary)
2. [System Architecture](#2-system-architecture)
3. [Data Architecture](#3-data-architecture)
4. [Master Task List](#4-master-task-list)
5. [Sprint Planning](#5-sprint-planning)
6. [Dependencies](#6-dependencies)
7. [Quality Requirements](#7-quality-requirements)
8. [Acceptance Criteria Traceability](#8-acceptance-criteria-traceability)
9. [Technical Decisions](#9-technical-decisions)

---

## 1. Executive Summary

This TRD translates PRD-2026-003 into an implementable plan for two independently shippable improvements to Foreman's agent pipeline:

**Part 1 -- Agent Mail Read Transport:** Wire up the read path for inter-phase messages. Agent Mail already sends Explorer reports, QA feedback, and QA reports as messages. This part adds the corresponding reads so Agent Mail becomes the primary transport, with disk files as automatic fallback. Also closes the Reviewer send gap, fixes `acknowledgeMessage()` registry resolution, adds stale message filtering via `runId`, and adds the Explorer report read path. Approximately 60 lines of new code plus targeted modifications.

**Part 2 -- Externalized Prompts and Workflow Config:** Move phase system prompts from TypeScript template literals in `roles.ts` to user-editable markdown files in `~/.foreman/prompts/`. Move phase mechanical config (model, budget, tools) to `~/.foreman/phases.json`. Move pipeline phase sequences to `~/.foreman/workflows.json` keyed by seed type. Add `foreman init` config seeding and a Reproducer phase for bug workflows. Three new loader modules plus bundled defaults.

**Scope:** 21 implementation tasks + 21 paired test tasks = 42 total tasks across 4 phases. No SQLite schema changes. No changes to `foreman status` or `foreman monitor`. Full backward compatibility when Agent Mail is unavailable or config files are absent.

**Key architectural constraints:**
- `roles.ts` prompt functions and `ROLE_CONFIGS` remain as fallback defaults -- no deletions
- `store.ts` is unchanged (zero schema changes)
- `dispatcher.ts` is unchanged
- Existing send paths are unchanged (only read paths are new)

---

## 2. System Architecture

### 2.1 Agent Mail Message Flow (After Part 1)

```
Explorer --- sdk.query() -------------------------------------------------->
  +-- sendMailText -> "developer-{seedId}"  "Explorer Report [run:{runId}]"     [existing send]
  +-- writes EXPLORER_REPORT.md                                                  [kept as fallback]

Developer <-- fetchLatestPhaseMessage("developer-{seedId}", "Explorer Report")   [NEW read]
          <-- fallback: EXPLORER_REPORT.md on disk
  +-- writes implementation files

QA --- sdk.query() -------------------------------------------------------->
  [FAIL] +-- sendMailText -> "developer-{seedId}"  "QA Feedback - Retry N [run:{runId}]"  [existing send]
  [PASS] +-- sendMailText -> "reviewer-{seedId}"   "QA Report [run:{runId}]"              [existing send]

Developer (retry) <-- fetchLatestPhaseMessage("developer-{seedId}", "QA Feedback", runId)   [NEW read]
                  <-- fallback: QA_REPORT.md on disk

Reviewer --- sdk.query() -------------------------------------------------->
  [issues] +-- sendMailText -> "developer-{seedId}"  "Review Findings [run:{runId}]"      [NEW send]
  +-- sendMailText -> "foreman"  "Review Complete"                                         [existing send]

Developer (retry) <-- fetchLatestPhaseMessage("developer-{seedId}", "Review Findings", runId) [NEW read]
                  <-- fallback: local reviewFeedback variable

Finalize --> sends "branch-ready" to refinery                                              [existing send]
```

### 2.2 Config Loading Flow (After Part 2)

```
runPipeline() starts
  |
  |-- loadPhaseConfigs()
  |     |-- ~/.foreman/phases.json exists? -> parse + validate -> return config
  |     |-- absent or invalid? -> return ROLE_CONFIGS from roles.ts
  |     |-- env var overrides (FOREMAN_EXPLORER_MODEL etc.) take precedence
  |
  |-- getWorkflow(seed.type)
  |     |-- ~/.foreman/workflows.json exists? -> parse -> lookup seed type
  |     |-- absent or invalid? -> return DEFAULT_WORKFLOWS[seed.type]
  |     |-- unknown seed type? -> fallback to "feature" workflow
  |
  |-- Cross-validate: every phase in workflow has a phases.json entry or ROLE_CONFIGS fallback
  |     |-- "finalize" always valid (implemented directly in runPipeline)
  |     |-- unknown phase with no fallback -> fail seed before spawning agents
  |
  |-- Validate: every workflow ends with "finalize"
  |     |-- missing finalize -> fail seed before spawning agents
  |
  |-- For each phase in workflow:
        |-- loadPrompt(phase, variables, builtInFallback)
        |     |-- ~/.foreman/prompts/{phase}.md exists? -> read + render template
        |     |-- absent? -> render builtInFallback (explorerPrompt(), etc.)
        |     |-- {{variable}} -> substitute from variables map
        |     |-- {{#if var}}...{{/if}} -> include block if var is truthy
        |     |-- unknown {{var}} -> replace with empty string
        |
        |-- phaseConfigs[phase] -> model, budget, tools, reportFile
        |-- runPhase(phase, renderedPrompt, phaseConfig, ...)
```

### 2.3 File Layout (New/Modified)

```
src/
  orchestrator/
    agent-mail-client.ts          [MODIFY] acknowledgeMessage() registry fix
    agent-worker.ts               [MODIFY] fetchLatestPhaseMessage(), read paths, wire loaders
    __tests__/
      agent-worker-mail.test.ts   [CREATE] Part 1 unit tests
  lib/
    prompt-loader.ts              [CREATE] Template loader with {{var}} and {{#if}} support
    phase-config-loader.ts        [CREATE] Reads ~/.foreman/phases.json
    workflow-config-loader.ts     [CREATE] Reads ~/.foreman/workflows.json, getWorkflow()
    __tests__/
      prompt-loader.test.ts       [CREATE] Prompt loader tests
      phase-config-loader.test.ts [CREATE] Phase config loader tests
      workflow-config-loader.test.ts [CREATE] Workflow config loader tests
  defaults/
    phases.json                   [CREATE] Bundled default phase config
    workflows.json                [CREATE] Bundled default workflow sequences
    prompts/
      explorer.md                 [CREATE] Default Explorer prompt
      developer.md                [CREATE] Default Developer prompt
      qa.md                       [CREATE] Default QA prompt
      reviewer.md                 [CREATE] Default Reviewer prompt
      reproducer.md               [CREATE] Default Reproducer prompt
  cli/
    commands/
      init.ts                     [MODIFY] Config file seeding

UNCHANGED:
  src/orchestrator/roles.ts       -- prompt functions + ROLE_CONFIGS kept as fallbacks
  src/orchestrator/dispatcher.ts  -- spawn strategy untouched
  src/lib/store.ts                -- SQLite schema untouched
  src/orchestrator/foreman-inbox-processor.ts -- untouched
```

---

## 3. Data Architecture

### 3.1 No SQLite Schema Changes

Per REQ-020, neither Part 1 nor Part 2 introduces any SQLite schema changes. All new data is either transient (Agent Mail messages) or file-based (`~/.foreman/` config files).

### 3.2 Agent Mail Message Subject Format (After TRD-007)

Messages include `runId` for stale message filtering:

| Message | Subject Format | From -> To |
|---------|---------------|------------|
| Explorer Report | `"Explorer Report [run:{runId}]"` | worker -> `developer-{seedId}` |
| QA Feedback | `"QA Feedback - Retry N [run:{runId}]"` | worker -> `developer-{seedId}` |
| QA Report | `"QA Report [run:{runId}]"` | worker -> `reviewer-{seedId}` |
| Review Findings | `"Review Findings [run:{runId}]"` | worker -> `developer-{seedId}` |
| Phase Complete | `"phase-complete"` | worker -> `foreman` |
| Review Complete | `"Review Complete"` | worker -> `foreman` |

### 3.3 Config File Schemas

**`~/.foreman/phases.json`** -- per-phase mechanical config:

```typescript
interface PhaseConfigFile {
  [phaseName: string]: {
    model: string;           // required: Claude model identifier
    maxBudgetUsd: number;    // required: max USD budget for the phase
    allowedTools: string[];  // required: whitelist of SDK tool names
    reportFile: string;      // required: output report filename
    promptFile: string;      // required: prompt template filename in prompts/
  };
}
```

**`~/.foreman/workflows.json`** -- phase sequences by seed type:

```typescript
interface WorkflowConfigFile {
  [seedType: string]: string[];  // ordered array of phase names, must end with "finalize"
}
```

**`~/.foreman/prompts/{phase}.md`** -- Mustache-light template:

| Syntax | Behavior |
|--------|----------|
| `{{variableName}}` | Replaced with value from variables map; missing = empty string |
| `{{#if variableName}}...{{/if}}` | Block included if variable is truthy; removed otherwise |
| Nested `{{#if}}` | Greedy match on outermost pair; inner tags treated as literal text |

---

## 4. Master Task List

### Phase 1: Agent Mail Read Transport (Part 1 from PRD)

---

#### TRD-001: Fix `acknowledgeMessage()` Registry Resolution (1h) [satisfies REQ-001]

- File: `src/orchestrator/agent-mail-client.ts`
- Actions:
  1. Add registry resolution at the top of `acknowledgeMessage()`: `const agentName = this.agentRegistry.get(agent) ?? agent;`
  2. Replace all uses of `agent` parameter with `agentName` in the API call (specifically the `agent_name` field in the `mcpCall` arguments)
- Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3
- Implementation AC:
  - [ ] Given a logical role name `"developer-bd-abc1"` that is registered in `agentRegistry`, when `acknowledgeMessage("developer-bd-abc1", 42)` is called, then the `mcpCall` sends `agent_name` as the resolved adjective+noun name from the registry
  - [ ] Given a role name `"unknown-role"` that is NOT in `agentRegistry`, when `acknowledgeMessage("unknown-role", 42)` is called, then the raw string `"unknown-role"` is passed as `agent_name` unchanged
  - [ ] Given the fix, when `fetchInbox()` + `acknowledgeMessage()` are called sequentially for the same role, then both resolve to the same agent name

---

#### TRD-001-TEST: `acknowledgeMessage()` Registry Resolution Tests (1h) [verifies TRD-001] [satisfies REQ-001] [depends: TRD-001]

- File: `src/orchestrator/__tests__/agent-mail-client-ack.test.ts`
- Actions:
  1. Test with registered role name -- verify `mcpCall` receives resolved name
  2. Test with unregistered role name -- verify raw name passthrough
  3. Test that `fetchInbox` and `acknowledgeMessage` resolve identically
- Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3
- Implementation AC:
  - [ ] Given a mock `AgentMailClient` with `agentRegistry` containing `"developer-bd-abc1" -> "SwiftFalcon"`, when `acknowledgeMessage("developer-bd-abc1", 42)` is called, then the underlying `mcpCall` receives `agent_name: "SwiftFalcon"`
  - [ ] Given a mock `AgentMailClient` with empty `agentRegistry`, when `acknowledgeMessage("raw-name", 42)` is called, then `mcpCall` receives `agent_name: "raw-name"`

---

#### TRD-002: Implement `fetchLatestPhaseMessage()` Helper (2h) [satisfies REQ-002] [satisfies REQ-026]

- File: `src/orchestrator/agent-worker.ts`
- Actions:
  1. Add module-scope `async function fetchLatestPhaseMessage(client, inboxRole, subjectPrefix, runId?)` alongside existing `sendMail`/`sendMailText` helpers
  2. If `client` is null, return `null` immediately
  3. Call `client.fetchInbox(inboxRole, { limit: 20 })` inside try/catch
  4. Filter messages: `!m.acknowledged && m.subject.startsWith(subjectPrefix)`
  5. If `runId` is provided, further filter: message subject or body contains the `runId` string
  6. Sort remaining by `receivedAt` descending, take first
  7. Call `client.acknowledgeMessage(inboxRole, parseInt(match.id, 10))` (catch errors but still return body)
  8. Log the fetch with `log()` and return `match.body`
  9. On any error, log non-fatal warning and return `null`
- Validates PRD ACs: AC-002-1, AC-002-2, AC-002-3, AC-002-4, AC-002-5, AC-002-6, AC-002-7, AC-026-2, AC-026-3, AC-026-4
- Implementation AC:
  - [ ] Given `client` is not null and a matching unacknowledged message exists with correct `runId`, when `fetchLatestPhaseMessage()` is called, then it returns `message.body` and calls `acknowledgeMessage()`
  - [ ] Given `client` is not null and no message matches the subject prefix, when called, then it returns `null`
  - [ ] Given `client` is not null and all matching messages are acknowledged, when called, then it returns `null`
  - [ ] Given multiple matching messages, when called, then it returns the body of the most recent (by `receivedAt`)
  - [ ] Given `client` is `null`, when called, then it returns `null` immediately with no API calls
  - [ ] Given `fetchInbox()` throws, when called, then error is logged as non-fatal and `null` is returned
  - [ ] Given `acknowledgeMessage()` throws, when called, then the message body is still returned
  - [ ] Given a `runId` is provided, when messages are filtered, then only messages containing that `runId` are considered
  - [ ] Given a message from a previous crashed run (different `runId`), when called with the current `runId`, then the stale message is not returned

---

#### TRD-002-TEST: `fetchLatestPhaseMessage()` Tests (2h) [verifies TRD-002] [satisfies REQ-002] [satisfies REQ-007] [satisfies REQ-026] [depends: TRD-002]

- File: `src/orchestrator/__tests__/agent-worker-mail.test.ts`
- Actions:
  1. Mock `AgentMailClient` with controlled `fetchInbox` and `acknowledgeMessage` responses
  2. Test all 9 cases from TRD-002 implementation ACs
  3. Test `runId` filtering: matching, non-matching, and absent `runId` in messages
- Validates PRD ACs: AC-002-1 through AC-002-7, AC-007-1 through AC-007-7, AC-026-2, AC-026-3, AC-026-4
- Implementation AC:
  - [ ] Given a mock client returning a matching unacknowledged message with correct `runId`, when `fetchLatestPhaseMessage()` is called, then it returns the message body and calls `acknowledgeMessage()` with correct args
  - [ ] Given a mock client returning messages with non-matching subjects, when called, then returns `null`
  - [ ] Given a mock client returning only acknowledged messages, when called, then returns `null`
  - [ ] Given a mock client returning two messages with same prefix but different `receivedAt`, when called, then returns the more recent body
  - [ ] Given `client` is `null`, when called, then returns `null` with zero mock interactions
  - [ ] Given a mock client where `fetchInbox()` throws, when called, then returns `null`
  - [ ] Given a mock client where `acknowledgeMessage()` throws, when called, then returns body anyway
  - [ ] Given messages from different `runId`s, when called with a specific `runId`, then only the matching message is returned

---

#### TRD-003: Update QA Feedback Read Path (2h) [satisfies REQ-003]

- File: `src/orchestrator/agent-worker.ts`
- Actions:
  1. In the Dev<->QA retry loop (around line 1134), after `runPhase("qa")` returns, add `fetchLatestPhaseMessage()` call before the existing `readReport()` call
  2. Read from inbox: `const qaMailBody = await fetchLatestPhaseMessage(agentMailClient, \`developer-${seedId}\`, "QA Feedback", runId)`
  3. Fall back to disk: `const qaReport = qaMailBody ?? readReport(worktreePath, "QA_REPORT.md")`
  4. Keep all downstream logic unchanged (`parseVerdict`, `extractIssues`, `feedbackContext` assignment)
- Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3, AC-003-4
- Implementation AC:
  - [ ] Given Agent Mail is available and a `"QA Feedback"` message exists with matching `runId`, when QA completes with FAIL, then the message body is used as `feedbackContext` for the Developer retry
  - [ ] Given Agent Mail is unavailable, when QA completes with FAIL, then `readReport(worktreePath, "QA_REPORT.md")` is used and the pipeline continues
  - [ ] Given Agent Mail returns no matching message, when QA completes, then disk fallback is used transparently
  - [ ] Given QA feedback is read from Agent Mail, when `parseVerdict()` is called on it, then the result matches parsing the equivalent disk file

---

#### TRD-003-TEST: QA Feedback Read Path Tests (2h) [verifies TRD-003] [satisfies REQ-003] [depends: TRD-003]

- File: `src/orchestrator/__tests__/agent-worker-mail.test.ts` (extend)
- Actions:
  1. Test mail-first read path with mock client returning QA feedback
  2. Test disk fallback when client is null
  3. Test disk fallback when no matching message
  4. Verify `parseVerdict` produces same result for mail vs disk content
- Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3, AC-003-4
- Implementation AC:
  - [ ] Given a mock pipeline context with Agent Mail returning QA feedback, when the QA read path executes, then `feedbackContext` is set from the mail body
  - [ ] Given a mock pipeline context with `agentMailClient` as `null`, when the QA read path executes, then `feedbackContext` is set from the disk file

---

#### TRD-004: Send Reviewer Findings to Developer Inbox (1h) [satisfies REQ-004]

- File: `src/orchestrator/agent-worker.ts`
- Actions:
  1. In the post-Reviewer dev-retry block (around line 1205), after `reviewFeedback` is extracted, add a `sendMailText()` call
  2. Guard: only send if `reviewReport` is non-null (AC-004-2)
  3. Call: `sendMailText(agentMailClient, \`developer-${seedId}\`, \`Review Findings [run:${runId}]\`, reviewFeedback)`
  4. Fire-and-forget -- existing `sendMailText` already handles errors silently (AC-004-3)
- Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3
- Implementation AC:
  - [ ] Given Reviewer verdict is FAIL and `devRetries < MAX_DEV_RETRIES` and `reviewReport` is non-null, when the retry block executes, then `sendMailText` is called with subject containing `"Review Findings"` and the current `runId`
  - [ ] Given `reviewReport` is null, when the retry block executes, then `sendMailText` is NOT called
  - [ ] Given Agent Mail is unavailable, when `sendMailText` fails silently, then the pipeline continues using the local `reviewFeedback` variable

---

#### TRD-004-TEST: Reviewer Findings Send Tests (1h) [verifies TRD-004] [satisfies REQ-004] [depends: TRD-004]

- File: `src/orchestrator/__tests__/agent-worker-mail.test.ts` (extend)
- Actions:
  1. Test that `sendMailText` is called when reviewReport is present and retry is triggered
  2. Test that `sendMailText` is NOT called when reviewReport is null
  3. Test that subject includes `runId`
- Validates PRD ACs: AC-004-1, AC-004-2, AC-004-3
- Implementation AC:
  - [ ] Given a mock pipeline with non-null reviewReport and retry conditions met, when the review retry block runs, then `sendMailText` is called with correct recipient and subject
  - [ ] Given a mock pipeline with null reviewReport, when the review retry block runs, then `sendMailText` is not called

---

#### TRD-005: Update Reviewer Findings Read Path (2h) [satisfies REQ-005]

- File: `src/orchestrator/agent-worker.ts`
- Actions:
  1. In the post-Reviewer dev-retry block, after the send in TRD-004, before calling `developerPrompt()` in the retry (around line 1220)
  2. Add: `const reviewMailBody = await fetchLatestPhaseMessage(agentMailClient, \`developer-${seedId}\`, "Review Findings", runId)`
  3. Use: `const reviewFeedbackForDev = reviewMailBody ?? reviewFeedback`
  4. Pass `reviewFeedbackForDev` to `developerPrompt()` instead of `reviewFeedback`
- Validates PRD ACs: AC-005-1, AC-005-2, AC-005-3
- Implementation AC:
  - [ ] Given Agent Mail is available and a `"Review Findings"` message exists with matching `runId`, when the Developer retry is prepared, then the message body is used as feedback context
  - [ ] Given Agent Mail is unavailable or no matching message exists, when the Developer retry is prepared, then the local `reviewFeedback` variable is used
  - [ ] Given review findings read from Agent Mail, when passed to `developerPrompt()`, then the prompt renders identically to the disk-based path

---

#### TRD-005-TEST: Reviewer Findings Read Path Tests (1h) [verifies TRD-005] [satisfies REQ-005] [depends: TRD-005]

- File: `src/orchestrator/__tests__/agent-worker-mail.test.ts` (extend)
- Actions:
  1. Test mail-first read with mock returning Review Findings
  2. Test fallback to local variable when mail unavailable
- Validates PRD ACs: AC-005-1, AC-005-2, AC-005-3
- Implementation AC:
  - [ ] Given a mock client returning Review Findings message, when the review read path executes, then the mail body is used as the developer feedback
  - [ ] Given a null client, when the review read path executes, then the local `reviewFeedback` variable is used

---

#### TRD-006: Explorer Report Read Path (2h) [satisfies REQ-023]

- File: `src/orchestrator/agent-worker.ts`
- Actions:
  1. Before the Developer phase starts (around line 1047), after `hasExplorerReport` is determined
  2. If `hasExplorerReport` is true, attempt to read Explorer report from mail: `const explorerMailBody = await fetchLatestPhaseMessage(agentMailClient, \`developer-${seedId}\`, "Explorer Report", runId)`
  3. If `explorerMailBody` is non-null, use it as the Explorer context for the Developer
  4. Fall back to existing `readReport(worktreePath, "EXPLORER_REPORT.md")` when mail body is null
  5. This read is informational (populates context), not a gate -- the Developer proceeds regardless
- Validates PRD ACs: AC-023-1, AC-023-2, AC-023-3, AC-023-4
- Implementation AC:
  - [ ] Given Agent Mail is available and an `"Explorer Report"` message exists with matching `runId`, when the Developer phase is about to start, then the mail body is used as Explorer context
  - [ ] Given Agent Mail is unavailable, when the Developer phase starts, then `EXPLORER_REPORT.md` is read from disk and the pipeline continues
  - [ ] Given no matching Explorer Report message exists, when the Developer phase starts, then disk fallback is used transparently
  - [ ] Given Explorer report read from mail, when used to set context and `hasExplorerReport`, then behavior is identical to disk-based read

---

#### TRD-006-TEST: Explorer Report Read Path Tests (1h) [verifies TRD-006] [satisfies REQ-023] [depends: TRD-006]

- File: `src/orchestrator/__tests__/agent-worker-mail.test.ts` (extend)
- Actions:
  1. Test mail-first read for Explorer report
  2. Test disk fallback when mail unavailable
  3. Test disk fallback when no matching message
- Validates PRD ACs: AC-023-1, AC-023-2, AC-023-3, AC-023-4
- Implementation AC:
  - [ ] Given a mock client returning an Explorer Report message, when the explorer read path executes, then the mail body is used as context
  - [ ] Given a null client, when the explorer read path executes, then the disk file is read instead

---

#### TRD-007: Stale Message Filtering via Run ID (2h) [satisfies REQ-026]

- File: `src/orchestrator/agent-worker.ts`
- Actions:
  1. Update all `sendMailText()` calls that send inter-phase reports to include `runId` in the subject: append ` [run:{runId}]` to existing subjects
  2. Affected subjects: `"Explorer Report"`, `"QA Feedback - Retry N"`, `"QA Report"`, `"Review Findings"`
  3. Update `fetchLatestPhaseMessage()` signature to accept optional `runId` parameter (done in TRD-002)
  4. In `fetchLatestPhaseMessage()`, when `runId` is provided, filter messages to only those containing the `runId` in subject or body
  5. Messages without any `runId` (from older Foreman versions) are skipped when `runId` filtering is active
- Validates PRD ACs: AC-026-1, AC-026-2, AC-026-3, AC-026-4
- Implementation AC:
  - [ ] Given `sendMailText()` sends a QA Feedback message, when the subject is constructed, then it includes `[run:{runId}]` (e.g., `"QA Feedback - Retry 1 [run:abc123]"`)
  - [ ] Given `fetchLatestPhaseMessage()` is called with a `runId`, when filtering messages, then only messages whose subject contains `[run:{runId}]` are considered
  - [ ] Given a stale message from a crashed run with a different `runId`, when the new run calls `fetchLatestPhaseMessage()`, then the stale message is skipped and disk fallback is used
  - [ ] Given a message without any `runId` tag (from an older Foreman version), when `fetchLatestPhaseMessage()` is called with a `runId`, then the old message is skipped

---

#### TRD-007-TEST: Stale Message Filtering Tests (2h) [verifies TRD-007] [satisfies REQ-026] [depends: TRD-007]

- File: `src/orchestrator/__tests__/agent-worker-mail.test.ts` (extend)
- Actions:
  1. Test subject format includes `[run:{runId}]`
  2. Test filtering with matching `runId`
  3. Test filtering with non-matching `runId`
  4. Test backward compatibility with messages lacking `runId`
- Validates PRD ACs: AC-026-1, AC-026-2, AC-026-3, AC-026-4
- Implementation AC:
  - [ ] Given mock messages with various `runId` tags, when `fetchLatestPhaseMessage()` is called with a specific `runId`, then only the matching message is returned
  - [ ] Given mock messages without `runId` tags, when `fetchLatestPhaseMessage()` is called with a `runId`, then those messages are skipped

---

#### TRD-008: Backward Compatibility Validation (2h) [satisfies REQ-006] [satisfies REQ-017]

- File: `src/orchestrator/agent-worker.ts`
- Actions:
  1. Audit all new `fetchLatestPhaseMessage()` call sites to verify they always have a disk or local-variable fallback
  2. Verify that `agentMailClient === null` path produces zero Agent Mail log messages
  3. Ensure no new imports or code paths can throw when Agent Mail is absent
  4. Add integration-level test scenarios for full pipeline with `agentMailClient = null`
- Validates PRD ACs: AC-006-1, AC-006-2, AC-006-3, AC-017-1, AC-017-2
- Implementation AC:
  - [ ] Given `agentMailClient` is `null`, when the full pipeline runs (Explorer -> Developer <-> QA -> Reviewer -> Finalize), then every phase completes successfully using disk-file reads with zero Agent Mail log messages
  - [ ] Given Agent Mail goes down mid-pipeline (after Explorer sends but before Developer reads), when Developer starts, then `fetchLatestPhaseMessage()` returns `null` and disk fallback is used
  - [ ] Given no Agent Mail configuration, when `foreman status` and `foreman monitor` are invoked, then output is identical to current implementation

---

#### TRD-008-TEST: Backward Compatibility Tests (2h) [verifies TRD-008] [satisfies REQ-006] [satisfies REQ-017] [depends: TRD-008]

- File: `src/orchestrator/__tests__/agent-worker-mail.test.ts` (extend)
- Actions:
  1. Full pipeline simulation with `agentMailClient = null` -- verify all phases use disk reads
  2. Test mid-pipeline Agent Mail failure -- verify seamless fallback
  3. Verify zero Agent Mail log output when client is null
- Validates PRD ACs: AC-006-1, AC-006-2, AC-006-3, AC-017-1, AC-017-2
- Implementation AC:
  - [ ] Given a mock pipeline with `agentMailClient = null`, when all phase read paths execute, then every `fetchLatestPhaseMessage()` returns `null` and disk reads succeed
  - [ ] Given a mock pipeline where `fetchInbox()` starts failing mid-run, when subsequent reads occur, then errors are caught and disk fallback is used seamlessly

---

#### TRD-009: Part 1 Comprehensive Unit Tests (3h) [satisfies REQ-007]

- File: `src/orchestrator/__tests__/agent-worker-mail.test.ts` (consolidation)
- Actions:
  1. Ensure all 7 test cases from REQ-007 are covered (some may already be covered by TRD-002-TEST through TRD-008-TEST)
  2. Add any missing edge case tests
  3. Verify test coverage for `fetchLatestPhaseMessage()` is >= 80%
  4. Verify overall Part 1 test coverage meets targets
- Validates PRD ACs: AC-007-1 through AC-007-7
- Implementation AC:
  - [ ] Given a mock client returning a matching unacknowledged message, when `fetchLatestPhaseMessage()` is called, then it returns the message body and calls `acknowledgeMessage()` with correct args
  - [ ] Given a mock client returning messages with non-matching subjects, when called, then returns `null`
  - [ ] Given a mock client returning only acknowledged messages, when called, then returns `null`
  - [ ] Given a mock client returning two messages with same prefix but different `receivedAt`, when called, then returns the more recent body
  - [ ] Given `client` is `null`, when called, then returns `null` with zero mock interactions
  - [ ] Given a mock client where `fetchInbox()` throws, when called, then returns `null` and logs a non-fatal warning
  - [ ] Given a mock client where `acknowledgeMessage()` throws, when called, then returns the body anyway

---

### Phase 2: Config Loaders (Part 2 Core from PRD)

---

#### TRD-010: Prompt Loader Utility (2h) [satisfies REQ-008]

- File: `src/lib/prompt-loader.ts` (new)
- Actions:
  1. Create `loadPrompt(phase, variables, fallback)` function
  2. Resolve prompt path: `join(homedir(), ".foreman", "prompts", \`${phase}.md\`)`
  3. If file exists, read it; if absent, use `fallback` string
  4. Implement `renderTemplate(template, vars)`:
     - Handle `{{#if var}}...{{/if}}` blocks via regex: `/\{\{#if (\w+)\}\}([\s\S]*?)\{\{\/if\}\}/g` -- greedy match on outermost pair
     - Substitute `{{variable}}` placeholders via regex: `/\{\{(\w+)\}\}/g` -- missing vars become empty string
  5. Trim final result
  6. Export `loadPrompt` and `renderTemplate` (for testing)
- Validates PRD ACs: AC-008-1, AC-008-2, AC-008-3, AC-008-4, AC-008-5, AC-008-6, AC-008-7
- Implementation AC:
  - [ ] Given `~/.foreman/prompts/explorer.md` exists with `{{seedId}}` and `{{seedTitle}}`, when `loadPrompt("explorer", { seedId: "bd-abc1", seedTitle: "Fix login" }, fallback)` is called, then placeholders are replaced with values
  - [ ] Given a prompt with `{{#if feedbackContext}}...{{/if}}` and `feedbackContext` is undefined, when rendered, then the block is omitted
  - [ ] Given a prompt with `{{#if feedbackContext}}...{{/if}}` and `feedbackContext` is non-empty, when rendered, then block content is included with markers removed
  - [ ] Given the prompt file does not exist, when `loadPrompt` is called, then the `fallback` string is rendered with variable substitution
  - [ ] Given `{{unknownVariable}}` in the template, when rendered, then it is replaced with empty string
  - [ ] Given rendered output has leading/trailing whitespace, when returned, then it is trimmed
  - [ ] Given nested `{{#if a}}...{{#if b}}...{{/if}}...{{/if}}`, when rendered, then greedy match on outermost pair processes correctly

---

#### TRD-010-TEST: Prompt Loader Tests (2h) [verifies TRD-010] [satisfies REQ-008] [satisfies REQ-016] [depends: TRD-010]

- File: `src/lib/__tests__/prompt-loader.test.ts` (new)
- Actions:
  1. Use `vi.mock` or temp directories to control file existence
  2. Test all 7 ACs from TRD-010
  3. Test `renderTemplate` directly for template edge cases
- Validates PRD ACs: AC-008-1 through AC-008-7, AC-016-1, AC-016-2, AC-016-3
- Implementation AC:
  - [ ] Given a temp prompt file with `{{seedId}}`, when `loadPrompt` is called with `seedId: "bd-abc1"`, then the output contains `"bd-abc1"` in place of the placeholder
  - [ ] Given a temp prompt with `{{#if feedbackContext}}FEEDBACK{{/if}}` and vars `{ feedbackContext: undefined }`, when rendered, then `"FEEDBACK"` is absent from output
  - [ ] Given no prompt file exists, when `loadPrompt` is called with fallback `"Default prompt for {{seedId}}"`, then output is `"Default prompt for bd-abc1"`
  - [ ] Given a template with `{{unknownVar}}`, when `renderTemplate` is called, then `{{unknownVar}}` is replaced with `""`

---

#### TRD-011: Phase Config Loader (2h) [satisfies REQ-009] [satisfies REQ-010]

- File: `src/lib/phase-config-loader.ts` (new)
- Actions:
  1. Create `loadPhaseConfigs()` function
  2. Resolve path: `join(homedir(), ".foreman", "phases.json")`
  3. If file absent, return `ROLE_CONFIGS` from `roles.ts`
  4. Parse JSON; on parse error, warn and return `ROLE_CONFIGS`
  5. Implement `validatePhaseConfig(raw)`: for each phase entry, check required fields: `model` (string), `maxBudgetUsd` (number), `allowedTools` (string[]), `reportFile` (string), `promptFile` (string)
  6. On validation error, warn with phase name + field name, return `ROLE_CONFIGS` for entire file
  7. Extra unrecognized fields are ignored
  8. Apply env var overrides (`FOREMAN_EXPLORER_MODEL` etc.) after loading from file
- Validates PRD ACs: AC-009-1 through AC-009-5, AC-010-1 through AC-010-4
- Implementation AC:
  - [ ] Given `~/.foreman/phases.json` exists with valid schema, when `loadPhaseConfigs()` is called, then it returns the parsed phase config map
  - [ ] Given `phases.json` does not exist, when called, then it returns `ROLE_CONFIGS`
  - [ ] Given `phases.json` has invalid JSON, when called, then it warns and returns `ROLE_CONFIGS`
  - [ ] Given `phases.json` is missing `model` from the explorer entry, when called, then it warns identifying `"explorer"` and `"model"` and returns `ROLE_CONFIGS`
  - [ ] Given `FOREMAN_EXPLORER_MODEL` env var is set, when config is loaded, then the env var takes precedence over the JSON file value
  - [ ] Given a phase entry with an extra unrecognized field `"custom": true`, when validation runs, then it passes (extra fields ignored)
  - [ ] Given `maxBudgetUsd` is a string `"5.00"` instead of number `5.00`, when validation runs, then it fails with a descriptive message

---

#### TRD-011-TEST: Phase Config Loader Tests (2h) [verifies TRD-011] [satisfies REQ-009] [satisfies REQ-010] [satisfies REQ-016] [depends: TRD-011]

- File: `src/lib/__tests__/phase-config-loader.test.ts` (new)
- Actions:
  1. Test valid file parsing
  2. Test absent file fallback
  3. Test invalid JSON fallback
  4. Test schema validation failures (missing field, wrong type)
  5. Test env var override precedence
  6. Test extra field tolerance
- Validates PRD ACs: AC-009-1 through AC-009-5, AC-010-1 through AC-010-4, AC-016-9, AC-016-10
- Implementation AC:
  - [ ] Given a temp `phases.json` with valid schema, when `loadPhaseConfigs()` is called, then the returned map has all phases with correct field values
  - [ ] Given no `phases.json`, when called, then `ROLE_CONFIGS` is returned
  - [ ] Given `phases.json` with syntax error, when called, then a warning is logged and `ROLE_CONFIGS` is returned
  - [ ] Given `phases.json` with `maxBudgetUsd: "5.00"` (string), when called, then validation fails with descriptive warning

---

#### TRD-012: Phase Config Schema Validation (1h) [satisfies REQ-010]

- File: `src/lib/phase-config-loader.ts` (extend from TRD-011)
- Actions:
  1. Implement `validatePhaseConfig(raw: unknown): void` (throws on invalid)
  2. For each key in the raw object, validate: `model` is string, `maxBudgetUsd` is number, `allowedTools` is string[], `reportFile` is string, `promptFile` is string
  3. On failure, throw with message: `"Phase '{phaseName}': field '{fieldName}' must be {expectedType}, got {actualType}"`
  4. Extra fields are silently ignored
- Validates PRD ACs: AC-010-1, AC-010-2, AC-010-3, AC-010-4
- Implementation AC:
  - [ ] Given a valid phase config object, when `validatePhaseConfig()` runs, then no error is thrown
  - [ ] Given a phase entry with extra field `"description": "test"`, when validation runs, then it passes
  - [ ] Given a phase entry with `maxBudgetUsd` as string, when validation runs, then it throws with message identifying the phase and field
  - [ ] Given a phase entry missing `allowedTools`, when validation runs, then it throws identifying `"allowedTools"` as missing

---

#### TRD-013: Workflow Config Loader (2h) [satisfies REQ-011]

- File: `src/lib/workflow-config-loader.ts` (new)
- Actions:
  1. Define `DEFAULT_WORKFLOWS` constant: feature, bug, chore, docs
  2. Create `loadWorkflows()`: read `~/.foreman/workflows.json`, parse, return; on error, warn and return defaults
  3. Create `getWorkflow(seedType)`: lookup in loaded workflows, fall back to `"feature"` workflow for unknown types
  4. Export both functions and `DEFAULT_WORKFLOWS`
- Validates PRD ACs: AC-011-1 through AC-011-6
- Implementation AC:
  - [ ] Given `~/.foreman/workflows.json` exists with valid JSON, when `loadWorkflows()` is called, then it returns the parsed workflow map
  - [ ] Given `workflows.json` does not exist, when called, then it returns `DEFAULT_WORKFLOWS`
  - [ ] Given `workflows.json` has invalid JSON, when called, then it warns and returns `DEFAULT_WORKFLOWS`
  - [ ] Given `seedType = "bug"`, when `getWorkflow("bug")` is called, then it returns `["reproducer", "developer", "qa", "finalize"]`
  - [ ] Given `seedType = "unknown"`, when `getWorkflow("unknown")` is called, then it returns the `"feature"` workflow
  - [ ] Given a custom workflow `"spike": ["explorer", "finalize"]` in the file, when `getWorkflow("spike")` is called, then it returns `["explorer", "finalize"]`

---

#### TRD-013-TEST: Workflow Config Loader Tests (2h) [verifies TRD-013] [satisfies REQ-011] [satisfies REQ-016] [depends: TRD-013]

- File: `src/lib/__tests__/workflow-config-loader.test.ts` (new)
- Actions:
  1. Test valid file parsing
  2. Test absent file fallback
  3. Test invalid JSON fallback
  4. Test `getWorkflow` for known types (bug, chore, feature)
  5. Test `getWorkflow` for unknown type (fallback to feature)
  6. Test custom user-defined workflow type
- Validates PRD ACs: AC-011-1 through AC-011-6, AC-016-4 through AC-016-8
- Implementation AC:
  - [ ] Given a temp `workflows.json` with `"spike": ["explorer", "finalize"]`, when `getWorkflow("spike")` is called, then it returns `["explorer", "finalize"]`
  - [ ] Given no `workflows.json`, when `loadWorkflows()` is called, then `DEFAULT_WORKFLOWS` is returned
  - [ ] Given `workflows.json` with syntax error, when called, then a warning is logged and `DEFAULT_WORKFLOWS` is returned
  - [ ] Given `getWorkflow("unknown")`, when called, then the `"feature"` workflow is returned

---

#### TRD-014: Workflow-Phase Cross-Validation (2h) [satisfies REQ-024]

- File: `src/lib/workflow-config-loader.ts` (extend) or `src/orchestrator/agent-worker.ts`
- Actions:
  1. Create `validateWorkflowPhases(workflow: string[], phaseConfigs: Record<string, unknown>, seedType: string): void`
  2. For each phase in the workflow: check if it exists in `phaseConfigs` or in `ROLE_CONFIGS` (built-in fallback)
  3. Special case: `"finalize"` is always valid (implemented directly in `runPipeline()`)
  4. If unknown phase found, throw descriptive error: `"Workflow '${seedType}' references unknown phase '${phaseName}' which has no config in phases.json or ROLE_CONFIGS"`
  5. Call this validation at the start of `runPipeline()` before any agent is spawned
  6. On validation failure, mark seed as failed with descriptive error
- Validates PRD ACs: AC-024-1, AC-024-2, AC-024-3, AC-024-4
- Implementation AC:
  - [ ] Given workflow contains `"reproducer"` and `phaseConfigs` has a `"reproducer"` entry, when validation runs, then it passes
  - [ ] Given workflow contains `"reproducer"` but neither `phaseConfigs` nor `ROLE_CONFIGS` has it, when validation runs, then an error is thrown identifying `"reproducer"` and the workflow
  - [ ] Given workflow contains `"finalize"`, when validation runs, then `"finalize"` is accepted without checking configs
  - [ ] Given validation fails, when the error propagates, then the seed is marked as failed and no agent phases execute

---

#### TRD-014-TEST: Workflow-Phase Cross-Validation Tests (1h) [verifies TRD-014] [satisfies REQ-024] [depends: TRD-014]

- File: `src/lib/__tests__/workflow-config-loader.test.ts` (extend)
- Actions:
  1. Test valid workflow with all phases in config
  2. Test workflow with unknown phase -- expect error
  3. Test `"finalize"` always valid
  4. Test error message content
- Validates PRD ACs: AC-024-1, AC-024-2, AC-024-3, AC-024-4
- Implementation AC:
  - [ ] Given workflow `["explorer", "developer", "finalize"]` and configs with `explorer` and `developer`, when validated, then no error
  - [ ] Given workflow `["unknown_phase", "finalize"]` and configs without `unknown_phase`, when validated, then error thrown with message containing `"unknown_phase"`

---

#### TRD-015: Finalize Phase Enforcement (1h) [satisfies REQ-025]

- File: `src/lib/workflow-config-loader.ts` (extend)
- Actions:
  1. Create `validateFinalizeEnforcement(workflows: Record<string, string[]>): void`
  2. For each workflow in the map, verify the last element is `"finalize"`
  3. If any workflow is missing `"finalize"` as last phase, throw: `"Workflow '${seedType}' must end with 'finalize' but ends with '${lastPhase}'"`
  4. If `"finalize"` appears but is not last: `"Workflow '${seedType}' has 'finalize' at position ${idx} but it must be the last phase"`
  5. Call this validation inside `loadWorkflows()` or at pipeline start
- Validates PRD ACs: AC-025-1, AC-025-2, AC-025-3, AC-025-4
- Implementation AC:
  - [ ] Given workflow `["explorer", "developer", "qa", "reviewer", "finalize"]`, when validation runs, then it passes
  - [ ] Given workflow `["developer", "qa"]` (missing finalize), when validation runs, then error is raised identifying the workflow
  - [ ] Given workflow `["developer", "finalize", "reviewer"]` (finalize not last), when validation runs, then error is raised indicating finalize must be last
  - [ ] Given all workflows in the loaded map, when `loadWorkflows()` returns, then all have been validated

---

#### TRD-015-TEST: Finalize Phase Enforcement Tests (1h) [verifies TRD-015] [satisfies REQ-025] [depends: TRD-015]

- File: `src/lib/__tests__/workflow-config-loader.test.ts` (extend)
- Actions:
  1. Test valid workflow ending with finalize
  2. Test workflow missing finalize
  3. Test workflow with finalize in wrong position
- Validates PRD ACs: AC-025-1, AC-025-2, AC-025-3, AC-025-4
- Implementation AC:
  - [ ] Given workflow ending with `"finalize"`, when validated, then no error
  - [ ] Given workflow `["developer", "qa"]`, when validated, then error thrown mentioning missing finalize
  - [ ] Given workflow `["developer", "finalize", "qa"]`, when validated, then error thrown mentioning finalize must be last

---

#### TRD-016: Wire Loaders into `runPipeline()` (4h) [satisfies REQ-012]

- File: `src/orchestrator/agent-worker.ts`
- Actions:
  1. Add imports: `loadPhaseConfigs` from `phase-config-loader.js`, `getWorkflow` from `workflow-config-loader.js`, `loadPrompt` from `prompt-loader.js`
  2. At `runPipeline()` start, load configs: `const phaseConfigs = loadPhaseConfigs()` and `const phases = getWorkflow(seed.type ?? "feature")`
  3. Run cross-validation: `validateWorkflowPhases(phases, phaseConfigs, seed.type)` and finalize enforcement
  4. Replace hardcoded phase sequence with iteration over `phases` array
  5. For each phase in the workflow (except `"finalize"`), use `phaseConfigs[phaseName]` for model/budget/tools
  6. Replace direct `explorerPrompt(...)` calls with: `loadPrompt("explorer", { seedId, seedTitle, seedDescription, seedComments }, explorerPrompt(seedId, seedTitle, description, comments))`
  7. Replace direct `developerPrompt(...)` calls similarly, using the existing function as fallback
  8. Replace direct `qaPrompt(...)` and `reviewerPrompt(...)` calls similarly
  9. Handle Dev<->QA retry loop: if workflow contains `"qa"`, run retry loop; if workflow omits `"qa"`, skip to next phase
  10. Handle reviewer absence: if workflow omits `"reviewer"`, skip reviewer block entirely
  11. When no external config files exist, behavior must be identical to current hardcoded implementation
- Validates PRD ACs: AC-012-1 through AC-012-8
- Implementation AC:
  - [ ] Given seed type `"feature"`, when `runPipeline()` executes, then phases `["explorer", "developer", "qa", "reviewer", "finalize"]` are run
  - [ ] Given seed type `"bug"`, when `runPipeline()` executes, then phases `["reproducer", "developer", "qa", "finalize"]` are run (no Explorer, no Reviewer)
  - [ ] Given seed type `"chore"`, when `runPipeline()` executes, then phases `["developer", "finalize"]` are run (no Explorer, QA, or Reviewer)
  - [ ] Given `~/.foreman/prompts/explorer.md` exists, when Explorer phase runs, then `loadPrompt` provides external prompt with built-in as fallback
  - [ ] Given `~/.foreman/phases.json` with custom Explorer model, when Explorer runs, then the custom model is used
  - [ ] Given no external config files, when `runPipeline()` executes, then behavior is identical to current hardcoded implementation
  - [ ] Given a workflow with `"qa"` but no `"reviewer"`, when QA passes, then pipeline proceeds to next phase (typically `"finalize"`)
  - [ ] Given a workflow omitting both `"qa"` and `"reviewer"`, when Developer completes, then pipeline proceeds directly to Finalize

---

#### TRD-016-TEST: Wire Loaders Integration Tests (3h) [verifies TRD-016] [satisfies REQ-012] [depends: TRD-016, TRD-010, TRD-011, TRD-013]

- File: `src/orchestrator/__tests__/agent-worker-config.test.ts` (new)
- Actions:
  1. Mock `runPhase` to track phase sequence
  2. Test feature workflow produces correct phase sequence
  3. Test bug workflow skips Explorer and Reviewer
  4. Test chore workflow runs only Developer + Finalize
  5. Test external prompt loading with mock file system
  6. Test fallback to built-in when no config files present
  7. Test Dev<->QA retry loop with workflow-driven phases
- Validates PRD ACs: AC-012-1 through AC-012-8
- Implementation AC:
  - [ ] Given a mock pipeline with seed type `"feature"`, when `runPipeline()` executes, then the phase sequence recorded is `["explorer", "developer", "qa", "reviewer", "finalize"]`
  - [ ] Given a mock pipeline with seed type `"bug"`, when `runPipeline()` executes, then the phase sequence is `["reproducer", "developer", "qa", "finalize"]`
  - [ ] Given a mock pipeline with seed type `"chore"`, when `runPipeline()` executes, then the phase sequence is `["developer", "finalize"]`

---

#### TRD-017: Bundled Default Files (2h) [satisfies REQ-014]

- Files:
  - `src/defaults/phases.json` (new)
  - `src/defaults/workflows.json` (new)
  - `src/defaults/prompts/explorer.md` (new)
  - `src/defaults/prompts/developer.md` (new)
  - `src/defaults/prompts/qa.md` (new)
  - `src/defaults/prompts/reviewer.md` (new)
  - `src/defaults/prompts/reproducer.md` (new)
- Actions:
  1. Create `src/defaults/phases.json` matching current `ROLE_CONFIGS` in `roles.ts` (explorer: haiku, developer: sonnet, qa: sonnet, reviewer: sonnet, reproducer: sonnet) with `promptFile` field per phase
  2. Create `src/defaults/workflows.json` with four workflows: feature, bug, chore, docs
  3. Extract current `explorerPrompt()` template literal content into `src/defaults/prompts/explorer.md` with `{{variable}}` placeholders
  4. Extract `developerPrompt()` into `developer.md` with `{{#if feedbackContext}}` conditional block
  5. Extract `qaPrompt()` into `qa.md`
  6. Extract `reviewerPrompt()` into `reviewer.md`
  7. Create `reproducer.md` prompt for bug reproduction with `{{seedId}}`, `{{seedTitle}}`, `{{seedDescription}}`
  8. Ensure all files use the documented template variable table from PRD Section 6.4
- Validates PRD ACs: AC-014-1, AC-014-2, AC-014-3, AC-014-4, AC-014-5
- Implementation AC:
  - [ ] Given `src/defaults/phases.json`, when compared to `ROLE_CONFIGS`, then models, budgets, tools, and report files match
  - [ ] Given `src/defaults/workflows.json`, when read, then it contains `feature`, `bug`, `chore`, `docs` workflows
  - [ ] Given `src/defaults/prompts/explorer.md` rendered with standard variables, when compared to `explorerPrompt()` output, then they are equivalent
  - [ ] Given `src/defaults/prompts/developer.md` rendered with `feedbackContext` present, when compared to `developerPrompt()` output, then feedback section is included; when absent, section is omitted
  - [ ] Given all five prompt files, when `{{variable}}` references are checked, then they use only variables from the documented table

---

#### TRD-017-TEST: Bundled Default Files Tests (2h) [verifies TRD-017] [satisfies REQ-014] [depends: TRD-017, TRD-010]

- File: `src/lib/__tests__/bundled-defaults.test.ts` (new)
- Actions:
  1. Read `src/defaults/phases.json` and validate it matches `ROLE_CONFIGS` structure
  2. Read `src/defaults/workflows.json` and validate it has all four default workflows
  3. Read each prompt file, render with `renderTemplate`, and compare to built-in function output
- Validates PRD ACs: AC-014-1 through AC-014-5
- Implementation AC:
  - [ ] Given `src/defaults/phases.json`, when parsed and compared to `ROLE_CONFIGS`, then all field values match
  - [ ] Given `src/defaults/prompts/explorer.md`, when rendered with test variables via `renderTemplate`, then output matches `explorerPrompt()` with same variables

---

#### TRD-018: Part 2 Comprehensive Unit Tests (3h) [satisfies REQ-016]

- Files:
  - `src/lib/__tests__/prompt-loader.test.ts` (extend)
  - `src/lib/__tests__/phase-config-loader.test.ts` (extend)
  - `src/lib/__tests__/workflow-config-loader.test.ts` (extend)
- Actions:
  1. Ensure all 10 test cases from REQ-016 are covered across the three test files
  2. Add any missing edge cases identified during implementation
  3. Verify coverage for each loader module is >= 80%
- Validates PRD ACs: AC-016-1 through AC-016-10
- Implementation AC:
  - [ ] Given `loadPrompt()` with file and all vars, when called, then returns fully rendered markdown (AC-016-1)
  - [ ] Given `loadPrompt()` with `{{#if feedbackContext}}` and var absent, when called, then block omitted (AC-016-2)
  - [ ] Given `loadPrompt()` with no file, when called, then rendered fallback returned (AC-016-3)
  - [ ] Given `loadWorkflows()` with valid file, when called, then parsed map returned (AC-016-4)
  - [ ] Given `loadWorkflows()` with no file, when called, then `DEFAULT_WORKFLOWS` returned (AC-016-5)
  - [ ] Given `loadWorkflows()` with invalid JSON, when called, then warns and returns defaults (AC-016-6)
  - [ ] Given `getWorkflow("bug")`, when called, then returns `["reproducer", "developer", "qa", "finalize"]` (AC-016-7)
  - [ ] Given `getWorkflow("unknown")`, when called, then returns feature workflow (AC-016-8)
  - [ ] Given `loadPhaseConfigs()` with valid file, when called, then parsed map returned (AC-016-9)
  - [ ] Given `loadPhaseConfigs()` with missing field, when called, then warns and returns `ROLE_CONFIGS` (AC-016-10)

---

### Phase 3: Init Seeding and UX (Part 2 UX from PRD)

---

#### TRD-019: `foreman init` Config Seeding (2h) [satisfies REQ-013]

- File: `src/cli/commands/init.ts`
- Actions:
  1. After existing `initAgentMailConfig()` call, add config seeding logic
  2. Check if `~/.foreman/phases.json` exists; if not, copy from `src/defaults/phases.json` and print confirmation
  3. Check if `~/.foreman/workflows.json` exists; if not, copy from `src/defaults/workflows.json` and print confirmation
  4. Check if `~/.foreman/prompts/` exists; if not, create directory and copy all `.md` files from `src/defaults/prompts/` and print confirmation
  5. If any file already exists, skip it (preserve user customizations) and print dim message
  6. Use `existsSync`/`mkdirSync`/`copyFileSync` (non-interactive, no prompts)
  7. Resolve default files relative to the package installation path (use `import.meta.url` or `__dirname` equivalent for ESM)
- Validates PRD ACs: AC-013-1, AC-013-2, AC-013-3, AC-013-4, AC-013-5
- Implementation AC:
  - [ ] Given `~/.foreman/phases.json` does not exist, when `foreman init` runs, then the bundled default is copied and a confirmation message is printed
  - [ ] Given `~/.foreman/workflows.json` does not exist, when `foreman init` runs, then the bundled default is copied and a confirmation message is printed
  - [ ] Given `~/.foreman/prompts/` does not exist, when `foreman init` runs, then all five prompt files are copied and a confirmation message is printed
  - [ ] Given `~/.foreman/phases.json` already exists, when `foreman init` runs, then the existing file is NOT overwritten
  - [ ] Given bundled defaults in `src/defaults/`, when the package is built, then the files are included in the distribution

---

#### TRD-019-TEST: `foreman init` Config Seeding Tests (2h) [verifies TRD-019] [satisfies REQ-013] [depends: TRD-019]

- File: `src/cli/commands/__tests__/init-config-seeding.test.ts` (new)
- Actions:
  1. Use temp directories to simulate `~/.foreman/`
  2. Test fresh init: all files created
  3. Test re-init: existing files not overwritten
  4. Test partial init: only missing files created
  5. Test that confirmation messages are printed
- Validates PRD ACs: AC-013-1 through AC-013-5
- Implementation AC:
  - [ ] Given a temp home dir with no `.foreman/`, when init seeding runs, then `phases.json`, `workflows.json`, and `prompts/*.md` are all created
  - [ ] Given a temp home dir with existing `phases.json`, when init seeding runs, then `phases.json` is untouched but missing files are still created
  - [ ] Given a temp home dir with existing `prompts/explorer.md` but no `prompts/developer.md`, when init seeding runs, then only `developer.md` (and other missing prompts) are copied

---

### Phase 4: Reproducer Phase (Part 2 Extension from PRD)

---

#### TRD-020: Reproducer Phase Implementation (3h) [satisfies REQ-015]

- File: `src/orchestrator/agent-worker.ts` and `src/defaults/prompts/reproducer.md`
- Actions:
  1. Add `"reproducer"` as a recognized phase in the pipeline loop (driven by workflow config, no hardcoding)
  2. When the workflow includes `"reproducer"` as the first phase, run it with: `loadPrompt("reproducer", { seedId, seedTitle, seedDescription }, builtInReproducerPrompt)`
  3. Use `phaseConfigs["reproducer"]` for model/budget/tools (from `phases.json` or built-in default)
  4. After Reproducer completes, check for `REPRODUCER_REPORT.md`
  5. Send reproducer report to Developer inbox via Agent Mail: `sendMailText(agentMailClient, \`developer-${seedId}\`, \`Reproducer Report [run:${runId}]\`, reproducerReport)`
  6. If Reproducer fails (cannot reproduce bug or phase errors), mark seed as stuck with note `"Reproduction failed"` and do NOT proceed to Developer. Do NOT auto-reset to open.
  7. Create built-in `reproducerPrompt()` function in `roles.ts` as fallback (or use the bundled `reproducer.md` default)
  8. Add `"reproducer"` entry to `ROLE_CONFIGS` or handle it in `loadPhaseConfigs()` fallback
- Validates PRD ACs: AC-015-1, AC-015-2, AC-015-3, AC-015-4
- Implementation AC:
  - [ ] Given seed type `"bug"` and workflow `["reproducer", "developer", "qa", "finalize"]`, when `runPipeline()` executes, then the Reproducer phase runs first using the reproducer prompt and config
  - [ ] Given the Reproducer phase completes successfully, when it finishes, then `REPRODUCER_REPORT.md` is written and the report is sent to the Developer inbox
  - [ ] Given the Reproducer prompt template, when rendered, then it includes `{{seedId}}`, `{{seedTitle}}`, and `{{seedDescription}}`
  - [ ] Given the Reproducer phase fails to reproduce the bug, when failure is detected, then the pipeline stops, the seed is marked as stuck with `"Reproduction failed"`, and no auto-reset occurs

---

#### TRD-020-TEST: Reproducer Phase Tests (2h) [verifies TRD-020] [satisfies REQ-015] [depends: TRD-020]

- File: `src/orchestrator/__tests__/agent-worker-reproducer.test.ts` (new)
- Actions:
  1. Test Reproducer runs as first phase for bug seeds
  2. Test report is written and sent to Developer inbox
  3. Test failure handling: seed marked stuck, no Developer phase
  4. Test prompt rendering with seed variables
- Validates PRD ACs: AC-015-1, AC-015-2, AC-015-3, AC-015-4
- Implementation AC:
  - [ ] Given a mock pipeline with bug seed, when the Reproducer phase runs, then it is the first phase executed and uses reproducer config
  - [ ] Given a successful Reproducer phase, when it completes, then `sendMailText` is called with subject containing `"Reproducer Report"`
  - [ ] Given a failed Reproducer phase, when failure is detected, then the seed is marked stuck and the Developer phase does NOT run

---

### Cross-Cutting: Non-Functional Requirements

The NFR tasks below are validated through the implementation and test tasks above. They do not require separate implementation work but are tracked here for traceability.

---

#### TRD-NFR-001: Zero Regression Without Config Files [satisfies REQ-018]

- Validated by: TRD-016 (wire loaders with fallback behavior), TRD-016-TEST (integration tests with no config files)
- Validates PRD ACs: AC-018-1, AC-018-2
- Implementation AC:
  - [ ] Given no external config files in `~/.foreman/`, when `runPipeline()` executes, then built-in TypeScript defaults are used and behavior is identical to current implementation
  - [ ] Given `developer.md` exists but `explorer.md` does not, when the pipeline runs, then Developer uses external prompt and Explorer uses built-in fallback

---

#### TRD-NFR-002: Invalid Config Resilience [satisfies REQ-019]

- Validated by: TRD-011 (phase config loader catches parse errors), TRD-013 (workflow loader catches parse errors), TRD-010 (prompt loader handles malformed templates)
- Validates PRD ACs: AC-019-1, AC-019-2, AC-019-3
- Implementation AC:
  - [ ] Given `phases.json` with JSON syntax error, when `loadPhaseConfigs()` is called, then a warning is logged and built-in defaults are returned
  - [ ] Given `workflows.json` with empty array `"feature": []`, when `getWorkflow("feature")` is called, then the empty array is returned (loader does not validate contents)
  - [ ] Given `explorer.md` with unclosed `{{#if`, when `loadPrompt()` processes it, then the malformed syntax passes through as literal text

---

#### TRD-NFR-003: No SQLite Schema Changes [satisfies REQ-020]

- Validated by: Code review -- `src/lib/store.ts` must have zero diff
- Validates PRD ACs: AC-020-1, AC-020-2
- Implementation AC:
  - [ ] Given the complete implementation, when `src/lib/store.ts` is reviewed, then zero lines have been added, modified, or removed
  - [ ] Given an existing Foreman installation, when the new version is deployed, then no migration is required

---

#### TRD-NFR-004: Existing CLI Commands Unchanged [satisfies REQ-021]

- Validated by: Code review -- no changes to `foreman status` or `foreman monitor` command files
- Validates PRD ACs: AC-021-1, AC-021-2
- Implementation AC:
  - [ ] Given the complete implementation, when `foreman status` is invoked, then output format and content are unchanged
  - [ ] Given the complete implementation, when `foreman monitor` is invoked, then polling and output are unchanged

---

#### TRD-NFR-005: Performance [satisfies REQ-022]

- Validated by: TRD-002 (fetchLatestPhaseMessage with AbortController timeout), TRD-010/TRD-011/TRD-013 (filesystem-only config loading)
- Validates PRD ACs: AC-022-1, AC-022-2, AC-022-3
- Implementation AC:
  - [ ] Given Agent Mail is available on localhost, when `fetchLatestPhaseMessage()` is called, then fetch + acknowledge completes within 500ms
  - [ ] Given `loadPrompt()`, `loadPhaseConfigs()`, and `loadWorkflows()` called at pipeline start, when measured, then all three complete within 50ms total
  - [ ] Given Agent Mail is unreachable, when `fetchLatestPhaseMessage()` is called, then it returns `null` within 5 seconds via `AbortController` timeout

---

## 5. Sprint Planning

### Phase 1: Agent Mail Read Transport -- 2 days (16h)

| Task | Estimate | Dependencies | Priority |
|------|----------|-------------|----------|
| TRD-001: acknowledgeMessage fix | 1h | none | P0 |
| TRD-001-TEST | 1h | TRD-001 | P0 |
| TRD-002: fetchLatestPhaseMessage | 2h | TRD-001 | P0 |
| TRD-002-TEST | 2h | TRD-002 | P0 |
| TRD-003: QA feedback read path | 2h | TRD-002 | P0 |
| TRD-003-TEST | 2h | TRD-003 | P0 |
| TRD-004: Reviewer findings send | 1h | TRD-002 | P1 |
| TRD-004-TEST | 1h | TRD-004 | P1 |
| TRD-005: Reviewer findings read | 2h | TRD-004 | P1 |
| TRD-005-TEST | 1h | TRD-005 | P1 |
| TRD-006: Explorer report read | 2h | TRD-002 | P0 |
| TRD-006-TEST | 1h | TRD-006 | P0 |
| TRD-007: Stale message filtering | 2h | TRD-002 | P1 |
| TRD-007-TEST | 2h | TRD-007 | P1 |
| TRD-008: Backward compat validation | 2h | TRD-003, TRD-005, TRD-006 | P0 |
| TRD-008-TEST | 2h | TRD-008 | P0 |
| TRD-009: Part 1 comprehensive tests | 3h | TRD-001 through TRD-008 | P0 |
| **Phase 1 Total** | **27h** | | |

### Phase 2: Config Loaders -- 3 days (24h)

| Task | Estimate | Dependencies | Priority |
|------|----------|-------------|----------|
| TRD-010: Prompt loader | 2h | none | P1 |
| TRD-010-TEST | 2h | TRD-010 | P1 |
| TRD-011: Phase config loader | 2h | none | P1 |
| TRD-011-TEST | 2h | TRD-011 | P1 |
| TRD-012: Phase config schema validation | 1h | TRD-011 | P2 |
| TRD-013: Workflow config loader | 2h | none | P1 |
| TRD-013-TEST | 2h | TRD-013 | P1 |
| TRD-014: Workflow-phase cross-validation | 2h | TRD-013 | P1 |
| TRD-014-TEST | 1h | TRD-014 | P1 |
| TRD-015: Finalize enforcement | 1h | TRD-013 | P1 |
| TRD-015-TEST | 1h | TRD-015 | P1 |
| TRD-016: Wire loaders into runPipeline | 4h | TRD-010, TRD-011, TRD-013, TRD-014, TRD-015 | P1 |
| TRD-016-TEST | 3h | TRD-016 | P1 |
| TRD-017: Bundled default files | 2h | none | P1 |
| TRD-017-TEST | 2h | TRD-017, TRD-010 | P1 |
| TRD-018: Part 2 comprehensive tests | 3h | TRD-010 through TRD-017 | P1 |
| **Phase 2 Total** | **32h** | | |

### Phase 3: Init Seeding -- 1 day (4h)

| Task | Estimate | Dependencies | Priority |
|------|----------|-------------|----------|
| TRD-019: foreman init config seeding | 2h | TRD-017 | P2 |
| TRD-019-TEST | 2h | TRD-019 | P2 |
| **Phase 3 Total** | **4h** | | |

### Phase 4: Reproducer Phase -- 1 day (5h)

| Task | Estimate | Dependencies | Priority |
|------|----------|-------------|----------|
| TRD-020: Reproducer phase | 3h | TRD-016, TRD-017 | P3 |
| TRD-020-TEST | 2h | TRD-020 | P3 |
| **Phase 4 Total** | **5h** | | |

### Total: 68h across 42 tasks (21 implementation + 21 test)

---

## 6. Dependencies

### Task Dependency Graph

```
Phase 1: Agent Mail Read Transport
  TRD-001 (ack fix)
    +-- TRD-001-TEST
    +-- TRD-002 (fetchLatestPhaseMessage)
          +-- TRD-002-TEST
          +-- TRD-003 (QA read path)
          |     +-- TRD-003-TEST
          +-- TRD-004 (Reviewer send)
          |     +-- TRD-004-TEST
          |     +-- TRD-005 (Reviewer read path)
          |           +-- TRD-005-TEST
          +-- TRD-006 (Explorer read path)
          |     +-- TRD-006-TEST
          +-- TRD-007 (Stale message filtering)
                +-- TRD-007-TEST
  TRD-003, TRD-005, TRD-006 --> TRD-008 (Backward compat)
    +-- TRD-008-TEST
  TRD-001 through TRD-008 --> TRD-009 (Comprehensive tests)

Phase 2: Config Loaders (independent of Phase 1)
  TRD-010 (Prompt loader)      -- independent
    +-- TRD-010-TEST
  TRD-011 (Phase config loader) -- independent
    +-- TRD-011-TEST
    +-- TRD-012 (Schema validation)
  TRD-013 (Workflow loader)     -- independent
    +-- TRD-013-TEST
    +-- TRD-014 (Cross-validation)
    |     +-- TRD-014-TEST
    +-- TRD-015 (Finalize enforcement)
          +-- TRD-015-TEST
  TRD-010, TRD-011, TRD-013, TRD-014, TRD-015 --> TRD-016 (Wire into runPipeline)
    +-- TRD-016-TEST
  TRD-017 (Bundled defaults) -- independent
    +-- TRD-017-TEST
  TRD-010 through TRD-017 --> TRD-018 (Comprehensive tests)

Phase 3: Init Seeding
  TRD-017 --> TRD-019 (foreman init seeding)
    +-- TRD-019-TEST

Phase 4: Reproducer
  TRD-016, TRD-017 --> TRD-020 (Reproducer phase)
    +-- TRD-020-TEST
```

### Cross-Phase Dependencies

- Phase 1 and Phase 2 are **independent** and can be developed in parallel
- Phase 3 depends on Phase 2 (needs bundled defaults from TRD-017)
- Phase 4 depends on Phase 2 (needs workflow-driven pipeline from TRD-016 and reproducer prompt from TRD-017)

### External Dependencies

- Agent Mail server (mcp_agent_mail) -- must be running for integration testing of Part 1; not required for unit tests
- No new npm dependencies required
- No new Agent Mail API endpoints required (only existing `fetchInbox` and `acknowledgeMessage`)

---

## 7. Quality Requirements

### Test Coverage Targets

| Scope | Unit Coverage | Integration Coverage |
|-------|-------------|---------------------|
| `fetchLatestPhaseMessage()` | >= 90% | N/A |
| `prompt-loader.ts` | >= 80% | N/A |
| `phase-config-loader.ts` | >= 80% | N/A |
| `workflow-config-loader.ts` | >= 80% | N/A |
| Pipeline read paths (Part 1) | >= 80% | >= 70% |
| Pipeline config wiring (Part 2) | >= 80% | >= 70% |
| Overall new code | >= 80% | >= 70% |

### Quality Gates

| Gate | Criteria | Blocking |
|------|----------|----------|
| Type check | `npx tsc --noEmit` passes with zero errors | Yes |
| Unit tests | `npm test` passes with all new tests green | Yes |
| Backward compat | Pipeline completes with `agentMailClient = null` and no config files | Yes |
| Coverage | Unit >= 80%, integration >= 70% for new code | Yes |
| Security | No secrets, no `any` escape hatches, input validation at boundaries | Yes |
| Performance | Config loading < 50ms, mail fetch < 500ms localhost, timeout < 5s unreachable | Yes |
| Zero schema changes | `src/lib/store.ts` has zero diff | Yes |
| Zero CLI changes | `foreman status` and `foreman monitor` unchanged | Yes |

### Definition of Done

A task is complete when:
1. Implementation matches all Implementation ACs (checked boxes)
2. Paired TEST task passes with all test ACs green
3. `npm run build && npx tsc --noEmit` passes
4. `npm test` passes (full suite, not just new tests)
5. Code follows TypeScript strict mode, ESM imports with `.js` extensions
6. No new `any` escape hatches

---

## 8. Acceptance Criteria Traceability

| REQ | Description | Implementation Tasks | Test Tasks |
|-----|-------------|---------------------|------------|
| REQ-001 | `acknowledgeMessage()` registry fix | TRD-001 | TRD-001-TEST |
| REQ-002 | `fetchLatestPhaseMessage()` helper | TRD-002 | TRD-002-TEST |
| REQ-003 | QA feedback read path | TRD-003 | TRD-003-TEST |
| REQ-004 | Reviewer findings send | TRD-004 | TRD-004-TEST |
| REQ-005 | Reviewer findings read path | TRD-005 | TRD-005-TEST |
| REQ-006 | Backward compatibility | TRD-008 | TRD-008-TEST |
| REQ-007 | Part 1 unit tests | TRD-009 | TRD-002-TEST through TRD-009 |
| REQ-008 | Prompt loader utility | TRD-010 | TRD-010-TEST |
| REQ-009 | Phase config loader | TRD-011 | TRD-011-TEST |
| REQ-010 | Phase config schema validation | TRD-012 | TRD-011-TEST |
| REQ-011 | Workflow config loader | TRD-013 | TRD-013-TEST |
| REQ-012 | Wire loaders into runPipeline | TRD-016 | TRD-016-TEST |
| REQ-013 | foreman init config seeding | TRD-019 | TRD-019-TEST |
| REQ-014 | Bundled default files | TRD-017 | TRD-017-TEST |
| REQ-015 | Reproducer phase | TRD-020 | TRD-020-TEST |
| REQ-016 | Part 2 unit tests | TRD-018 | TRD-010-TEST through TRD-018 |
| REQ-017 | Zero regression without Agent Mail | TRD-008 | TRD-008-TEST |
| REQ-018 | Zero regression without config files | TRD-NFR-001, TRD-016 | TRD-016-TEST |
| REQ-019 | Invalid config resilience | TRD-NFR-002, TRD-010, TRD-011, TRD-013 | TRD-010-TEST, TRD-011-TEST, TRD-013-TEST |
| REQ-020 | No SQLite schema changes | TRD-NFR-003 | Code review |
| REQ-021 | Existing CLI commands unchanged | TRD-NFR-004 | Code review |
| REQ-022 | Performance | TRD-NFR-005, TRD-002 | Performance validation |
| REQ-023 | Explorer report read path | TRD-006 | TRD-006-TEST |
| REQ-024 | Workflow-phase cross-validation | TRD-014 | TRD-014-TEST |
| REQ-025 | Finalize phase enforcement | TRD-015 | TRD-015-TEST |
| REQ-026 | Stale message filtering | TRD-002, TRD-007 | TRD-002-TEST, TRD-007-TEST |

---

## 9. Technical Decisions

### TD-001: Message-Triggered Sequential (Option A)

**Decision:** Retain the existing sequential `await`-chain in `runPipeline()` and add inbox reads between phases.

**Rationale:** ~60 lines of new code for Part 1. Zero new processes. Zero SQLite changes. Full backward compatibility. The alternatives (daemon-per-phase, central state machine, thread-based) require 200-800+ lines of new code and introduce architectural complexity that is not justified by the requirements.

### TD-002: Fallback-First Design

**Decision:** Every new read path (Agent Mail inbox, external config file, external prompt file) has an automatic fallback to the existing mechanism (disk file, `ROLE_CONFIGS`, built-in prompt function).

**Rationale:** Ensures zero regression for existing installations. Operators can adopt features incrementally. A missing or broken config file never crashes the pipeline.

### TD-003: Run ID in Subject for Stale Filtering

**Decision:** Embed `runId` in the message subject as `[run:{runId}]` rather than using a separate metadata field.

**Rationale:** The Agent Mail message schema uses `subject` and `body_md` fields. Subject-based filtering is simpler and more observable (visible in inbox listings). No new Agent Mail API features required. Backward compatible -- messages without `runId` tags are simply skipped by the new filter.

### TD-004: roles.ts Kept as Fallback

**Decision:** `roles.ts` prompt functions (`explorerPrompt()`, `developerPrompt()`, etc.) and `ROLE_CONFIGS` are kept unchanged as fallback defaults. No code is deleted from `roles.ts`.

**Rationale:** The external config files in `~/.foreman/` are optional. If they are absent, deleted, or corrupted, the pipeline must fall back to the built-in TypeScript implementations. This also means the existing template-loader system in `roles.ts` (using `loadAndInterpolate()`) continues to work as-is.

### TD-005: Template Syntax Simplicity

**Decision:** Use simple `{{variable}}` and `{{#if var}}...{{/if}}` template syntax. No partials, no nested conditionals, no complex expressions.

**Rationale:** The prompt templates are simple enough that a basic regex-based renderer suffices. Complex template engines (Handlebars, Mustache) would add a dependency and complexity for minimal benefit. The PRD explicitly states nested `{{#if}}` uses greedy match and is documented as unsupported but non-breaking.

### TD-006: Validation at Pipeline Start

**Decision:** Cross-validate workflow phases against phase configs and enforce finalize-last at the start of `runPipeline()`, before any agent is spawned.

**Rationale:** Fail-fast prevents wasted agent time and budget. A descriptive error message at startup is easier to diagnose than a runtime failure mid-pipeline when an unknown phase name is encountered.
