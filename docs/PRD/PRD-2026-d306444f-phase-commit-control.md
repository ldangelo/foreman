---
document_id: PRD-2026-d306444f
label: prd-phase-commit
version: 1.0.3
status: Draft
date: 2026-08-29
scale_depth: LIGHT
author: Lead Agent
total_requirements: 9
readiness_score: 5.0
readiness_gate: PASS
---

# PRD: Operator-Controlled Phase Commits (`commit:` tag)

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 7 |
| Should | 2 |
| Could | 0 |
| Won't | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 9/9 (100%) |
| Risk flags | 5 |
| Dependencies | 9 |
| Open ambiguity markers | 0 |
| External dependencies | 1 (planned, not implemented) |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
|---|---|---|---|---:|
| REQ-001 | Declare a phase-level `commit:` boolean | Must | Low | 2 |
| REQ-002 | Default to committing when the tag is absent | Must | Low | 2 |
| REQ-003 | Defer a phase's work when `commit: false` | Must | Medium | 3 |
| REQ-004 | Absorb deferred work into the next committing phase | Must | Medium | 2 |
| REQ-005 | Reject a non-boolean `commit:` value at load | Must | Low | 2 |
| REQ-006 | Emit a durable warning when deferred work is never committed | Must | Medium | 3 |
| REQ-007 | Make deferrals and warnings readable against their run | Should | Low | 3 |
| REQ-008 | Refuse a manifest whose cleanup cannot coexist with a deferral | Must | Medium | 2 |
| REQ-009 | Preserve the tag across serialization round-trips | Should | Low | 2 |

## Problem Statement

Foreman commits every phase's output unconditionally at the phase boundary. A
run of the bundled `prd` workflow therefore produces five commits — one per
phase — with no way for the manifest author to say otherwise.

The operator wants control over commit granularity, not more commits. The
motivating case, in the operator's words, is the `prd` workflow: the PRD and TRD
documents should land on **one** commit and the implementation on **another**.
Today those are four document commits plus an implementation commit, so the
reviewable unit does not match the unit of work.

Who feels it: the solo operator authoring workflow manifests and reviewing the
PR a run opens. There is no second audience.

## Design Principle

