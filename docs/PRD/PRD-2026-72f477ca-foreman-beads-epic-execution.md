---
document_id: PRD-2026-72f477ca
label: prd-foreman-beads-epic-execution
version: 1.0.1
status: Draft
date: 2026-10-05
scale_depth: STANDARD
total_requirements: 13
total_acceptance_criteria: 25
readiness_score: 4.75
---

# PRD: Foreman Auto-Execution of `implement-trd-beads`-Scaffolded Epic Trees

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 11 |
| Should | 2 |
| Could | 0 |
| Won't | 0 (4 explicit out-of-scope items below; not numbered requirements) |

| Metric | Value |
|---|---:|
| Requirement coverage | 13/13 (100%) |
| Risk flags | 3 global + 3 per-requirement (REQ-001, REQ-003, REQ-005, REQ-008, REQ-011 are Medium/High complexity) |
| Dependencies | 1 (cross-reference, not a blocking dependency) |
| Open ambiguity markers | 0 |
| TRD decisions required | 2 |

## 1. Executive Summary

Today, `ensemble-implement-trd-beads --plan` scaffolds a TRD-scoped bead hierarchy (epic → stories → tasks), and an operator must manually re-run the same command with `--execute` to build it — a separate, manual step that Foreman plays no part in. Foreman already has a working, general mechanism for "a bead transitions to open → Foreman auto-dispatches a workflow in one worktree" (`BeadsWatcher`'s `issue_type` → `task_types:` mapping, already wired for `implement_trd_beads`, `implement_trd`, and `bug`), but nothing connects it to the beads-execution path, and nothing distinguishes a human-run `--plan` from a Foreman-triggered one.

This PRD closes that gap with the smallest change that reuses existing infrastructure: when `--plan` is run with `--foreman`, the Scaffold step tags the root epic bead for Foreman pickup; Foreman's existing workflow mapping and worktree/lease/resume mechanisms take it from there, dispatching the already-generic `/ensemble-beads-build <epic-id>` executor instead of re-running the TRD-specific preflight a second time. A human running `--plan` interactively is unaffected — their beads are never tagged, and Foreman never touches them.

**Relationship to the bigger picture:** `docs/PRD/PRD-2026-d3051d4b-foreman-native-work-graph.md` (Draft, Phase B of a three-phase programme, itself dependent on two further Draft PRDs) already targets this same problem space with a fundamentally different, more ambitious model — moving the execution DAG natively into Foreman so each bead-tree node becomes its own Foreman run/worktree/PR/supervision slot. That model is architecturally incompatible with this PRD's single-run/single-worktree design, not complementary to it. None of that three-phase programme is implemented today (only one of its three prerequisite PRDs has a TRD). Per explicit decision, this PRD ships as a **deliberate stopgap**: it delivers the "no manual re-invocation" and "no conflicts" goals now, using only infrastructure that already exists, and is expected to become redundant if/when PRD-2026-d3051d4b's programme is implemented.

## 2. Problem Statement

- **Problem**: Foreman operators (small team, shared projects) must manually re-run `implement-trd-beads --execute` after `--plan` completes; there is no automatic pickup, and running the Scaffold phase outside Foreman risks `BeadsWatcher` dispatching against a still-forming tree or colliding with unprotected external Beads writers.
- **Primary users**: Foreman operators dispatching runs across shared projects.
- **Success criteria**: (1) zero manual re-invocation after `--plan --foreman` completes, AND (2) zero bead-DB conflicts or premature child-bead dispatch during/after scaffold.
- **Constraints**: ensemble-side (scaffold) changes are acceptable; no stated restriction on Foreman-side changes, on backward-compatibility for already-scaffolded (untagged) beads, or on adding new CLI flags — though this PRD chooses not to add any (see Won't list).
- **Existing solutions tried**: none in production yet; the "tag epic as `issue_type: epic`, re-run `--execute`" idea was the only approach considered before this PRD's elicitation, and is superseded by Option B/C reasoning below (reusing the existing `implement_trd_beads` mapping on the root epic only, rather than a new, overly broad `epic` mapping).

## 3. Functional Requirements

### REQ-001 (Must) [Complexity: Medium]: Conditional tagging on Foreman-triggered scaffold

When `implement-trd-beads` is invoked with both `--plan` and `--foreman`, after Scaffold completes, the root epic bead MUST be tagged with `issue_type: implement_trd_beads`, `agent_context.trd_path` set to the TRD's project-relative path, and the `foreman-exec` label. [RISK: MEDIUM — touches ensemble's scaffold code path directly; the only requirement in this PRD requiring a behavioral change to `implement-trd-beads` itself rather than reuse of existing Foreman mechanisms.]

- AC-001-1: Given a TRD-scoped bead hierarchy has just been scaffolded via `implement-trd-beads --plan --foreman`, when Scaffold completes, then the root epic bead's `issue_type` is `implement_trd_beads`, its `agent_context.trd_path` matches the TRD argument, and its labels include `foreman-exec`.
- AC-001-2: Given Scaffold fails partway through (e.g. a `br create` error on a child bead), when the command exits non-zero, then the root epic bead is NOT tagged.
- AC-001-3: Given a TRD whose epic was already tagged and dispatched by a prior `--plan --foreman` invocation, when `--plan --foreman` is re-run against the same TRD, then the skill's existing resume-detection (scanning for an existing `[trd:<slug>]` epic, already used by `--execute`) finds the prior epic; re-tagging it is a harmless no-op — no duplicate tree, no duplicate dispatch.

### REQ-002 (Must) [Complexity: Low]: No tagging without `--foreman`

When `implement-trd-beads --plan` is invoked WITHOUT `--foreman`, the generated bead hierarchy MUST NOT be tagged for Foreman pickup — behavior is unchanged from today.

- AC-002-1: Given a human runs `implement-trd-beads --plan` interactively (no `--foreman`), when Scaffold completes, then no `foreman-exec` label or `issue_type` change is applied to the root epic.
- AC-002-2: Given an operator later manually adds the tags by hand to a bead scaffolded without `--foreman`, when `BeadsWatcher` next polls, then it is treated identically to any other tagged bead (REQ-006 applies) — no separate "was this really a `--foreman` scaffold" provenance check exists.

### REQ-003 (Must) [Complexity: High]: Dispatch target is the generic beads-build executor

The Foreman workflow mapped to `issue_type: implement_trd_beads` MUST dispatch `/ensemble-beads-build <epic-id> --foreman` against the triggering epic bead, instead of re-running `implement-trd-beads --execute`'s full TRD preflight (TRD file resolution, Design Readiness Gate, staleness gate, team/marketplace checks). [RISK: HIGH — the exact mechanism for passing the triggering bead's own id into the workflow's command template is undetermined (see Risk Flags); confirmed in refinement as acceptable to leave as a TRD-level decision rather than a PRD ambiguity, given AC-003-2's fail-loud fallback.]

