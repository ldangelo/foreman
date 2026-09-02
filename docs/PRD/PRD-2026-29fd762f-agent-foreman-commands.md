---
document_id: PRD-2026-29fd762f
label: prd-agent-foreman-commands
version: 1.0.0
status: Draft
date: 2026-09-02
scale_depth: STANDARD
author: Foreman ensemble-create-prd
foreman_task_title: Add OMP/Claude Code/Codex/OpenCode foreman commands
total_requirements: 16
readiness_score: 4.00
readiness_gate: PASS
---

# PRD: OMP, Claude Code, Codex, and OpenCode Foreman Commands

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 11 |
| Should | 4 |
| Could | 1 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 16/16 (100%) |
| Risk flags | 7 |
| Dependencies | 19 |
| Open ambiguity markers | 7 |
| External dependencies | 4 |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Provide agent-native Foreman command assets | Must | Medium | 2 |
| REQ-002 | Support task creation commands by workflow type | Must | Medium | 3 |
| REQ-003 | Support one-step ad-hoc run submission | Must | Medium | 2 |
| REQ-004 | Support run list/status commands | Must | Low | 2 |
| REQ-005 | Support single run detail commands | Must | Low | 2 |
| REQ-006 | Support task detail/status commands | Must | Low | 2 |
| REQ-007 | Keep commands thin over real `foreman` CLI verbs | Must | Medium | 2 |
| REQ-008 | Validate required inputs before dispatch | Must | Medium | 3 |
| REQ-009 | Make backend/provider expectations explicit | Must | Medium | 2 |
| REQ-010 | Install or expose commands predictably per agent | Should | High | 2 |
| REQ-011 | Provide consistent prompt wording across agents | Should | Medium | 2 |
| REQ-012 | Preserve project and API configuration safety | Must | Medium | 2 |
| REQ-013 | Document generated command inventory | Must | Low | 2 |
| REQ-014 | Test generated assets and command examples | Must | High | 3 |
| REQ-015 | Avoid fabricating unsupported CLI behavior | Should | Medium | 2 |
| REQ-016 | Add optional command discovery metadata | Could | Low | 1 |

## Problem Statement

Foreman operators currently create work and inspect progress primarily through direct CLI invocations such as `foreman task create`, `foreman task approve`, `foreman run submit`, `foreman run list`, `foreman run get`, and `foreman task get`. That is precise but inconvenient inside agent tools where users expect short command/prompt shortcuts.

The requested product change is to add Foreman command assets for OMP, Claude Code, Codex, and OpenCode. These commands should make it easy to create new tasks for the relevant Foreman workflow types and to inspect run/task status from the agent environment without remembering the full CLI syntax.

Primary users are Foreman operators using AI coding agents. Success means an operator can create a workflow-backed task or ad-hoc run, list runs, and inspect a specific run/task through the command system of their current agent while preserving Foreman's existing Go CLI and Phoenix API boundaries.

## Foreman Mode Notes

This PRD was generated under `--foreman`. Clarifying interviews were skipped by contract. Defaults were applied where safe; unresolved items are marked inline with `[NEEDS CLARIFICATION: ...]`.

## Goals

- Add agent command assets for OMP, Claude Code, Codex, and OpenCode.
- Provide commands for creating Foreman tasks per workflow type.
- Provide commands to submit ad-hoc runs, list runs, inspect one run, and inspect one task.
- Keep every command a thin wrapper around the real `foreman` CLI or documented API.
- Keep behavior consistent across agent backends even if file formats differ.

## Non-Goals

- Adding new Foreman server workflow types.
- Adding new Go CLI verbs beyond the command assets unless a missing thin-wrapper need is proven.
- Implementing Codex/OpenCode runtime providers for Foreman execution.
- Changing task lifecycle, approval, dependency, run admission, worktree, or AutoPR semantics.
- Replacing the CLI with direct event-store writes or projection writes.
- Auto-approving ordinary `task create` commands unless the command explicitly uses `run submit` or an approved ad-hoc path.

## Research and Context

### Existing codebase

Foreman is a mixed Go/Elixir system:

- `packages/foreman_server/` — Elixir/Phoenix backend, event store, projections, workflow catalog, run execution, task provider integration.
- `packages/foreman_cli/` — Go CLI, the operator-facing command/query client.
- `packages/jido_harness/` — current Jido Harness adapter and provider integration.
- `docs/user-guide.md` and `docs/cli-reference.md` — living operator docs.

