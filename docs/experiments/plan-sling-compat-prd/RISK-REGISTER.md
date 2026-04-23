# Risk Register: Plan → Sling Compatibility

**Project:** Make Foreman Planning Output Directly Consumable by Foreman Execution
**Document ID:** RISK-FOREMAN-PLAN-SLING-COMPAT
**Version:** 1.0.0
**Date:** 2026-04-15

---

## Risk Summary

| Risk ID | Title | Severity | Likelihood | Status |
|---------|-------|----------|------------|--------|
| **RISK-1** | Backward Compatibility — TRD Parser Column Ambiguity | Medium | Medium | Open |
| **RISK-2** | Parser Ambiguity — Sprint/Story Numbering Collision | Low | Low | Open |
| **RISK-3** | Backward Compatibility — Existing Beads TRD Format Mismatch | High | Medium | Open |
| **RISK-4** | Dependency Parsing — Range Expression Semantics | Low | Medium | Open |
| **RISK-5** | Task Status Ambiguity — Silent Task Dropping | High | Medium | Open |
| **RISK-6** | Identifier Collision — Idempotent Re-runs | Low | Medium | Open |
| **RISK-7** | Dependency Wire Ordering — Forward Reference Silent Failures | Medium | Low | Open |
| **RISK-8** | Migration Path — Existing Projects with Beads TRDs | Low | Low | Open |
| **RISK-9** | Command Surface Bloat — `sling prd` vs `sling trd` Confusion | Low | Medium | Open |
| **RISK-10** | Pi Session Failure — Partial State from Failed Run | Medium | Low | Open |

---

## RISK-1: Backward Compatibility — TRD Parser Column Ambiguity

### Description

`parseTrd()` auto-detects column indices from markdown table headers using alias matching. The column aliases for `id` are `["id"]` and for `task` are `["task", "description", "title"]`. If `create-trd-foreman` outputs a table header with a column name not in these aliases, the parser throws `SLING-010` ("Table header missing required columns").

**Specific failure modes:**
- Column named `TRD ID` → not in `id` aliases → `SLING-010`
- Column named `Task ID` → `id` matches `TRD ID`? No, it's case-sensitive (normalized to lowercase but exact match required)
- Column named `Title` → in `task` aliases ✓
- Column named `Task Description` → partial match? No, exact lowercase match required
- Column named `Description` → in `task` aliases ✓

### Evidence

From `trd-parser.ts`:
```typescript
const COLUMN_ALIASES: Record<keyof ColumnMap, string[]> = {
  id: ["id"],
  task: ["task", "description", "title"],
  estimate: ["est.", "est", "estimate", "hours", "time"],
  deps: ["deps", "dependencies", "dep", "depends on", "depends"],
  files: ["files", "file", "affected files"],
  status: ["status", "done", "state"],
};

// In parseTableHeader():
for (let i = 0; i < cells.length; i++) {
  const normalized = cells[i].toLowerCase().trim();
  for (const [key, aliases] of Object.entries(COLUMN_ALIASES)) {
    if (aliases.includes(normalized) && !(key in map)) {
      (map as Record<string, number | null>)[key] = i;
    }
  }
}
```

### Severity

**Medium**

The failure is detectable (`SLING-010` thrown), but it would cause the entire `sling prd` pipeline to fail silently (PRD readiness gate passed, Pi session completed, but parsing fails).

### Likelihood

**Medium**

`create-trd-foreman` could accidentally use a different column name (e.g., `Task ID`) if the prompt template changes without understanding the alias constraints.

### Mitigation

1. **Explicit column header specification:** The `create-trd-foreman.yaml` command template must explicitly specify `| ID | Task | Est. | Deps |` as the required table header format.
2. **Validation step:** Add a Phase 3 validation step in the command YAML that asserts the table header contains `id` (exact lowercase).
3. **Integration test:** `trd-parser-foreman.test.ts` must test `parseTrd()` against `create-trd-foreman` output and assert no `SLING-010` errors.
4. **Documentation:** Document the column alias constraint in the command YAML comments.

### Residual Risk

**Low** (after mitigation — validation step + integration test)

---

## RISK-2: Parser Ambiguity — Sprint/Story Numbering Collision

### Description

`parseSprintHeader()` extracts sprint number `N` from `### N.M Sprint N` where `N.M` is the sprint sequence number (e.g., `1.1` for the first sprint). The parser uses `parseInt()` to extract the sprint number, then re-attaches the suffix. Story numbering within sprints uses `#### Story N.M`.

