# PRD: Make Foreman Planning Output Directly Consumable by Foreman Execution

## Document Metadata

- **Document ID:** PRD-FOREMAN-PLAN-SLING-COMPAT
- **Version:** 1.0.0
- **Status:** Draft
- **Date:** 2026-04-15
- **Owner:** Foreman orchestrator
- **Parent PRD Reference:** N/A (new feature)

---

## 1. Problem Statement

Currently, `foreman plan` produces markdown documents (PRD → TRD) via `/ensemble:create-prd` and `/ensemble:create-trd` (or `/ensemble:create-trd-foreman`). These are human-readable artifacts, but **not machine-consumable by `foreman run`**.

The execution flow is broken at the handoff:

```
foreman plan → PRD → TRD (markdown) → [manual foreman sling trd ...] → foreman run
```

Step 4 requires a manual `foreman sling trd <trd-file>` invocation after `foreman plan` completes. This is an unnecessary friction point: the TRD is already a structured document, and `foreman sling` already parses it. The manual invocation step exists because `create-trd` was designed for beads, not for Foreman's native task store.

The goal is:

```
foreman plan → PRD → TRD (native tasks) → foreman run
```

Where `foreman sling prd` (not `foreman sling trd`) runs a new `/ensemble:create-trd-foreman` command that emits a **Foreman-native structured TRD/task plan** that `sling` can consume deterministically — producing tasks in the native store marked `ready` (no `[x]` in markdown), with the correct priority, type, and dependency wiring.

---

## 2. Goals and Non-Goals

### Goals

1. **`foreman plan` output is sling-compatible by default.** Running `foreman plan <desc>` should produce a TRD that `foreman sling trd` can consume directly without manual intervention.

2. **New `/ensemble:create-trd-foreman` command (in ../ensemble).** A variant of `create-trd` that outputs a Foreman-native structured TRD. It reads the PRD and produces a markdown TRD that is **specifically formatted to be parsed by Foreman's TRD parser** (`parseTrd()` in `trd-parser.ts`).

3. **A new `foreman sling prd` subcommand** (not just `sling trd`) that:
   - Takes a PRD file path (not TRD)
   - Runs `/ensemble:create-trd-foreman` internally
   - Directly produces native tasks in the Foreman task store
   - Marks tasks `ready` (no `[x]` status in markdown) — no manual approval step

4. **Full end-to-end flow:**
   ```
   foreman plan <desc> → docs/PRD/PRD-YYYY-NNN.md
   foreman sling prd docs/PRD/PRD-YYYY-NNN.md → native tasks marked ready
   foreman run         → dispatches ready tasks
   ```

5. **Backward compatibility preserved.** Existing `foreman sling trd <trd-file>` continues to work with the existing `parseTrd()` parser and `create-trd` output.

### Non-Goals

1. **We are not redesigning the TRD parser.** `parseTrd()` in `trd-parser.ts` is stable. The new command produces markdown that satisfies the existing parser's expectations.

2. **We are not migrating beads to native tasks.** `create-trd-beads` remains as-is for projects that use beads. The `create-trd-foreman` is a parallel output path.

3. **We are not modifying `foreman run` behavior.** `foreman run` dispatches `ready` tasks as it does today. This work only changes how tasks are created during the planning phase.

---

## 3. Requirements

### REQ-001: New `/ensemble:create-trd-foreman` command in ../ensemble

**Statement:** `../ensemble` should expose a new command `create-trd-foreman` (YAML + generated markdown) that, given a PRD path, produces a TRD document formatted for Foreman's native task store.

**Acceptance Criteria:**
- AC-001-1: Given `/ensemble:create-trd-foreman <prd-path>` in Pi, when run, then the model reads the PRD, performs technical elicitation, and writes a TRD to the specified output directory.
- AC-001-2: The generated TRD satisfies Foreman's `parseTrd()` format: H1 epic title, `**Document ID:**` frontmatter, `### N.M Sprint N` headers, `#### Story N.M` headers, markdown tables with ID/Task/Estimate/Dependencies columns.
- AC-001-3: All task status values in the generated TRD are `[ ]` (open), not `[x]` (completed), ensuring tasks are created in `ready` status in the native store.

