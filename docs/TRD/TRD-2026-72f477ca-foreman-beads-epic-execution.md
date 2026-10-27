---
document_id: TRD-2026-72f477ca
label: trd-foreman-beads-epic-execution
version: 1.0.2
status: Draft
date: 2026-10-05
source_prd: PRD-2026-72f477ca
design_readiness_score: 4.5
constitution_compliance: passed
---

# TRD: Foreman Auto-Execution of `implement-trd-beads`-Scaffolded Epic Trees

Source PRD: `docs/PRD/PRD-2026-72f477ca-foreman-beads-epic-execution.md` (v1.0.1, 13 requirements, 25 ACs).

## Phase 1 Validation Notes

- PRD structural sections present (Executive Summary, Problem Statement, Functional Requirements, Non-Goals, Dependencies, Approvals, Entry/Exit Criteria, Risk Flags, Implementation Readiness Gate, Constitution Gate) — semantically equivalent to this skill's expected section set; PASS.
- Requirements numbering sequential, no gaps (REQ-001..REQ-013); AC format is Given/When/Then throughout — PASS.
- **BDD coverage flag**: this skill's minimum is ≥3 AC-NNN-M per functional REQ-NNN (happy/edge/error-negative). Only REQ-001 meets this (3 ACs). REQ-002 through REQ-010 and REQ-013 have 2 ACs each; REQ-011/REQ-012 (1 AC each) are treated as non-functional/process requirements (test infrastructure, documentation) and exempted from this bar, consistent with this skill's functional/non-functional distinction even though the source PRD did not split them into separate sections. **Consequence**: TRD-NNN-TEST tasks below carry as many Test AC Scenarios as there are source PRD ACs per requirement (2, not 3, for the 10 under-covered functional REQs) — flagged here rather than fabricating a third scenario with no PRD AC behind it.
- PRD Implementation Readiness Gate score: 4.75 (PASS, ≥4.0) — proceeded without re-gating.

## Phase 2: Architecture Design

### Domain Analysis

- **Technical domains touched**: ensemble's `implement-trd-beads` Scaffold phase (ensemble repo); Foreman's `ImplementationContext` struct, `implement-trd-beads.yaml` workflow manifest, and run-finalization failure propagation (Foreman repo). No new UI, no new persistence schema.
- **Companion domains**: `research` (the three architecture alternatives below) — see `TRD-2026-72f477ca-foreman-beads-epic-execution-research.md`. No `data-model` (no new entities, schemas, or migrations; this feature only reads/writes existing bead fields — `issue_type`, labels, `agent_context.trd_path`).
- **Greenfield/brownfield**: brownfield — both `implement-trd-beads` and Foreman's workflow/dispatch machinery are existing, in-production systems.
- **Capability Reuse Check**: no existing `kind: foundational` TRD was found in `docs/TRD/` with an overlapping capability token (bead-tagging, Foreman dispatch mapping) — this repo does not currently use the foundational-TRD pattern for any existing TRD. This TRD is standalone, `kind` unset (1:1 with its source PRD).

### Architecture Alternatives (decided)

Full comparison in the companion research artifact. Decision: **Option A — extend `ImplementationContext` with a new `bead_id` field**, mirroring the existing `trd_path`/`beads_database_path` fields exactly, exposed to command templates as `{{implementation.bead_id}}`. Rejected: (B) unifying the `{task.*}` template context used by `artifact:` paths into `command:` strings — unknown whether these are currently the same rendering engine, too large an unknown for this PRD's scope; (C) parsing the bead id out of `task_id` inside `ensemble-beads-build` — rejected as a brittle cross-repo string-format coupling.

### System Architecture

