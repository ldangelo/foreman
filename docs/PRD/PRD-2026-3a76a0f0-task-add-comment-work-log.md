---
document_id: PRD-2026-3a76a0f0
label: prd-task-add-comment-work-log
version: 1.0.1
status: Draft
date: 2026-09-18
scale_depth: STANDARD
total_requirements: 14
total_acceptance_criteria: 39
readiness_score: 4.8
---

# PRD: Task Work Log Comment Tool via TaskProvider

Foreman task title read from `FOREMAN_TASK_TITLE`: **Add foreman_task_add_comment MCP tool for workflow work-log entries via TaskProvider**

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
| Risk flags | 12 |
| Dependencies | 10 |
| Open ambiguity markers | 0 |
| TRD decisions required | 2 |

## Acceptance Criteria Summary

| Requirement | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Add a TaskProvider comment contract | Must | Medium | 3 |
| REQ-002 | Implement Beads comments through SystemBrRunner | Must | High | 3 |
| REQ-003 | Expose foreman_task_add_comment as an MCP write tool | Must | High | 3 |
| REQ-004 | Resolve run, project, and provider task context server-side | Must | High | 3 |
| REQ-005 | Compose structured Work Log bodies server-side | Must | Medium | 3 |
| REQ-006 | Preserve write-policy safety with an explicit policy decision | Must | High | 3 |
| REQ-007 | Keep workers isolated from Beads internals | Must | Medium | 2 |
| REQ-008 | Return typed successes and typed failures | Must | Medium | 3 |
| REQ-009 | Instruct bundled workflow agents to write useful work logs | Must | Medium | 3 |
| REQ-010 | Verify with a live dispatched workflow | Must | Medium | 3 |
| REQ-011 | Document implemented operator behavior | Must | Medium | 2 |
| REQ-012 | Preserve existing task aggregate MCP behavior | Should | Low | 3 |
| REQ-013 | Limit v1 provider scope to Beads | Should | Low | 2 |
| REQ-014 | Provide tests across provider, MCP, and prompt layers | Should | Medium | 3 |

## 1. Executive Summary

Foreman workflows need a direct, structured way to leave durable Work Log entries on the underlying task-tracker issue. For Beads-backed tasks, that means adding comments to the bead associated with the run. The dispatched worker must not shell out to `br` or learn Beads internals; it must call a new MCP tool, `foreman_task_add_comment`, and Foreman must route the write through the configured `TaskProvider` adapter.

This PRD requires a new provider-level comment capability, a Beads implementation backed by `br comments add`, an MCP tool that derives task/provider context from Foreman's run and task projections, and workflow prompt guidance that makes the tool part of normal phase work logging. This is intentionally a new MCP-to-TaskProvider mutation path, distinct from existing `foreman_task_*` tools that operate on Foreman's own task aggregate.

Foreman mode auto-selected STANDARD depth. Clarifying interviews were skipped; source-verified facts supplied in the task description are treated as authoritative for this PRD.

## 2. Background and Evidence

Source-verified current state:

- `packages/foreman_server/lib/foreman_server/task_provider.ex` currently declares callbacks for provider metadata, create/list/get, lifecycle transitions, priority, and dependencies. It does not declare `comment/3` or `annotate/3`.
- `packages/foreman_server/lib/foreman_server/task_providers/beads_adapter.ex` is the production Beads provider and already uses `SystemBrRunner` through the configured `@runner`.
- `packages/foreman_server/lib/foreman_server/task_providers/system_br_runner.ex` is the established `br` entry point and serializes calls per database.
- `packages/foreman_server/lib/foreman_server/mcp/tools.ex` owns MCP schemas and handlers, including existing `foreman_task_*` tools and `foreman_inbox_send`.
- `packages/foreman_server/lib/foreman_server/mcp/policy.ex` uses `allow_workflow_writes` to hide/refuse current write tools, including `foreman_inbox_send`.
- `packages/foreman_server/lib/foreman_server/task_provider/registry.ex` can resolve the active provider module and project config for a project.
- `RunExecutor` already calls `TaskProvider.Registry` and then `provider_module.claim/3`, `complete/3`, and `fail/3` for provider lifecycle writes.
- Bundled workflow prompts already include guidance for `foreman_inbox_send`; similar guidance can be added for work-log comments.