### REQ-002: New `foreman sling prd` CLI subcommand

**Statement:** `foreman sling` should accept a `prd` subcommand that takes a PRD path and produces native tasks without requiring a separate `sling trd` invocation.

**Acceptance Criteria:**
- AC-002-1: Given `foreman sling prd docs/PRD/PRD-YYYY-NNN.md`, when run interactively, then `foreman sling prd` runs `/ensemble:create-trd-foreman docs/PRD/PRD-YYYY-NNN.md` and then parses the resulting TRD into native tasks.
- AC-002-2: All tasks are created with `status: open` (ready for dispatch), not `in_progress` or `completed`.
- AC-002-3: `foreman sling prd` accepts `--auto` flag to skip confirmation prompt, suitable for non-interactive pipeline use.
- AC-002-4: `foreman sling prd --dry-run` previews the parsed task hierarchy without writing to the task store.
- AC-002-5: `foreman sling prd` supports `--project <name>` and `--project-path <absolute-path>` for project targeting.

### REQ-003: Sling-compatible TRD output contract

**Statement:** The TRD produced by `create-trd-foreman` must satisfy the `parseTrd()` parser in `src/orchestrator/trd-parser.ts` deterministically, without ambiguity.

**Acceptance Criteria:**
- AC-003-1: The TRD contains a markdown table with `ID` and `Task` columns as required by `parseTrd()` (column map alias: `id`, `task`).
- AC-003-2: Sprint headers follow the pattern `### N.M Sprint N` (matched by `SPRINT_PATTERN = /^###\s+\d+\.\d+[a-z]?\s+Sprint\s+(\d+[a-z]?)\s*[:-]?\s*(.*)/i`).
- AC-003-3: Story headers follow `#### Story N.M` (matched by `STORY_PATTERN = /^####\s+Story\s+(\d+\.\d+)\s*[:-]?\s*(.*)/i`).
- AC-003-4: All task status values are `[ ]` (open) — not `[x]`, not blank.
- AC-003-5: Dependencies use the format `TASK-ID` (e.g., `AT-T001`) in the Dependencies column, compatible with `parseDeps()`.
- AC-003-6: Task IDs follow the pattern `[A-Z]+-T\d+` (e.g., `AT-T001`), validated by the risk register parser.

### REQ-004: Sling output contract for native task store

**Statement:** When `sling prd` writes tasks to the native store, they must be marked `ready` and have correct priority/type.

**Acceptance Criteria:**
- AC-004-1: Tasks are created with `status: open` and are included in `br ready` output (unblocked, not deferred).
- AC-004-2: Tasks created from epic/sprint/story hierarchy are linked via `parent-child` dependencies, so the epic blocks sprints, sprints block stories, stories block tasks.
- AC-004-3: Tasks have `externalId` set to `trd:<TRD-ID>` (e.g., `trd:AT-T001`), enabling idempotent re-runs.
- AC-004-4: Task type mapping: `epic` → `epic`, `sprint` → `feature`, `story` → `feature`, `task` → `task`, `test` → `task`, `spike` → `chore`.
- AC-004-5: Task priority mapping: sprint priority `critical` → P0, `high` → P1, `medium` → P2, `low` → P3.

### REQ-005: Backward compatibility

**Statement:** Existing `foreman sling trd <trd-file>` continues to work without modification.

**Acceptance Criteria:**
- AC-005-1: `foreman sling trd <trd-file>` with a TRD produced by `create-trd` (beads path) continues to parse correctly.
- AC-005-2: `foreman sling trd <trd-file>` with a TRD produced by `create-trd-foreman` (native path) continues to parse correctly.
- AC-005-3: No changes to `parseTrd()` API signature or return type.
- AC-005-4: No changes to `sling-executor.ts` execute function signature or return type.

### REQ-006: Command split between plan and sling

**Statement:** The CLI command split must be clear: `foreman plan` handles PRD/TRD creation, `foreman sling prd` handles native task instantiation from a PRD.