Relevant source surfaces observed during reconnaissance:

- `packages/foreman_cli/cmd/foreman/main.go` dispatches only `project`, `task`, `run`, `workflow`, and `init` top-level commands.
- `packages/foreman_cli/cmd/foreman/task.go` implements `task create`, `task approve`, `task retry`, and `task get`.
- `packages/foreman_cli/cmd/foreman/run.go` implements `run list`, `run get`, `run cancel`, `run remove`, `run reset`, and `run submit`.
- `docs/user-guide.md` documents that `run submit` is unified onto the task path and that `--backend` is presently a client-side/stale value for Codex/OpenCode.
- `docs/prompts/fix-workflows.md` records the earlier concern that Pi/OMP-specific syntax should generalize across Pi, Claude, Codex, and OpenCode command backends.

### Existing PRD style and cross-cutting requirements

The closest recent PRD style is `docs/PRD/PRD-2026-e33bcab7-stacked-pr-phase-tag.md`: frontmatter, health summary, AC summary table, assumptions, feature-area grouping, dependency map, risks, and readiness gate.

Cross-cutting requirements from existing docs:

- The Go CLI must remain a thin HTTP client and must not write server state directly.
- New operator-visible commands must be documented in living docs, not only in point-in-time PRDs.
- CLI behavior must be verified against Go source or a fresh build, not against a stale root binary.
- Codex/OpenCode backend names may appear in CLI validation today, but runtime support is not equivalent to provider readiness.

### External dependencies

| Dependency | Status | Impact |
|---|---|---|
| `foreman` Go CLI | Existing | All command assets should call real CLI verbs or display copyable CLI invocations. |
| OMP command format | Assumed external | Target format and install location are unresolved. [NEEDS CLARIFICATION: What does OMP mean here, and what exact command-file format/location should Foreman generate for it?] |
| Claude Code command format | External | Commands likely live as slash-command markdown files, but exact repo/user scope is unresolved. [NEEDS CLARIFICATION: Should Claude Code commands be installed project-local, user-global, or both?] |
| Codex command format | External | Target command mechanism and installation path are unresolved. [NEEDS CLARIFICATION: Which Codex CLI/app command format should these assets target?] |
| OpenCode command format | External | Target command mechanism and installation path are unresolved. [NEEDS CLARIFICATION: Which OpenCode command/plugin file format should these assets target?] |

### Technical constraints

- Commands must not advertise nonexistent Foreman CLI verbs.
- Task creation commands must respect current `--trd-path` requirements for `implement-trd` and `implement-trd-beads`.
- `run submit --backend codex|opencode` being accepted by the CLI must not be described as runtime execution support until server-side provider support exists.
- Agent command assets may need to shell out; they must preserve `FOREMAN_API_URL` and `FOREMAN_API_TOKEN` environment behavior rather than embedding secrets.

## Assumptions

- A1 — "commands" means agent-native command/prompt assets, not new Foreman domain command types.
- A2 — The initial command inventory should cover bundled workflow selectors visible in `docs/user-guide.md`: `assess`, `discover`, `fix`, `implement`, `implement-trd`, `implement-trd-beads`, `plan`, `prd`, `release`, `trd`, and `verify`.
- A3 — For workflow-backed tasks, the safest default is `foreman task create --workflow-type <workflow>` followed by explicit `foreman task approve`, except `run submit` remains the one-step ad-hoc path.
- A4 — Command assets should generate/call CLI invocations instead of bypassing the CLI with raw `POST /api/commands` unless an unsupported flag forces a documented fallback.
- A5 — Project-local command assets are preferred for repository-specific Foreman workflows. [NEEDS CLARIFICATION: Should generated commands also support user-global install for reuse across repos?]
- A6 — Command output can be JSON by default for status/detail commands to preserve full run/task state.

## Requirements

### Feature Area: Agent Command Inventory

### REQ-001: Provide agent-native Foreman command assets

**Priority:** Must · **Complexity:** Medium · **Risk:** [RISK: Each target agent may use a different command-file schema and install path.]

Foreman provides command assets for OMP, Claude Code, Codex, and OpenCode so operators can invoke Foreman workflows/status checks inside their active agent tool.