Upstream Beads capability:

- `br comments add <id> [TEXT]` supports adding issue comments.
- `br comments add <id> -m <text>` supplies the message as a flag.
- Beads' comments table supplies comment timestamp and author, so Foreman should not fabricate those values in the comment body.

## 3. Personas

- **Dispatched workflow agent:** needs one Foreman MCP tool for recording what it did during a phase without knowing the task provider implementation.
- **Foreman operator:** needs a task-tracker Work Log that survives outside Foreman's run logs and inbox.
- **Foreman maintainer:** needs clear provider boundaries, typed contracts, policy gating, tests, and documentation for this new mutation path.
- **Task-provider adapter author:** needs an explicit provider callback contract for comment support.

## 4. Scope

In scope:

- Add `TaskProvider.comment/3` or an equivalent explicitly named comment callback.
- Implement the comment callback for `BeadsAdapter` using `SystemBrRunner` and `br comments add`.
- Add MCP tool `foreman_task_add_comment`.
- Build the Work Log body from structured tool fields: workflow name, phase name, and description of work performed.
- Validate required structured fields and bounded body length before any provider write.
- Resolve `run_id`, Foreman task, project, provider module, and provider task id server-side.
- Gate the tool under the implemented MCP write policy.
- Add workflow prompt/skill guidance for phase start, material milestones, blockers, and phase completion.
- Verify via a live dispatched run and `br comments list <task-id>` or `br show <task-id>`.
- Update operator-facing docs only after behavior is implemented.

Out of scope:

- Implementing this PRD during PRD creation.
- Direct worker access to `br`, Beads SQLite, or `BeadsAdapter` internals.
- A Kata provider implementation before Kata itself exists.
- Changing Beads schema or timestamp/author behavior.
- Replacing Foreman logs, activity, phase artifacts, or `foreman_inbox_send`.
- Routing this tool through Foreman's task aggregate or `CommandGateway` unless a TRD explicitly rejects the TaskProvider route with evidence.

## 5. Assumptions From Foreman Mode

- Tool name is `foreman_task_add_comment`.
- Work Log v1 targets the run's underlying provider-tracked task, not arbitrary task ids supplied by the agent.
- The agent should provide `run_id`, `workflow_name`, `phase_name`, and `description`; Foreman should resolve task and provider context.
- The MCP schema should not accept caller-supplied provider task ids or Beads issue ids in v1.
- The server should compose a parseable comment body such as a `Work Log` block with `Workflow`, `Phase`, and `Work performed` fields.
- Created-at and author are supplied by Beads and must not be manually duplicated as authoritative timestamps.
- Policy gating needs an explicit TRD decision: either use existing `allow_workflow_writes` for v1 or introduce a narrower comment-write policy. This PRD requires the decision and tests; it does not pre-choose a separate flag.
- Live verification must prove an agent call happened during a dispatched run, not merely that instructions rendered in a prompt.

## 6. Requirements

### REQ-001: Add a TaskProvider comment contract

Priority: Must
Complexity: Medium
Risk: A vague provider return type could create a bare-map boundary and future adapter drift.

`ForemanServer.TaskProvider` MUST define an explicit callback for adding comments to upstream provider issues.

- AC-001-1: Given the behavior is inspected, when `behaviour_info(:callbacks)` is read, then it includes a comment callback with arity 3.
- AC-001-2: Given the callback is documented, when maintainers read `task_provider.ex`, then the docs state the arguments are provider issue id, comment body, and project config.
- AC-001-3: Given the callback returns success, when its return type is inspected, then it is a typed result such as `{:ok, Issue.t()}` or a purpose-built comment struct, never an untyped bare map.