**Potential collision:** If a TRD has sprint `1.1` and story `1.1.1`, the parser would parse sprint `1.1` as `number=1, suffix="a"` and story `1.1.1` as `ref="1.1.1"`. This is correctly handled by the existing parser (story refs are just strings, not parsed as numbers), but any deviation from the expected numbering format could cause incorrect parent-child wiring in `sling-executor`.

### Severity

**Low**

The existing parser handles this correctly. The risk is that `create-trd-foreman` generates malformed numbering that the parser silently accepts but wires incorrectly.

### Likelihood

**Low**

`create-trd-foreman` will follow the existing `create-trd` pattern for numbering, which is already compatible with the parser.

### Mitigation

1. **Explicit numbering convention:** Document in `create-trd-foreman.yaml` that sprint numbering is `N.M` and story numbering is `N.M` (not `N.M.N`).
2. **Numbering validation:** Add a validation step that checks no three-part story numbers exist (e.g., reject `Story 1.1.1`).

### Residual Risk

**Very Low** (after mitigation)

---

## RISK-3: Backward Compatibility — Existing Beads TRD Format Mismatch

### Description

Projects that have run `foreman plan` with `create-trd` (beads path) have TRD files in `docs/TRD/` that may use a different format than `parseTrd()` expects. Specifically, `create-trd` outputs task lists as markdown checklists (not tables) in some sections:

```markdown
- [ ] **AT-001**: Implement feature X (8h) [satisfies REQ-001]
```

The current `parseTrd()` parser ONLY parses markdown tables within Story sections. It would fail to extract tasks from checklist-style output, throwing `SLING-002: No tasks extracted`.

### Severity

**High**

This would break backward compatibility for existing TRD files. `foreman sling trd <existing-trd>` would fail on existing projects.

### Likelihood

**Medium**

The existing `create-trd` output format uses tables within Story sections, but may use checklists in other sections. The parser handles this correctly for existing TRDs. However, if the beads path migrates to a fully checklist-based format, `parseTrd()` would break.

### Mitigation

1. **Document table format requirement:** Both `create-trd` and `create-trd-foreman` must emit markdown tables (not checklists) for task sections.
2. **Backward compatibility test:** TRD-FSC-008 specifically tests `foreman sling trd` on existing beads-path TRDs.
3. **Fallback parser (future):** If needed, a `--legacy` flag to `sling trd` could enable a checklist-style fallback parser.
4. **CI validation:** Add a test that `parseTrd()` succeeds on all TRDs in `docs/TRD/`.

### Residual Risk

**Medium** (depends on beads path maintaining table format)

---

## RISK-4: Dependency Parsing — Range Expression Semantics

### Description

`parseDeps()` handles range expressions like `"AT-T001 through AT-T008"` by expanding them into individual IDs:

```typescript
const rangeMatch = part.match(/^([A-Z]+-T)(\d+)\s+through\s+\1(\d+)$/i);
// Expands "AT-T001 through AT-T008" → ["AT-T001", "AT-T002", ..., "AT-T008"]
```

While this is correct, emitting ranges in `create-trd-foreman` output:
1. Reduces human readability (scanning a range vs. individual IDs)
2. Adds parsing complexity for the dependency wire logic (sling-executor must handle ranges)
3. Is unnecessary — individual IDs are clearer and fully supported

### Severity

**Low**

The parser handles ranges correctly. The risk is readability and maintainability, not correctness.

### Likelihood

**Medium**

`create-trd-foreman` prompt could emit ranges if the underlying LLM generation chooses that format.

### Mitigation

1. **Explicit constraint:** `create-trd-foreman.yaml` must explicitly specify that dependencies should be individual comma-separated IDs (no ranges).
2. **Validation step:** Assert that no `through` keyword appears in Deps column cells.

### Residual Risk

**Very Low** (after mitigation)

---

## RISK-5: Task Status Ambiguity — Silent Task Dropping

### Description

`parseTrd()` interprets task status markers as:
- `[ ]` → `status: "open"` → created as ready
- `[x]` → `status: "completed"` → created but skipped when `skipCompleted=false`
- `[~]` → `status: "in_progress"` → created in-progress