**Acceptance Criteria:**
- AC-006-1: `foreman plan` terminates after TRD generation (does NOT write tasks to native store).
- AC-006-2: `foreman sling prd` takes a PRD and outputs native tasks directly (does NOT generate a TRD markdown file — it consumes the TRD generated by the embedded command).
- AC-006-3: The user-facing hint after `foreman plan` completion changes from:
   > `Next step: foreman sling trd ${outputDir}/TRD.md`
   to:
   > `Next step: foreman sling prd docs/PRD/PRD-YYYY-NNN.md`

---

## 4. Technical Architecture

### 4.1 High-Level Flow

```
┌─────────────────────────────────────────────────────────────────────────┐
│  foreman plan <desc>                                                  │
│    └─ dispatchPlanStep(epic, "/ensemble:create-prd", input)          │
│    └─ dispatchPlanStep(epic, "/ensemble:refine-prd", input)           │
│    └─ dispatchPlanStep(epic, "/ensemble:create-trd", input)           │
│    └─ dispatchPlanStep(epic, "/ensemble:refine-trd", input)           │
│                                                                         │
│  Output: docs/PRD/PRD-YYYY-NNN.md  +  docs/TRD/TRD-YYYY-NNN.md         │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  foreman sling prd docs/PRD/PRD-YYYY-NNN.md                            │
│    1. Run Pi session: /ensemble:create-trd-foreman <prd>               │
│       → writes docs/TRD/TRD-YYYY-NNN-foreman.md                        │
│    2. parseTrd(doc/TRD/TRD-YYYY-NNN-foreman.md) → SlingPlan            │
│    3. sling-executor: SlingPlan → native tasks (status=open/ready)    │
│    4. Print summary                                                     │
└─────────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────────┐
│  foreman run                                                            │
│    → dispatches ready tasks from native store                           │
└─────────────────────────────────────────────────────────────────────────┘
```

### 4.2 Command Definitions

#### `/ensemble:create-trd-foreman` (new, in ../ensemble)

**Location:** `packages/development/commands/create-trd-foreman.yaml` (new file)

**Source:** Based on `create-trd.yaml` v3.0.0, modified to:
- Output TRD compatible with `parseTrd()` (Foreman-native formatting constraints)
- All task status values: `[ ]` (never `[x]`)
- Task IDs must match `[A-Z]+-T\d+` pattern
- Sprint/Story headers must match existing regex patterns
- No beads-specific annotations (no `[satisfies REQ-NNN]` — only `[satisfies REQ-NNN]` as existing TRD format)
- Output path: `docs/TRD/TRD-YYYY-NNN-foreman.md`

**Note on `[satisfies REQ-NNN]`:** The existing TRD parser does NOT parse `[satisfies REQ-NNN]` annotations in task tables. The current parser only extracts: `trdId`, `title`, `estimateHours`, `dependencies`, `files`, `status`. The PRD→TRD traceability mapping (`[satisfies REQ-NNN]`) is informational in the task description field, not the table cells.

#### `foreman sling prd` (new subcommand)

**Location:** `src/cli/commands/sling.ts` — new `prdSubcommand` added alongside existing `trdSubcommand`

**Signature:**
```bash
foreman sling prd <prd-file>
  [--project <name>]
  [--project-path <absolute-path>]
  [--auto]           # skip confirmation
  [--dry-run]        # preview only
  [--json]           # output parsed structure
  [--force]          # refresh even if trd:<ID> already exists
```

**Steps:**
1. Resolve project path via `resolveSlingProjectPath()`
2. Run embedded Pi session: `/ensemble:create-trd-foreman <prd-file>` → writes TRD to temp dir or output dir
3. Read generated TRD file
4. `parseTrd(trdContent)` → `SlingPlan`
5. `analyzeParallel(plan, content)` → `ParallelResult`
6. `execute(plan, parallel, options, taskStore)` → `SlingResult`
7. Print summary

### 4.3 parseTrd() Compatibility Requirements

The following table documents exactly which TRD structural elements `parseTrd()` can process, and what `create-trd-foreman` must emit:

