# PRD-2026-008: Workflow Enhancements — Bash Phases, Merge Strategy, Type-Based Dispatch

| Field | Value |
|---|---|
| Document ID | PRD-2026-008 |
| Version | 1.0.1 |
| Status | Draft |
| Date | 2026-04-18 |
| Scale Depth | LIGHT |
| Total Requirements | 8 |
| Readiness Score | 4.5 |

## PRD Health Summary

- **Requirements by priority:** Must (6), Should (2), Could (0), Won't (0)
- **AC coverage:** 8/8 requirements have acceptance criteria (100%)
- **Risk flags:** 2 requirements flagged
- **Dependencies:** 4 cross-requirement dependencies

## Product Summary

**Problem:** Foreman workflows are rigid — every phase must be an AI agent session, merge behavior is hardcoded to auto-merge, and the dispatcher maps almost all bead types to `default.yaml`. This prevents lightweight workflows like "run a skill, test, merge" for bugs, and forces all completed work through the same merge path regardless of risk.

**Solution:** Extend the workflow YAML schema with three capabilities:
1. **Bash command phases** that run shell commands in the worktree alongside AI phases
2. **Per-workflow merge strategy** (`auto`, `pr`, or `none`) controlling post-finalize behavior
3. **Type-based workflow dispatch** mapping bead type to workflow filename with fallback

**Value proposition:** A `bug.yaml` workflow can invoke `/ensemble:fix-issue`, run `npm run test`, and auto-merge — all without touching the pipeline executor's core logic. New workflow types are just YAML files.

**Target user:** Foreman operator (solo developer).

## Goals and Non-Goals

### Goals
- Enable mixed-mode workflows (AI phases + bash phases + skill/command phases)
- Let each workflow declare its own merge strategy
- Automatically select workflow by bead type without manual labeling
- Maintain backward compatibility — existing workflows and dispatch behavior unchanged

### Non-Goals
- DAG-based workflows (Archon-style `depends_on` / `when:` routing) — future work
- Approval gates or interactive loops — future work
- Variable substitution (`$nodeId.output`) between phases — future work

---

## Workflow Phase Types

### REQ-001: Bash Command Phases

**Priority:** Must | **Complexity:** Medium | [RISK: Bash commands run unsandboxed in worktrees — a malicious or misconfigured command could affect the host filesystem]

A workflow phase can specify a `bash:` field instead of `prompt:` or `command:`. The bash command runs in the worktree directory. Exit code 0 = success, non-zero = failure. Bash phases have a default timeout of 120 seconds; the process is killed and the phase treated as failed if it exceeds this.

```yaml
- name: test
  bash: "npm run test"
  artifact: TEST_RESULTS.md
  verdict: true
  retryWith: developer
  retryOnFail: 2
```

- AC-001-1: Given a workflow with a `bash:` phase, when the pipeline executor reaches that phase, then it runs the command in the worktree via a safe shell execution method and captures stdout/stderr.
- AC-001-2: Given a bash phase that exits with code 0, when `verdict: true` is set, then the phase is treated as PASS.
- AC-001-3: Given a bash phase that exits non-zero, when `retryWith` is configured, then the pipeline retries with the specified phase (same as current AI verdict retry behavior).
- AC-001-4: Given a bash phase, when `artifact:` is set, then stdout/stderr is written to that file in the worktree.
- AC-001-5: Given a bash phase that runs longer than 120 seconds, when the timeout elapses, then the process is killed and the phase is treated as a failure.

### REQ-002: Command/Skill Phases

**Priority:** Must | **Complexity:** Low

A workflow phase can specify a `command:` field containing a skill invocation (e.g., `/ensemble:fix-issue`). This is sent as a prompt to a Pi SDK session, identical to current `prompt:` phases but with the command string used directly instead of loading a `.md` file. Command phases support full parity with prompt phases: `models`, `maxTurns`, `artifact`, `verdict`, `retryWith`, `retryOnFail`, `mail`, `files`, and `skipIfArtifact` all work identically.

