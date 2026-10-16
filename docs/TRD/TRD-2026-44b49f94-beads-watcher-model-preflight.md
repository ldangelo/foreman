---
document_id: TRD-2026-44b49f94
label: trd-beads-watcher-model-preflight
version: 1.0.1
status: Draft
date: 2026-10-15
source_prd: PRD-2026-44b49f94
prd_reference: docs/PRD/PRD-2026-44b49f94-beads-watcher-model-preflight.md
pr_version_locked: 1.0.1
design_readiness_score: 4.4
complexity: Low-Medium
estimated_touchpoints: 7
affected_components:
  - ForemanServer.AgentRuntime.JidoHarness.ModelCatalog
  - ForemanServer.Workflow.RunExecutor
  - ForemanServer.Workflow.Catalog
  - priv/defaults/workflows
  - ForemanServer.TaskProviders.BeadsWatcher
---

# TRD: Fix BeadsWatcher Preflight `:model_not_found` for `minimax/MiniMax-M2.7`

## TRD Health Summary

| Metric | Value |
|---|---:|
| PRD requirements covered | 12/12 |
| Implementation tasks | 12 |
| Touchpoints (files) | 7 (6 code/docs + tests; 2 gated on an open decision) |
| Open technical decisions | 3 |
| Data migrations | 0 |
| Reversibility | Full revert of one file; no persisted-shape change |

## Root Cause (determined, not hypothesized)

**The failure is a `models.default` value-shape defect against a column-scoped
catalog matcher, and the observed run was dispatched from a bead whose
workflow was an installed runtime copy, not the bundled one.**

Chain of evidence, each item independently reproducible:

1. `RunExecutor.preflight_providers_and_models/1`
   (`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:723`)
   runs before any phase and aggregates per-phase failures into
   `{:provider_model_preflight_failed, failures}`, which
   `handle_info(:kickoff, …)` (`run_executor.ex:355-367`) turns into a terminal
   run failure before `handle_kickoff_ready/1` runs — so before any worktree is
   provisioned and before the Jobsite phase program starts. This matches the
   observed symptom exactly, and it is what makes "the run did nothing" checkable
   rather than inferred.
2. For a phase declaring `provider: pi` plus `models.default`, the check is
   `ModelCatalog.check(:pi, model)` → `pi_model_exists?/1`
   (`.../jido_harness/model_catalog.ex:32`), which shells
   `pi --list-models <model>` and feeds the table to `parse_result/2` (`:58`).
3. `parse_result/2` builds its candidate as
   `"#{row_provider}/#{row_model}"` **only when the searched model contains a
   `/`**; otherwise it compares `row_model` alone. So the comparison is
   *column-scoped to the shape of the input*: `"MiniMax"` is compared against
   the `model` column and can never equal `MiniMax-M2.7`; a bare vendor name is
   structurally unable to match any row.
4. Two distinct declaration shapes therefore fail preflight while naming a
   model that is present on the host:
   - `models.default: MiniMax` — a vendor name where a model id belongs.
     Verified: `{:error, {:model_not_found, "MiniMax"}}`.
   - any value whose provider prefix does not equal the table's `provider`
     column verbatim (case, aliasing, or an unregistered prefix), because the
     composed candidate string then differs from the searched string even
     though a real model was matched.
5. The shape in the *installed runtime catalog* is #4's first bullet:
   `~/.foreman/workflows/bug.yaml`, `task.yaml`, `feature.yaml`, `epic.yaml`,
   `default.yaml`, `discover.yaml`, `implement.yaml`, `release.yaml`,
   `smoke.yaml`, `verify.yaml` all declare `models: {default: MiniMax}`.
   The *bundled* workflows in this repo that declare a model use the qualified
   form `minimax/MiniMax-M2.7` (`assess.yaml`, `fix.yaml`, `prd.yaml`,
   `review.yaml`), which verifies `:ok` against the live catalog on this host.