| parseTrd element | Expected format | create-trd-foreman output |
|-----------------|-----------------|--------------------------|
| Epic title | `# <title>` (H1) | `# <title>` |
| Document ID | `**Document ID:** <id>` | `**Document ID:** TRD-YYYY-NNN-foreman` |
| Sprint header | `### N.M Sprint N` (regex) | `### 1.1 Sprint 1: <goal>` |
| Story header | `#### Story N.M` (regex) | `#### Story 1.1: <title>` |
| Table header | Any row with `id` and `task` columns | `\| ID \| Task \| Est. \| Deps \|` |
| Task trdId | Any string (no pattern enforced in parser) | `AT-T001` format |
| Task estimate | `2h`, `2.5h` (regex in `parseEstimate()`) | `2h`, `4h`, `8h` |
| Task deps | Comma-separated IDs or range `X-T001 through X-T008` | `AT-T001, AT-T002` |
| Task status | `[ ]` open, `[x]` completed, `[~]` in_progress | Always `[ ]` |
| Risk Register | Section `## 7.` with table | Optional; omit if `--no-risks` |
| Quality Req. | Section `## 6.` prose | Optional; omit if `--no-quality` |
| Acceptance Criteria | Section `## 5.` with FR-NN subsections | Generated but not parsed into SlingPlan.tasks |

**Critical note:** The parser extracts task information ONLY from markdown tables within a Story section. There is NO extraction of `[satisfies REQ-NNN]` annotations, `[verifies TRD-NNN]` annotations, or any inline task metadata. All task data must appear in the table.

### 4.4 Data Model (SlingPlan → Native Tasks)

```
SlingPlan {
  epic: { title, description, documentId, qualityNotes }
  sprints: TrdSprint[]          → native tasks (type=epic, type=feature)
  acceptanceCriteria: Map
  riskMap: Map
}

TrdSprint {
  number, title, goal, priority
  stories: TrdStory[]           → native tasks (type=feature, parent-child dep to sprint)
}

TrdStory {
  title, frNumber?
  tasks: TrdTask[]             → native tasks (type=task/feature/chore, parent-child dep to story)
}

TrdTask {
  trdId, title, estimateHours, dependencies, files, status, riskLevel?
}
```

**External ID format:**
- Epic: `trd:<documentId>` (e.g., `trd:TRD-2026-018-foreman`)
- Sprint: `trd:<documentId>:sprint:<number>` (e.g., `trd:TRD-2026-018-foreman:sprint:1`)
- Story: `trd:<documentId>:story:<sprintNumber>.<storyIndex+1>` (e.g., `trd:TRD-2026-018-foreman:story:1.1`)
- Task: `trd:<trdId>` (e.g., `trd:AT-T001`)

---

## 5. Command Split Definition

| Phase | Command | Input | Output | Tool |
|-------|---------|-------|--------|------|
| Plan | `foreman plan <desc>` | Product description | PRD.md + TRD.md in docs/ | `dispatchPlanStep()` → Pi `/ensemble:create-prd`, `create-trd` |
| Sling PRD | `foreman sling prd <prd>` | PRD file path | Native tasks in SQLite (status=open/ready) | Embedded Pi `/ensemble:create-trd-foreman` → `parseTrd()` → `sling-executor` |
| Sling TRD | `foreman sling trd <trd>` | TRD file path | Native tasks in SQLite (status=open/ready) | `parseTrd()` → `sling-executor` (existing, unchanged) |
| Run | `foreman run` | None (dispatches ready tasks) | Agent execution | `dispatcher.dispatch()` |

### 5.1 Updated plan completion hint

In `src/cli/commands/plan.ts`, the hint at line 422 currently reads:
```typescript
`\nNext step: foreman sling trd ${outputDir}/TRD.md`,
```

This should change to:
```typescript
`\nNext step: foreman sling prd ${prdPath} --auto`,
```

Where `prdPath` is the path to the PRD that was either passed via `--from-prd` or created during the plan step.

---

## 6. Migration from create-trd-beads to create-trd-foreman in ../ensemble

### 6.1 What changes