- AC-001-1: Given the command assets are generated or installed, when an operator lists commands in a supported agent, then Foreman task/run commands are discoverable with clear names and descriptions.
- AC-001-2: Given a target agent format is unavailable or unknown, when installation is attempted, then Foreman reports the unsupported format with setup instructions rather than writing guessed files.

### REQ-002: Support task creation commands by workflow type

**Priority:** Must · **Complexity:** Medium · **Risk:** [RISK: Workflow names can drift from the runtime catalog if duplicated by hand.]

Foreman command assets expose task creation shortcuts for each supported workflow selector.

- AC-002-1: Given an operator invokes a workflow task command with project, title, and optional description, when the command runs, then it creates a Foreman task using `foreman task create --project <id> --title <title> --workflow-type <workflow>`.
- AC-002-2: Given the workflow type is `implement-trd` or `implement-trd-beads`, when `--trd-path` is omitted, then the command refuses locally with a message naming the required flag.
- AC-002-3: Given the workflow selector is not available in the installed/runtime catalog, when the command runs, then the user sees the underlying Foreman CLI/server error without the command asset rewriting it into success.

### REQ-003: Support one-step ad-hoc run submission

**Priority:** Must · **Complexity:** Medium

Foreman command assets include an ad-hoc submit command for direct workflow execution through `foreman run submit`.

- AC-003-1: Given project ID, workflow, and prompt are supplied, when the ad-hoc command runs, then it invokes `foreman run submit --workflow <name> --prompt <text> --project-id <id>`.
- AC-003-2: Given an optional work ID is supplied, when the command runs, then it passes `--work-id <id>` and does not generate a different task ID.

### REQ-004: Support run list/status commands

**Priority:** Must · **Complexity:** Low

Foreman command assets provide a run-list command for checking all runs and filtered statuses.

- AC-004-1: Given no filters, when the operator invokes the run-list command, then it executes `foreman run list` and displays the returned run projections.
- AC-004-2: Given status, project ID, or limit is supplied, when the command runs, then it forwards only the matching real flags: `--status`, `--project-id`, and `--limit`.

### REQ-005: Support single run detail commands

**Priority:** Must · **Complexity:** Low

Foreman command assets provide a single-run status/detail command.

- AC-005-1: Given a run ID is supplied, when the operator invokes the run-detail command, then it executes `foreman run get <run-id>`.
- AC-005-2: Given no run ID is supplied, when the command is invoked, then it refuses before calling the CLI and explains the required positional argument.

### REQ-006: Support task detail/status commands

**Priority:** Must · **Complexity:** Low

Foreman command assets provide a task status/detail command.

- AC-006-1: Given a task ID is supplied, when the operator invokes the task-detail command, then it executes `foreman task get <task-id>`.
- AC-006-2: Given no task ID is supplied, when the command is invoked, then it refuses before calling the CLI and explains the required positional argument.

### Feature Area: CLI Boundary and Validation

### REQ-007: Keep commands thin over real `foreman` CLI verbs

**Priority:** Must · **Complexity:** Medium

The command assets must use real Foreman CLI verbs and must not invent hidden behavior.

- AC-007-1: Given a command asset is reviewed, when its Foreman invocation is inspected, then every verb/flag maps to Go source under `packages/foreman_cli/cmd/foreman`.
- AC-007-2: Given a Foreman CLI command exits non-zero, when invoked through an agent command, then the non-zero failure is surfaced to the operator and not summarized as success.

### REQ-008: Validate required inputs before dispatch

**Priority:** Must · **Complexity:** Medium

Command assets validate obvious required arguments before they call Foreman.

- AC-008-1: Given a task-create command omits project or title, when invoked, then it refuses before dispatch and names the missing fields.
- AC-008-2: Given a run-submit command omits project ID, workflow, or prompt, when invoked, then it refuses before dispatch and names the missing fields.
- AC-008-3: Given a path argument is supplied for `--trd-path`, when it is absolute or traverses outside the project, then the command refuses or lets the Foreman CLI refuse with the exact error.

### REQ-009: Make backend/provider expectations explicit

**Priority:** Must · **Complexity:** Medium · **Risk:** [RISK: CLI-accepted backend values are not the same as server-side provider readiness.]

Commands that expose backend selection explain and preserve the current backend caveat.