6. Live verification on this host (pi CLI at `~/.local/bin/pi`):
   `pi --list-models MiniMax` returns 3 `minimax` rows — `MiniMax-M2.7`,
   `MiniMax-M2.7-highspeed`, `MiniMax-M3` — so the model exists; rows whose
   `model` column is exactly `MiniMax`: **0**; rows matching the composed
   `minimax/MiniMax-M2.7`: **1**. Running the verbatim `parse_result/2` logic
   against that table reproduces `:ok` for `minimax/MiniMax-M2.7`,
   `{:error, {:model_not_found, …}}` for `MiniMax`.

**Why the run was dispatched at all:** BeadsWatcher resolves `issue_type` to a
workflow through `Catalog.type_to_workflow/1`, which reads each manifest's own
`task_types:` declaration (`catalog.ex:106`). `bug` maps to nothing in the
bundled set, so a run reported for a bug bead necessarily came from an
installed copy that declares the mapping — i.e. from a workflow whose model
declaration is the *unqualified* shape in item 5. That reconciles the reported
`minimax/MiniMax-M2.7` string (the bundled/legacy qualified form) with a
`model_not_found` outcome without needing the model to be genuinely absent.

**Confidence:** the matcher's column-scoping defect (items 3-4) and the
`MiniMax`-vs-`minimax/MiniMax-M2.7` declaration divergence (item 5) are proven
by code plus live command output. The exact declaration string in
run-0381b526… is *inferred*, because nothing durable recorded which workflow
copy or which `models.default` that run loaded — which is AC-005-1's gap, and
TASK-006 closes it. The PRD's C2 branch (an unmapped bead type) is real but is
a *different* symptom (a bead that never produces a run at all) and is scoped
to TASK-008/TASK-009.

## Revised PRD Interpretation

One PRD statement is wrong as written and is corrected here rather than
silently implemented:

- **AC-001-3's premise** ("the workflow name and the resolved source of its
  definition are recorded with the run") is achievable, but the PRD's framing of
  REQ-001 as a *dispatchability* requirement understates it: the dominant real
  defect is not that a workflow fails to resolve, it is that a workflow that
  resolves can declare a model value its own validator cannot express as a
  match. REQ-001/REQ-006 are therefore implemented primarily through
  **load-time** validation (TASK-001) rather than dispatch-time routing.
- **The PRD's 2 remaining `[NEEDS CLARIFICATION]` markers are answered in "Open
  Technical Decisions"** (OTD-1, OTD-2) with a recommended default, since both
  are technical rather than product questions.
- `REQ-012` ("no second dispatch path") gains a concrete instance the PRD could
  not see: the bundled `priv/defaults/workflows` set and the installed
  `~/.foreman/workflows` set are two declarations of the same workflows that
  have already diverged on exactly the field at fault. TASK-011 makes the
  divergence visible; convergence of the two sets is out of scope and is
  escalated, not fixed here.

## Scope and Non-Goals

**In scope:** model-value validation at load time; a truthful, single failure
class for catalog mismatch vs catalog-unreachable; enough run evidence that a
future occurrence needs no guessing; explicit eligibility reporting for unmapped
bead types; the operator-facing documentation of all of it.

**Out of scope (explicit, so nobody "improves" it in review):**
- Relaxing, downgrading, or making preflight optional. AC-010-2 requires a test
  that an invalid model still stops a run.
- Catalog caching/batching beyond the `{provider, model}` memo that already
  exists (`run_executor.ex:~780`, `cached_model_check/3`).
- Any change to `RunStallReported`, messaging, scheduler, or inbox surfaces.
- A model registry or a "known-good model" list. There is none today and this
  TRD does not add one; inventing one would move the host dependency from the
  catalog query into a checked-in constant, which is worse.
- Renaming existing events (constitution §1 rule 8: convention applies to new
  code only).

## Touchpoint Map

