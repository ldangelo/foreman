# Foreman Recovery Handoff — 2026-04-10

## Goal
Continue the Foreman recovery effort autonomously while keeping the shipped public product boundary beads-first in the current checkout. The active recovery lane remains machine-readable CLI truthfulness: remove plausible-lie JSON/stdout/stderr contracts, surface ignored intent, and stop human-only failures from leaking into automation paths.

## Latest Handoff Update

- New concrete bug observed after the earlier lane closure: `foreman status` reports stale SDK run `bd-kf16` as a healthy `RUNNING 145h+` active agent.
- Store truth shows the run is still marked `running`, but its last recorded activity was on `2026-04-04T17:04:28.251Z` and no live process exists.
- `npx tsx src/cli/index.ts stop bd-kf16 --dry-run` confirms the current operational truth: `no pid found; would mark run as stuck without sending SIGTERM`.
- Product judgment: this should be doctor-owned repair, not manual operator cleanup.
- Start the next session from `src/cli/commands/status.ts`, `src/orchestrator/doctor.ts`, and `src/orchestrator/__tests__/doctor.test.ts`. Keep the slice bounded to stale SDK active-run rendering and doctor `--fix` reconciliation.


## Current Truth
- Current branch: `feature/bd-7w5o-product-truth-reset`
- Continue on this branch; do not reset or clean the dirty worktree.
- The worktree is heavily modified across docs, CLI, libraries, and orchestrator files. Treat it as shared state, not an isolated slice.
- Public product boundary is beads-first in this checkout.
- Do not reopen native-task public CRUD/operator surfaces.
- `foreman task` remains limited to beads-first approval plus transitional import helper behavior.

## Required Working Style
- Start every substantive turn with `todo_write` and keep exactly one task `in_progress` at a time.
- Use repo truth and observed behavior over memory or older notes if they conflict.
- Do not use destructive git commands without asking.
- Prefer focused verification: targeted Vitest file(s) plus `npx tsc --noEmit`.
- Prefer subprocess-style tests whenever stdout/stderr separation or ignored-intent signaling is part of the contract.
- Preserve additive compatibility where possible; remove fabricated or misleading output entirely when additive repair is impossible.
- Fix helper-boundary contract breaks at the helper when that is the real source of the lie.

## Recovery Work Already Completed
### Product-boundary cutover
- `src/cli/commands/task.ts` is already cut back to a bounded public surface:
  - `approveCommand`
  - `importCommand`
- No public native-task CRUD/operator surface should be restored.

### Beads-first backlog/approval model
- `src/lib/beads-rust.ts`
  - `FOREMAN_BACKLOG_LABEL = "foreman:backlog"`
  - `withBacklogLabel(...)`
  - `filterApprovedReadyIssues(...)`
  - `isParentChildDependent(...)`
  - `BeadsRustClient.create(..., { backlog?: boolean })`
  - `ready()` excludes backlog-labeled beads
  - `listBacklog()`
  - `approve(id, { recursive? })`
- `src/orchestrator/sling-executor.ts` creates Foreman-created beads with `backlog: true`
- `src/cli/commands/bead.ts` creates beads with `backlog: true`
- `src/orchestrator/dispatcher.ts` no longer force-dispatches backlog-labeled beads in specific-seed fallback
- `src/cli/commands/task.ts` exports `foreman task approve <bead-id>`

### Status/dashboard truthfulness already completed
- `src/cli/commands/status.ts`
  - aggregated `projects`, `skippedProjects`, `queueWarnings`, `summary`
  - single-project `status --json` no longer fabricates zeroes on snapshot failure
- `src/cli/commands/dashboard.ts` is backlog-bead model only
- `src/lib/priority.ts`
  - `normalizePriority(...)`
  - `formatPriorityForBr(...)`
  - `formatPriorityLabel(...)`
- `src/lib/beads-rust.ts` normalizes numeric priorities to string labels

### JSON / stream truth fixes already completed
- `monitor --json`
  - now includes `warnings: []`
  - `--recover` warning is included in JSON and still echoed to stderr
- `sentinel status --json`
  - machine-readable JSON errors for uninitialized project and outer failure path
- `worktree list --json`
  - machine-readable JSON errors on failures
- `merge --resolve --json`
  - machine-readable JSON errors for validation, missing run, conflict-state, and outer catch paths
- `sling trd --json`
  - pure JSON stdout on success
  - machine-readable JSON errors for targeting and TRD read/parse failures