- AC-009-1: Given a backend flag is exposed by an agent command, when help is displayed, then it states that current `run submit --backend` behavior may be client-side only and does not prove Codex/OpenCode runtime provider support.
- AC-009-2: Given a backend value is supplied, when the command runs, then it passes only values accepted by the real CLI or refuses locally with the accepted set.

### REQ-010: Install or expose commands predictably per agent

**Priority:** Should · **Complexity:** High · **Risk:** [RISK: Incorrect installation paths can pollute user-global agent config or fail silently.]

Foreman provides a deterministic way to install, generate, or document command assets for each target agent.

- AC-010-1: Given an operator asks for command installation, when a target agent is selected, then Foreman writes only to documented paths for that agent or prints copyable files if install location is unresolved.
- AC-010-2: Given existing user command files would be overwritten, when installation runs, then Foreman requires an explicit overwrite path or emits a refusal with the existing file path. [NEEDS CLARIFICATION: Should overwrite prompts be interactive, flag-driven, or never supported in Foreman automation?]

### REQ-011: Provide consistent prompt wording across agents

**Priority:** Should · **Complexity:** Medium

Command descriptions, argument names, and examples remain semantically consistent across OMP, Claude Code, Codex, and OpenCode.

- AC-011-1: Given equivalent commands in two target agents, when their descriptions are compared, then they describe the same required inputs and same Foreman CLI behavior.
- AC-011-2: Given an agent format cannot express a feature such as typed arguments, when the asset is generated, then the command body still validates required inputs before dispatch where possible.

### REQ-012: Preserve project and API configuration safety

**Priority:** Must · **Complexity:** Medium

Command assets do not embed credentials or hard-code project-specific secrets.

- AC-012-1: Given a command asset is generated, when its contents are inspected, then it does not contain `FOREMAN_API_TOKEN` values or other secret literals.
- AC-012-2: Given an operator has configured `FOREMAN_API_URL` or `FOREMAN_API_TOKEN`, when a command invokes `foreman`, then the environment is inherited by the CLI rather than duplicated into command files.

### Feature Area: Documentation and Verification

### REQ-013: Document generated command inventory

**Priority:** Must · **Complexity:** Low

Living documentation lists the generated/exposed command names, target agents, and the Foreman CLI invocations they wrap.

- AC-013-1: Given the feature is implemented, when `README.md`, `docs/user-guide.md`, and `docs/cli-reference.md` are searched, then operator-visible command names and install/update steps are documented or explicitly marked not applicable.
- AC-013-2: Given a command wraps a workflow selector, when docs list it, then the docs state whether the command creates a task requiring later approval or submits an ad-hoc auto-approved run.

### REQ-014: Test generated assets and command examples

**Priority:** Must · **Complexity:** High · **Risk:** [RISK: Asset templates can pass unit tests while examples drift from the real CLI.]

Implementation includes tests or validation scripts that prove command assets are syntactically valid and wrap real CLI commands.

- AC-014-1: Given command assets are generated from templates, when tests run, then each template renders with required argument placeholders present and no unresolved template variables.
- AC-014-2: Given documented example Foreman invocations, when validation runs, then their verbs and flags are checked against Go CLI source or a fresh `go build ./cmd/foreman` binary, not the stale root artifact.
- AC-014-3: Given generated assets for multiple agents, when validation runs, then all target formats are included or unsupported targets are explicitly skipped with reason.

### REQ-015: Avoid fabricating unsupported CLI behavior

**Priority:** Should · **Complexity:** Medium · **Risk:** [RISK: Existing cli-reference.md contains historical/stale sections and must not be copied blindly.]

Commands and docs must be grounded in implemented CLI/source behavior.

- AC-015-1: Given a proposed command name or flag is not implemented in `packages/foreman_cli/cmd/foreman`, when the asset inventory is generated, then it is omitted or marked future-only rather than emitted as usable.
- AC-015-2: Given an old docs section claims a command exists but Go source does not route it, when implementing this feature, then source wins and the stale docs claim is not propagated.

### REQ-016: Add optional command discovery metadata

**Priority:** Could · **Complexity:** Low

Generated commands may include machine-readable metadata to help users/agents discover Foreman command categories.

- AC-016-1: Given an agent format supports metadata tags/categories, when Foreman command assets are generated, then commands may be tagged as `foreman`, `task`, `run`, and the workflow selector where applicable.