| # | Path | Change | Why |
|---:|---|---|---|
<!-- 7 rows: 1-3 and 5-7 are unconditional; row 4 is gated on OTD-1. -->
| 1 | `packages/foreman_server/lib/foreman_server/agent_runtime/jido_harness/model_catalog.ex` | Rewrite `parse_result/2` to compare on the provider/model pair with an explicit, total decomposition of the searched value; add distinct error atoms | Root cause. The matcher's behaviour must not depend on whether the input happens to contain a `/`. |
| 2 | `packages/foreman_server/lib/foreman_server/workflow/interpreter.ex` | Extend `validate_phase_models_value!/3` (`:507`) to require a fully-qualified `"<provider>/<model-id>"` value for a phase that also declares `provider:` | Turns a dispatch-time failure into a load-time refusal; the failing value is caught when the manifest is read, before a worktree or a paid agent session exists. |
| 3 | `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex` | Include phase name, provider, declared model, and catalog failure class in the preflight failure payload persisted with the run (`:355-367`, `phase_provider_and_model_check/2` at `:736`) | AC-005-1. |
| 4 | `packages/foreman_server/priv/defaults/workflows/{assess,fix,prd,review}.yaml` | **No model-value edit** — these already carry the qualified form and verify `:ok` on this host; the defect lives in the installed copies (TASK-006), not here. Touched only if OTD-1 resolves to "give untyped bead types a default workflow", which would add `task_types:` to the other two bundled manifests | REQ-001, REQ-008, OTD-1 |
| 5 | `packages/foreman_server/lib/foreman_server/task_providers/beads_watcher.ex` | Give "no type field" / "type maps to nothing" / "type field unusable" three distinct outcomes instead of one `:transient` retry loop (`:1112`) | REQ-002, AC-001-2 |
| 6 | `AGENTS.md`, `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` | Document the qualified-model requirement, the new failure classes, and the recovery path | This repo's documentation gate; REQ-009 |
| 7 | `packages/foreman_server/test/**` | Cover items 1-3 and the AC-010-2 guard | Constitution §1 rule 3 |

## Implementation Tasks (rationale)

Design notes for the ids in **Master Task List** above; that section is
authoritative for the scaffold. TASK-NNN here and TRD-NNN there are the same
work: TASK-00N ↔ TRD-00N for N=1..2 is split differently (matcher + validator
ordering), so consult the Master Task List for dependency edges, not this
section.

### TASK-001 — Reject an unqualified `models.default` at workflow load time
**Covers:** REQ-001, REQ-006, REQ-010 **Depends on:** none **Complexity:** Low

Add to `Interpreter.validate_phase_models_value!/3` the rule: a phase declaring
both `provider:` and `models.default` must declare `models.default` as
`"<non-empty>/<non-empty>"`. Reject with an error naming the phase index, the
offending value, and the expected shape.

Implementation note found in review: `validate_phase_models_value!/3` receives
only the phase map and already reads sibling keys from it
(`Map.get(phase, "models")`), and the phase's `provider` is read the same way at
`interpreter.ex:448`. So the qualification test must read `Map.get(phase,
"provider")` inside this validator rather than depending on the order of the
separate provider-validation pass — otherwise a phase with `models` and no
`provider` would be refused, and one is legitimate (see the next bullet).

- Do **not** reject an unqualified `models.default` on a phase that declares no
  provider; that is the legitimate "match on model column" case documented in
  `model_catalog.ex:15-19` and would break existing manifests for no gain.
- Stop condition: an added test loads a manifest with `provider: pi` +
  `models: {default: MiniMax}` and the load **fails**, and the same manifest
  with `minimax/MiniMax-M2.7` loads. Do not also touch dispatch-time code in
  this task.

### TASK-002 — Make the catalog matcher total over input shape
**Covers:** REQ-004, REQ-007 **Depends on:** TASK-001 (so the qualified-only path is the enforced norm) **Complexity:** Medium

Replace `parse_result/2`'s conditional candidate composition with one
decomposition: split the searched value on the **first** `/`; with a prefix, a
row matches iff `row_provider == prefix and row_model == rest`; without one, a
row matches iff `row_model == value`. Case-exact comparison stays, but the
result must no longer depend on a string-shape coincidence.

- Return `{:error, {:model_not_found, model}}` only when the query answered
  with a parseable table; a query that failed or timed out must keep
  `{:catalog_query_failed, …}` and must not be rewritten into absence
  (`model_catalog.ex:49-52` already distinguishes them — preserve that; AC-007-1/2).