- **`ImplementationContext`** (`packages/foreman_server/lib/foreman_server/workflow/implementation_context.ex`): add `bead_id: String.t() | nil` to the struct (new optional field, not in `@enforce_keys` — mirrors `beads_database_path`'s optionality), derived in `build/1` alongside `trd_path`/`beads_database_path` for `implement_trd_beads`-type workflows. Struct-update syntax only (`%__MODULE__{ctx | bead_id: ...}`), consistent with this repo's Aggregate State Design convention even though this struct is not itself an aggregate.
- **`implement-trd-beads.yaml`**: the single phase's `command:` changes from `/skill:ensemble-full-implement-trd-beads {{implementation.trd_path_argument}} --foreman` to `/skill:ensemble-beads-build {{implementation.bead_id}} --foreman`. `task_types: [implement_trd_beads]` is unchanged — this is an in-place command change to the SAME mapping, not a new workflow.
- **Run finalization** (wherever `RunExecutor`/`finalize_run` currently decides `RunCompleted` vs `RunFailed`): must read beads-build's own completion/failure signal (exact source TBD at TRD-004 implementation time; not yet traced against beads-build's actual output contract) and propagate `RunFailed` when incomplete children are reported.
- **Ensemble's Scaffold phase**: gains a conditional branch — when `--foreman` is present, after `br create`-ing the full tree, additionally tag the root epic bead (`br update <root-id> --labels foreman-exec`, plus setting `issue_type`/`agent_context.trd_path` via whatever `br`/beads-rust mechanism sets those fields).

**Compatibility note (carried into Adversarial Review below)**: changing `implement-trd-beads.yaml`'s command in place changes dispatch behavior for *any* bead already carrying `issue_type: implement_trd_beads`, not only ones newly tagged by this feature. No currently-known in-flight bead relies on the old command (confirmed: user did not select "must support existing in-flight TRDs" as a constraint during PRD elicitation), but this is a real behavior change to an existing, already-wired mapping, not an additive one.

**Non-functional note**: no new performance/latency target is introduced for how quickly a tagged bead is picked up — dispatch latency continues to be governed entirely by `BeadsWatcher`'s existing, unchanged poll interval. Intentionally out of scope for this stopgap.

## Phase 3: Task Breakdown and Planning

### Cross-Repo Coordination