If `create-trd-foreman` accidentally emits `[x]` for any task (e.g., during a review/revision phase), those tasks would be created with `status=completed` and **silently dropped from the ready queue**. The `sling-executor` would log them in `result.skipped`, but without a warning, the user would see fewer tasks than expected.

### Severity

**High**

Silent task dropping would cause the user to believe fewer tasks were created than were actually defined. Tasks marked `[x]` in the TRD would never be dispatched.

### Likelihood

**Medium**

The `create-trd-foreman` command template specifies all tasks as `[ ]`, but if the LLM generation deviates (e.g., marking completed subtasks as `[x]` within a story), tasks could be dropped.

### Mitigation

1. **Mandatory `[ ]` status:** The `create-trd-foreman.yaml` command template must explicitly specify that ALL task status values in the task table must be `[ ]` — never `[x]` or `[~]`.
2. **Validation step:** Phase 3 must include a validation step that asserts no `[x]` or `[~]` markers exist in task tables. If found, the command must fail with an error.
3. **Automated test:** `trd-parser-foreman.test.ts` must count `[x]` and `[~]` occurrences in the fixture TRD and assert 0.
4. **sling-executor warning:** If `skipCompleted=false` (default), and any tasks have `status=completed`, print a warning before executing.

### Residual Risk

**Low** (after mitigation — validation step + automated test)

---

## RISK-6: Identifier Collision — Idempotent Re-runs

### Description

If `foreman sling prd` is run multiple times on the same PRD:
1. Tasks with the same `externalId` already exist in the native store
2. `sling-executor.ts` behavior: skip existing tasks unless `force: true`
3. Second run produces: `created=0, skipped=N, failed=0`
4. This is **correct behavior** for idempotent re-runs after plan refinement

However, if the user wants to **refresh** tasks (e.g., after modifying the PRD), they need `--force`. Without this flag, old tasks persist with stale content.

### Severity

**Low**

The behavior is intentional and well-defined. The risk is user confusion about why re-runs show "0 created".

### Likelihood

**Medium**

Users who re-run `sling prd` after plan refinement may expect fresh tasks without `--force`.

### Mitigation

1. **Clear output message:** After a re-run with 0 created tasks, print a message: `N tasks skipped (already exist). Use --force to refresh.`
2. **Documentation:** Document the idempotency behavior in the CLI help text.
3. **Session log:** Include the idempotency note in the session log.

### Residual Risk

**Very Low** (after mitigation)

---

## RISK-7: Dependency Wire Ordering — Forward Reference Silent Failures

### Description

`sling-executor.ts` wires task dependencies in `wireTaskDependencies()` by iterating over the `plan.sprints` → `plan.stories` → `plan.tasks` order. If a task depends on a task that hasn't been created yet (forward reference), the dependency call fails because `trdIdToTaskId.get(depTrdId)` returns `undefined`.

The current code logs this as `SLING-007` error and **silently skips the dependency**:
```typescript
if (!depTaskId) {
  if (options.skipCompleted) continue;
  depErrors.push(`SLING-007: Dependency target ${depTrdId} not found for ${task.trdId}`);
  continue;
}
```

This means tasks with forward dependency references are created but **not wired to their dependencies**. They would appear as unblocked (ready) even though they should be blocked.

### Severity

**Medium**

The dependency is silently dropped. Tasks would execute out of order if the dependency was semantically required.

### Likelihood

**Low**

`create-trd-foreman` generates tasks in dependency order (within a story, tasks are sequential). Forward references would only occur if the LLM generation violates ordering constraints.

### Mitigation