- Add a table-driven test with rows from the live `pi --list-models` output for:
  qualified hit, qualified miss on provider, qualified miss on model, unqualified
  hit, unqualified ambiguous (same model id under two providers), and a header-only
  (empty) table. The empty-table case must be `:model_not_found`, not a crash.

### TASK-003 — Separate the three preflight causes in the failure payload
**Covers:** REQ-003, REQ-004, REQ-005 **Depends on:** TASK-002 **Complexity:** Low

`phase_provider_and_model_check/2` already yields
`:phase_provider_unsupported`, `:phase_provider_not_installed`, and
`:phase_model_invalid`. Ensure each carries `{phase_name, provider, model_or_nil,
underlying_reason}` end-to-end into the run's terminal reason, and that a
`catalog_query_failed` is not flattened into `model_not_found` on the way
(prd REQ-002/§5.3: absent vs malformed vs unreachable are three causes).

- Verify by asserting on the exact tuple in a `run_executor` test with a stubbed
  catalog, not by reading a log line.

### TASK-004 — Prove a preflight failure executed zero phases
**Covers:** REQ-003 **Depends on:** TASK-003 **Complexity:** Low

Add a test driving `RunExecutor`'s kickoff path with an injected failing
catalog, asserting: no `PhaseStarted` for any phase, no worktree record, and the
terminal reason is the preflight tuple. This is the test that makes "the run did
nothing" a fact rather than an inference.

### TASK-005 — Record the selected workflow and model resolution on the run
**Covers:** REQ-005, REQ-006 **Depends on:** TASK-003 **Complexity:** Medium

Make the run's own record carry, per phase: workflow name, the loaded manifest's
source root (bundled vs installed), provider, declared `models.default`, and the
model actually passed to the driver. `phase_model/1` (`run_executor.ex:2025`) and
`foreman_env/4`'s `FOREMAN_MODEL` (`:2926`, `:3049`) are the two places that
already compute this; record the value at the one place that has both the
declaration and the resolved provider rather than recomputing at read time.

- Constraint from the PRD (AC-006-2) and this repo's rules: the workflow's
  declared value wins; the environment value is a gap-filler only. If the code
  today disagrees, that disagreement is the finding to report — do not change
  precedence inside this task.
- OTD-2 decides durability. If it resolves to "durable", this task adds the
  event; if "log sufficient", it records on run state only. Do not do both.

### TASK-006 — Inventory installed workflows (prerequisite for TASK-001, not a follow-up)
**Covers:** REQ-001, REQ-012 **Depends on:** none — **and TASK-001 depends on this** **Complexity:** Medium (investigation-first)

TASK-001 will make the installed set (`~/.foreman/workflows/*.yaml`, which
declares `MiniMax`) fail to load. That is correct, and it is also a breaking
change for any operator whose runtime copy is stale, so TASK-001 must not land
before this inventory exists. Ordering corrected during refinement: this task
originally depended on TASK-001, which would have had the refusal reach the
operator first and the explanation second:

1. Enumerate every installed workflow reachable by the current server and
   classify its `models.default` as qualified / unqualified / absent.
2. Report the count and names of the unqualified ones to the operator before
   merging; they need `foreman init --force` to refresh from the bundled set.
3. Do **not** silently normalize an unqualified value into
   `minimax/<value>` at load time — that guess is how the next version of this
   bug gets shipped, and the PRD's risk register forbids it.

- Stop condition: a written statement of which installed manifests TASK-001
  will refuse, and the one-line operator action that fixes each.

### TASK-007 — Make preflight stay fail-closed (guard test)
**Covers:** REQ-010 **Depends on:** TASK-001, TASK-006 **Complexity:** Low

One test, explicitly, so a later "make the error quieter" change fails: a
manifest whose model cannot be validated produces a terminal run failure with
zero phases and no worktree or branch, because the kickoff gate stands ahead of
worktree provisioning entirely. Where the failure is a load-time refusal
(TASK-001), the proof is that the manifest never becomes a runnable workflow at
all — assert both paths, since they are different guarantees and AC-010-2 is
satisfied by neither alone.

