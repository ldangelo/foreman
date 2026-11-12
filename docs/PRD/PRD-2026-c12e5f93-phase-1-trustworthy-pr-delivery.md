---
document_id: PRD-2026-c12e5f93
label: prd-phase-1-trustworthy-pr-delivery
version: 1.1.0
status: Draft
date: 2026-11-08
scale_depth: STANDARD
total_requirements: 5
total_acceptance_criteria: 18
readiness_score: 4.25
---

# PRD: Phase 1 — Trustworthy PR Delivery

## PRD Health Summary

| Priority | Count |
|---|---:|
| Must | 5 |
| Should | 0 |
| Could | 0 |
| Won't (this phase) | 0 |

| Metric | Value |
|---|---:|
| Requirement coverage | 5/5 (100%) |
| Acceptance-criteria coverage | 5/5 (100%) |
| Risk flags | 5 |
| Open clarification markers | 0 |

| REQ | Description | Priority | Complexity | ACs |
|---|---|---|---|---:|
| REQ-001 | Collect required check evidence for the PR head | Must | High | 6 |
| REQ-002 | Produce structured review findings | Must | High | 2 |
| REQ-003 | Classify PR risk and publish actionable guidance | Must | High | 5 |
| REQ-004 | Keep merging human-approved in Phase 1 | Must | High | 2 |
| REQ-005 | Expose the evidence and gate status | Must | Medium | 3 |

## 1. Executive Summary

Foreman’s current review prompts request tests and static checks, but prompt instructions are not proof that checks ran or passed. This phase makes PR quality and review evidence machine-verifiable, tied to the exact PR head, and visible to operators and reviewers. It adds a structured risk decision with rationale and actionable PR review instructions while preserving the current human approval requirement for every merge.

This phase intentionally does **not** enable auto-merge. Its outcome is a trustworthy foundation for deciding whether a later, separately approved phase can safely automate eligible MEDIUM/LOW PRs.

Version 1.1.0 (2026-11-12) resolves the two open decisions with the operator's choices (§6), corrects the baseline claims the source did not bear out (§3) and records the preconditions the operator attached to accepting the Phase 0 engine decision (§5). No requirement id and no existing acceptance criterion changed; six acceptance criteria were added where a settled decision had none (§8).

## 2. Users

* **Project owner:** configures required checks for generated PRs.
* **Human reviewer:** needs findings, risk rationale, and proof tied to the PR head.
* **Foreman operator:** needs fail-closed behavior when checks are missing, stale, or ambiguous.

## 3. Scope

### In scope

* Discover/configure required project check sources and record machine-verifiable results.
* Bind checks, review outputs, unresolved findings, and risk classification to the exact PR head SHA.
* Publish structured risk rationale and specific human review instructions to the PR.
* Invalidate quality/review evidence when the PR head changes.
* Keep all merges operator-approved and SHA-pinned.

### Out of scope

* Automatic merge, which belongs to Phase 2.
* Raw idea cultivation or PRD/TRD lifecycle, which belongs to Phase 3.
* Model-only quality claims without machine-verifiable check evidence.
* Server-run command checks (a command Foreman itself runs against a checkout of the head): deferred, not in the first release (§6).

### Baseline this PRD builds on (verified against `origin/main` `0699076a`, 2026-11-12)

Paths are relative to `packages/foreman_server/` unless they start with `docs/`. The TRD re-verifies each row against source.