- shared project targeting
  - `src/lib/project-path.ts` and `src/cli/commands/project-task-support.ts` are now JSON-aware for helper-boundary targeting failures
- `doctor --json`
  - success JSON on stdout
  - failure JSON on stderr

### Latest completed slice in this session
- `src/cli/commands/recover.ts`
  - command-status/progress text now goes to stderr, leaving stdout for raw artifact payloads and streamed AI output
  - `--raw` is now explicitly collection-only and says the recovery agent was not invoked
  - `--raw` now exits non-zero when context collection itself is degraded instead of reading like clean success
  - artifact collection now surfaces degradation warnings for missing worktree/log/test/bead/git/blocked-bead inputs instead of silently treating partial context as complete
  - if the recovery agent runs on degraded context and succeeds, recover now reports degraded completion and exits non-zero rather than printing a clean success message
  - validation failures (`--reason`, missing runs, bad `--run-id`) now return through `recoverAction()` with truthful non-zero outcomes
- `src/cli/__tests__/recover.test.ts`
  - added focused coverage for raw collection-only behavior and degraded-collection AI completion behavior

## Exact Current Verification State
Recent focused checks that passed:
- `npx vitest run src/cli/__tests__/json-output.test.ts`
- `npx vitest run src/cli/__tests__/sentinel-json-output.test.ts`
- `npx vitest run src/cli/__tests__/worktree-json-output.test.ts`
- `npx vitest run src/cli/__tests__/merge-json-resolve-errors.test.ts src/cli/__tests__/merge-json-output.test.ts`
- `npx vitest run src/cli/__tests__/sling-json-output.test.ts`
- `npx vitest run src/cli/__tests__/status-project-targeting-json.test.ts`
- `npx vitest run src/cli/__tests__/doctor-json-streams.test.ts`
- `npx vitest run src/cli/__tests__/status-project-flag.test.ts`
- `npx vitest run src/cli/__tests__/stop.test.ts`
- `npx vitest run src/cli/__tests__/retry.test.ts src/cli/__tests__/retry-project-flag.test.ts`
- `npx vitest run src/cli/__tests__/attach.test.ts src/cli/__tests__/attach-follow.test.ts`
- `npx vitest run src/cli/__tests__/mail.test.ts`
- `npx vitest run src/cli/__tests__/reset-command-contract.test.ts src/cli/__tests__/reset-project-flag.test.ts src/cli/__tests__/reset-detect-stuck.test.ts src/cli/__tests__/reset-mismatch.test.ts src/cli/__tests__/reset-br-backend.test.ts`
- `npx vitest run src/cli/__tests__/recover.test.ts`
- `npx tsc --noEmit`

## Immediate Next Slice
A new bounded truthfulness slice is now justified: stale SDK active-run honesty across `status` and `doctor`.

### Concrete evidence
- `foreman status` currently shows `bd-kf16` as `RUNNING 145h+` in finalize.
- Store truth for run `0e6063cc-ba4e-4188-b0a0-7ac626ed7883`:
  - `seed_id = bd-kf16`
  - `status = running`
  - `started_at = 2026-04-04T16:34:06.470Z`
  - `completed_at = null`
  - progress `lastActivity = 2026-04-04T17:04:28.251Z`
- No matching live process was found.
- `npx tsx src/cli/index.ts stop bd-kf16 --dry-run` reports: `no pid found; would mark run as stuck without sending SIGTERM`.

### Why this reopens the lane
The previous lane was correctly closed for already-audited stdout/stderr/JSON command contracts. This new evidence identifies a different but still bounded plausible-lie contract bug: `status` presents stale SDK run state as a healthy active agent, and `doctor` does not detect or repair it even though this is system-owned control-plane integrity work.

### Recommended bounded fix
- `src/cli/commands/status.ts`
  - stop presenting stale SDK runs as clean `RUNNING` active agents
  - surface degraded/stale state honestly when liveness evidence is missing or stale
- `src/orchestrator/doctor.ts`
  - detect stale SDK/Pi-based active runs using timeout / last-activity evidence rather than PID checks
  - `--fix` should reconcile them conservatively
- Prefer `stuck` over `failed` for repaired stale active SDK runs unless repo evidence proves an actual run failure; align with existing `stop` semantics for interrupted/dead active work rather than overstating failure

### Verification target
- Add focused tests for stale SDK run detection and repair in doctor/status surfaces
- Prefer subprocess-style coverage where stdout/stderr/exit-code behavior matters
- Run targeted Vitest file(s) plus `npx tsc --noEmit`