### TASK-008 — Split the BeadsWatcher eligibility outcome vocabulary
**Covers:** REQ-002 **Depends on:** none **Complexity:** Low

At `beads_watcher.ex:1112`, `{:error, :unmapped_type}` currently funnels into the
same `:transient` retry-forever path as a read hiccup. Give it its own outcome
with its own telemetry reason so a permanently-inert bead is distinguishable
from a temporarily-unreadable one. Keep the retry-forever behavior itself; that
is documented fail-closed intent (AGENTS.md, TRD-005) and changing it is a
product decision, not a bug fix.

### TASK-009 — Report dispatch eligibility completely by construction
**Covers:** REQ-008 **Depends on:** TASK-008 **Complexity:** Medium

Derive the mapped/unmapped type report from the catalog's own `task_types`
declarations (`Catalog.type_to_workflow_map/0`, `catalog.ex:127`) rather than a
hand-written list, and surface the resulting set somewhere an operator will
actually look. AC-008-2's "complete by construction" is satisfied only if adding
a workflow with a new `task_types:` entry changes the report with no second edit.

### TASK-010 — Prove the claim about the original run
**Covers:** REQ-005, Root Cause **Depends on:** TASK-005 **Complexity:** Low

With TASK-005's recording in place, reproduce the reported failure on a
controlled bead and confirm the recorded evidence names the same model string as
the report. If it does not reproduce, the root-cause section above is wrong and
must be corrected in this document, not quietly in the code.

### TASK-011 — Documentation pass
**Covers:** REQ-005, REQ-009, documentation gate **Depends on:** TASK-001..TASK-009 **Complexity:** Low

Per AGENTS.md's Documentation Discipline gate: list every added/renamed
identifier in this change (failure-class atoms, `task_types` entries, any new
event, CLI-visible behaviour), grep each across `CLAUDE.md`, `AGENTS.md`,
`README.md`, `docs/user-guide.md`, `docs/cli-reference.md`, and state which of
the five needed edits and which did not and why. Document the recovery path
REQ-009 asks for (correct the cause → re-open the bead → one new run, failed
history retained) and the "declares `models.default` must be qualified" rule
where operators author workflows.

## Master Task List

Task ids are stable across the restructure: TASK-NNN below maps to TRD-NNN for
the bead scaffold, and each implementation task carries an explicit
`TRD-NNN-TEST` sibling. The earlier "## Implementation Tasks" prose is the
design rationale; this section is the machine-parsed authority.

### PR 1: Correct the catalog matcher without changing what preflight refuses

**Shippable State:** `ModelCatalog.parse_result/2` decides a match from one total decomposition of the searched value instead of a string-shape coincidence; a catalog that could not answer is never reported as a model that is absent; the preflight failure tuple names phase, provider, model, and cause end-to-end. No workflow that loads today stops loading under this PR, and no dispatch that succeeds today fails. Guarded by tests, including the zero-phase proof.

- [ ] **TRD-001**: Rewrite `ModelCatalog.parse_result/2` to a total decomposition: split the searched value on the first `/`; with a prefix a row matches iff `row_provider == prefix and row_model == rest`; without one, iff `row_model == value`. Keep case-exact comparison. [satisfies REQ-004] (2h)
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-007-2
- [ ] **TRD-001-TEST**: Table-driven matcher tests over captured live `pi --list-models` rows: qualified hit, qualified provider-miss, qualified model-miss, unqualified hit, unqualified ambiguous across two providers, header-only empty table. [verifies TRD-001] [satisfies REQ-004] [depends: TRD-001] (1.5h)
  - Validates PRD ACs: AC-004-2, AC-007-2
- [ ] **TRD-002**: Preserve the `catalog_query_failed` vs `model_not_found` split from `pi_model_exists?/1` through `phase_provider_and_model_check/2` into the run's terminal reason, with `{phase_name, provider, model_or_nil, reason}` carried end-to-end. [satisfies REQ-007] [depends: TRD-001] (2h)
  - Validates PRD ACs: AC-007-1, AC-005-1
