---
document_id: PRD-2026-f2049b7e
label: prd-inbox-command-phase-progress
version: 1.0.1
status: Draft
date: 2026-09-18
scale_depth: STANDARD
total_requirements: 14
total_acceptance_criteria: 44
readiness_score: 4.7
---

# PRD: Inbox Progress for Command-Driven PRD and Fix Phases

Foreman task title read from user-delivered Foreman subject: **Wire foreman_inbox_send operator updates into prd.yaml and fix.yaml command phases**

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 11 |
| Should | 3 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 14/14 (100%) |
| Acceptance criteria coverage | 14/14 (100%) |
| Risk flags | 11 |
| Dependencies | 12 |
| Open ambiguity markers | 0 |
| TRD decisions required | 2 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Identify command-phase inbox coverage gaps | Must | Low | 3 |
| REQ-002 | Select a source-validated delivery mechanism | Must | High | 4 |
| REQ-003 | Preserve Foreman subject and skill argument semantics | Must | High | 4 |
| REQ-004 | Cover every `prd.yaml` core phase | Must | Medium | 5 |
| REQ-005 | Cover the `fix.yaml` core phase | Must | Medium | 2 |
| REQ-006 | Apply the standard operator progress contract | Must | Medium | 4 |
| REQ-007 | Keep inbox-send failures non-blocking | Must | Medium | 3 |
| REQ-008 | Refresh installed runtime workflows/prompts | Must | Medium | 2 |
| REQ-009 | Pin manifest/prompt behavior with tests | Must | Medium | 3 |
| REQ-010 | Verify live dispatched workflow inbox delivery | Must | High | 4 |
| REQ-011 | Update operator/developer documentation | Must | Medium | 3 |
| REQ-012 | Protect secrets, prompts, and large output | Should | Medium | 3 |
| REQ-013 | Preserve existing review-tail behavior | Should | Low | 2 |
| REQ-014 | Provide operator-readable evidence | Should | Low | 2 |

## 1. Executive Summary

`prd.yaml` and `fix.yaml` run their main work through `command:` phases such as `/skill:ensemble-create-prd {{input.prompt}} --foreman` and `/skill:ensemble-fix-issue {{input.prompt}} --foreman`. Source and repo guidance state that command phases do not receive Foreman's rendered prompt body. Existing `foreman_inbox_send` guidance lives in prompt files, so review phases get operator-visible progress while command-driven create/refine/implement/fix phases can stay silent.

This PRD requires every phase in `prd.yaml` and `fix.yaml` to produce the same operator-visible inbox progress behavior as existing prompt phases when `foreman_inbox_send` is available. The implementation must validate the mechanism before changing manifests, because converting `command:` to `prompt:` can alter skill invocation, argument rendering, artifact paths, and Foreman subject delivery. Acceptance requires live dispatched `prd` and `fix` runs verified with `foreman_inbox_get`, not only static text checks.

Foreman refine mode auto-applied all structural findings. Ambiguity scan complete: 0 items marked for clarification.

## 2. Background and Evidence

Relevant evidence:

- `packages/foreman_server/priv/defaults/workflows/prd.yaml` has command phases for `create-prd`, `refine-prd`, `create-trd`, `refine-trd`, and `implement-trd`.
- `packages/foreman_server/priv/defaults/workflows/fix.yaml` has a command phase for `fix`.
- `packages/foreman_server/priv/defaults/workflows/prompts/*.md` already include standard `foreman_inbox_send` progress guidance.
- `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` dispatches `:command` phases differently from prompt phases.
- `AGENTS.md` states that a `command:` phase has no in-prompt channel.
- `foreman_inbox_send` is a write-gated MCP tool; `foreman_inbox_get` reads the resulting run inbox messages.

## 3. Goals

- Operators see concise progress at phase start, material milestones, blockers, and phase completion across `prd.yaml` and `fix.yaml`.
- Command-phase skill behavior, Foreman subject delivery, artifacts, commits, stack PR behavior, and review phases are preserved.
- Live dispatched runs prove actual inbox delivery.