**The feature is generic: `commit: true` commits the phase's work, `commit:
false` does not. Foreman does what the manifest says.**

This principle is the outcome of refinement and is recorded because v1.0.0
violated it. That draft carried a requirement conditioning the commit decision
on which directories a *later* phase inspects, derived from an implementation
detail rather than from the feature. Nothing about *whether a phase commits*
depends on directories, phase adjacency, or what any other phase reads.

Two outcomes follow, and the line between them is **satisfiability**:

- **Foreman refuses when the manifest cannot be honored.** Either a value is
  unreadable (REQ-005), or two declarations cannot both be satisfied no matter
  what the run does (REQ-008). Executing an unsatisfiable manifest guarantees a
  failure later, so the honest moment to say so is at load.
- **Foreman warns and proceeds when the manifest *can* be honored but the
  consequence would be invisible** (REQ-006). Refusing here would override an
  explicit instruction; staying silent would produce a run that looks successful
  with nothing to show.

*(v1.0.1 and v1.0.2 stated this as "warns and proceeds — it does not refuse",
which was already false of REQ-005 and became more so with REQ-008. The
satisfiability test is the rule that was actually being applied.)*

### Precedence over the working-tree implementation

**This document takes precedence over the uncommitted implementation in the
working tree.** That code is prior art, not a specification, and it currently
disagrees with this PRD in three ways:

1. It refuses to load a workflow when a deferral precedes a document-gated
   phase — the directory-conditioned rule this PRD **removed** (see Non-Goals).
2. It refuses to load a workflow when deferred work is never committed — which
   REQ-006 makes a **warning**.
3. It has no equivalent of **REQ-008**, the one cross-declaration refusal this
   PRD does require.

All three must be reconciled toward this PRD. Where the code and this document
disagree, the document wins; the code was written before these decisions were
made and encodes guesses that were subsequently rejected.

## Goals

- Give the manifest author per-phase control over whether a phase commits.
- Preserve today's behavior for every manifest that says nothing.
- Batch consecutive phases into one commit without losing any work.

## Non-Goals

- Controlling the commit **message**, author, or hooks. Only *whether* a phase
  commits is in scope.
- Per-phase or stacked pull requests. A run still opens at most one PR from its
  single branch; stacked PRs are ensemble-skill behavior that `--foreman`
  disables.
- Discarding a phase's output. `false` means *defer*, never *throw away*.
- Changing the commit shape of any bundled workflow. Every bundled phase ships
  `commit: true`, so no existing run changes behavior; batching is an operator
  edit. The deliverable is the control, not a new default.
- **Building the user-facing warning/error channel.** See External Dependencies:
  the Telegram/Slack channel is planned and unbuilt. This PRD produces messages
  and does not own their delivery.
- **Fixing the planning-document gate's coupling to commit state.** Observed
  during refinement and deliberately out of scope: that gate determines "new in
  this phase" by inspecting committed *and* uncommitted files, so its result can
  vary with whether a previous phase committed. If that coupling is a defect it
  is a defect in the gate — a phase-scoped question should not depend on commit
  state — and it warrants its own investigation rather than constraining this
  feature. No bundled workflow currently combines a deferral with a gated phase.

## External Dependencies

| Dependency | Status | Effect on this PRD |
|---|---|---|
| User-facing warning/error channel (Telegram/Slack) | **Planned, not implemented** | None blocking. REQ-006 requires only that its warning be durable; REQ-007 targets the existing run-scoped operator inbox. No requirement waits on the channel. |

The operator intends to build a user-facing channel that receives warnings and
errors, and identifies this feature's notices as a fitting first consumer. The
design consequence is deliberately narrow: this PRD **produces** operator
messages and does not own their delivery. When the channel exists it becomes an
additional delivery target for messages this feature already emits (REQ-007
AC-007-3 keeps them structured so it can), requiring no change to any
requirement below.

> **Forward-pointer note (added 2026-09-01; updated 2026-09-01).**
> 
> ~~The claim that "REQ-007 targets the existing run-scoped operator inbox" is FALSE,~~
> REQ-007 was ~~dropped~~ **IMPLEMENTED** via `foreman-q5bm`. `ForemanServer.Aggregates.InboxThread`
> is now **reachable and readable**:
> - `CommandRouter.aggregate_module_for/1` has `"inbox:"` clause → routes to InboxThread
> - Event structs `InboxMessageAppended` / `InboxDeliveryUpdated` created under `lib/foreman_server/events/`
> - `ProjectionStore` handles both events, exposing `inbox_thread/1` and `list_inbox_threads/0`
> - MCP tool `foreman_inbox_get` added to expose inbox via `inbox.get` command
> 
> ~~REQ-001 through REQ-006, REQ-008 and REQ-009 shipped~~ **ALL 9 REQUIREMENTS NOW SHIPPED.**
> The routing gap tracked as `foreman-q5bm` is **CLOSED**.

## Assumptions

Recorded rather than presented as decided:

- **A1** — The only user is the solo operator who authors the bundled manifests
  and reviews the resulting PR.
- **A2** — Constraints are inherited from the existing codebase: the current
  workflow manifest schema, the fail-loud rules in `AGENTS.md` §5.2/§5.3, and
  the workflow-level `worktree:` block as the precedent for how a manifest key
  is validated and normalized.
- **A3** — Prior art is the unconditional commit at every phase boundary, plus
  the uncommitted working-tree implementation described under "Precedence over
  the working-tree implementation". *(v1.0.0 claimed "no alternative was
  previously tried", which was false.)*
- **A4** — `commit:` belongs at phase level rather than workflow level, because
  each phase produces its own output. This is the opposite shape from
  `worktree:`, which is workflow-level because a run has exactly one worktree.
- **A5** — `commit:` has no meaning for a workflow that provisions no worktree
  (`worktree: enabled: false`): there is no checkout to commit in, so the tag is
  inert rather than an error. Verified by AC-003-3 rather than left asserted.
- **A6** — A phase that produced no changes creates no commit regardless of its
  tag. Deliberately carries no AC: AC-002-1 already scopes the default-commit
  case to a phase "with changes in the worktree", so the empty case is covered
  by construction rather than by a separate assertion.
- **A7** — The run-scoped operator inbox (`inbox:<run_id>` /
  `InboxMessageAppended`, surfaced by `foreman inbox` and the `foreman watch`
  cockpit) is the correct home for run-scoped notices, because it is already
  per-run and already read during review. Foreman's durable run logs are not,
  since they carry worker output only.
- **A8** — **Every phase a manifest declares will run.** `PhaseSpec` accepts no
  conditional, guard, or skip key (`@fields` is `name`, `prompt`, `prompt_path`,
  `artifact_template`, `command`, `bash`, `required_file`, `index`, `models`,
  `max_turns`, `mail`, `context`, `commit`), so "no later phase commits" is
  decidable from the manifest alone. REQ-008's load-time refusal depends on
  this; were conditional phases introduced, its predicate would become
  unsound and this PRD would need revisiting.

## Requirements

### Feature Area: Declaration

#### REQ-001: Declare a phase-level `commit:` boolean

**Priority:** Must · **Complexity:** Low

A workflow phase may declare `commit:` with the value `true` or `false`. `true`
means the phase's work is committed when the phase completes; `false` means the
work is left in the run's worktree for a later phase to commit.

- AC-001-1: Given a phase declaring `commit: true`, when the workflow loads,
  then the phase carries a boolean `true` — not the string `"true"`.
- AC-001-2: Given a phase declaring `commit: false`, when the workflow loads,
  then the phase carries a boolean `false`, and that value reaches the component
  that decides whether to commit.

#### REQ-002: Default to committing when the tag is absent

**Priority:** Must · **Complexity:** Low

A phase that declares no `commit:` key commits, preserving the behavior from
before this feature existed. Absent and `false` are distinct: absent means "take
the default", `false` means "defer".

- AC-002-1: Given a phase with no `commit:` key, when the phase completes with
  changes in the worktree, then those changes are committed.
- AC-002-2: Given a phase with no `commit:` key, when the workflow loads, then
  no `commit` value is synthesized onto the phase, so "declared nothing" stays
  distinguishable from "declared the default".

### Feature Area: Deferral

#### REQ-003: Defer a phase's work when `commit: false`

**Priority:** Must · **Complexity:** Medium

A phase declaring `commit: false` completes without creating a commit and
without discarding anything. Its files remain in the run's worktree.

[RISK: a deferral that discarded the work, or that committed anyway, would both
present as a successful phase — the failure is only visible by inspecting the
branch tip and the worktree separately.]

- AC-003-1: Given a phase declaring `commit: false` that wrote a file, when the
  phase completes, then the run's branch tip is unchanged.
- AC-003-2: Given the same phase, when the phase completes, then the file it
  wrote is still present in the worktree.
- AC-003-3: Given a workflow declaring `worktree: enabled: false`, when a phase
  in it declares either `commit:` value, then the phase completes normally and
  the tag changes nothing — there being no checkout, it is inert rather than an
  error (A5).

#### REQ-004: Absorb deferred work into the next committing phase

**Priority:** Must · **Complexity:** Medium

The next phase that commits captures both its own output and everything deferred
by preceding phases, in one commit. This is the requirement that delivers the
motivating case.

[RISK: partial absorption — committing the phase's own output while missing
deferred files — produces a commit that looks correct and silently omits work.]

- AC-004-1: Given phase A declaring `commit: false` and phase B declaring
  `commit: true`, when both complete, then exactly one commit exists and it
  contains both A's and B's files.
- AC-004-2: Given a **test fixture** modelled on `prd.yaml` — not the bundled
  manifest, which ships all-`true` per Non-Goals — whose `create-prd`,
  `refine-prd`, and `create-trd` phases defer and whose `refine-trd` phase
  commits, when the run reaches `implement-trd`, then the PRD and TRD documents
  are on a single commit separate from the implementation commit.

### Feature Area: Validation and Reporting

#### REQ-005: Reject a non-boolean `commit:` value at load

**Priority:** Must · **Complexity:** Low

A `commit:` value that is neither `true` nor `false` is a malformed manifest and
is refused when the workflow loads, naming the offending phase. This is one of
exactly two refusals in the feature — this one for an unreadable value, REQ-008
for two declarations that cannot both be honored. Every other consequence is a
warning.

[RISK: a truthiness test would read the string `"false"` as "commit", silently
doing the opposite of what the manifest says.]

- AC-005-1: Given a phase declaring `commit: maybe`, when the workflow loads,
  then loading fails with an error naming the phase and stating that `commit`
  must be a boolean, and no run is dispatched.
- AC-005-2: Given a phase declaring a quoted `commit: "false"`, when the
  workflow loads, then loading fails for the same reason rather than the string
  being coerced to a boolean — so the value never reaches the commit decision
  at all.

#### REQ-006: Emit a durable warning when deferred work is never committed

**Priority:** Must · **Complexity:** Medium

Deferred work can end a run uncommitted two ways: the manifest declares
`commit: false` with no later committing phase, or the run terminates before a
committing phase is reached. Either way PR creation — which counts commits — has
nothing to propose. Foreman honors the manifest and warns; it does not refuse to
load.

This requirement owns only that the warning is **emitted and durable**. Making
it readable against a specific run is REQ-007, which is a Should — so this
requirement is verifiable whether or not REQ-007 ships. *(Through v1.0.2 this
Must depended on that Should for its own acceptance, which is the priority
inversion v1.0.1 removed elsewhere.)*

[RISK: without the warning this is the silent-success failure mode — a run that
reports success with no PR and no stated reason.]

- AC-006-1: Given a workflow whose last committing opportunity declares
  `commit: false` **and which declares `cleanup: never`**, when the workflow
  loads, then it loads successfully and the run executes. (With a destructive
  cleanup mode the same manifest is refused — see REQ-008.)
- AC-006-2: Given that same run, when it completes, then a durable warning
  states that work was left uncommitted, so an absent or empty PR is
  attributable.
- AC-006-3: Given a run whose phase deferred and which then terminates before
  any committing phase, when the run reaches its terminal state, then the same
  warning is raised, naming the uncommitted work.

#### REQ-007: Make deferrals and warnings readable against their run

**Priority:** Should · **Complexity:** Low

Each phase that defers reports that it did so, naming the phase, and REQ-006's
warning is made readable against the specific run it came from. Without this, a
missing commit has no per-run explanation and the operator must diff the
worktree against the branch to reconstruct what happened.

Notices go to the **run-scoped operator inbox** (A7). They are not written to the
durable run logs, which carry worker output only.

- AC-007-1: Given a phase declaring `commit: false`, when the phase completes,
  then a notice identifying that phase as having deferred its work is readable
  against that run.
- AC-007-2: Given a run that triggered the REQ-006 warning, when the operator
  reviews that specific run, then the warning is readable against it without
  consulting server-wide output.
- AC-007-3: Given any notice this feature emits, when it is recorded, then it
  carries structured fields identifying the run and the phase rather than only a
  formatted message string, so the planned external channel can deliver it
  without this feature changing.

#### REQ-008: Refuse a manifest whose cleanup cannot coexist with a deferral

**Priority:** Must · **Complexity:** Medium

A workflow declaring a destructive worktree cleanup mode (`cleanup: always`, or
`cleanup: on_success` on the successful path) together with deferred work that no
later phase commits is **unsatisfiable**: cleanup promises to remove the
worktree, the deferral guarantees uncommitted content in it, and `git worktree
remove` refuses on a dirty tree. Foreman refuses such a manifest at load,
naming the deferring phase and the cleanup mode.

The predicate is the same one REQ-006 already computes — "deferred work that
nothing later commits" — branched on cleanup mode. `cleanup: never`, the
default, is unaffected and remains a warning (REQ-006).

Refusing is correct here rather than warning because the manifest asks for two
things that cannot both happen, so proceeding guarantees a late failure whose
stated cause is a cleanup error rather than the commit decision that produced it.

[RISK: an over-broad predicate would reject legitimate manifests — a deferral
followed by any committing phase is fine, and only the *never committed* case is
unsatisfiable. A false positive blocks a valid workflow at load, which is more
disruptive than the warning it replaces.]

- AC-008-1: Given a workflow declaring `cleanup: always` whose final phase
  declares `commit: false`, when the workflow loads, then loading fails naming
  the deferring phase and the cleanup mode, and no run is dispatched.
- AC-008-2: Given a workflow declaring `cleanup: always` with a deferring phase
  that **is** followed by a committing phase, when the workflow loads, then it
  loads successfully — the deferral is absorbed before cleanup runs, so nothing
  is unsatisfiable.

### Feature Area: Data Integrity

#### REQ-009: Preserve the tag across serialization round-trips

**Priority:** Should · **Complexity:** Low

The resolved phase is serialized when a run is recorded and can be written back
out as YAML. `commit:` must survive both without changing meaning, and an absent
tag must not become a present one.

- AC-009-1: Given each bundled workflow, when its manifest is written out and
  re-read, then every phase's `commit` value is unchanged, including phases
  where it is absent.
- AC-009-2: Given a phase declaring `commit: false`, when the run's workflow
  snapshot is recorded and read back, then the value is still boolean `false` —
  not a string, and not absent.

## Ambiguity scan

Ambiguity scan complete: 0 items marked for clarification.

All five markers carried by v1.0.0 are resolved. Four were answered by the
satisfiability rule in the Design Principle. The fifth — which surface carries
operator notices — is answered by A7 and by the REQ-006/REQ-007 split, with the
planned Telegram/Slack channel recorded as a non-blocking external dependency
rather than an open question.

## Failure scenarios considered

- **Deferred work is silently dropped** — covered by REQ-003 AC-003-2 (files
  must survive on disk) and REQ-004 AC-004-1 (the absorbing commit must contain
  them).
- **Deferred work meets a destructive cleanup** — covered by REQ-008; the
  manifest is refused at load rather than failing later as an unattributable
  cleanup error.
- **Manifest lies about intent** — covered by REQ-005; a non-boolean is refused
  rather than coerced, so `"false"` cannot read as "commit".
- **Run succeeds with nothing to review** — covered by REQ-006; the outcome is
  permitted but never silent.
- **Run dies mid-pipeline holding deferred work** — covered by AC-006-3.
- **Reporting requirement is dropped as optional** — covered by the REQ-006 /
  REQ-007 split; the Must's warning does not depend on the Should's surface.
- **Regression for existing manifests** — covered by REQ-002 and the Non-Goal
  fixing every bundled phase at `commit: true`.

## Dependency Map

- REQ-002 depends on REQ-001 (the tag must exist before a default is meaningful).
- REQ-005 depends on REQ-001.
- REQ-009 depends on REQ-001.
- REQ-004 depends on REQ-003 (work must be deferred before it can be absorbed).
- REQ-006 depends on REQ-003 (deferral must exist to be reported).
- REQ-007 depends on REQ-003.
- REQ-008 depends on REQ-003.
- REQ-007 depends on REQ-006 — it makes that requirement's durable warning
  run-scoped. The direction matters: a Should building on a Must is sound, the
  reverse was the inversion fixed in v1.0.3.
- REQ-008 depends on REQ-006 — it reuses the never-committed predicate rather
  than computing its own.

Cluster to implement together: REQ-001, REQ-002, REQ-005 (declaring and
validating the value). Then REQ-003, REQ-004 (deferral behavior). Then REQ-006,
REQ-008 (the shared predicate and its two outcomes). Then REQ-007 (reporting).
REQ-009 is independent.

No circular dependencies. No requirement depends on the unbuilt external
channel.

## Implementation Readiness Gate

| Dimension | v1.0.3 | v1.0.2 | v1.0.1 | v1.0.0 | Notes |
|---|---:|---:|---:|---:|---|
| Completeness | 5 | 4 | 4 | 4 | The cleanup interaction is now a requirement rather than an unexamined gap, and REQ-006 no longer leans on the unbuilt channel for its acceptance — which was the reason this was held at 4. |
| Testability | 5 | 5 | 4 | 4 | All 21 ACs are observable. A5 moved from asserted to verified (AC-003-3); A6 is explicitly covered by construction rather than left silent. |
| Clarity | 5 | 5 | 5 | 4 | The refuse-vs-warn line is now a stated test (satisfiability) instead of a rule with unacknowledged exceptions. |
| Feasibility | 5 | 5 | 5 | 4 | REQ-008 reuses REQ-006's predicate and reads an existing workflow-level key; A8 confirms the predicate is decidable from the manifest. |
| **Overall** | **5.0** | **4.75** | **4.5** | **4.0** | **PASS** |

Readiness score: 4.75 → 5.0 (improved).

**What 5.0 does not claim.** The scope is one boolean manifest tag at LIGHT
depth, and two things remain deliberately unresolved rather than solved: the
planning-gate coupling is a recorded Non-Goal, and REQ-008's predicate is sound
only while A8 holds. A 5.0 here means the document is internally consistent and
every requirement is verifiable — not that the surrounding subsystem is.

## Changelog

### v1.0.3 — 2026-08-29

Refined against all 10 findings from the second review pass.

**Added**

- **REQ-008** (Must, Medium): a manifest combining destructive worktree cleanup
  with never-committed deferred work is refused at load. Grounded in verified
  behavior — `clean_worktree/2` runs `git worktree remove` without `--force`
  (`vcs_adapter/default.ex:193`, intent stated at `:299-301`), so it fails on a
  dirty tree and the run ends on a cleanup error whose real cause is a
  `commit: false` several phases earlier.
- **A8**: every declared phase runs — `PhaseSpec` accepts no conditional or skip
  key — so REQ-008's "no later phase commits" predicate is decidable statically.
  Recorded with its dependency made explicit.
- **AC-003-3** verifying A5 (`commit:` inert when no worktree is provisioned).
- **AC-007-3** requiring notices carry structured fields, so the planned
  external channel can consume them unchanged.
- **AC-008-1**, **AC-008-2** (the second pinning that the refusal is *not*
  over-broad), **AC-009-2** (run-record snapshot round-trip).

**Changed**

- **Design Principle** reformulated around **satisfiability**: refuse when the
  manifest cannot be honored, warn when it can be but the consequence is
  invisible. The prior "does not refuse" wording was already false of REQ-005.
- **REQ-006 / REQ-007 split** to remove a Must-depends-on-Should inversion.
  REQ-006 now owns only that the warning is emitted and durable; REQ-007 owns
  run-scoped readability. REQ-006 is verifiable whether or not REQ-007 ships.
- **AC-005-2** rewritten: it previously said a quoted `"false"` is refused "when
  the value reaches the commit decision", a moment that load-time refusal makes
  unreachable.
- **AC-006-1** scoped to `cleanup: never`; it otherwise asserts a manifest loads
  successfully that REQ-008 now refuses.
- **AC-004-2** reworded to name a test fixture rather than reading as the
  bundled `prd.yaml`, which Non-Goals guarantee ships all-`true`.
- **REQ-005** no longer claims to be the only refusal.
- **Precedence** section now lists three disagreements with the working-tree
  implementation, the third being that it lacks REQ-008 entirely.
- **A6** annotated to say why it carries no AC.
- **REQ-009** re-filed from "Non-Functional" to a **Data Integrity** feature
  area; round-trip preservation is functional data integrity, not a quality
  attribute.
- **Frontmatter**: added `author` and `readiness_gate`, matching the convention
  used by the jido-series PRDs. `status` deliberately stays `Draft` — every PRD
  in `docs/PRD/` is `Draft`, and the readiness gate already carries the signal.
- **Readiness** 4.75 → 5.0 (Completeness 4 → 5), with an explicit note on what
  the score does not claim.

### v1.0.2 — 2026-08-29

**Added**

- **External Dependencies** section recording the user-facing warning/error
  channel (Telegram/Slack) as **planned, not implemented**, with the explicit
  note that no requirement blocks on it.
- **Precedence over the working-tree implementation** subsection stating that
  this document wins where the uncommitted code disagrees.
- **A7**: the run-scoped operator inbox is the home for operator notices;
  durable run logs are not, since they carry worker output only.
- **AC-006-3**: a run that terminates while holding deferred work raises the
  same warning — the runtime path, distinct from the manifest-shape path.

**Changed**

- **REQ-007** resolved: notices target the existing run-scoped inbox, and the
  planned channel becomes an additional delivery target for the same messages.
- **Readiness** 4.5 → 4.75 (Testability 4 → 5).

**Resolved markers:** 1 → 0.

### v1.0.1 — 2026-08-29

Refined against all 12 synthesis findings.

**Removed**

- **Old REQ-007** (document-discovery protection) and the entire
  directory/gate-collision framing. It conditioned "does this phase commit" on
  which directories a *later* phase inspects — an implementation constraint
  promoted into a requirement. Its removal dissolved two further findings: the
  priority inversion (a Must depending on a Should safeguard) and the
  contradiction with the batching Goal.

**Changed**

- **REQ-006**: refusing to load a workflow whose deferred work is never
  committed → **warn and proceed**.
- **REQ-005**: scope narrowed to the one genuine refusal (a malformed value);
  second AC added for the quoted-string case.
- **Assumption A3**: corrected. It claimed no alternative had been tried while an
  implementation sat in the working tree.
- **Non-Goals**: added that no bundled workflow changes commit shape, and that
  the gate's coupling to commit state is out of scope.

**Added**

- **Design Principle** section stating the generic rule and why v1.0.0 broke it.
- **REQ-007** (new): a deferral is visible in run output.
- `[RISK]` indicators on REQ-003 and REQ-004.
- **A5** and **A6**, closing both scope gaps.

**Resolved markers:** 5 → 1.

## Next step

`/ensemble:create-trd docs/PRD/PRD-2026-d306444f-phase-commit-control.md`