### Implementation handoff
#### Target files
- `src/cli/commands/status.ts`
- `src/orchestrator/doctor.ts`
- `src/orchestrator/__tests__/doctor.test.ts`
- likely a focused status test file under `src/cli/__tests__/` if current coverage does not already exercise active-agent stale rendering honestly

#### Required behavior
- `foreman status` must stop rendering stale SDK/Pi-based runs as healthy active `RUNNING` agents when repo evidence shows the run is no longer live.
- Use existing run progress / last-activity evidence and the configured stale timeout threshold rather than PID checks for SDK workers.
- `foreman doctor` must report stale active SDK runs as a warning/failure that tells the truth about the stale state instead of passing them as healthy.
- `foreman doctor --fix` must reconcile stale active SDK runs conservatively to `stuck` and record truthful completion metadata/eventing, unless the implementation finds repo evidence that `failed` is the only honest terminal state.
- Keep the public product boundary beads-first; do not reopen any native-task surfaces while making this repair.

#### Acceptance criteria
- Reproducing the stale SDK run scenario no longer shows a clean healthy `RUNNING` card in `foreman status`.
- `foreman doctor` detects the stale SDK run instead of returning `pass` for it.
- `foreman doctor --fix` moves the stale SDK run out of the active set using the chosen truthful terminal state.
- Focused Vitest coverage exists for stale SDK detection and fix behavior.
- `npx tsc --noEmit` passes.

#### Nice-to-have, only if it falls out naturally
- Reuse one shared stale-SDK detection helper between status and doctor if the same evidence calculation would otherwise be duplicated.


### If future work resumes
Start from the concrete stale-run evidence above. Do not broaden this into generic cleanup; keep the slice limited to truthful active-run rendering and doctor-owned repair for stale SDK runs.  


## Known Constraints to Preserve
- Beads remains the canonical public task backend
- Backlog is represented via `foreman:backlog`, not a fake beads status
- Dashboard stays beads-first
- `foreman task approve <bead-id>` is valid public UX
- Repo truth beats memory/docs if they disagree
- Do not update AGENT.md / CLAUDE.md unless current checkout truth itself changes

## Relevant Files Touched in This Recovery Lane
- `src/cli/commands/attach.ts`
- `src/cli/commands/doctor.ts`
- `src/cli/commands/mail.ts`
- `src/cli/commands/merge.ts`
- `src/cli/commands/monitor.ts`
- `src/cli/commands/project-task-support.ts`
- `src/cli/commands/recover.ts`
- `src/cli/commands/reset.ts`
- `src/cli/commands/retry.ts`
- `src/cli/commands/sentinel.ts`
- `src/cli/commands/sling.ts`
- `src/cli/commands/status.ts`
- `src/cli/commands/stop.ts`
- `src/cli/commands/worktree.ts`
- `src/lib/project-path.ts`
- `src/cli/__tests__/attach-follow.test.ts`
- `src/cli/__tests__/attach.test.ts`
- `src/cli/__tests__/doctor-json-streams.test.ts`
- `src/cli/__tests__/mail.test.ts`
- `src/cli/__tests__/merge-json-resolve-errors.test.ts`
- `src/cli/__tests__/merge-json-output.test.ts`
- `src/cli/__tests__/recover.test.ts`
- `src/cli/__tests__/reset-br-backend.test.ts`
- `src/cli/__tests__/reset-command-contract.test.ts`
- `src/cli/__tests__/reset-detect-stuck.test.ts`
- `src/cli/__tests__/reset-mismatch.test.ts`
- `src/cli/__tests__/reset-project-flag.test.ts`
- `src/cli/__tests__/retry-project-flag.test.ts`
- `src/cli/__tests__/retry.test.ts`
- `src/cli/__tests__/sentinel-json-output.test.ts`
- `src/cli/__tests__/sling-json-output.test.ts`
- `src/cli/__tests__/status-project-targeting-json.test.ts`
- `src/cli/__tests__/status-project-flag.test.ts`
- `src/cli/__tests__/stop.test.ts`
- `src/cli/__tests__/worktree-json-output.test.ts

## Current Git Status Reminder
This branch contains many pre-existing modified files unrelated to the next slice. Before editing, re-read the target file and avoid assumptions that only the latest changes are present.

## Session Logging Requirement
At session end, write an Obsidian session log under:
`/Users/ldangelo/Library/Mobile Documents/iCloud~md~obsidian/Documents/ldangelo/Sessions/`
and append the new session link to the relevant topic note’s Related Sessions section.
