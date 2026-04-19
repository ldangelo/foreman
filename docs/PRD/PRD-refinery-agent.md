# PRD: Refinery Agent — Replace Refinery Script with Agentic Pipeline

**Status:** Draft
**Epic:** foreman-20707
**Created:** 2026-04-18

---

## Product Summary

**Problem:** The existing refinery script (refinery.ts + conflict-resolver.ts + merge-strategy-routing.ts + merge-queue.ts + auto-merge.ts, ~1500 lines) succeeds less than 5% of the time. It is effectively non-functional. When it fails, it blocks the merge queue and requires manual intervention for every PR.

**Solution:** Replace the entire refinery script with an agent that has the same tools a human developer uses: Read, Bash, Edit, Write, git, and gh. The agent reads the queue, processes each PR entry end-to-end, and either merges it or escalates it. Exactly what we just did manually to fix PR #124 — but continuous and automated.

**Value Proposition:** The merge queue becomes reliable. Operators stop babysitting PRs. The 95% failure rate becomes a 95% success rate.

---

## User Analysis

### Primary Users

| User | Current Pain | After |
|------|-------------|-------|
| Foreman operator | Manually watching refinery failures, pushing fixes to PR branches, babysitting merges | Agent handles end-to-end; operator only notified for real escalations |
| On-call engineer | Refinery blocks releases because it can't self-heal | Agent fixes what breaks; real regressions escalate clearly |
| PR author | Waiting days for manual merge after CI passes | Agent merges within minutes of CI passing |

### Current Workflow

```
run dispatches task → worktree PR created → CI runs → queue entry created →
refinery attempts merge → fails → operator notified → operator manually fixes →
operator retries or creates manual PR → days pass
```

### Target Workflow

```
run dispatches task → worktree PR created → CI runs → queue entry created →
agent picks up entry → agent reads diff → agent fixes issues → agent builds/tests →
agent merges or escalates → operator only notified for real failures
```

---

## Goals & Non-Goals

### Goals

1. **Replace the refinery script entirely** with an agent that can read, fix, build, test, push, and merge
2. **Achieve 90%+ success rate** on queue entries reaching a terminal state (merged or escalated) within 30 minutes
3. **Self-heal common failures:** type errors, missing imports, wiring gaps, stale branches
4. **Escalate correctly:** when a PR truly can't be auto-merged, create a clear manual PR and notify the operator
5. **No operator babysitting:** the queue runs continuously without human intervention

### Non-Goals

1. **Do not change the queue system.** The merge-queue remains the trigger and source of truth. Only the executor changes.
2. **Do not add features to the merge pipeline.** This is a rewrite, not an upgrade.
3. **Do not break existing PR workflows.** Existing PRs in flight continue working.
4. **Do not make the agent do code review.** It only fixes mechanical/structural issues (type errors, wiring gaps, missing imports). Semantic decisions stay with humans.
5. **Do not replace `foreman run`.** The agent replaces the refinery, not the task dispatcher.

---

## Functional Requirements

### FR-1: Agent Worker Replaces Refinery Script

The `refinery-agent` worker is a pi-agent that owns the full queue processing loop:

1. Poll the merge queue at a configurable interval (default: 60s)
2. For each `pending` entry, read the PR diff via `gh pr diff`
3. Run `npm run build` to catch type errors
4. Run `npm run test` to catch test failures
5. If build or tests fail:
   - Read the error output
   - Identify the fix (missing import, type error, wiring gap, etc.)
   - Apply the fix via `edit` or `write`
   - Commit and push to the PR branch
   - Re-run build/tests
   - If still failing after 2 iterations, escalate
6. If build and tests pass, run `gh pr merge`
7. If merge has conflicts, attempt `git rebase` with `gh pr checkout` + `git rebase main`
8. If rebase succeeds, force-push and merge
9. If rebase fails, create a manual PR with clear conflict resolution instructions and mark the queue entry as `escalated`
10. Update queue entry status after each action