## 4. Non-Goals

- No new inbox domain model.
- No new MCP write policy flag.
- No change to `foreman_inbox_send` schema, body limit, metadata allowlist, or telemetry contract.
- No broad RunExecutor refactor unless the TRD proves it is the narrowest safe mechanism.

## 5. Personas

- **Foreman operator:** needs enough inbox progress to know a run is active, blocked, or complete without tailing raw logs.
- **Workflow author:** needs one safe pattern for command and prompt phases.
- **Foreman maintainer:** needs source contracts, tests, docs, and installed runtime workflows to stay aligned.

## 6. Assumptions

- `allow_workflow_writes: true` is the condition under which workflow agents can use `foreman_inbox_send`.
- Inbox progress is best-effort and non-blocking.
- The existing prompt guidance text is the baseline safety and cadence contract.
- The TRD must choose the mechanism: prompt conversion, command-visible instruction injection, skill-level instruction, adapter/runtime support, or another source-validated approach.

## 7. Requirements

### REQ-001: Identify command-phase inbox coverage gaps

Priority: Must  
Complexity: Low

The implementation plan MUST identify every `prd.yaml` and `fix.yaml` phase that cannot currently receive standard inbox guidance through a prompt body.

- AC-001-1: Given `prd.yaml` is inspected, when phase actions are listed, then `create-prd`, `refine-prd`, `create-trd`, `refine-trd`, and `implement-trd` are identified as command-driven core phases.
- AC-001-2: Given `fix.yaml` is inspected, when phase actions are listed, then `fix` is identified as a command-driven core phase.
- AC-001-3: Given prompt-driven phases are inspected, when their prompt bodies are read, then `coderabbit-review`, `repo-rules-review`, and bundled prompt templates are confirmed to already carry the `foreman_inbox_send` guidance.

### REQ-002: Select a source-validated delivery mechanism

Priority: Must  
Complexity: High  
Risk: A naive `command:` to `prompt:` conversion can change skill invocation or argument rendering.

The solution MUST be selected only after validating how RunExecutor, worker adapters, command rendering, prompt rendering, environment variables, MCP tools, and skill invocation interact.

- AC-002-1: Given the TRD evaluates options, when it recommends a mechanism, then it cites source paths and tests proving how command phases receive command text, prompt text, environment variables, and tools.
- AC-002-2: Given prompt conversion is proposed, when it is accepted, then tests prove the equivalent `/skill:ensemble-* ... --foreman` invocation still runs with the intended arguments and Foreman subject.
- AC-002-3: Given a non-conversion mechanism is proposed, when it is accepted, then tests prove command-dispatched skill agents receive the standard inbox guidance before they begin work.
- AC-002-4: Given an option only adds static text to a file the worker never sees, when reviewed, then that option is rejected.

### REQ-003: Preserve Foreman subject and skill argument semantics

Priority: Must  
Complexity: High  
Risk: Breaking subject delivery can produce correct-looking docs about the wrong task.

The change MUST preserve the existing Foreman subject contract and skill arguments.

- AC-003-1: Given `create-prd` receives a task prompt, when the phase runs after the change, then ensemble create-PRD still uses the task subject and description intended by Foreman.
- AC-003-2: Given command strings currently include `{{input.prompt}}`, when the replacement path is rendered, then text containing spaces, quotes, newlines, and shell metacharacters is delivered as one intended prompt, not split or executed.
- AC-003-3: Given later `prd.yaml` phases rely on files created by earlier phases, when the workflow runs, then artifact discovery and phase commits still locate expected PRD/TRD outputs.
- AC-003-4: Given `--foreman` is present in existing skill commands, when phases run after the change, then `--foreman` behavior remains active.

### REQ-004: Cover every `prd.yaml` core phase

Priority: Must  
Complexity: Medium
Risk: Partial coverage would leave some PRD/TRD work silent and make operators misread active phases as stalled.