## Dependency Map

| REQ | Depends On | Blocked By | Notes |
|---|---|---|---|
| REQ-001 | — | Target-agent format decisions | Root inventory requirement. |
| REQ-002 | REQ-001, REQ-007, REQ-008 | — | Workflow-task command family. |
| REQ-003 | REQ-001, REQ-007, REQ-008 | — | One-step ad-hoc path. |
| REQ-004 | REQ-001, REQ-007 | — | Run-list command. |
| REQ-005 | REQ-001, REQ-007, REQ-008 | — | Single-run inspect command. |
| REQ-006 | REQ-001, REQ-007, REQ-008 | — | Single-task inspect command. |
| REQ-007 | — | — | Source-grounding invariant. |
| REQ-008 | REQ-007 | — | Validation before dispatch. |
| REQ-009 | REQ-003, REQ-007 | Server provider caveat | Backend help/caveat. |
| REQ-010 | REQ-001 | Target-agent format decisions | Install/generate workflow. |
| REQ-011 | REQ-001, REQ-010 | — | Cross-agent consistency. |
| REQ-012 | REQ-001, REQ-010 | — | Secret/config safety. |
| REQ-013 | REQ-001–REQ-012 | — | Living docs. |
| REQ-014 | REQ-001–REQ-013 | Target-agent parsers may be absent | Verification. |
| REQ-015 | REQ-007, REQ-013, REQ-014 | — | Anti-drift guard. |
| REQ-016 | REQ-001, REQ-011 | Agent metadata support | Optional. |

Potential circular dependencies: none identified.

Implementation clusters:

1. Source-grounded command inventory: REQ-001, REQ-007, REQ-015.
2. Task/run command families: REQ-002 through REQ-006, REQ-008, REQ-009.
3. Multi-agent generation/install: REQ-010 through REQ-012, REQ-016.
4. Docs and validation: REQ-013, REQ-014.

## Risks and Open Questions

- Target-agent command formats are not confirmed for OMP, Codex, and OpenCode.
- Claude Code install scope is unresolved.
- Backend terminology can mislead users because CLI `--backend` acceptance does not equal server provider support.
- Workflow inventory could drift if command templates duplicate bundled workflow names rather than deriving them.
- Existing CLI reference contains annotated stale sections; implementation must verify against source.

## Adversarial Review

### Issues Found and Resolutions

1. **Gap — target command formats are ambiguous.**  
   Resolution: Marked format/install questions inline and required unsupported targets to fail loudly rather than guessed writes.

2. **Ambiguity — task creation vs ad-hoc run submission could be conflated.**  
   Resolution: Split task-create commands (explicit approval path) from `run submit` (one-step ad-hoc path) and required docs to state the difference.

3. **Contradiction risk — Codex/OpenCode command assets might imply Foreman can execute with Codex/OpenCode providers.**  
   Resolution: Added backend/provider caveat and required help text to avoid implying runtime support.

4. **Missing edge case — TRD-backed workflows need `--trd-path`.**  
   Resolution: Added local refusal requirements for `implement-trd` and `implement-trd-beads` without a TRD path.

5. **Testability issue — generated prompt assets can drift from real CLI behavior.**  
   Resolution: Added validation requirement against Go CLI source/fresh build.

6. **Operational safety issue — command installation could overwrite user assets.**  
   Resolution: Added overwrite refusal/explicit-policy requirement and left interaction policy as clarification.

7. **Documentation gap — operator-visible command names must be discoverable.**  
   Resolution: Added living-doc requirement covering README, user guide, and CLI reference.

All resolutions were auto-applied under Foreman mode.

## Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---:|---|
| Completeness | 4 | Covers command families, validation, install, docs, and tests; exact target formats remain open. |
| Testability | 4 | Every Must/Should req has ACs; target-agent parser availability may limit full automated validation. |
| Clarity | 4 | Clear distinction between task create, run submit, run list/get, task get; inline markers isolate unresolved details. |
| Feasibility | 4 | Thin CLI wrappers are feasible; per-agent install formats need confirmation. |

Overall readiness score: **4.00** — PASS.

Ambiguity scan complete: 7 items marked for clarification.

## Suggested Next Step

Use this PRD as input to TRD creation:

```text
/ensemble-create-trd docs/PRD/PRD-2026-29fd762f-agent-foreman-commands.md
```