### REQ-002: Implement Beads comments through SystemBrRunner

Priority: Must
Complexity: High
Risk: Bypassing the runner would break lease serialization and duplicate `br` invocation policy.

`BeadsAdapter` MUST implement the comment callback by invoking Beads through the configured runner.

- AC-002-1: Given a valid issue id and comment body, when `BeadsAdapter.comment/3` runs, then it calls the configured `SystemBrRunner` path with the equivalent of `br comments add <id> -m <body>`.
- AC-002-2: Given the provider config includes a Beads database path, when the comment command runs, then it uses the same serialized runner/lease conventions as other Beads writes and never calls `System.cmd` directly.
- AC-002-3: Given `br` returns an error envelope or unparsable output, when the adapter handles it, then it returns a `%ProviderError{}` with retryability derived from the adapter's code map or an explicit comment-error mapping.

### REQ-003: Expose foreman_task_add_comment as an MCP write tool

Priority: Must
Complexity: High
Risk: This is the first direct MCP-to-TaskProvider mutation and can blur aggregate/provider boundaries.

MCP clients MUST be able to discover and call `foreman_task_add_comment` when write policy permits it.

- AC-003-1: Given MCP write policy permits the tool, when `tools/list` is called, then `foreman_task_add_comment` appears with schema fields for `run_id`, `workflow_name`, `phase_name`, and `description`, and no provider issue id or Beads id input field.
- AC-003-2: Given valid arguments for a provider-tracked run, when the tool is called, then it resolves the task provider and requests a comment write through `TaskProvider.comment/3`.
- AC-003-3: Given implementation is inspected, when the handler is traced, then it does not dispatch `task.update`, write projections, append aggregate events directly, or mutate the Foreman task aggregate.

### REQ-004: Resolve run, project, and provider task context server-side

Priority: Must
Complexity: High
Risk: Trusting agent-supplied task ids could write to the wrong bead.

The tool MUST derive the provider issue target from Foreman's run/task state rather than trusting a free-form provider issue id from the worker.

- AC-004-1: Given a valid `run_id`, when the tool runs, then it loads the run projection and obtains the associated `project_id`, `task_id`, and workflow context needed to route the provider call.
- AC-004-2: Given the run or task is missing, untracked, or lacks a provider issue id, when the tool runs, then it returns a typed `NOT_FOUND` or `INVALID_STATE` error and writes no provider comment.
- AC-004-3: Given the project has no active task provider config, when the tool runs, then it returns a typed provider-configuration error and writes no provider comment.

### REQ-005: Compose structured Work Log bodies server-side

Priority: Must
Complexity: Medium
Risk: Free-form or unbounded comments would be inconsistent, hard to parse, and unsafe to send to the provider.

Foreman MUST construct the comment body from structured fields supplied to the MCP tool.

- AC-005-1: Given `workflow_name`, `phase_name`, and `description` are supplied, when the tool writes the comment, then the body includes a stable `Work Log` shape with those fields and no fabricated authoritative timestamp or author.
- AC-005-2: Given a caller omits, blanks, or exceeds bounded length for any required structured field, when the tool validates arguments, then it returns `INVALID_PARAMS` before any provider call.
- AC-005-3: Given the Beads comment is created, when it is listed with `br comments list` or shown with `br show`, then Beads provides the comment creation time and author, while Foreman's body provides workflow, phase, and work-performed content.

### REQ-006: Preserve write-policy safety with an explicit policy decision

Priority: Must
Complexity: High
Risk: A new write tool could become unexpectedly available or be over-gated without a documented decision.

The implementation MUST make and test an explicit MCP policy decision for work-log comments.

- AC-006-1: Given default MCP configuration, when `tools/list` is called, then `foreman_task_add_comment` exposure matches the documented policy decision and is covered by tests.
- AC-006-2: Given the tool is directly called while policy denies it, when dispatch reaches MCP policy, then the request is refused before provider routing and no Beads command runs.
- AC-006-3: Given the TRD evaluates policy options, when implementation starts, then it records whether v1 uses `allow_workflow_writes` or a narrower comment-write flag, with rationale and documentation updates.