1. **Dependency ordering constraint:** `create-trd-foreman.yaml` must specify that tasks within a story must be ordered so that dependencies reference only earlier tasks in the same story.
2. **Validation step:** Add a validation step that checks no forward references exist (i.e., for each task's dependencies, the dependency task ID appears earlier in the table).
3. **Warning on SLING-007:** Change the log level from `result.errors.push()` to a warning printout, so the user sees the issue.

### Residual Risk

**Low** (after mitigation — ordering constraint + validation)

---

## RISK-8: Migration Path — Existing Projects with Beads TRDs

### Description

Projects that used `foreman plan` with `create-trd` (beads path) have TRD files in `docs/TRD/`. Switching to `create-trd-foreman` would generate a new TRD in the same location (same filename). This would overwrite the beads-path TRD.

However:
1. The beads path TRD is still valid for `foreman sling trd`
2. The new `create-trd-foreman` output uses the same filename, so both are in the same format (table-based)
3. The migration is seamless if the beads path also uses tables

### Severity

**Low**

The formats are compatible. No migration is strictly required.

### Likelihood

**Low**

Existing projects can continue using their existing TRDs. No forced migration.

### Mitigation

1. **No forced migration:** Do not deprecate or remove the existing TRD files. They remain as historical artifacts.
2. **Documentation:** Document that both `sling trd` and `sling prd` can consume TRDs in the standard table format.
3. **Versioned output:** Consider adding a `**Format:** foreman-native` frontmatter field to distinguish new TRDs from legacy TRDs.

### Residual Risk

**Very Low**

---

## RISK-9: Command Surface Bloat — `sling prd` vs `sling trd` Confusion

### Description

Users may be confused about the distinction between `foreman sling prd` and `foreman sling trd`:
- `sling prd` takes a PRD, runs `create-trd-foreman`, then parses the TRD
- `sling trd` takes a TRD, parses it directly

The commands have different inputs but similar outputs (native tasks). Users may wonder: "Which one should I use?"

### Severity

**Low**

The commands have clear, distinct input types (PRD vs TRD). The user-facing help text explains the difference.

### Likelihood

**Medium**

Users new to Foreman may not understand the PRD→TRD→task flow.

### Mitigation

1. **Clear help text:** `sling prd --help` must clearly state it takes a PRD and creates tasks. `sling trd --help` must state it takes a TRD.
2. **Completion hint in plan:** After `foreman plan`, the completion hint suggests `sling prd` (not `sling trd`), making the intended path obvious.
3. **Documentation:** Update CLAUDE.md with the new flow diagram.

### Residual Risk

**Very Low** (after mitigation)

---

## RISK-10: Pi Session Failure — Partial State from Failed Run

### Description

If the embedded Pi session (`/ensemble:create-trd-foreman`) fails partway through:
1. The TRD file may be partially written (incomplete)
2. `parseTrd()` would fail when reading the partial file
3. No tasks would be created

The current `sling prd` implementation would catch the `parseTrd()` error and exit with code 1, which is correct. However, if the Pi session partially writes a malformed TRD, the error message might not be clear about what went wrong.

### Severity

**Medium**

The user would see a parsing error without understanding why (Pi session failed, or TRD is malformed).

### Likelihood

**Low**

Pi sessions have error handling. Partial writes are rare.

### Mitigation

1. **Clear error propagation:** If Pi session fails, the error message from Pi (`planResult.errorMessage`) must be printed to stderr before any parsing attempt.
2. **File existence check:** Before parsing, check if the TRD file exists. If not, print "create-trd-foreman did not produce output file" as the error.
3. **Transaction-like behavior:** If `parseTrd()` fails, do not run `execute()`. The partial file is not committed to the task store.

### Residual Risk

**Low** (after mitigation)

---

## Risk Trend Over Time

```
Implementation Phase →

RISK-5 (Task Status):   ████████████ High ████→→→→→→→→→→→→→→→→→→→→→→→→→ Low
  (mitigation: validation step + automated test)

RISK-3 (Backward Compat): ████████████ High ██████████→→→→→→→→→→→→→→→→→→ Medium
  (mitigation: backward compat test + CI validation)

RISK-1 (Column Ambiguity): ████████ Medium ████→→→→→→→→→→→→→→→→→→→→→→ Low
  (mitigation: explicit constraint + integration test)

RISK-7 (Forward Deps):   ████████ Medium ████→→→→→→→→→→→→→→→→→→→→→→→ Low
  (mitigation: ordering constraint + validation)

All other risks:         ███ Low ███→→→→→→→→→→→→→→→→→→→→→→→→→→ Very Low
```

---

## Closed Risks

None yet — all risks are open pending implementation.

---

## Risk Ownership

| Risk ID | Owner | Review Frequency |
|---------|-------|-----------------|
| RISK-1 | create-trd-foreman implementer | Before TRD-FSC-001-TEST |
| RISK-3 | Backward compat test author | Before TRD-FSC-008 |
| RISK-5 | create-trd-foreman implementer | Before TRD-FSC-001 |
| RISK-7 | create-trd-foreman implementer | Before TRD-FSC-001 |
| RISK-9 | CLI help text author | Before TRD-FSC-003 |
