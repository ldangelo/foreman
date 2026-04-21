# Executive Summary: Plan → Sling Compatibility

**Document ID:** EXEC-FOREMAN-PLAN-SLING-COMPAT
**Version:** 1.0.0
**Date:** 2026-04-15
**Outputs Location:** `docs/experiments/plan-sling-compat-prd/`

---

## What This Package Contains

This package contains the planning documents for making `foreman plan` output directly consumable by `foreman run`. The result is a PRD-first flow where `foreman plan` stays focused on PRD→TRD creation, and `foreman sling prd` handles native task instantiation.

## Documents

| File | Purpose |
|------|---------|
| `PRD-FOREMAN-PLAN-SLING-COMPAT.md` | Product Requirements Document — problem statement, goals, requirements (REQ-001 through REQ-006), technical architecture, command split definition, migration path, AC summary, risk overview |
| `TRD-FOREMAN-PLAN-SLING-COMPAT.md` | Technical Requirements Document — architecture decision, component design, master task list (TRD-FSC-001 through TRD-FSC-009), sprint planning, traceability matrix |
| `AC-VALIDATION-MATRIX.md` | Acceptance Criteria Validation Matrix — per-AC verification method, test artifact, pass criteria, test execution order, fixtures, regression tests, edge cases |
| `RISK-REGISTER.md` | Risk Register — 10 risks identified (RISK-1 through RISK-10), severity/likelihood ratings, mitigation strategies, residual risk assessments |
| `README.md` (this file) | Navigation guide |

---

## The Problem

```
Current (broken) flow:
  foreman plan <desc> → PRD + TRD (markdown) → [MANUAL STEP] foreman sling trd ... → foreman run
                                                                      ↑
                                                            friction point: manual intervention

Target (seamless) flow:
  foreman plan <desc> → PRD + TRD (markdown) → foreman sling prd <prd> → native tasks (ready) → foreman run
```

`foreman plan` currently outputs PRD + TRD as markdown files and suggests a manual `foreman sling trd` invocation as the next step. This manual step is unnecessary friction — the TRD is already in the right format for `parseTrd()`.

---

## The Solution

### 1. New `/ensemble:create-trd-foreman` command (in ../ensemble)

A variant of `create-trd` that outputs a Foreman-native TRD:
- Uses markdown tables (not checklists) for task sections
- All task status values: `[ ]` (never `[x]`)
- Task IDs follow `[A-Z]+-T\d+` pattern
- Sprint/Story headers match existing `parseTrd()` regex patterns
- No beads-specific annotations in task tables

**File to create:** `packages/development/commands/create-trd-foreman.yaml`

### 2. New `foreman sling prd` CLI subcommand

A new subcommand under `foreman sling` that:
- Takes a PRD path (not TRD)
- Runs embedded Pi session: `/ensemble:create-trd-foreman <prd>`
- Reads the generated TRD
- Parses via `parseTrd()` + executes via `sling-executor`
- Creates native tasks marked `open` (ready for dispatch)

**File to modify:** `src/cli/commands/sling.ts` (add `prdSubcommand`)

### 3. Updated plan completion hint

After `foreman plan` completes, the hint changes from:
```
Next step: foreman sling trd docs/TRD/TRD-YYYY-NNN.md
```
to:
```
Next step: foreman sling prd docs/PRD/PRD-YYYY-NNN.md --auto
```

**File to modify:** `src/cli/commands/plan.ts` (line 422)

---

## Command Split

| Command | Input | Output | Tool |
|---------|-------|--------|------|
| `foreman plan` | Product description | PRD.md + TRD.md (markdown files) | `dispatchPlanStep()` → Pi |
| `foreman sling prd` | PRD file path | Native tasks (SQLite, status=open) | Embedded Pi → `parseTrd()` → `sling-executor` |
| `foreman sling trd` | TRD file path | Native tasks (SQLite, status=open) | `parseTrd()` → `sling-executor` (existing) |
| `foreman run` | None | Dispatched agent execution | `dispatcher.dispatch()` |

---

## Key Design Decisions

### Decision 1: TRD Parser is Stable — We Adapt to It

`parseTrd()` in `src/orchestrator/trd-parser.ts` is the fixed contract. `create-trd-foreman` must produce output that satisfies the parser. We are NOT modifying the parser to accommodate `create-trd-foreman`.