| Aspect | create-trd (beads) | create-trd-foreman (native) |
|--------|-------------------|---------------------------|
| Output file | `docs/TRD/TRD-YYYY-NNN.md` | `docs/TRD/TRD-YYYY-NNN-foreman.md` |
| Task status | `[ ]` (open), `[x]` (completed) allowed | Always `[ ]` — no completed tasks in output |
| REQ-NNN traceability | `[satisfies REQ-NNN]` in task table | `[satisfies REQ-NNN]` in task description only |
| Dependency annotation | `[depends: TRD-NNN]` in task table | Dependencies in Deps column (`AT-T001, AT-T002`) |
| Team config | `## Team Configuration` section | Omitted (Foreman handles team via workflow YAML) |
| File save behavior | Saves TRD to `docs/TRD/` | Saves TRD to `docs/TRD/` (then consumed by sling prd) |
| PRD readiness gate | Checked (score >= 4.0 required) | Checked (same gate) |

### 6.2 Phase/step alignment

`create-trd-foreman` reuses most phases from `create-trd.yaml` v3.0.0:

| Phase | create-trd (beads) | create-trd-foreman | Notes |
|-------|-------------------|---------------------|-------|
| Phase 1 | PRD Ingestion and Validation | PRD Ingestion and Validation | Unchanged |
| Phase 2 | Architecture Design | Architecture Design | Unchanged |
| Phase 3 | Task Breakdown and Planning | Task Breakdown and Planning | **Modified: output format constrained to parseTrd()** |
| Phase 4 | MCP Enhancement (Optional) | MCP Enhancement (Optional) | Unchanged |
| Phase 5 | Adversarial Review and Design Gate | **Omitted** (not needed for Foreman-native output — the sling prd pipeline does its own validation) | **Removed** |
| Phase 6 | Output Management | Output Management | **Modified: file naming + status always [ ]** |

### 6.3 Phase 3 (Task Breakdown) modifications for Foreman-native output

The key modification is in **Phase 3, Step 1: Master Task List Generation**:

**Before (beads path):**
- Task IDs: `- [ ] **AT-001**: Description (8h) [satisfies REQ-001]`
- Status: `[ ]` open or `[x]` completed
- Annotations in table or checklist format

**After (foreman-native path):**
- Task IDs in table format with columns: `| ID | Task | Est. | Deps |`
- All status values: `[ ]` (open only)
- Task ID format: `[A-Z]+-T\d+` (e.g., `AT-T001`, `AT-T002`)
- Dependencies in `Deps` column: `AT-T001, AT-T002` (comma-separated)
- Estimates in `Est.` column: `2h`, `4h`, `8h`
- `[satisfies REQ-NNN]` annotations moved to task description (not parseable by `parseTrd()`, but preserved for human readers)

**Example task table (create-trd-foreman output):**

```markdown
#### Story 1.1: Authentication Implementation

| ID | Task | Est. | Deps |
|----|------|------|------|
| AT-T001 | Implement JWT token generation with RS256 signing | 4h | |
| AT-T002 | Implement JWT token validation middleware | 2h | AT-T001 |
| AT-T003 | Add token refresh endpoint | 4h | AT-T002 |
| AT-T004 | Write unit tests for token generation | 2h | AT-T001 |
```

**Critical:** The `parseTrd()` parser looks for `| ID | Task |` table header pattern. The word "ID" must appear in the first column header (not "TRD ID" or "Task ID").

---

## 7. Acceptance Criteria Summary

### Table: Acceptance Criteria Proven