```yaml
- name: fix
  command: "/ensemble:fix-issue {task.title} {task.description}"
  models:
    default: sonnet
  maxTurns: 80
  artifact: DEVELOPER_REPORT.md
  mail:
    onStart: true
    onComplete: true
```

- AC-002-1: Given a phase with `command:`, when the pipeline executor reaches it, then it creates a Pi SDK session and sends the command string as the prompt.
- AC-002-2: Given a command string with `{task.title}` or `{task.description}` placeholders, when the phase starts, then placeholders are interpolated from the bead's metadata.
- AC-002-3: Given a `command:` phase with `verdict: true` and `retryWith: developer`, when the command phase produces a FAIL verdict, then the pipeline retries with the developer phase (same as `prompt:` phase behavior).

### REQ-003: Phase Type Resolution

**Priority:** Must | **Complexity:** Low

The pipeline executor determines phase type by which field is present: `bash:` = shell execution, `command:` = Pi SDK with inline prompt, `prompt:` = Pi SDK with prompt file (current behavior). Exactly one of these three fields must be present per phase.

- AC-003-1: Given a phase with both `bash:` and `prompt:`, when the workflow is loaded, then validation rejects it with a clear error message.
- AC-003-2: Given a phase with none of `bash:`, `command:`, or `prompt:`, when the workflow is loaded, then validation rejects it.

---

## Merge Strategy

### REQ-004: Per-Workflow Merge Strategy

**Priority:** Must | **Complexity:** Medium | [RISK: Refinery currently assumes auto-merge for all completed runs]

Workflow YAML accepts a top-level `merge:` field that controls post-finalize behavior.

```yaml
name: bug
merge: auto       # auto-merge after finalize (default, current behavior)
```

```yaml
name: feature
merge: pr         # create a PR for manual review
```

```yaml
name: analysis
merge: none       # skip merging (analysis/dry-run workflows)
```

Valid values: `auto` (default), `pr`, `none`. When absent, defaults to `auto` (preserving current behavior).

- AC-004-1: Given a workflow with `merge: auto`, when the pipeline completes finalize, then autoMerge triggers immediately (current behavior).
- AC-004-2: Given a workflow with `merge: pr`, when the pipeline completes finalize, then the refinery creates a GitHub PR via `gh pr create` instead of merging, and sets the run status to `pr-created`.
- AC-004-3: Given a workflow with no `merge:` field, when the pipeline completes, then behavior defaults to `auto`.
- AC-004-4: Given a workflow with `merge: none`, when the pipeline completes finalize, then no merge or PR is created, the run status is set to `completed`, and the worktree/branch is left intact for manual inspection.

### REQ-005: Merge Strategy Propagation

**Priority:** Must | **Complexity:** Low

The resolved merge strategy must be available to the auto-merge and refinery code paths. The dispatcher stores the workflow's merge strategy in the run record (SQLite) so that downstream merge logic can read it without re-parsing the YAML.

- AC-005-1: Given a dispatched run, when auto-merge processes it, then it reads the merge strategy from the run record and branches accordingly (merge vs. PR vs. skip).

---

## Type-Based Dispatch

### REQ-006: Workflow Resolution by Bead Type

**Priority:** Must | **Complexity:** Low

`resolveWorkflowName()` maps bead type to workflow filename: `bug` to `bug.yaml`, `feature` to `feature.yaml`, `chore` to `chore.yaml`, etc. If the resolved file does not exist in either `.foreman/workflows/` or bundled defaults, falls back to `default.yaml`.

Resolution precedence (unchanged for labels, extended for types):
1. `workflow:<name>` label on the bead (highest priority)
2. Bead type to matching workflow filename
3. `default.yaml` (fallback)