### Decision 2: Same Filename for Both TRD Formats

`create-trd-foreman` outputs to `docs/TRD/TRD-YYYY-NNN.md` (same as beads path). Both `sling trd` and `sling prd` can consume the same file. Using the same filename maximizes backward compatibility.

### Decision 3: Status Always [ ]

All task status values in `create-trd-foreman` output must be `[ ]` (open). This ensures tasks are created as `ready` for dispatch. The parser interprets `[x]` as `completed` (silently skipped by default), which is undesirable for a planning-first flow.

### Decision 4: Embed Pi Session in sling prd

`sling prd` runs `/ensemble:create-trd-foreman` as an embedded Pi session (same pattern as `dispatchPlanStep()`). It does NOT directly generate TRD content — it delegates to the same Pi agent that would run interactively.

---

## Critical Risks

| Risk | Severity | Mitigation |
|------|----------|-------------|
| **RISK-5:** Task status `[x]` causes silent task dropping | High | Validation step: assert no `[x]` in task tables |
| **RISK-3:** Beads TRD format mismatch breaks existing sling trd | High | Backward compat test + CI validation of all TRDs |
| **RISK-1:** Column name ambiguity (e.g., `TRD ID` instead of `ID`) | Medium | Explicit constraint + integration test |
| **RISK-7:** Forward dependency references silently dropped | Medium | Ordering constraint + validation step |

---

## Implementation Phases

```
Sprint 1: Foundation (21h)
  ├─ TRD-FSC-001: create-trd-foreman.yaml (8h)
  ├─ TRD-FSC-002: generate create-trd-foreman.md (1h)
  └─ TRD-FSC-003: sling prd CLI subcommand (12h)

Sprint 2: Validation (14h)
  ├─ TRD-FSC-001-TEST: parseTrd() compatibility (4h)
  ├─ TRD-FSC-003-TEST: CLI integration (6h)
  └─ TRD-FSC-004: trd-parser-foreman.test.ts (4h)

Sprint 3: Integration (26h)
  ├─ TRD-FSC-005: plan completion hint (2h)
  ├─ TRD-FSC-005-TEST: hint validation (2h)
  ├─ TRD-FSC-006: sling-prd.test.ts (8h)
  ├─ TRD-FSC-007: end-to-end flow test (6h)
  ├─ TRD-FSC-008: backward compatibility (4h)
  └─ TRD-FSC-009: PRD readiness gate (4h)

Total: ~61h (~9-10 days)
```

---

## Acceptance Criteria Summary

- **29 acceptance criteria** across 6 requirements
- `foreman plan` outputs PRD + TRD and does NOT write tasks to the native store
- `foreman sling prd` takes a PRD and produces native tasks marked `ready`
- All tasks in `create-trd-foreman` output have status `[ ]` (open)
- The TRD output satisfies `parseTrd()` without any parser modifications
- Backward compatibility preserved: existing `sling trd` continues to work
- No changes to `parseTrd()` API signature or `execute()` API signature

---

## What Was Deliberately Excluded

1. **No TRD parser redesign.** The parser is stable. We adapt to it.
2. **No beads-to-native task migration.** Beads remain for projects that use them. `create-trd-foreman` is a parallel path.
3. **No `foreman run` modifications.** `foreman run` dispatches `ready` tasks as it does today.
4. **No automatic PRD→TRD→task pipeline.** `foreman sling prd` is a separate command invocation (not auto-triggered after `foreman plan`). Users maintain control over when tasks are created.
5. **No `[satisfies REQ-NNN]` parsing.** The parser doesn't extract these annotations. They remain informational in task descriptions.
6. **No parallelization hints in TRD.** `analyzeParallel()` infers parallelization from existing TRD content. No new format elements required.

---

## Open Questions (Unresolved in This PRD)

1. **Should we add a `**Format:** foreman-native` frontmatter field** to distinguish new TRDs from legacy TRDs? (RISK-8 mitigation)
2. **Should `sling prd` automatically wire implicit dependencies** (task N depends on task N-1 within a story)? (Recommended: yes)
3. **Should `sling prd` check PRD readiness score before proceeding?** (Recommended: yes — propagate failure)
4. **Should we add a `--legacy` flag to `sling trd`** for checklist-style TRDs from existing projects? (Future work, not in scope)