| AC | Description | Verification Method |
|----|-------------|---------------------|
| AC-001-1 | create-trd-foreman reads PRD, elicits technical, writes TRD | Run `/ensemble:create-trd-foreman <prd>` in Pi session; inspect output file |
| AC-001-2 | TRD satisfies parseTrd() format | Parse output TRD with `parseTrd()`; must not throw |
| AC-001-3 | All task statuses are `[ ]` | Inspect TRD markdown; count `[x]` occurrences → must be 0 |
| AC-002-1 | sling prd runs create-trd-foreman + parseTrd + execute | Run `foreman sling prd <prd> --dry-run --json`; verify SlingPlan parsed |
| AC-002-2 | Tasks created with status=open | Run `foreman sling prd <prd>`; query `br list --status=open`; verify tasks present |
| AC-002-3 | --auto flag skips confirmation | Run `foreman sling prd <prd> --auto --dry-run`; no interactive prompt |
| AC-002-4 | --dry-run previews without writing | Run `foreman sling prd <prd> --dry-run`; query task store → no new tasks |
| AC-002-5 | --project and --project-path work | Run with `--project <name>` and `--project-path <abs>`; verify correct project |
| AC-003-1 | Table has ID and Task columns | Inspect TRD table header |
| AC-003-2 | Sprint headers match SPRINT_PATTERN | Test regex against all sprint headers in TRD |
| AC-003-3 | Story headers match STORY_PATTERN | Test regex against all story headers in TRD |
| AC-003-4 | All task statuses are `[ ]` | Count `[x]` occurrences in TRD tasks table |
| AC-003-5 | Dependencies use TASK-ID format | Inspect Deps column; verify format |
| AC-003-6 | Task IDs match [A-Z]+-T\d+ | Test regex against all task IDs |
| AC-004-1 | Tasks in br ready output | Run `br ready`; verify tasks appear |
| AC-004-2 | Parent-child dependencies correct | Query task store; verify epic→sprint→story→task hierarchy |
| AC-004-3 | externalId set to trd:<TRD-ID> | Query task store; verify externalId field |
| AC-004-4 | Type mapping correct | Query task store; verify type field for each task |
| AC-004-5 | Priority mapping correct | Query task store; verify priority field for each task |
| AC-005-1 | sling trd works with create-trd output | Run `foreman sling trd <existing-trd>`; verify tasks created |
| AC-005-2 | sling trd works with create-trd-foreman output | Run `foreman sling trd <foreman-trd>`; verify tasks created |
| AC-005-3 | parseTrd() API unchanged | Existing tests pass without modification |
| AC-005-4 | execute() API unchanged | Existing sling executor tests pass without modification |
| AC-006-1 | foreman plan does not write tasks | Run `foreman plan <desc>`; query task store → no new tasks |
| AC-006-2 | foreman sling prd creates tasks | Run `foreman sling prd <prd>`; query task store → tasks present |
| AC-006-3 | Updated completion hint | Inspect console output after `foreman plan`; verify hint text |

---

## 8. Risks and Mitigations

### Risk 1: Backward Compatibility — TRD Parser Ambiguity

**Description:** `parseTrd()` has column aliases that could cause ambiguity in `create-trd-foreman` output. For example, if the Task column header is named "Description" instead of "Task", the parser would still match it (since `task` has alias `["task", "description", "title"]`). However, if the ID column header is named "TRD ID" (not "ID"), the parser would NOT match it, causing `SLING-010`.

**Severity:** Medium
**Likelihood:** Medium

**Mitigation:**
- Use explicit column headers `ID` and `Task` in all `create-trd-foreman` output.
- Add an integration test `trd-parser-integration.test.ts` that runs `parseTrd()` on `create-trd-foreman` output and asserts no errors.

### Risk 2: Parser Ambiguity — Sprint Number Extraction

**Description:** `parseSprintHeader()` extracts the sprint number using `parseInt(rawNumber, 10)`, then re-attaches the suffix. If the TRD has sprint `1.1a` in the title, the parser extracts `number=1` and `suffix="a"`, but the story numbering within that sprint (e.g., `Story 1.1.1`) references the sprint as `1.1`. This is already handled correctly in the existing code, but any deviation from this pattern in `create-trd-foreman` would cause incorrect parent-child wiring.

**Severity:** Low
**Likelihood:** Low

**Mitigation:**
- Document the sprint number pattern explicitly in the `create-trd-foreman.yaml` command.
- Add a validation step that checks sprint/story numbering consistency before saving the TRD.

### Risk 3: Backward Compatibility — Existing TRD files

**Description:** Projects that already have TRD files generated by `create-trd` (beads path) will be processed by `foreman sling trd` using the same `parseTrd()`. If those TRDs use a different table format (e.g., checklist format instead of tables, or different column headers), `parseTrd()` will throw `SLING-002: No tasks extracted`.

**Severity:** High
**Likelihood:** Medium