- AC-003-1: Given a tagged root epic bead transitions to `status: open`, when `BeadsWatcher` dispatches the resulting task, then the dispatched command targets `/ensemble-beads-build` with that bead's own id as its argument, not a TRD-path argument.
- AC-003-2: Given the triggering bead id cannot be resolved into a command argument by whatever mechanism the TRD selects, when dispatch would otherwise proceed, then the run fails loudly with a named error rather than silently falling back to the old `--execute` path.

### REQ-004 (Must) [Complexity: Low]: No timeout regression

The beads-tree-execution workflow entry MUST NOT declare `timeout_minutes:`/`timeoutMinutes:`, preserving Foreman's existing infinite-default behavior for this workflow (per `FailurePolicy.resolve/2` precedence — an absent key already means no wall-clock deadline).

- AC-004-1: Given the workflow manifest for this dispatch, when it is loaded, then it declares no `timeout_minutes:`/`timeoutMinutes:` key.
- AC-004-2: Given a scaffolded tree large enough to run for many hours (e.g. 50+ beads), when the run is in progress past what a typical phase timeout would be, then it is never auto-failed by a wall-clock deadline — confirming the absent key resolves through `FailurePolicy` to `:infinity`, not merely that the key is textually missing.

### REQ-005 (Must) [Complexity: Medium]: Dependency-graph-aware resume, owned by beads-build