1. **Review prompts only ask for checks.** `priv/defaults/workflows/prompts/review-repo-rules.md:56-62` tells the agent to run "the narrowest test command" and the formatter; no phase records an exit code in a typed event.
2. **CI results are already read from GitHub; what is missing is binding and identity.** One `gh pr view` returns the head SHA and the check rollup (`lib/foreman_server/github/pr_status.ex:131,275,321`). The normalised check carries no time (`pr_status.ex:64-71,388-418`), `PrChecksChanged` records only the failing checks and a digest (`lib/foreman_server/events/pr_checks_changed.ex:13-46`, `lib/foreman_server/pr_observation.ex:43-51,199-204`), and a head change leaves the earlier checks state in place (`lib/foreman_server/pr_watch_fold.ex:111-117` against `:129-139`; `lib/foreman_server/aggregates/run/pr_watch.ex:522-542`).
3. **REQ-004's dependency exists and is stronger than assumed.** An approval names the head and is checked against GitHub at approval (`lib/foreman_server/run_pr_merge.ex:74-98`, `lib/foreman_server/command_gateway.ex:250-259`), the aggregate voids it when the head differs (`lib/foreman_server/aggregates/run.ex:976-1010`), the merge re-reads the live head (`run_pr_merge.ex:185-197`) and `gh` is told `--match-head-commit` (`lib/foreman_server/github/pr_merge.ex:40`). REQ-004's remaining work is adversarial tests, not new code. What the gate does not do is read checks, findings or risk (`aggregates/run.ex:1260-1267` checks only that the gate is approved): that is REQ-001's gate, not REQ-004's.
4. **"PR comment integration" (REQ-003's dependency) does not exist.** No code under `lib/foreman_server/workflow`, `github`, `pr_watcher` or `vcs_adapter` posts a PR comment or review; the `gh` write calls are `pr create`, `pr merge` and `git push`. REQ-003 builds the first comment write.
5. **Review findings are free text.** `lib/foreman_server/workflow/review_findings.ex:13-27` extracts a Markdown block between HTML-comment markers and reads an absent block as `:none` (no findings); the block is pasted into the PR body at creation (`lib/foreman_server/workflow/auto_pr.ex:519-525`, `lib/foreman_server/workflow/phase_pr.ex:453-459`). Nothing parses severity, location, disposition or head.
6. **`Review.Verdict` is a different concept and stays separate.** `lib/foreman_server/review/verdict.ex` grades a finished run against its bead (`met`, `partially_met`, `not_met`, `undetermined`), carries no head SHA and posts to the task provider, not to GitHub. REQ-002 and REQ-003 neither reuse nor replace it.
7. **Phase 0 is merged and its engine decision is accepted with preconditions** (operator, 2026-11-12): see §5.
8. **Observing a head change is opt-in.** The PR watcher is on by default (`config/config.exs:311`) and observes a PR when it is associated or readied; later heads are seen by the poll loop (`FOREMAN_PR_MONITOR_ENABLED`, `config/runtime.exs:80-81`) or by a verified webhook (`FOREMAN_GITHUB_WEBHOOK_SECRET`, `config/runtime.exs:229-231`).

## 4. Requirements

### REQ-001: Collect required check evidence for the PR head

Priority: Must; Complexity: High. Risk: A claimed pass can be unverified or belong to another commit.

* AC-001-1: Given a configured check passes, when Foreman records it, then provider/command, check identity, result, completion time, and exact head SHA are stored.
* AC-001-2: Given any required check fails, is missing, stale, or tied to another SHA, when eligibility is evaluated, then the PR is blocked from advancing and the operator sees the reason.
* AC-001-3: Given a project has no configured checks, when verification runs, then Foreman does not infer success from a review prompt and requires an explicit fallback policy or operator disposition.
* AC-001-4: Given a required check is evaluated, when its result is recorded, then the result is read from GitHub's check runs and commit statuses in the same response that names the PR head SHA and is matched against the project's required-check list (name, kind, optional workflow); agent-run output, an agent-written file and a claim in a review prompt are never evidence.
* AC-001-5: Given a project has no configured checks and an operator waives check evidence, when the waiver is recorded, then it is an operator-only command that names the approver identity, the reason codes waived and a reason, is pinned to the PR head SHA, and covers no other head.
* AC-001-6: Given the durable idempotency store is not switched on and answering, when an operator enables required checks for a project, then Foreman refuses and names the missing store.

### REQ-002: Produce structured review findings

Priority: Must; Complexity: High. Risk: Unresolved findings can be lost in unstructured artifacts.

* AC-002-1: Given automated review completes, when findings are recorded, then severity, location, description, disposition, source, and head SHA are machine-readable.
* AC-002-2: Given required review evidence is missing or malformed, when the phase completes, then the run remains ineligible and presents the defect for operator action.

### REQ-003: Classify PR risk and publish actionable guidance

Priority: Must; Complexity: High. Risk: Under-classification may suppress necessary human scrutiny.

* AC-003-1: Given review completes, when risk is recorded, then it includes HIGH/MEDIUM/LOW, rubric version, rationale, evidence, unresolved findings, human-review instructions, and head SHA.
* AC-003-2: Given risk is ambiguous, missing, or conflicting, when eligibility is evaluated, then it follows the conservative HIGH/blocked path and cannot authorize automation.
* AC-003-3: Given a report is valid, when Foreman publishes it, then the PR receives an actionable comment; a changed head invalidates the old report and requires refresh.
* AC-003-4: Given a report contains text derived from agent output, when Foreman publishes it, then that text has been redacted with the project's secret values, bounded in length and neutralised against markup and @-mentions, and a project secret value that survives redaction blocks publication with a typed reason.
* AC-003-5: Given the rubric is applied, when risk is recorded, then the rule level is computed only from machine-derived inputs, a model judgement is read from a typed marker block and can only raise the level, and a missing, malformed or conflicting judgement yields HIGH.

### REQ-004: Keep merging human-approved in Phase 1

Priority: Must; Complexity: High. Risk: Enabling automation before evidence and policy are validated could merge unsafe changes.

* AC-004-1: Given any PR completes Phase 1 review, when a merge is requested without operator approval pinned to its current head SHA, then Foreman refuses the merge.
* AC-004-2: Given the head changes after approval, when merge is attempted, then approval is considered stale and a new human decision is required.

### REQ-005: Expose the evidence and gate status

Priority: Must; Complexity: Medium. Risk: Invisible blocked conditions invite manual bypass.

* AC-005-1: Given a PR is blocked or eligible for human review, when an operator inspects it, then required checks, stale/missing evidence, findings, risk rationale, and next actions are visible.
* AC-005-2: Given evidence is updated, when projections refresh, then the displayed decision corresponds to the latest PR head and policy version.
* AC-005-3: Given the evidence projection could not be read (an event-log read failed at boot, or a stored record is malformed), when an operator inspects a PR, then its status is `unknown` with the cause and is never shown as eligible or clean.

## 5. Dependencies and Exit Criteria

**Prerequisite:** Phase 0 durable run and provenance guarantees. The Phase 0 engine decision (`docs/decisions/phase-0-durable-execution-engine.md`: extend the current event-sourced engine; no Temporal, Conductor or Pi Durable) is accepted by the operator (2026-11-12) with four preconditions on Phase 1 code:

* **P-1** `foreman-by6nl`: `Idempotency.Effect.run/4` must refuse an effect whose key is undecided, before any Phase 1 effect exists.
* **P-2** `foreman-tnlqt`: `gh pr create` must consult GitHub for an existing PR before it runs and before its key settles `failed`; the block, reset and resume sequence that was inferred from source must be walked by a test.
* **P-3** the durable idempotency store (`config :foreman_server, :jido_ecto, enabled: true` and `JIDO_CHECKPOINT_DATABASE_URL`; production default is off, `config/prod.exs:78`) must be on in a deployment before Phase 1 gating is enabled there. This is a deployment step; AC-001-6 is its guard in code.
* **P-4** (a design rule, not a bead) every Phase 1 effect is keyed by head SHA, because the existing `pr_create` and `branch_push` keys carry none and a settled key is run again (`lib/foreman_server/idempotency/effect.ex:174-175`).

Exit when quality checks and risk evidence are machine-verifiable, tied to the current SHA, changed heads invalidate prior evidence, and every merge still requires human approval. Adversarial tests must cover missing results, spoofed/stale results, and head changes.

| Requirement | Depends on |
|---|---|
| REQ-001 | Phase 0 provenance and execution capability; GitHub check data through `PrStatus` (exists); preconditions P-1 to P-4 |
| REQ-002 | Review workflow and durable artifacts (exist as free-text Markdown artifacts; a typed record replaces the parse) |
| REQ-003 | REQ-001, REQ-002; PR comment integration, which does not exist and is built here as a keyed effect (P-4) |
| REQ-004 | Existing SHA-pinned human merge gate (exists, verified in §3 item 3); REQ-004's work is adversarial tests |
| REQ-005 | Evidence projection and operator interface (`PrWatch.DTO` and its HTTP, MCP and CLI readers exist and are extended) |

## 6. Open Decisions

No `[NEEDS CLARIFICATION]` markers remain. Decisions resolved in v1.1.0 (operator, 2026-11-12):

| Decision | Resolution | Where |
|---|---|---|
| Check sources in the first release, and the configuration format | (A) GitHub check runs and commit statuses read from the same `gh pr view` response as the head SHA, filtered by a per-project `required_checks` list of entries (name, kind `check_run` or `status_context`, optional workflow); (C) an explicit operator waiver pinned to the head SHA for a project with no checks. Server-run command checks (B) are deferred: they would run project code on a host whose filesystem and network the Phase 0 execution profile records as unenforced. Agent-run output, an agent-written file and a review-prompt claim are never evidence | AC-001-1, AC-001-3 to AC-001-5 |
| Gate switch, per project | `required_checks` absent: nothing changes, evidence is recorded and shown. `required_checks` present, including an empty list: the evidence gate applies to approval of that project's PRs, and an empty list means "no checks configured", which needs a waiver | AC-001-2, AC-001-3, AC-001-6 |
| What "blocked from advancing" means | The operator `merge_approve` is refused with typed reasons while the evidence for the current head is not eligible and not waived. `run.pr.merge` already needs an approved gate pinned to the head | AC-001-2, AC-004-1 |
| Risk rubric | A versioned, deterministic, table-driven rubric over machine-derived inputs; a model's judgement is read from a typed marker block and can only raise the level; the rubric is stated below | AC-003-1, AC-003-2, AC-003-5 |
| Auto-merge | Not enabled in Phase 1. Every merge stays operator-approved and SHA-pinned | REQ-004 |

**Risk rubric v1 (inputs and rules).** Inputs, all machine-derived (nothing an agent writes is an input, except the optional model judgement, which can only raise): (1) the changed paths and counts GitHub reports for the PR head; (2) size, lines added plus deleted; (3) whether any changed path is on the sensitive-path list; (4) required-check coverage and result at the head, and whether a waiver was needed; (5) unresolved review findings at the head, by severity; (6) the PR base branch against the run's recorded base branch; (7) the model's judgement from a typed marker block.

Rules. **HIGH** when any of: a sensitive path is touched; any required check is not passing at the head (missing, failing, pending, stale, or for another SHA), none is configured, or a waiver was needed; findings evidence is absent, malformed or for another head, or an unresolved critical or major finding exists; the base branch is not the run's recorded base; the changed-path evidence is incomplete (GitHub lists fewer files than it counts); the diff exceeds the HIGH size limit; the model judgement is missing, malformed, for another head, or HIGH. **MEDIUM** when no HIGH rule applies and: an unresolved minor finding exists, or the diff exceeds the MEDIUM size limit, or the model judges MEDIUM. **LOW** otherwise. The final level is the maximum of the rule level and the model level; anything ambiguous, missing, conflicting or malformed is HIGH. The record carries `rubric_version`; changing a rule, a limit or the path list changes it.

Not settled here, and put to the operator in the TRD (section 11): the numeric size limits and the sensitive-path list (the repository holds no evidence from which to derive numbers, so the TRD proposes values), which reasons an operator may waive, whether an absent model judgement is HIGH or neutral, and whether the PR monitor or the webhook must be on for a project with the gate enabled. Two decisions stay with later phases: auto-merge (Phase 2) and server-run command checks.

## 7. Readiness Gate

* Completeness 5/5 — both clarification markers are resolved, the baseline is corrected against source, and every settled decision has an acceptance criterion.
* Testability 4/5 — every criterion names an observable event, typed reason, refusal or displayed value; the numeric thresholds are proposals until the operator confirms them in the TRD.
* Clarity 4/5 — the rubric is stated as inputs and rules; "advancing" is defined as the operator's `merge_approve`.
* Feasibility 4/5 — GitHub carries what REQ-001 needs (probed with `gh` 2.103.3: a check run reports `completedAt`; a status context reports `startedAt` and no completion time or creator; `gh pr view --json files` lists at most 100 files, so the rubric compares the count with the list). The first comment write and the effect preconditions P-1 and P-2 carry the risk.

**Overall 4.25/5 — PASS (was 4.0).** This phase preserves human approval for every merge.

## 8. Changelog

| Version | Date | Changes |
|---|---|---|
| 1.0.0 | 2026-11-08 | Initial draft: 5 requirements, 12 ACs; two open clarification markers (check providers and configuration, risk rubric). |
| 1.1.0 | 2026-11-12 | Both clarification markers resolved with the operator's decisions (§6): GitHub check evidence plus an operator waiver, deterministic rubric with a raise-only model judgement. Baseline corrected against source (§3): REQ-004's dependency exists and is stronger than assumed (its work is adversarial tests); "PR comment integration" does not exist; `Review.Verdict` is a separate concept; findings are free text; head-change observation is opt-in. §5 records the Phase 0 engine decision as accepted with preconditions P-1 to P-4. Six acceptance criteria added, none changed: AC-001-4 (GitHub is the only evidence source), AC-001-5 (operator waiver pinned to the head SHA), AC-001-6 (durable-store guard when enabling required checks), AC-003-4 (redaction before publishing), AC-003-5 (deterministic rubric, model can only raise), AC-005-3 (an unreadable projection is `unknown`, never clean). 18 ACs. Requirement ids and the 12 existing criteria are unchanged. |