Every core phase in `prd.yaml` MUST have operator-visible inbox progress behavior.

- AC-004-1: Given `create-prd` starts, when `foreman_inbox_send` is available, then the run inbox receives a concise start note and completion note.
- AC-004-2: Given `refine-prd` starts, when `foreman_inbox_send` is available, then the run inbox receives phase progress consistent with the standard contract.
- AC-004-3: Given `create-trd` starts, when `foreman_inbox_send` is available, then the run inbox receives phase progress consistent with the standard contract.
- AC-004-4: Given `refine-trd` starts, when `foreman_inbox_send` is available, then the run inbox receives phase progress consistent with the standard contract.
- AC-004-5: Given `implement-trd` starts, when `foreman_inbox_send` is available, then the run inbox receives phase progress consistent with the standard contract.

### REQ-005: Cover the `fix.yaml` core phase

Priority: Must  
Complexity: Medium
Risk: Fix runs are common operator-facing workflows, so missing progress there undermines the inbox feature even if PRD phases are covered.

The core `fix` phase MUST have operator-visible inbox progress behavior.

- AC-005-1: Given the `fix` phase starts, when `foreman_inbox_send` is available, then the run inbox receives a concise start note and completion note.
- AC-005-2: Given the `fix` phase encounters a blocker, when `foreman_inbox_send` is available, then the run inbox receives a blocker note without dumping logs, prompts, credentials, or command output.

### REQ-006: Apply the standard operator progress contract

Priority: Must  
Complexity: Medium
Risk: Inconsistent cadence can create noisy inboxes or omit the milestones operators rely on.

Command-driven phases MUST use the same cadence and safety language as existing prompt-driven phases.

- AC-006-1: Given a covered phase starts, when `foreman_inbox_send` is available, then it sends a start note that identifies the phase and current intent.
- AC-006-2: Given a covered phase reaches a material milestone, when `foreman_inbox_send` is available, then it sends a concise milestone note.
- AC-006-3: Given a covered phase completes, when `foreman_inbox_send` is available, then it sends a concise completion note with result or next-phase handoff.
- AC-006-4: Given no material change occurred, when time passes, then the phase does not send timer-only chatter.

### REQ-007: Keep inbox-send failures non-blocking

Priority: Must  
Complexity: Medium
Risk: Treating progress updates as mandatory would turn an observability helper into a workflow failure source.

Inbox progress reporting MUST NOT become a hard dependency for workflow completion.

- AC-007-1: Given `foreman_inbox_send` is denied by MCP policy, when a covered phase runs, then the phase continues its main work.
- AC-007-2: Given `foreman_inbox_send` returns an error or is unavailable, when a covered phase runs, then the phase continues and only mentions the progress-update failure in its final artifact when relevant.
- AC-007-3: Given a covered phase succeeds but progress send failed, when Foreman records phase outcome, then the phase is not marked failed solely because the inbox update failed.

### REQ-008: Refresh installed runtime workflows/prompts

Priority: Must  
Complexity: Medium
Risk: Editing source manifests without reinstalling runtime copies leaves live dispatch unchanged.

The implementation MUST update installed runtime workflow/prompt copies after changing bundled source manifests or prompts.

- AC-008-1: Given bundled source workflows or prompts change, when verification runs, then `foreman init --force` has been executed using a freshly built CLI path or verified source command.
- AC-008-2: Given stale runtime workflows would omit the change, when a live run is dispatched, then the installed runtime copy used by that run contains the accepted change.

### REQ-009: Pin manifest/prompt behavior with tests

Priority: Must  
Complexity: Medium
Risk: Without automated checks, future workflow edits can silently remove command-phase progress instructions.

Automated tests MUST fail if `prd.yaml` or `fix.yaml` regress to uncovered core phases.