On `run resume` (or any re-dispatch) of a beads-tree-execution run, Foreman MUST re-invoke `/ensemble-beads-build` against the SAME epic id, relying on beads-build's own bead-dependency-graph traversal — not any new Foreman-side phase/progress model — to resume only incomplete work in correct dependency order. [RISK: MEDIUM — correctness depends entirely on beads-build's own resume logic already doing the right thing; this PRD adds no Foreman-side verification of dependency-order correctness.]

- AC-005-1: Given a paused/failed beads-tree-execution run with some children already closed, when it is resumed, then beads-build is re-invoked against the same epic id and completed children are not re-executed.
- AC-005-2: Given a resumed run's dependency graph has a child whose dependency was closed by an unrelated bead update made outside this run, when beads-build re-evaluates readiness, then it uses the bead graph's current state, not a cached view from the prior attempt.

### REQ-006 (Must) [Complexity: Low]: Reuse existing `trd_path` validation; no new provenance check

A bead tagged `issue_type: implement_trd_beads` + `foreman-exec` whose `agent_context.trd_path` is missing or invalid MUST be blocked by the existing `BeadsWatcher` validation (missing/invalid-`trd_path` comment), exactly as today. No new epic-specific scaffold-provenance validation is added.

- AC-006-1: Given an epic bead tagged by hand with no `agent_context.trd_path`, when `BeadsWatcher` polls it, then it is blocked with the existing missing-`trd_path` remediation comment, unchanged from current behavior.
- AC-006-2: Given an epic bead tagged with a `agent_context.trd_path` pointing at a file that has since been deleted from the repo, when `BeadsWatcher` validates it, then it is blocked the same way as a missing `trd_path` — "invalid" already covers "points at a nonexistent file," not only "field absent."

### REQ-007 (Must) [Complexity: Low]: Fail-closed label gate preserved

Absence of the `foreman-exec` label on an epic bead, regardless of `issue_type`, MUST result in Foreman never dispatching it.

- AC-007-1: Given an epic bead with `issue_type: implement_trd_beads` but no `foreman-exec` label, when `BeadsWatcher` polls it, then it is skipped exactly as any other unlabeled bead today.
- AC-007-2: Given an epic bead's `foreman-exec` label is added after dispatch and then removed while the run is mid-execution, when the label is removed, then the in-flight run is NOT retroactively cancelled — the label gate governs new dispatch decisions only, not already-running work.

### REQ-008 (Must) [Complexity: Medium]: Run failure propagation

A beads-tree-execution run that cannot complete all children MUST terminate as Foreman `RunFailed`, never a silent `RunCompleted`. [RISK: MEDIUM — depends on beads-build actually surfacing a distinguishable failure signal that Foreman's run finalization can read; not independently verified against beads-build's source in this PRD.]

- AC-008-1: Given beads-build reports one or more children could not complete, when the run finalizes, then its Foreman run status is `RunFailed` and the incomplete children are named in the run's artifact/report.
- AC-008-2: Given all children complete but the root epic bead itself is never explicitly closed, when the run finalizes, then completion is judged by child-bead state, not by the epic bead's own status field. [Assumption, not independently confirmed with the user; flagged as a TRD decision in Risk Flags.]

### REQ-009 (Must) [Complexity: Low]: Root-epic-only tagging scope

Scaffold MUST add `foreman-exec` + `issue_type: implement_trd_beads` to the ROOT epic bead only; child beads (stories/tasks) are created exactly as today, with no labels/`issue_type` changes.

- AC-009-1: Given a scaffolded tree with N child beads, when tagging completes, then exactly one bead (the root epic) carries the new label/`issue_type`; all N children are unaffected.
- AC-009-2: Given an operator manually adds `foreman-exec` + `issue_type: implement_trd_beads` to a CHILD bead (not the root epic) by hand, when `BeadsWatcher` polls it, then it is evaluated using the same REQ-006 validation as any other tagged bead — this PRD defines no root-detection enforcement rule that specially rejects non-root beads.

### REQ-010 (Must) [Complexity: Low]: No new locks for external bead edits

A human manually editing a child bead while Foreman is actively executing its epic MUST NOT be blocked or queued by any new lock; any resulting conflict is surfaced only via beads-build's own existing status checks, consistent with `BeadsDbLease`'s documented scope (external, non-Foreman writers are out of scope for Foreman-side locking).