**Mitigation:**
- Document the table format requirement clearly in the TRD output.
- Add a `--legacy` flag to `sling trd` that enables a fallback parser for checklist-style TRDs.
- Run `foreman sling trd <existing-trd> --dry-run` as a validation step before running `foreman sling prd` on a project for the first time.

### Risk 4: Dependency Parsing — Range Expressions

**Description:** `parseDeps()` in `trd-parser.ts` handles range expressions like `"AT-T001 through AT-T008"`. However, `create-trd-foreman` must emit individual dependencies (no ranges) to avoid ambiguity about which specific task IDs are in the range. If the TRD generator emits ranges, the parser would expand them correctly, but human readability in the TRD markdown would be reduced.

**Severity:** Low
**Likelihood:** Medium

**Mitigation:**
- `create-trd-foreman` should emit individual comma-separated IDs in the Dependencies column (no ranges).
- Document this constraint in the command YAML.

### Risk 5: Task Status Ambiguity

**Description:** `parseTrd()` interprets `[x]` as `completed` and `[~]` as `in_progress`. If `create-trd-foreman` accidentally emits `[x]` for any task (even during review/revision phases), those tasks would be created with `status=completed` and skipped by `sling-executor.ts` when `skipCompleted: false` (default). This would silently drop tasks from the native store.

**Severity:** High
**Likelihood:** Medium

**Mitigation:**
- The task table in `create-trd-foreman` must always emit `[ ]` for task status.
- Add a validation step in the TRD generation that asserts no `[x]` or `[~]` markers exist in task tables.
- Add an automated test that parses the output TRD and verifies all task statuses are `open`.

### Risk 6: Identifier Collision

**Description:** If multiple `foreman sling prd` runs are executed on the same PRD (e.g., after a failed run), tasks with the same `externalId` already exist in the native store. The current `sling-executor.ts` behavior is to skip existing tasks (increment `result.skipped`) unless `force: true` is passed.

**Severity:** Low
**Likelihood:** Medium

**Mitigation:**
- Document that `foreman sling prd --force` refreshes tasks.
- The idempotency behavior (skip existing) is correct for the intended use case — re-running after plan refinement.

### Risk 7: Dependency Wire Ordering

**Description:** `wireTaskDependencies()` in `sling-executor.ts` iterates over tasks and wires dependencies in order. If a task depends on a task that hasn't been created yet (forward reference), the dependency would fail silently (logged as `SLING-007`). This is a design flaw in the executor, not in `create-trd-foreman`, but it means the TRD must ensure dependencies reference only previously-defined tasks (i.e., `AT-T002` depends on `AT-T001` — `AT-T001` appears before `AT-T002`).

**Severity:** Medium
**Likelihood:** Low

**Mitigation:**
- `create-trd-foreman` should generate tasks in dependency order (topological order).
- Document the dependency ordering constraint in the command YAML.

### Risk 8: Migration Path for Existing Projects

**Description:** Projects that already used `foreman plan` with `create-trd` (beads path) have TRD files in `docs/TRD/`. Switching to `create-trd-foreman` would generate a new TRD with a different slug (`-foreman` suffix), leaving the old TRD in place.

**Severity:** Low
**Likelihood:** Low

**Mitigation:**
- `create-trd-foreman` output uses the same slug as the original TRD (just different path convention).
- The user can run `foreman sling prd` with `--force` on the new TRD to refresh tasks.
- Old TRD files remain in `docs/TRD/` as historical artifacts.

---

## 9. Implementation Phasing

### Phase 1: Baseline (this PRD)
- Write this document
- Review acceptance criteria
- Sign off on the TRD output contract

### Phase 2: Command Creation (`create-trd-foreman.yaml`)
- Create `packages/development/commands/create-trd-foreman.yaml` based on `create-trd.yaml`
- Modify Phase 3 task breakdown output format
- Remove Phase 5 (Adversarial Review) or simplify it
- Add validation step for `[ ]` status constraint
- Regenerate `create-trd-foreman.md` via `npm run generate`