### REQ-007: Keep workers isolated from Beads internals

Priority: Must
Complexity: Medium
Risk: Prompt guidance can accidentally teach workers to bypass the MCP boundary.

Workflow workers MUST interact only with Foreman's MCP tool for Work Log writes.

- AC-007-1: Given bundled prompts or skills mention work-log comments, when they are inspected, then they instruct agents to call `foreman_task_add_comment` and do not instruct agents to run `br`, open Beads SQLite, or call Beads internals.
- AC-007-2: Given a dispatched agent successfully writes a Work Log entry, when execution evidence is reviewed, then the only worker-visible interface used is the MCP tool.

### REQ-008: Return typed successes and typed failures

Priority: Must
Complexity: Medium
Risk: Generic success/error payloads make worker recovery and tests unreliable.

The MCP tool MUST expose a bounded typed result and typed errors.

- AC-008-1: Given a comment is written successfully, when the tool responds, then it returns a typed result containing at least `run_id`, `task_id`, `provider`, and `status: "comment_added"`.
- AC-008-2: Given validation fails, provider routing fails, or the provider returns an error, when the tool responds, then it returns an MCP error code that distinguishes invalid params, not found/invalid state, policy refusal, and provider failure.
- AC-008-3: Given a provider error contains sensitive command output, when converted to an MCP response, then the response includes only safe bounded diagnostic text.

### REQ-009: Instruct bundled workflow agents to write useful work logs

Priority: Must
Complexity: Medium
Risk: A tool without prompt guidance will not be used during normal workflow execution.

Bundled workflow prompts and related skill guidance MUST tell dispatched agents when and how to call the tool.

- AC-009-1: Given bundled prompts are installed, when a standard workflow phase starts, reaches a material milestone, hits a blocker, or completes, then prompt guidance tells the agent to add a concise Work Log entry when the tool is available.
- AC-009-2: Given the tool is denied, unavailable, or fails, when an agent follows prompt guidance, then it continues the phase and reports the failed work-log attempt only if relevant to the final artifact.
- AC-009-3: Given prompt sources are changed, when verification runs, then runtime prompt copies are refreshed with `foreman init --force` or equivalent so live dispatched runs use the new guidance.

### REQ-010: Verify with a live dispatched workflow

Priority: Must
Complexity: Medium
Risk: Static prompt checks can pass while agents never call the tool.

The feature MUST be proven through a real workflow run that writes a provider comment.

- AC-010-1: Given the implementation is complete, runtime prompts are refreshed, and writes are enabled according to policy, when a `prd` or `fix` workflow is dispatched on a Beads-backed task, then at least one phase calls `foreman_task_add_comment`.
- AC-010-2: Given the phase call succeeds, when `br comments list <task-id>` or `br show <task-id>` is run by the verifier, then the Work Log entry is visible with correct workflow, phase, description, Beads timestamp, and Beads author.
- AC-010-3: Given live verification is reported, when evidence is reviewed, then it includes the run id, task id, tool-call proof, and Beads comment proof.

### REQ-011: Document implemented operator behavior

Priority: Must
Complexity: Medium
Risk: Foreman's existing docs already contain stale TaskProvider capability claims.

Operator and maintainer docs MUST be updated after implementation to match the real behavior.

- AC-011-1: Given implementation changes behavior, when finalization occurs, then `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/user-guide.md`, and `docs/cli-reference.md` are checked and surgically updated where the new tool, policy, or provider callback affects documented expectations.
- AC-011-2: Given docs mention TaskProvider capabilities, when this feature ships, then they do not claim unsupported callbacks and they accurately include comment support only where implemented.

### REQ-012: Preserve existing task aggregate MCP behavior

Priority: Should
Complexity: Low