### FR-2: Agent Reads PR State

The agent reads the PR in context before acting:

- `gh pr view` for title, body, author, labels, status checks
- `gh pr diff` for the actual code changes
- `gh api repos/{owner}/{repo}/commits/{sha}/status` for CI status
- `gh api repos/{owner}/{repo}/pulls/{number}/files` for file list

This gives the agent enough context to make decisions without being in the worktree.

### FR-3: Agent Fixes Common Mechanical Failures

The agent knows how to fix the most common refinery failures:

| Failure Mode | Agent Fix |
|---|---|
| `as never` type casts | Remove cast, add proper type to EventType union |
| Missing EventType values | Add missing values to store.ts EventType union |
| Unwired imports | Read module, find call sites, add import + call |
| Missing `npm install` | Run `npm install` before build |
| Stale branch | `git fetch origin main && git rebase origin/main` |
| `.beads/issues.jsonl` conflict | `git stash` before merge, `git stash pop` after |
| Untracked file conflict | Move conflicting file, merge, restore |

### FR-4: Configurable Fix Budget

Each queue entry has a configurable fix budget (default: 2 iterations):

```
MAX_FIX_ITERATIONS=2
```

After exhausting the budget, the agent:
1. Creates a manual PR with a clear description of what was tried and what failed
2. Marks the queue entry as `escalated`
3. Notifies the operator via the existing notification channel

### FR-5: Deterministic Merge Ordering

The agent respects the merge queue's ordering:
- Processes entries in FIFO order (oldest first)
- One entry at a time (no parallel processing)
- If an entry depends on another entry's PR, waits for the dependency to merge first

### FR-6: Self-Documenting Actions

The agent writes a log of all actions taken:

```
docs/reports/{queue-entry-id}/AGENT_LOG.md

## Actions
- 12:01:03 Read PR diff for foreman-0bd47
- 12:01:15 npm run build → FAILED (TypeScript errors in guardrails.ts)
- 12:01:22 Fixed as never casts in heartbeat-manager.ts
- 12:01:31 npm run build → PASSED
- 12:01:40 npm run test → PASSED (3099 tests)
- 12:01:45 gh pr merge --squash foreman-0bd47 → SUCCESS
```

This log is committed alongside any fixes so the git history shows what the agent did and why.

### FR-7: Minimal Code Replacement

The replacement must be lean:

| Old File | Fate |
|---|---|
| `src/orchestrator/refinery.ts` | Replaced by agent worker |
| `src/orchestrator/conflict-resolver.ts` | Replaced by agent |
| `src/orchestrator/merge-strategy-routing.ts` | Replaced by agent |
| `src/orchestrator/merge-queue.ts` | Kept — queue trigger + source of truth |
| `src/orchestrator/auto-merge.ts` | Replaced by agent |
| `src/lib/store.ts` | Kept — queue still writes events |
| Queue entries in SQLite | Kept — agent reads and writes |

Target: ~50 lines of agent worker code replacing ~1500 lines of script.

---

## Non-Functional Requirements

### Performance

- Queue entry processing: < 30 minutes to terminal state (merged or escalated)
- Build + test verification: < 5 minutes per iteration
- Fix iteration: < 2 minutes (agent applies fix, commits, pushes)

### Reliability

- 90%+ of queue entries reach a terminal state without human intervention
- False escalation rate (agent gives up on mergeable PRs): < 5%
- Agent never force-pushes to main or shared branches

### Cost

- Agent model: MiniMax Haiku (cheapest capable model)
- Estimated cost per queue entry: < $0.10 (build + 2 fix iterations + merge)
- Cost is acceptable: current manual operator time costs far more

### Observability

- Every action logged to AGENT_LOG.md in queue entry reports dir
- Queue entry status updates written to SQLite after each action
- Operator notification only on escalation (not on every fix)

### Security