- [ ] **TRD-002-TEST**: Assert the exact terminal tuple for three injected catalog outcomes (not-found, query-failed, provider-not-installed) — distinct, no two equal. [verifies TRD-002] [satisfies REQ-002] [depends: TRD-002] (1h)
  - Validates PRD ACs: AC-002-1, AC-004-1
- [ ] **TRD-003**: Drive `RunExecutor`'s kickoff path with a failing catalog and assert zero `PhaseStarted`, no worktree record, and the preflight tuple as the terminal reason. [satisfies REQ-003] [depends: TRD-002] (1.5h)
  - Validates PRD ACs: AC-003-1
- [ ] **TRD-003-TEST**: Same harness asserts the owning bead reflects a failed dispatch and not a completion. [verifies TRD-003] [satisfies REQ-003] [depends: TRD-003] (1h)
  - Validates PRD ACs: AC-003-2

### PR 2: Refuse an unqualified model declaration at load time, with the operator inventory that makes the refusal fair

**Shippable State:** a phase declaring both `provider:` and `models.default` is refused at manifest load unless the value is `"<provider>/<model-id>"`, the refusal names phase index, offending value, and expected shape, and every installed runtime manifest the refusal will break has been enumerated with its one-line fix. This is the breaking PR and must not land before TRD-004's inventory is written.

- [ ] **TRD-004**: Inventory every installed runtime workflow's `models.default` as qualified / unqualified / absent, and report the names that a load-time refusal would break, before any validator change merges. [satisfies REQ-012] (2h)
  - Validates PRD ACs: AC-012-1
- [ ] **TRD-004-TEST**: Regression guard: the inventory script classifies the two known shapes correctly against fixture manifests. [verifies TRD-004] [satisfies REQ-012] [depends: TRD-004] (1h)
  - Validates PRD ACs: AC-012-1
- [ ] **TRD-005**: Extend `Interpreter.validate_phase_models_value!/3` to require a qualified `models.default` when the same phase map also declares `provider` (read via `Map.get(phase, "provider")`, as `interpreter.ex:448` already does); leave a provider-less unqualified value legal. [satisfies REQ-001] [satisfies REQ-006] [depends: TRD-004] (2h)
  - Validates PRD ACs: AC-001-1, AC-006-1
- [ ] **TRD-005-TEST**: Load three manifests: provider+qualified (loads), provider+unqualified (refused, error names index/value/shape), models-only-unqualified (loads). [verifies TRD-005] [satisfies REQ-001] [depends: TRD-005] (1h)
  - Validates PRD ACs: AC-001-1, AC-010-1
- [ ] **TRD-006**: Guard test that an unloadable manifest and a loadable-but-invalid-model run both stop before any phase, proving the gate was not downgraded to a warning. [satisfies REQ-010] [depends: TRD-005] (1h)
  - Validates PRD ACs: AC-010-1
- [ ] **TRD-006-TEST**: The same guard asserted from the executor side, so neither half of AC-010-2 rests on the other. [verifies TRD-006] [satisfies REQ-010] [depends: TRD-006] (1h)
  - Validates PRD ACs: AC-010-2

### PR 3: Make the next occurrence self-explaining, and make bead eligibility loud

**Shippable State:** a run's record names the workflow it ran, the source root its manifest came from, and the model each phase was given; a labelled bead that cannot be dispatched produces one of three distinct recorded outcomes instead of an infinite silent retry; the type-to-workflow report is derived from the manifests themselves; and the documented recovery path is real.

- [ ] **TRD-007**: Record per-phase model resolution plus workflow name and manifest source root on the run, at the single place that already holds both the declaration and the resolved provider (`phase_model/1`, `run_executor.ex:2025`). Log/run-state only unless OTD-2 decides otherwise; do not add an event for a diagnostic by default. [satisfies REQ-005] [satisfies REQ-006] [depends: TRD-002] (3h)
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-006-1
- [ ] **TRD-007-TEST**: Assert the recorded values survive a run and match what was declared, and that a declared-vs-environment conflict records the documented winner. [verifies TRD-007] [satisfies REQ-006] [depends: TRD-007] (1.5h)
  - Validates PRD ACs: AC-006-2