- AC-009-1: Given bundled workflow manifests are tested, when `prd.yaml` is parsed, then all core phases are proven to receive inbox progress instructions through the selected mechanism.
- AC-009-2: Given bundled workflow manifests are tested, when `fix.yaml` is parsed, then the `fix` phase is proven to receive inbox progress instructions through the selected mechanism.
- AC-009-3: Given existing prompt files are tested, when their bodies are checked, then current non-blocking `foreman_inbox_send` guidance remains present.

### REQ-010: Verify live dispatched workflow inbox delivery

Priority: Must  
Complexity: High  
Risk: Static prompt/manifest checks can pass while dispatched agents still never call the tool.

Acceptance MUST include live dispatched runs proving actual inbox writes.

- AC-010-1: Given a live `prd` workflow run is dispatched with MCP writes enabled, when `foreman_inbox_get` is called for that run, then messages from at least one formerly command-driven `prd.yaml` core phase are present.
- AC-010-2: Given a live `fix` workflow run is dispatched with MCP writes enabled, when `foreman_inbox_get` is called for that run, then messages from the formerly command-driven `fix` phase are present.
- AC-010-3: Given inbox messages are inspected, when their bodies are reviewed, then they are concise operator-facing notes rather than full prompts, logs, credentials, or command output.
- AC-010-4: Given live verification completes, when the implementation report is written, then it includes run IDs and the `foreman_inbox_get` evidence used to prove delivery.

### REQ-011: Update operator/developer documentation

Priority: Must  
Complexity: Medium
Risk: If docs are not checked, operators may continue to expect prompt-only behavior or miss the runtime-install requirement.

Operator and developer docs MUST describe the real behavior after this change.

- AC-011-1: Given the change affects workflow/operator expectations, when finalization runs, then `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/user-guide.md`, and `docs/cli-reference.md` are checked for needed updates.
- AC-011-2: Given any of those docs mention command phases, prompt phases, inbox progress, or bundled workflow behavior, when a stale claim exists, then it is corrected surgically.
- AC-011-3: Given a doc file does not need edits, when the implementation report is written, then the report states why no edit was needed.

### REQ-012: Protect secrets, prompts, and large output

Priority: Must
Complexity: Medium
Risk: Progress messages that include prompts, credentials, logs, or command output can expose sensitive data and bloat the run inbox.

Progress updates MUST maintain the same safety boundaries as existing prompt guidance — and MUST NOT surface message bodies, including sensitive data, via telemetry metadata. AC-012-3 is the release-blocking control: an implementation that satisfies every other MUST while adding inbox message bodies to telemetry metadata does NOT satisfy this requirement.

- AC-012-1: Given a phase has access to task prompts, credentials, environment variables, or command output, when it sends an inbox note, then those contents are not copied into the note.
- AC-012-2: Given a phase has a large log or test output, when progress is sent, then the inbox note summarizes state and points to normal artifacts/logs instead of embedding output.
- AC-012-3: Given a phase processes sensitive data, when telemetry for inbox send is captured, then message body contents are not added to telemetry metadata. Release-blocking; non-negotiable.

### REQ-013: Preserve existing review-tail behavior

Priority: Should  
Complexity: Low

Existing prompt-driven review phases SHOULD keep their current inbox guidance and behavior.

- AC-013-1: Given `coderabbit-review` and `repo-rules-review` run after the change, when their prompts are rendered, then they still include standard `foreman_inbox_send` guidance.
- AC-013-2: Given review phases complete, when their artifacts are written, then existing report format, unresolved-findings markers, commit behavior, and stack PR behavior are preserved.

### REQ-014: Provide operator-readable evidence

Priority: Should  
Complexity: Low

Final implementation evidence SHOULD make the behavior easy for operators to audit.

- AC-014-1: Given implementation is complete, when the phase report is read, then it lists which phases now send progress and how that was verified.
- AC-014-2: Given a live run was used for proof, when the evidence is read, then it includes enough identifiers for a maintainer to reproduce the `foreman_inbox_get` checks.

## 8. Dependency Map