- Agent only operates on PR branches in the `foreman/` namespace
- Agent never pushes to main or shared feature branches
- Agent credentials scoped to repo (gh auth)

---

## Acceptance Criteria

### AC-1: Agent processes a failing queue entry end-to-end

Given a queue entry with a PR that has type errors,
when the agent picks up the entry,
then the agent reads the error, applies fixes, commits, pushes, verifies build+tests pass, and merges.

**Test:** Create a PR with a deliberate type error. Add to queue. Verify agent fixes it and merges.

### AC-2: Agent escalates correctly

Given a queue entry with a PR that requires semantic conflict resolution,
when the agent exhausts its fix budget without resolving the conflict,
then the agent creates a manual PR with clear instructions and marks the queue entry as `escalated`.

**Test:** Create a PR with an unresolvable conflict. Add to queue. Verify agent escalates with a clear manual PR.

### AC-3: Agent doesn't break working PRs

Given a queue entry with a PR that builds and tests pass,
when the agent picks up the entry,
then the agent merges it without modification.

**Test:** Create a clean PR (no errors). Add to queue. Verify agent merges without changes.

### AC-4: Agent self-heals the PR we just fixed

Given PR #124 (guardrails wiring),
when the agent processes its queue entry,
then the agent identifies the missing EventType values, wires the modules, builds, tests, and merges — all automatically.

**Test:** Add PR #124 to the queue. Verify agent processes it end-to-end without human help.

### AC-5: Queue runs continuously

Given the agent is running,
when new queue entries are added,
then the agent picks them up within the poll interval and processes them.

**Test:** Add 3 queue entries in sequence. Verify all 3 are processed.

### AC-6: No force-push to main

Given the agent is running,
whenever the agent pushes,
then the push target is always a feature branch (not main or shared branches).

**Test:** Audit all `git push` calls in agent worker. Verify none target main.

---

## Implementation Notes

### Agent Session Architecture

The agent runs in a separate pi-agent session from `foreman run`:

```
main session: foreman run → dispatches task → creates PR → creates queue entry
agent session: refinery-agent worker → polls queue → processes entries
```

Communication: both sessions read/write the same SQLite DB (`.foreman/foreman.db`) and use `gh` for PR operations.

### Agent Prompt

The agent prompt is intentionally minimal:

```
You are the Foreman Refinery Agent. Your job is to process merge queue entries
and either merge PRs or escalate them.

For each queue entry:
1. Read the PR diff (gh pr diff)
2. Build (npm run build)
3. Test (npm run test)
4. Fix what breaks (edit/write)
5. Commit + push
6. Merge (gh pr merge)
7. On failure: escalate with clear manual PR

Working directory: {queue_entry.worktree_path}
PR branch: foreman/{seed_id}
Target: main

Log all actions to docs/reports/{seed_id}/AGENT_LOG.md
```

### Migration Path

1. Deploy agent alongside existing refinery (behind a feature flag)
2. Pilot on a subset of queue entries
3. Compare success rate to existing refinery
4. Once agent success rate > 90%, flip the flag: agent handles all entries
5. Delete old refinery code

### Rollback

If the agent fails catastrophically, set `REFINERY_AGENT_ENABLED=false` in `.foreman/foreman.env` and the queue stops processing. No queue entries are lost — they remain in `pending` status until the agent (or the old refinery) picks them up.

---

## Appendix: What the Agent Replaces

```
src/orchestrator/refinery.ts             (~400 lines) → agent
src/orchestrator/conflict-resolver.ts    (~300 lines) → agent
src/orchestrator/merge-strategy-routing.ts (~250 lines) → agent
src/orchestrator/auto-merge.ts           (~400 lines) → agent
src/orchestrator/merge-queue.ts          (~150 lines) → KEPT
─────────────────────────────────────────────────────────────────
Total removed:                           ~1350 lines
Total added:                             ~50 lines of agent config + prompts
```

The merge-queue is kept because it owns the queue data model and scheduling. The agent is the executor, not the scheduler.