- AC-010-1: Given a human runs `br update <child-id> --status=in_progress` while Foreman's beads-build execution is running against the same epic, when beads-build next reads that bead's status, then it handles the conflict via its own existing logic (skip/log), with no new Foreman lock rejecting the human's write.
- AC-010-2: Given a human closes (not just edits) a child bead mid-execution via `br update <id> --status=closed`, when beads-build next checks that bead, then it accepts the external completion at face value rather than treating it as an error.

### REQ-011 (Should) [Complexity: Medium]: Automated synthetic-tree regression test

An automated/integration test using a small synthetic TRD + bead tree (2-3 beads, one dependency edge) SHOULD assert Foreman auto-dispatches and completes it with no manual `--execute`/task-create step. [RISK: MEDIUM — building a reliable synthetic-tree test harness (fixture TRD, fixture beads DB, test Foreman instance) is nontrivial effort relative to the rest of this PRD.]

- AC-011-1: Given a synthetic 3-bead tree tagged as this PRD specifies, when the test suite runs it against a test Foreman instance, then the run reaches `RunCompleted` with no manual intervention.

### REQ-012 (Should) [Complexity: Low]: Documentation updates (constitution §8 gate)

`AGENTS.md`/`docs/user-guide.md`/`docs/cli-reference.md` SHOULD be updated to describe the new tag-driven auto-pickup behavior for `implement-trd-beads --plan --foreman`, per the constitution's documentation-discipline gate.

- AC-012-1: Given this feature ships, when a reader checks `docs/user-guide.md`'s Beads/Foreman integration section, then it describes the `--plan --foreman` auto-tagging behavior and the `/ensemble-beads-build` dispatch path.

### REQ-013 (Must) [Complexity: Low]: Explicit stopgap/supersession note

This PRD and its TRD MUST record `PRD-2026-d3051d4b-foreman-native-work-graph.md` as the long-term architectural replacement; this feature is a deliberate stopgap, not a permanent model, and is expected to become redundant if/when that programme is implemented.

- AC-013-1: Given this PRD, when read, then its Dependencies/Relationships section names `PRD-2026-d3051d4b` explicitly as the superseding design.
- AC-013-2: Given `PRD-2026-d3051d4b` is later implemented, when an operator reads this PRD afterward, then nothing in this PRD's original requirements needs editing to stay historically accurate (per this repo's point-in-time-spec convention) — the Changelog is the mechanism for recording that supersession occurred, not a rewrite of the original text.

## 4. Non-Goals / Explicitly Out of Scope

- **W-1**: No per-child-bead Foreman runs, OTP-native scheduling, or any part of `PRD-2026-d3051d4b`'s Phase B architecture.
- **W-2**: No new Foreman CLI flags/verbs for triggering this workflow — dispatch is purely tag-driven via `BeadsWatcher`, consistent with TRD-018's removal of direct task-creation verbs.
- **W-3**: No new typed Foreman field for a PRD path — PRD context, if needed at execution time, is discoverable from the TRD itself, not a new `agent_context`/`ImplementationContext` field.
- **W-4**: No new locking mechanism for external (non-Foreman) bead writers — `BeadsDbLease`'s documented scope is unchanged.

## 5. Dependencies and Relationships

- **Cross-reference, not a blocking dependency**: `docs/PRD/PRD-2026-d3051d4b-foreman-native-work-graph.md` (Draft) — see Executive Summary. This PRD does not depend on it, does not block it, and is explicitly superseded by it if/when it ships.
- No dependency on `PRD-2026-0eac69b3` or `PRD-2026-aba4b79c` (the two PRDs `PRD-2026-d3051d4b` itself depends on) — this PRD's design deliberately avoids needing `WorkRequest`/`RunSlots` or agent-emitted-subgraph credentials.

### Cross-Requirement Dependency Map

| Requirement | Depends on | Relationship |
|---|---|---|
| REQ-002 | REQ-001 | Defines the complementary "off" case for the same tagging mechanism |
| REQ-003 | REQ-001 | Dispatch requires the epic to already carry `issue_type: implement_trd_beads` |
| REQ-005 | REQ-003 | Resume re-invokes the same `/ensemble-beads-build` dispatch target |
| REQ-006 | REQ-001 | Validates the `agent_context.trd_path` field REQ-001 sets |
| REQ-007 | REQ-001 | Gates on the `foreman-exec` label REQ-001 adds |
| REQ-008 | REQ-003 | Failure propagation concerns the run REQ-003 dispatches |
| REQ-009 | REQ-001 | Scopes where REQ-001's tagging is allowed to apply |
| REQ-011 | REQ-001, REQ-003, REQ-005 | Exercises the full tag → dispatch → resume chain |
| REQ-013 | (none) | Independent documentation/cross-reference requirement |