### Phase 3: CLI Integration (`foreman sling prd`)
- Add `prdSubcommand` to `src/cli/commands/sling.ts`
- Implement embedded Pi session runner for `create-trd-foreman`
- Integrate with `parseTrd()` + `sling-executor.ts`
- Update `--dry-run` output to show plan structure
- Update plan completion hint

### Phase 4: Testing
- Add `trd-parser-integration.test.ts` for `create-trd-foreman` output
- Add `sling-prd.test.ts` for CLI integration
- Add validation test: assert no `[x]` markers in task tables
- Add validation test: assert all task statuses parse to `open`

### Phase 5: Documentation
- Update CLAUDE.md with new command flow
- Update `docs/workflow-yaml-reference.md` if needed
- Document `--force` behavior for idempotent re-runs

---

## 10. Files to Create/Modify

### New Files (in ../ensemble)

| File | Description |
|------|-------------|
| `packages/development/commands/create-trd-foreman.yaml` | New command definition |
| `packages/development/commands/ensemble/create-trd-foreman.md` | Generated prompt (via `npm run generate`) |

### New Files (in foreman)

| File | Description |
|------|-------------|
| `src/cli/commands/__tests__/sling-prd.test.ts` | CLI integration tests |
| `src/orchestrator/__tests__/trd-parser-foreman.test.ts` | TRD parser integration tests |

### Modified Files (in foreman)

| File | Changes |
|------|---------|
| `src/cli/commands/sling.ts` | Add `prdSubcommand`, embed Pi session runner |
| `src/cli/commands/plan.ts` | Update completion hint from `sling trd` to `sling prd` |
| `src/cli/__tests__/sling.test.ts` | May need updates for new `sling prd` tests |

---

## 11. Open Questions

1. **TRD filename convention:** Should `create-trd-foreman` output to `docs/TRD/TRD-YYYY-NNN.md` (same as beads path) or `docs/TRD/TRD-YYYY-NNN-foreman.md`? Using the same filename enables `sling trd` to consume both. But it would overwrite beads-path TRDs. Using the `-foreman` suffix is safer but means `sling trd` can't consume it directly — only `sling prd` can.

   **Recommendation:** Use the same filename (`TRD-YYYY-NNN.md`) so both `sling trd` and `sling prd` can consume it. This maximizes compatibility.

2. **Parallel sprint detection:** `analyzeParallel()` in `sprint-parallel.ts` analyzes sprint parallelization from TRD content. Should `create-trd-foreman` emit parallel sprint hints in the TRD (e.g., `[parallel:group-a]` in sprint metadata), or should this be inferred from existing TRD content?

   **Recommendation:** Let `analyzeParallel()` infer parallelization from existing content (no new format needed). The existing `--no-parallel` flag controls this.

3. **Implicit dependencies:** The current TRD format requires explicit `[depends: TASK-ID]` or Deps column entries. Should `create-trd-foreman` automatically infer dependencies from story ordering (tasks in the same story depend on previous tasks in that story)?

   **Recommendation:** Yes — `create-trd-foreman` should auto-wire sequential dependencies within a story (task N depends on task N-1) as a default, unless explicitly overridden.

4. **PRD readiness gate:** Should `foreman sling prd` check the PRD's readiness score before proceeding? The `create-trd-foreman` command performs this check internally. But if the user runs `sling prd` on a PRD that failed its readiness gate, should the command fail?

   **Recommendation:** Yes — propagate the PRD readiness gate failure. Print a warning and halt if the PRD score is below 4.0.

---

## 12. Dependency Map

```
REQ-001 (create-trd-foreman command)
  └─ Requires: ../ensemble YAML generator infrastructure
  └─ Blocks: REQ-002 (sling prd subcommand)

REQ-002 (sling prd CLI subcommand)
  └─ Depends on: REQ-001 (command must exist)
  └─ Blocks: REQ-004 (sling output contract)

REQ-003 (parseTrd() compatibility)
  └─ No new dependencies
  └─ Validated by: REQ-001 AC-001-2

REQ-004 (native task store output contract)
  └─ Depends on: parseTrd() contract satisfied
  └─ Validates: sling-executor.ts existing behavior

REQ-005 (backward compatibility)
  └─ No new dependencies
  └─ Validated by: existing tests pass
```
