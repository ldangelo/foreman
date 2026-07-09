---
name: foreman-pipeline-diagnosis
description: "Use when a Foreman run appears stuck, has missing artifacts, stale projections, failed PR gates, confusing inbox/debug output, or potentially missing phase reports."
---

# Foreman Pipeline Diagnosis

## When to Use

Use this skill for stuck agents, missing reports, projection lag, status/watch/debug mismatch, PR wait/merge failures, or ambiguous run/task state.

## Diagnostic Order

1. `foreman status` or `foreman watch` for current projection state.
2. `foreman debug <task-id> --raw` when exact artifacts/logs/mail are needed before AI analysis.
3. `foreman inbox --task <task-id> --events` for lifecycle events, phase completions/retries/verdicts, Overwatch nudges, and agent-error mail.
4. `foreman server doctor` for projection lag, DB/projection/worker/VCS/provider/integration health, and metrics.
5. Use `/api/v1/runs/<run-id>/debug?view=raw` only when CLI views are insufficient and auth context is available.

## Classify Before Mutating

Classify the issue before mutating state: projection lag, hung Pi SDK session, provider rate limit, stale prompt/workflow, missing artifact, PR gate failure, merge conflict, true implementation failure, or infrastructure/runtime startup failure.

## Missing Artifact Checks

- Compare workflow `artifact` field, report directory paths from debug/report, trace warnings, and actual file existence.
- If the prompt says to write root reports, runtime prompt copies are stale; refresh with `foreman init --force` after a build or use `foreman doctor --fix` where appropriate.

## Do Not

- Do not mass retry before root cause.
- Do not treat raw logs as the source of truth when event/debug timeline exists.
- Do not manually delete active worktrees as the first recovery step.