Existing Foreman task tools SHOULD continue to operate on Foreman's task aggregate/projections unless separately changed.

- AC-012-1: Given `foreman_task_get`, `foreman_task_list`, or `foreman_task_update` are called, when this feature is present, then their existing aggregate/projection behavior is unchanged.
- AC-012-2: Given `foreman_task_add_comment` is called, when implementation is inspected, then its separate provider-adapter path is documented in code comments or tests so future maintainers do not assume it matches other `foreman_task_*` tools.
- AC-012-3: Given existing task aggregate tests run, when this feature is added, then they remain green or failures are explained by intentional documented changes.

### REQ-013: Limit v1 provider scope to Beads

Priority: Should
Complexity: Low

The first implementation SHOULD support Beads only and leave future providers to implement the new callback when they exist.

- AC-013-1: Given a non-Beads provider lacks comment support, when the tool is called for that provider, then Foreman returns a typed unsupported-provider error rather than silently succeeding.
- AC-013-2: Given Kata provider work is still draft/unimplemented, when this feature ships, then it does not block on Kata comment support.

### REQ-014: Provide tests across provider, MCP, and prompt layers

Priority: Should
Complexity: Medium
Risk: This spans behavior contracts, policy, adapter command construction, and live prompt use.

The implementation SHOULD include focused automated tests plus the required live proof.

- AC-014-1: Given automated tests run, when provider tests execute, then they prove `TaskProvider.comment/3` exists and `BeadsAdapter.comment/3` constructs the correct `br comments add` runner request.
- AC-014-2: Given MCP tests run, when policy, argument validation, context resolution, and provider error paths are exercised, then each returns the expected typed result or error.
- AC-014-3: Given prompt tests or static checks run, when bundled prompts are inspected, then they include Work Log guidance without instructing direct Beads access.

## 7. Dependency Map

| Requirement | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | None | None | Defines provider contract. |
| REQ-002 | REQ-001 | Beads runner request support | First concrete provider implementation. |
| REQ-003 | REQ-001, REQ-004, REQ-006 | MCP schema/handler work | New MCP-to-provider path. |
| REQ-004 | REQ-003 | Run/task projection shape | Must identify provider task safely. |
| REQ-005 | REQ-003 | None | Server-side formatting. |
| REQ-006 | REQ-003 | TRD policy decision | Must decide `allow_workflow_writes` vs narrower flag. |
| REQ-007 | REQ-003, REQ-009 | Prompt wording | Boundary requirement. |
| REQ-008 | REQ-002, REQ-003, REQ-004 | Error mapping | Typed MCP contract. |
| REQ-009 | REQ-003, REQ-006 | Prompt install refresh | Makes tool used in workflows. |
| REQ-010 | REQ-002, REQ-003, REQ-009 | Live Beads-backed run | Acceptance proof. |
| REQ-011 | REQ-001 through REQ-010 | Implementation finalized | Docs must reflect actual behavior. |
| REQ-012 | REQ-003 | Regression tests | Avoids accidental aggregate behavior change. |
| REQ-013 | REQ-001, REQ-002 | Provider detection | Supports Beads only in v1. |
| REQ-014 | REQ-001 through REQ-013 | Test fixtures | Automated confidence plus live proof. |

Implementation clusters:

- **Provider contract and Beads implementation:** REQ-001, REQ-002, REQ-013, provider parts of REQ-014.
- **MCP tool and policy:** REQ-003, REQ-004, REQ-006, REQ-008, REQ-012.
- **Workflow adoption and proof:** REQ-005, REQ-007, REQ-009, REQ-010.
- **Docs and finalization:** REQ-011.

No circular dependencies identified.

## 8. Non-Functional Requirements

Covered within requirements:

- **Security:** policy gating, no direct worker Beads access, no sensitive provider output leaks.
- **Reliability:** provider errors typed, no silent success-with-error, existing task tools preserved.
- **Observability:** live verification evidence and typed outcomes make failures diagnosable.
- **Maintainability:** explicit callback, typed return, documented new architecture path.
- **Operational safety:** default exposure controlled by MCP write policy decision.