| Requirement | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | — | — | Establishes phase inventory. |
| REQ-002 | REQ-001 | — | TRD decision point. |
| REQ-003 | REQ-002 | — | Must be proven before workflow edits. |
| REQ-004 | REQ-002, REQ-003 | — | Applies chosen mechanism to `prd.yaml`. |
| REQ-005 | REQ-002, REQ-003 | — | Applies chosen mechanism to `fix.yaml`. |
| REQ-006 | REQ-004, REQ-005 | — | Defines cadence and content. |
| REQ-007 | REQ-006 | — | Keeps progress best-effort. |
| REQ-008 | REQ-004, REQ-005 | — | Ensures live runtime uses source edits. |
| REQ-009 | REQ-002, REQ-004, REQ-005 | — | Regression protection. |
| REQ-010 | REQ-008, REQ-009 | MCP write availability in test env | Hard proof. |
| REQ-011 | REQ-002, REQ-004, REQ-005 | — | Documentation sync. |
| REQ-012 | REQ-006 | — | Safety constraints. |
| REQ-013 | REQ-004, REQ-005 | — | Preserve review prompts. |
| REQ-014 | REQ-010 | — | Operator auditability. |

Requirement clusters:

- Discovery and decision: REQ-001 through REQ-003.
- Workflow behavior: REQ-004 through REQ-008, REQ-012, REQ-013.
- Verification and docs: REQ-009 through REQ-011, REQ-014.

Circular dependencies: none identified.

## 9. TRD Decision Points

1. Decide whether to convert command phases to prompt phases, inject guidance through a command-visible channel, use skill-level instruction, extend adapter/runtime support, or use another source-validated mechanism.
2. Define the narrowest safe way to run `prd` and `fix` workflows with MCP writes enabled and verify delivery with `foreman_inbox_get`.

## 10. Adversarial Review

- **Prompt conversion may change command semantics.** Resolution: REQ-002 and REQ-003 require source validation and tests before accepting a mechanism.
- **Static guidance can pass without live tool calls.** Resolution: REQ-010 requires live dispatched `prd` and `fix` runs verified through `foreman_inbox_get`.
- **Inbox send could become phase-critical.** Resolution: REQ-007 makes inbox failures non-blocking.
- **Runtime copies can stay stale.** Resolution: REQ-008 requires `foreman init --force` and live-run proof from installed runtime copies.
- **Progress messages can leak prompts or secrets.** Resolution: REQ-006 and REQ-012 preserve the concise/safe progress contract.
- **Existing review phases could regress.** Resolution: REQ-013 requires preserving review prompt behavior, artifacts, commits, and stack PR behavior.

## 11. Implementation Readiness Gate

| Dimension | Score | Rationale |
|---|---:|---|
| Completeness | 4.7 | Covers phase inventory, mechanism choice, all target phases, safety, tests, docs, runtime install, live proof, and per-requirement risk flags. |
| Testability | 4.8 | Includes source tests plus live `foreman_inbox_get` verification for `prd` and `fix` workflows. |
| Clarity | 4.6 | Restores complete requirement and acceptance-criteria wording and makes TRD decision points explicit. |
| Feasibility | 4.5 | Builds on existing MCP tool and prompt guidance; main risk remains command/prompt semantics. |

Overall readiness score: **4.7**

Gate decision: **PASS** — ready for TRD handoff.

## 12. Suggested Next Step

Create a TRD for `PRD-2026-f2049b7e` and decide the command-phase guidance delivery mechanism before implementation.

## 13. Changelog

### 2026-09-18 — v1.0.1

- Restored full PRD prose, requirement headings, acceptance criteria, dependency-map rows, TRD decision points, and readiness-gate text where prior text had become compressed or incomplete.
- Added explicit risk indicators to all Medium-complexity requirements.
- Recalculated PRD Health risk flags from 8 to 11 while preserving 14 requirements and 44 acceptance criteria.
- Re-scored readiness from 4.5 to 4.7 after structural restoration and risk-flag completion.