## 6. Approvals and Decision Ownership

Repo owner (you) signs off, judged against the design decisions confirmed in this PRD's elicitation session: tag-on-`--plan --foreman` only, root-epic-only tagging, fail-closed label gate, no timeouts, dependency-graph-aware resume owned by beads-build, reuse of existing `BeadsWatcher` validation with no new provenance check, and explicit stopgap/supersession framing against `PRD-2026-d3051d4b`. No separate review board.

## 7. Entry and Exit Criteria

- **Entry**: a TRD for this PRD is written and passes the Design Readiness Gate.
- **Exit**: an epic scaffolded via `implement-trd-beads --plan --foreman` on a real TRD is picked up and fully executed by Foreman end-to-end with zero manual operator steps (AC-011-1's synthetic-tree test plus one manual real-TRD verification).

## 8. Risk Flags

- [RISK: MEDIUM] REQ-003's exact mechanism for passing the triggering bead's own id into the workflow's command template is undetermined — deferred to the TRD (AC-003-2 defines the fail-loud fallback if it can't be resolved). Confirmed in refinement as an acceptable TRD-level deferral, not a PRD ambiguity.
- [RISK: LOW] REQ-008 AC-008-2's "epic completion judged by child-bead state, not the epic's own status field" is an assumption, not independently confirmed with the user — a TRD decision should revisit it against beads-build's actual completion signal.
- [RISK: MEDIUM] This is an explicit stopgap (REQ-013); implementation effort here is partially throwaway if/when `PRD-2026-d3051d4b`'s programme ships. Accepted per the user's own "Sequenced: ship narrow now" decision.

Per-requirement risk indicators (Medium/High complexity): REQ-001, REQ-003, REQ-005, REQ-008, REQ-011 — see inline `[RISK: ...]` tags under each in Section 3.

## 9. Implementation Readiness Gate

| Dimension | Score (1-5) |
|---|---:|
| Completeness | 5 |
| Testability | 5 |
| Clarity | 4 |
| Feasibility | 5 |
| **Average** | **4.75** |

**Readiness score: 4.25 → 4.75 (improved)** — Completeness and Testability both improved after refinement (idempotency AC, dependency map, and 6 added Must-level ACs closed real gaps found in Synthesis). Clarity held at 4 (REQ-003's deferred mechanism remains a legitimate, acknowledged open point, not a clarity defect). **PASS (≥4.0)**.

## 10. Constitution Gate

Source: `docs/standards/constitution.md` (canonical; no `.specify/memory/constitution.md` present).

- §4 Architecture Rules (Binding): no new event, aggregate, or CQRS surface proposed (REQ-003/REQ-010 reuse existing mechanisms) — PASS.
- §5 Approval Requirements ("Architecture changes... new patterns... require explicit user approval before implementation"): this PRD's command-dispatch and tagging-convention change qualifies; satisfied by this run's own `implementation_approval` checkpoint (ensemble-new-feature Phase 3) plus the Approvals section above — PASS.
- §8 Documentation Discipline: satisfied by REQ-012 — PASS.

**Constitution Gate: PASSED** (unchanged by refinement; no new event/aggregate/CQRS/approval/documentation surface was introduced).

## Changelog

| Date | Change | Author |
|---|---|---|
| 2026-10-05 | Initial draft, scoped as explicit stopgap vs. PRD-2026-d3051d4b | Claude Code (session with repo owner) |
| 2026-10-05 | Refinement (v1.0.1): added complexity tags and per-requirement risk indicators to all 13 requirements; added idempotency AC-001-3; added Cross-Requirement Dependency Map; added 2nd AC to 6 under-covered Must requirements (REQ-004, REQ-006, REQ-007, REQ-009, REQ-010, REQ-013); re-scored readiness 4.25 → 4.75 | Claude Code (session with repo owner) |