## 9. Adversarial Review

### Issue 1: Policy gating could be under-specified

Problem: The task description both suggests `allow_workflow_writes` and asks for a design decision on whether comments deserve a separate flag.

Resolution auto-applied under foreman mode: REQ-006 requires an explicit TRD decision and tests, without making a separate flag mandatory.

### Issue 2: Agent-supplied task ids could write to the wrong provider issue

Problem: Letting the worker pass arbitrary issue ids would violate the boundary and could corrupt unrelated beads.

Resolution auto-applied under foreman mode: REQ-004 requires server-side resolution from `run_id` and Foreman projections.

### Issue 3: Existing `foreman_task_*` naming may imply aggregate routing

Problem: Current task tools operate on Foreman's task aggregate, while this tool must call TaskProvider directly.

Resolution auto-applied under foreman mode: REQ-003 and REQ-012 explicitly document and preserve the architectural distinction.

### Issue 4: Free-form comment text would reduce Work Log consistency

Problem: A single body string would produce unparseable comments and inconsistent phase details.

Resolution auto-applied under foreman mode: REQ-005 requires structured fields and server-side body composition.

### Issue 5: Prompt-only verification can give false confidence

Problem: The previous inbox-work PRD identified that rendered guidance is insufficient if agents never call the tool.

Resolution auto-applied under foreman mode: REQ-010 requires live dispatched workflow proof and external Beads comment evidence.

### Issue 6: Beads adapter return type is unclear

Problem: Comments may not return a full issue payload; returning a bare map would violate Foreman typed-boundary rules.

Resolution auto-applied under foreman mode: REQ-001 requires a typed result, allowing TRD to choose `Issue.t()` or a narrower comment struct.

### Issue 7: Stale documentation could mislead implementers

Problem: AGENTS.md reportedly documents unsupported provider callbacks such as `annotate/3`.

Resolution auto-applied under foreman mode: REQ-011 requires documentation correction based on implemented behavior.

### Issue 8: Unbounded or misdirected input could create unsafe provider writes

Problem: A direct provider mutation tool must not let agents supply provider issue ids or oversized comment text.

Resolution auto-applied under foreman mode: REQ-003 excludes provider issue id inputs from the MCP schema, and REQ-005 requires bounded structured-field validation before provider calls.

## 10. Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 5.0 | Covers provider contract, adapter, MCP, policy, prompts, docs, and live verification. |
| Testability | 4.9 | ACs now cover schema exclusion, bounded inputs, and live runtime prompt refresh; live verification still depends on Beads-backed run availability. |
| Clarity | 4.7 | Two TRD decisions remain but are explicit and bounded, and v1 input boundaries are clearer. |
| Feasibility | 4.5 | Builds on existing TaskProvider, SystemBrRunner, MCP policy, and prompt patterns. |
| Overall | 4.8 | PASS |

Gate decision: PASS. Save PRD.

## 11. TRD Decisions Required

1. Choose typed success return for `TaskProvider.comment/3`: reuse `Issue.t()` only if Beads can return/refresh issue data cleanly, otherwise introduce a narrow comment result struct.
2. Choose MCP policy control: existing `allow_workflow_writes` for v1 or a narrower comment-write flag, with tests and docs matching the decision.

## 12. Suggested Next Step

Create a TRD from this PRD:

```bash
/ensemble-create-trd docs/PRD/PRD-2026-3a76a0f0-task-add-comment-work-log.md
```

## 13. Changelog

### 2026-09-18 — v1.0.1

- Clarified that v1 MCP schema must not accept provider issue ids or Beads ids.
- Added bounded structured-field validation before provider writes.
- Tightened Work Log body requirements to avoid fabricated authoritative timestamps/authors.
- Strengthened live verification to require refreshed runtime prompts.
- Re-scored readiness from 4.7 to 4.8.