This TRD's Master Task List spans two repositories. **TRD-001** (conditional root-epic tagging in `implement-trd-beads`'s Scaffold phase) is an **ensemble-repo** change — it does not touch Foreman code and must not be tracked in Foreman's own `.beads/` database, since Foreman's `BeadsWatcher`/`ImplementationContext` machinery assumes every tracked bead's work happens inside the registered project's own `project_root` (Foreman's checkout), not an unrelated repo. **TRD-002 through TRD-007** are Foreman-repo changes and are the only tasks scaffolded into this repo's Beads DB by this TRD's `beads_plan` stage.

Consequence: `TRD-006a`'s `[Depends: TRD-001]` and `TRD-001-TEST`'s existence are **documentation-only cross-references** in this TRD — they are not scaffolded as Foreman beads. The ensemble team must track `TRD-001`/`TRD-001-TEST` in their own repo's issue tracker (manually, or via their own equivalent of this PRD/TRD pair); `TRD-006a` cannot start until that work is confirmed complete, which is a coordination dependency this TRD can document but cannot enforce or automate.

### PR 1: Scaffold tagging (ensemble repo)

**Shippable State:** Running `implement-trd-beads --plan --foreman` on a TRD produces a root epic bead tagged `issue_type: implement_trd_beads` + `agent_context.trd_path` + `foreman-exec`; running `--plan` without `--foreman` is byte-for-byte unchanged. Foreman does not yet act on the tag (PR 2 required for that) — this PR alone is not yet end-to-end observable by an operator beyond inspecting the bead.

- [ ] TRD-001: Implement conditional root-epic tagging in `implement-trd-beads`'s Scaffold phase, gated on `--foreman` presence. [Satisfies REQ-001, REQ-002, REQ-009] (Est: 4h)
  - Implementation AC:
    - [ ] Scenario: `--plan --foreman` tags root epic only — Given a TRD-scoped Scaffold run with `--foreman`, When Scaffold completes, Then the root epic carries `issue_type: implement_trd_beads` + `agent_context.trd_path` + `foreman-exec`, and no child bead is modified.
    - [ ] Scenario: `--plan` without `--foreman` tags nothing — Given a Scaffold run without `--foreman`, When it completes, Then no label/`issue_type` change is applied anywhere.
    - [ ] Scenario: Scaffold failure leaves no partial tag — Given a `br create` error mid-Scaffold, When the command exits non-zero, Then the root epic is not tagged.
- [ ] TRD-001-TEST: BDD tests for root-epic tagging [Verifies TRD-001] [Satisfies REQ-001, REQ-002, REQ-009] [Depends: TRD-001] (Est: 2h)
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-001-3, AC-002-1, AC-002-2, AC-009-1, AC-009-2
  - Test AC:
    - [ ] Scenario: tags applied with `--foreman` (AC-001-1)
    - [ ] Scenario: no tag on scaffold failure (AC-001-2)
    - [ ] Scenario: re-`--plan` against an already-tagged epic is a no-op via existing resume-detection (AC-001-3)
    - [ ] Scenario: no tag without `--foreman` (AC-002-1)
    - [ ] Scenario: manually post-hoc-tagged bead validated like any other (AC-002-2)
    - [ ] Scenario: only root epic tagged, N children unaffected (AC-009-1)
    - [ ] Scenario: manually tagged child bead evaluated independently, no root-only enforcement (AC-009-2)

### PR 2: Foreman dispatch target, `bead_id` context field, failure propagation (Foreman repo)

**Shippable State:** A tagged, labeled root epic bead transitioning to open is auto-dispatched by Foreman to `/ensemble-beads-build <epic-id> --foreman` in a single worktree with no timeout; a run that can't complete all children terminates `RunFailed`; resuming a paused run re-invokes beads-build against the same epic. End-to-end observable: a hand-tagged epic bead gets picked up and executed with zero manual Foreman steps.

- [ ] TRD-002: Extend `ImplementationContext` with `bead_id` (Option A), derived at approval time alongside `trd_path`/`beads_database_path`. [Satisfies REQ-003] (Est: 3h)
  - Implementation AC:
    - [ ] Scenario: `bead_id` populated for `implement_trd_beads` workflows — Given approval of a task dispatched from a tagged epic bead, When `ImplementationContext.build/1` runs, Then `bead_id` is set to that bead's id.
    - [ ] Scenario: unresolvable `bead_id` fails loudly — Given the triggering bead id cannot be determined, When context build is attempted, Then it returns a named error (`{:implementation_context_failed, :bead_id_missing}` or equivalent), never a silent `nil`.
- [ ] TRD-002-TEST: Unit tests for `ImplementationContext.bead_id` [Verifies TRD-002] [Satisfies REQ-003] [Depends: TRD-002] (Est: 1h)
  - Validates PRD ACs: AC-003-1, AC-003-2
  - Test AC:
    - [ ] Scenario: `bead_id` resolves correctly (AC-003-1)
    - [ ] Scenario: unresolvable `bead_id` fails loudly, no silent fallback (AC-003-2)
- [ ] TRD-003: Update `implement-trd-beads.yaml`'s phase `command:` to `/skill:ensemble-beads-build {{implementation.bead_id}} --foreman`; confirm manifest declares no `timeout_minutes:`. [Satisfies REQ-003, REQ-004] [Depends: TRD-002] (Est: 1h)
  - Implementation AC:
    - [ ] Scenario: dispatched command targets beads-build with the bead id, not a TRD-path argument.
    - [ ] Scenario: workflow manifest declares no `timeout_minutes:`/`timeoutMinutes:` key.
- [ ] TRD-003-TEST: Workflow manifest and dispatch-rendering tests [Verifies TRD-003] [Satisfies REQ-003, REQ-004] [Depends: TRD-003] (Est: 1h)
  - Validates PRD ACs: AC-003-1, AC-004-1, AC-004-2
  - Test AC:
    - [ ] Scenario: command renders with bead id argument (AC-003-1)
    - [ ] Scenario: manifest has no timeout key (AC-004-1)
    - [ ] Scenario: long-running phase (simulated past a typical deadline) is never auto-failed (AC-004-2)
- [ ] TRD-004: Trace beads-build's incomplete-children signal and wire/fix run finalization to terminate `RunFailed` (not silent `RunCompleted`) when it fires. [Satisfies REQ-008] [Depends: TRD-003] (Est: 6h; RISK: MEDIUM — root cause/exact signal not yet confirmed against beads-build source; timebox initial investigation to 2h before re-scoping)
  - Implementation AC:
    - [ ] Scenario: incomplete children → `RunFailed`, incomplete children named in the run artifact.
    - [ ] Scenario: all children complete but root epic bead itself never explicitly closed → run still completes (per PRD AC-008-2's stated assumption).
- [ ] TRD-004-TEST: Failure propagation tests [Verifies TRD-004] [Satisfies REQ-008] [Depends: TRD-004] (Est: 2h)
  - Validates PRD ACs: AC-008-1, AC-008-2
  - Test AC:
    - [ ] Scenario: `RunFailed` on incomplete children (AC-008-1)
    - [ ] Scenario: completion judged by child-bead state, not epic status field (AC-008-2)
- [ ] TRD-005: Confirm (regression-test only, no expected code change) that existing `BeadsWatcher` `trd_path` validation, label gate, and run-resume already satisfy REQ-005, REQ-006, REQ-007, REQ-010 unmodified. [Satisfies REQ-005, REQ-006, REQ-007, REQ-010] [Depends: TRD-003] (Est: 3h)
  - Implementation AC:
    - [ ] Scenario: resume re-invokes beads-build against the same epic id with no new Foreman-side progress model (REQ-005).
    - [ ] Scenario: missing/invalid `trd_path` still blocks via the existing remediation path (REQ-006).
    - [ ] Scenario: unlabeled epic never dispatches (REQ-007).
    - [ ] Scenario: external bead edits are never locked or queued (REQ-010).
- [ ] TRD-005-TEST: Regression tests for existing-behavior requirements [Verifies TRD-005] [Satisfies REQ-005, REQ-006, REQ-007, REQ-010] [Depends: TRD-005] (Est: 3h)
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-006-1, AC-006-2, AC-007-1, AC-007-2, AC-010-1, AC-010-2
  - Test AC:
    - [ ] Scenario: resumed run skips completed children (AC-005-1)
    - [ ] Scenario: resumed run re-evaluates readiness against current graph state, not a stale cache (AC-005-2)
    - [ ] Scenario: missing `trd_path` blocks with existing comment (AC-006-1)
    - [ ] Scenario: `trd_path` pointing at a deleted file blocks the same way (AC-006-2)
    - [ ] Scenario: tagged-but-unlabeled epic is skipped (AC-007-1)
    - [ ] Scenario: label removed mid-run does not cancel the in-flight run (AC-007-2)
    - [ ] Scenario: concurrent human `br update --status=in_progress` is not blocked (AC-010-1)
    - [ ] Scenario: human-closed child bead is accepted at face value (AC-010-2)

### PR 3: End-to-end synthetic test and documentation

**Shippable State:** An automated synthetic 3-bead tree is auto-dispatched and completed by Foreman end-to-end with no manual steps; operator-facing docs describe the new behavior; this feature's stopgap relationship to `PRD-2026-d3051d4b` is on record.

- [ ] TRD-006a: Build fixture TRD + fixture beads DB (synthetic 3-bead tree, one dependency edge, correctly pre-tagged per TRD-001's convention). [Satisfies REQ-011] [Depends: TRD-001] (Est: 4h) — no Foreman dependency; can run in parallel with TRD-004/TRD-005.
  - Implementation AC:
    - [ ] Scenario: a synthetic 3-bead tree with one dependency edge is correctly tagged per TRD-001's convention.
- [ ] TRD-006b: Wire a test Foreman instance against the TRD-006a fixtures and exercise the full tag → dispatch → resume → failure-propagation chain end to end. [Satisfies REQ-011] [Depends: TRD-006a, TRD-004, TRD-005] (Est: 4h; RISK: MEDIUM — harness wiring is the largest remaining unknown in this TRD)
  - Implementation AC:
    - [ ] Scenario: the fixture tree is auto-dispatched and executed against a real (test) Foreman instance with no manual intervention.
- [ ] TRD-006b-TEST: End-to-end synthetic-tree test [Verifies TRD-006b] [Satisfies REQ-011] [Depends: TRD-006b] (Est: 2h)
  - Validates PRD ACs: AC-011-1
  - Test AC:
    - [ ] Scenario: run reaches `RunCompleted` with zero manual intervention (AC-011-1)
- [ ] TRD-007: Update `AGENTS.md`/`docs/user-guide.md`/`docs/cli-reference.md` to document `--plan --foreman` auto-tagging and the `/ensemble-beads-build` dispatch path; confirm the PRD already records `PRD-2026-d3051d4b` as the stopgap's long-term replacement. [Satisfies REQ-012, REQ-013] [Depends: TRD-003] (Est: 2h)
  - Implementation AC:
    - [ ] Scenario: docs describe the new tag-driven auto-pickup behavior (REQ-012).
    - [ ] Scenario: no PRD/TRD text edit is needed for REQ-013 — the supersession note already exists; confirm only.
- [ ] TRD-007-TEST: Documentation completeness check [Verifies TRD-007] [Satisfies REQ-012, REQ-013] [Depends: TRD-007] (Est: 0.5h)
  - Validates PRD ACs: AC-012-1, AC-013-1, AC-013-2
  - Test AC:
    - [ ] Scenario: `docs/user-guide.md` describes the new behavior (AC-012-1)
    - [ ] Scenario: PRD's Dependencies section names `PRD-2026-d3051d4b` explicitly (AC-013-1)
    - [ ] Scenario: Changelog, not original requirement text, is the supersession record (AC-013-2)

### Dependency Graph

`TRD-001` is independent (ensemble repo, no Foreman dependency). `TRD-002 → TRD-003 → {TRD-004, TRD-005}`; `TRD-006a` depends only on `TRD-001` (parallel with TRD-004/TRD-005); `TRD-006b` depends on `{TRD-006a, TRD-004, TRD-005}`; `TRD-007` depends only on `TRD-003`. Acyclic, confirmed by inspection. **Critical path** (restructured in refinement to parallelize TRD-006a against TRD-004/TRD-005): `TRD-002 (3h) → TRD-003 (1h) → TRD-004 (6h) → TRD-004-TEST (2h) → TRD-006b (4h) → TRD-006b-TEST (2h)` ≈ 18h of sequential work (down from 22h pre-refinement); `TRD-001`, `TRD-006a`, and `TRD-007` parallelize off this path.

## Phase 5: Adversarial Review and Design Gate

### Architecture Self-Critique (≥2 issues found)

1. **Unresolved call-site**: TRD-002's `bead_id` field assumes the value is derivable at `ImplementationContext.build/1`'s existing call site, but the exact source (is the bead id already present in whatever map `CommandGateway`'s `task.approve` enrichment passes in, since `task_id` already encodes it — or does a new field need explicit threading from `BeadsWatcher`'s `task.create` envelope through to approval?) was not traced against source in this TRD. **Resolution**: TRD-002's implementation step must trace this call site first; flagged as an implementation-time risk, not a blocking TRD gap, since the *outcome* (a `bead_id` field on the struct) is unambiguous regardless of which call site supplies it.
2. **In-place behavior change to an existing mapping**: TRD-003 changes `implement-trd-beads.yaml`'s command for the entire `implement_trd_beads` `issue_type`, not only for newly-tagged beads — any bead already carrying that `issue_type` from before this change would also switch to the new dispatch target. **Resolution**: documented explicitly above (System Architecture's Compatibility note); accepted because no in-flight dependency on the old command was identified, and the PRD's own constraints elicitation did not select backward-compatibility as a requirement.

### Task Coverage Analysis

All 13 PRD requirements have ≥1 TRD task with a `[Satisfies REQ-NNN]` annotation (REQ-001 → TRD-001; REQ-002 → TRD-001; REQ-003 → TRD-002/TRD-003; REQ-004 → TRD-003; REQ-005 → TRD-005; REQ-006 → TRD-005; REQ-007 → TRD-005; REQ-008 → TRD-004; REQ-009 → TRD-001; REQ-010 → TRD-005; REQ-011 → TRD-006a/TRD-006b; REQ-012 → TRD-007; REQ-013 → TRD-007). No orphaned TRD task references a nonexistent REQ-NNN. **Zero coverage issues found.**

### Dependency and Estimate Review

No circular or implicit dependencies (confirmed acyclic above). One estimate/dependency issue flagged: **TRD-004's 6h estimate is the least certain task in this TRD** (explicitly RISK: MEDIUM, root cause not yet confirmed) — recommended resolution: timebox the initial investigation to 2h; if the beads-build failure signal isn't identified by then, split TRD-004 into a smaller investigation spike plus a follow-up implementation task rather than absorbing overrun into the original estimate.

### Testability Review

Every Implementation AC above is phrased as a concrete Given/When/Then with an objective pass/fail condition; no subjective language (e.g. "intuitive", "user-friendly") was used. Every TRD-NNN-TEST task's `Validates PRD ACs` list has exactly one Test AC Scenario per listed AC, with no AC left unlinked: TRD-001-TEST (7 ACs/7 scenarios), TRD-002-TEST (2/2), TRD-003-TEST (3/3), TRD-004-TEST (2/2), TRD-005-TEST (8/8), TRD-006-TEST (1/1), TRD-007-TEST (3/3). **No testability issues found beyond the BDD-coverage flag already noted in Phase 1.**

### Design Readiness Gate

| Dimension | Score (1-5) |
|---|---:|
| Architecture completeness | 4 (TRD-002's exact call-site left as implementation-time tracing, per Self-Critique #1) |
| Implementation coverage | 5 (100% REQ coverage, confirmed) |
| Dependency clarity | 5 (explicit, acyclic, documented) |
| Estimate confidence | 4 (TRD-004 flagged as uncertain) |
| **Average** | **4.5** |

**PASS (≥4.0)** — proceeded to Constitution Gate without pausing for reconfirmation.

## Phase 6: Constitution Gate

**Constitution Gate: running**

Source: `docs/standards/constitution.md` (canonical; unchanged since the PRD's own gate check).

- §1 Core Principles (TDD): every TRD-NNN implementation task is paired with a TRD-NNN-TEST task; no feature task is undocumented against this rule — PASS.
- §4 Architecture Rules (Binding): `ImplementationContext` is a plain struct, not an aggregate/event/command — no Event Store Append, Actor Supervision, or CQRS rule applies; struct-update syntax (`%__MODULE__{ctx | bead_id: ...}`) is specified, consistent with this repo's state-mutation convention — PASS.
- §5 Approval Requirements: this TRD's `ImplementationContext` field addition and workflow-command change qualify as an architecture change requiring explicit approval; satisfied by the still-pending `implementation_approval` checkpoint in this `ensemble-new-feature` run, plus the PRD's own Approvals section — PASS (deferred to that checkpoint, as before).
- §8 Documentation Discipline: satisfied by TRD-007 — PASS.

**Constitution Gate: PASSED**

## Acceptance Criteria Traceability Matrix

| PRD REQ-NNN | Description | Implementation Tasks | Test Tasks |
|---|---|---|---|
| REQ-001 | Conditional tagging on Foreman-triggered scaffold | TRD-001 | TRD-001-TEST |
| REQ-002 | No tagging without `--foreman` | TRD-001 | TRD-001-TEST |
| REQ-003 | Dispatch target is beads-build | TRD-002, TRD-003 | TRD-002-TEST, TRD-003-TEST |
| REQ-004 | No timeout regression | TRD-003 | TRD-003-TEST |
| REQ-005 | Dependency-graph-aware resume | TRD-005 | TRD-005-TEST |
| REQ-006 | Reuse existing `trd_path` validation | TRD-005 | TRD-005-TEST |
| REQ-007 | Fail-closed label gate preserved | TRD-005 | TRD-005-TEST |
| REQ-008 | Run failure propagation | TRD-004 | TRD-004-TEST |
| REQ-009 | Root-epic-only tagging scope | TRD-001 | TRD-001-TEST |
| REQ-010 | No new locks for external edits | TRD-005 | TRD-005-TEST |
| REQ-011 | Automated synthetic-tree test | TRD-006a, TRD-006b | TRD-006b-TEST |
| REQ-012 | Documentation updates | TRD-007 | TRD-007-TEST |
| REQ-013 | Explicit stopgap/supersession note | TRD-007 | TRD-007-TEST |

**Traceability check: 13 requirements covered, 0 uncovered, 0 orphaned annotations.**

## Companion Artifacts

- `TRD-2026-72f477ca-foreman-beads-epic-execution-research.md` — Architecture Alternatives comparison for REQ-003's dispatch mechanism (Options A/B/C).

## Changelog

| Date | Change | Author |
|---|---|---|
| 2026-10-05 | Initial draft, TRD-002 architecture decided as Option A (extend ImplementationContext) | Claude Code (session with repo owner) |
| 2026-10-05 | Refinement (v1.0.1): split TRD-006 into TRD-006a (fixture setup, no Foreman dependency)/TRD-006b (harness wiring), parallelizing it against TRD-004/TRD-005 and shortening the critical path from ~22h to ~18h; added non-functional dispatch-latency note | Claude Code (session with repo owner) |
| 2026-10-05 | v1.0.2: added Cross-Repo Coordination section documenting TRD-001 as an ensemble-repo task not scaffolded in Foreman's Beads DB, per user decision before beads_plan | Claude Code (session with repo owner) |
| 2026-10-27 | PR 2 shipped in Foreman (supersedes the original `implement-trd-beads` dispatch described above; the original requirement text is left as written). TRD-002: `ImplementationContext.bead_id` (frozen from `task.external_id`, earlier, #530). TRD-003: `implement-trd-beads.yaml` now dispatches `/skill:ensemble-beads-build {{implementation.bead_id}} --foreman`, no `timeout_minutes`; a still-unresolved `{{implementation.*}}` placeholder refuses approval with `{:implementation_placeholder_unresolved, [...]}`; `ensemble-beads-build` accepted by `foreman_workflow_validate`. TRD-004: `Workflow.BeadsTreeCompletion` runs after the last phase's commit and fails the run unless every parent-child descendant of the epic is `closed`; traced signal: beads-build is a prompt with no exit code or machine-readable result, so the Beads graph is the only signal (the epic's own status is never consulted; an unreadable graph fails closed). TRD-005: regression tests. TRD-007: docs (CLAUDE.md, user guide, `docs/lessons/`); AGENTS.md deliberately not edited per its own Documentation Gate. Open risks: (a) installed ensemble `beads-build` v1.2.0 does not declare `--foreman` and documents its epic argument as `beads-NNN or a numeric ID` while Foreman ids look like `foreman-ab12` - whether it treats such an id as a bead id or a title slug is the ensemble repo's contract, not verified live (TRD-006b does the live run); (b) ensemble-side TRD-001 (`implement-trd-beads --plan --foreman` tagging the root epic) is a separate ensemble PR - until it ships an operator tags the epic by hand. See `docs/lessons/beads-runtime-and-dispatch.md` AC-006-2 code change: TRD-005 expected 'regression test only', but the audit found `check_trd_path` accepted any non-empty value, so a deleted/untracked TRD looped on `task.approve` failure; fixed in the watcher (`check_trd_path_at_head` via `ImplementationContext.validate_trd_path/2` blocks the bead). | Claude Code (BeadsBuildPr2) |