- [ ] **TRD-008**: Split the `{:error, :unmapped_type}` path at `beads_watcher.ex:1112` from the transient read-failure path, giving it its own outcome and telemetry reason while keeping the documented fail-closed retry. [satisfies REQ-002] (2h)
  - Validates PRD ACs: AC-001-2, AC-002-1
- [ ] **TRD-008-TEST**: Pipeline test asserting absent-type / unmapped-type / malformed-type yield three distinct recorded outcomes. [verifies TRD-008] [satisfies REQ-002] [depends: TRD-008] (1.5h)
  - Validates PRD ACs: AC-002-1, AC-002-2
- [ ] **TRD-009**: Derive the mapped/unmapped bead-type report from `Catalog.type_to_workflow_map/0` and surface it where an operator will look; adding a `task_types:` entry must change the report with no second edit. [satisfies REQ-008] [depends: TRD-008] (2h)
  - Validates PRD ACs: AC-008-1
- [ ] **TRD-009-TEST**: Assert the report is complete over the bundled set and that adding a manifest with a new `task_types:` entry appears without touching the reporter. [verifies TRD-009] [satisfies REQ-008] [depends: TRD-009] (1h)
  - Validates PRD ACs: AC-008-2
- [ ] **TRD-010**: Reproduce the reported failure on a controlled bead with TRD-007's evidence in place, and confirm the recorded model string matches the report — or correct this TRD's Root Cause section in the same change. [satisfies REQ-005] [depends: TRD-007] (1.5h)
  - Validates PRD ACs: AC-005-1
- [ ] **TRD-010-TEST**: No new code test; the artifact is the reproduction record attached to this document's changelog. [verifies TRD-010] [satisfies REQ-005] [depends: TRD-010] (0.5h)
  - Validates PRD ACs: AC-005-1
- [ ] **TRD-011**: Documentation pass across `CLAUDE.md`, `AGENTS.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`: the qualified-model rule, the new failure classes, the eligibility report, and the recovery path. [satisfies REQ-009] [depends: TRD-005] [depends: TRD-008] (2h)
  - Validates PRD ACs: AC-009-1
- [ ] **TRD-011-TEST**: Grep-based check that every renamed or added identifier in this change appears in the five doc files and that no removed identifier survives as a live instruction. [verifies TRD-011] [satisfies REQ-009] [depends: TRD-011] (1h)
  - Validates PRD ACs: AC-009-1

### Deferred (explicitly not in this plan)

- **REQ-011** (catalog query budget / caching) — PRD priority **Won't** this
  release; the existing `{provider, model}` memo already bounds it. Carrying it
  as a bead would create work with no acceptance owner.
- **OTD-1** — whether untyped bead types get a default workflow. Gates the
  `task_types:` half of touchpoint 4; deliberately unresolved and escalated, so
  no task here depends on a guess.

## Complexity Assessment

| Task | Complexity | Driver |
|---|---|---|
| TASK-001 | Low | One validator clause + 2 tests |
| TASK-002 | Medium | Matcher semantics + table-driven tests; easy to get ambiguous-match wrong |
| TASK-003 | Low | Payload threading |
| TASK-004 | Low | Test only |
| TASK-005 | Medium | Crosses executor → record; OTD-2 gates the shape |
| TASK-006 | Medium | Requires host inspection, not code reading |
| TASK-007 | Low | Single guard test |
| TASK-008 | Low | One clause split |
| TASK-009 | Medium | New read surface |
| TASK-010 | Low | Depends on TASK-005 |
| TASK-011 | Low | Mechanical but blocking |

Overall: **Low-Medium.** No new dependencies, no migrations, no schema change.
The risk is not effort, it is blast radius: TASK-001 refuses manifests that
today load.

## Testing Plan

- Unit: `model_catalog_test.exs` table-driven matrix (TASK-002);
  `interpreter_test.exs` qualified/unqualified/provider-less triple (TASK-001).