- AC-006-1: Given a bead of type `bug` and a `bug.yaml` workflow file exists, when dispatched, then `bug.yaml` is used.
- AC-006-2: Given a bead of type `bug` and no `bug.yaml` exists, when dispatched, then `default.yaml` is used.
- AC-006-3: Given a bead with label `workflow:smoke` and type `bug`, when dispatched, then `smoke.yaml` is used (label takes precedence).

### REQ-007: Workflow File Discovery

**Priority:** Should | **Complexity:** Low

`resolveWorkflowName()` checks for the existence of the type-mapped workflow file before returning it. This requires a filesystem check at resolution time (currently the function is pure string logic).

- AC-007-1: Given `resolveWorkflowName("bug", [])` called, when `bug.yaml` does not exist in either search path, then it returns `"default"` (not `"bug"`).

---

## Placeholder Interpolation

### REQ-008: Task Metadata in Command Strings

**Priority:** Should | **Complexity:** Low

Command strings and bash strings support `{task.*}` placeholders interpolated from the bead's metadata at phase start time. Supported placeholders: `{task.title}`, `{task.description}`, `{task.id}`, `{task.type}`, `{task.priority}`.

Literal braces can be escaped with a backslash: `\{task.title\}` emits the literal text `{task.title}` without interpolation.

- AC-008-1: Given a command `/ensemble:fix-issue {task.title}` and a bead with title "Fix login timeout", when the phase starts, then the prompt sent to Pi SDK is `/ensemble:fix-issue Fix login timeout`.
- AC-008-2: Given a placeholder `{task.foo}` that doesn't match any known field, when the phase starts, then it is left as-is (not interpolated) and a warning is logged.
- AC-008-3: Given a command containing `\{task.title\}`, when the phase starts, then the literal text `{task.title}` is emitted without interpolation.

---

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---|
| REQ-001 | Bash command phases | Must | Medium | 5 |
| REQ-002 | Command/skill phases | Must | Low | 3 |
| REQ-003 | Phase type resolution | Must | Low | 2 |
| REQ-004 | Per-workflow merge strategy | Must | Medium | 4 |
| REQ-005 | Merge strategy propagation | Must | Low | 1 |
| REQ-006 | Workflow resolution by bead type | Must | Low | 3 |
| REQ-007 | Workflow file discovery | Should | Low | 1 |
| REQ-008 | Task metadata interpolation | Should | Low | 3 |

## Dependency Map

- **REQ-002 depends on REQ-008** — command phases need placeholder interpolation
- **REQ-001 depends on REQ-003** — bash phases need phase type resolution
- **REQ-004 depends on REQ-005** — merge strategy needs propagation to refinery
- **REQ-006 depends on REQ-007** — type dispatch needs file existence check for fallback

**Implementation clusters:**
1. Phase types: REQ-001, REQ-002, REQ-003, REQ-008 (workflow-loader + pipeline-executor)
2. Merge strategy: REQ-004, REQ-005 (workflow-loader + auto-merge + refinery + store)
3. Type dispatch: REQ-006, REQ-007 (workflow-loader)

---

## Implementation Readiness Gate

| Dimension | Score | Notes |
|---|---|---|
| Completeness | 5 | All three feature areas covered with requirements |
| Testability | 5 | Every Must/Should requirement has verifiable ACs in Given/When/Then format |
| Clarity | 4 | YAML examples anchor each requirement; placeholder escaping adds minor complexity |
| Feasibility | 4 | All requirements map to known code paths; REQ-004 requires refinery refactoring (flagged) |
| **Overall** | **4.5** | **PASS** |

---

## Changelog

| Date | Version | Changes |
|---|---|---|
| 2026-04-18 | 1.0.0 | Initial draft from create-prd |
| 2026-04-18 | 1.0.1 | Refinement: added bash phase 120s timeout (AC-001-5), added [RISK] tag to REQ-001, added `merge: none` option (AC-004-4), added placeholder escape syntax (AC-008-3), clarified command phase full parity with prompt phases (AC-002-3), scored Implementation Readiness Gate (4.5 PASS) |