- Integration: `run_executor_test.exs` kickoff-with-failing-catalog → zero
  phases, no worktree, exact terminal tuple (TASK-004/007).
- Pipeline: `beads_watcher_pipeline_test.exs` — the three eligibility outcomes
  are distinct (TASK-008).
- Live/manual: TASK-010's reproduction, plus the installed-manifest inventory in
  TASK-006.
- Full suite must be green; this repo accepts no "known flaky" baseline
  (AGENTS.md, Known Issues).

## Rollout and Rollback

- Order: TASK-002 + TASK-003 + TASK-004 (safe, purely additive correctness) may
  ship independently of TASK-001. TASK-001 is the one with operator impact and
  should ship with TASK-006's inventory and TASK-011's docs in the same change,
  never alone.
- Rollback: revert TASK-001's validator clause restores load behavior exactly;
  no persisted data changes, so a revert is complete. TASK-002's matcher fix is
  not a rollback candidate — reverting it re-introduces the defect.
- Operator action after TASK-001 lands: `foreman init --force` to refresh
  installed runtime prompts/workflows. Dispatch paths fail fast on stale
  runtime assets, so an operator who skips it will see a clear refusal rather
  than a silent mismatch.

## Open Technical Decisions

**OTD-1 (maps to PRD AC-001-3):** should an untyped `task`/`feature`/`epic` bead
get a default workflow, or stay out-of-scope-by-design? Recommendation: stay
out-of-scope, but *reported* — TASK-008/009 make the silence the bug, not the
routing. Needs operator confirmation because it changes who owns those beads.

**OTD-2 (maps to PRD AC-005-2):** durable record vs log-only for per-phase model
evidence. Recommendation: log-only plus run-state, because adding an event for
this alone widens the event surface for a diagnostic, and the existing
`workflow_snapshot` already carries the manifest. Blocks TASK-005's shape;
decide before implementing it.

**OTD-3:** should `ModelCatalog.check/2` treat a bare-vendor `MiniMax` as a
legitimate prefix query (returning the set of matching models) or always as a
miss? Recommendation: always a miss — a phase must name one model, and a
"matches several" success would make dispatch non-deterministic. Implemented by
TASK-002's unqualified-hit row in the test matrix.

## Changelog

- 2026-10-15 — v1.0.1 (`trd_refine`, Foreman mode): 4 findings auto-applied —
  (1) TASK-006 reordered to precede TASK-001, since the load-time refusal is the
  breaking change and the inventory is its warning; (2) TASK-001 given the
  concrete `Map.get(phase, "provider")` read its cross-validator dependency
  actually requires; (3) Root Cause item 5 corrected to name 4 of 6 bundled
  manifests and to explain why the installed set is the relevant source for a
  bug/feature bead; (4) preflight's position restated as ahead of worktree
  provisioning, with TASK-007 proving both the gate path and the load path.
  Touchpoint count unchanged at 6 files + tests.
- 2026-10-15 — v1.0.0 (`trd_create`): TRD from locked PRD v1.0.1; root cause
  determined from source plus live catalog output.

## Requirement Traceability

| PRD REQ | Task(s) | Proof |
|---|---|---|
| REQ-001 | TASK-001, TASK-006 | load test + inventory |
| REQ-002 | TASK-003, TASK-008 | distinct tuples, pipeline test |
| REQ-003 | TASK-004 | zero-phase assertion |
| REQ-004 | TASK-002, TASK-003 | matcher matrix |
| REQ-005 | TASK-003, TASK-005, TASK-010 | recorded evidence + live repro |
| REQ-006 | TASK-001, TASK-005 | validator + precedence test |
| REQ-007 | TASK-002, TASK-003 | empty-table and query-failed rows |
| REQ-008 | TASK-009 | derived report |
| REQ-009 | TASK-011 | docs gate |
| REQ-010 | TASK-007 | guard test |
| REQ-011 | — | explicitly not implemented (Won't) |
| REQ-012 | TASK-006 | inventory names the second set |
