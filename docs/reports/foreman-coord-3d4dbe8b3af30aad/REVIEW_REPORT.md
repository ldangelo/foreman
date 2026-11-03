# Repository-rules review

## Review engine

Reviewer: built-in repository-rules pass against `AGENTS.md` (Foreman agent
context) and the codebase's own Elixir/Phoenix idioms.

Diff range: `git diff main...HEAD` (`$FOREMAN_BASE_BRANCH=main`, set and
non-empty).

Range content: two new files only —
`docs/reports/foreman-coord-3d4dbe8b3af30aad/FIX_REPORT.md` and
`docs/reports/foreman-coord-3d4dbe8b3af30aad/REVIEW_CODERABBIT_REPORT.md`.
No `.ex`/`.exs`/config/workflow/CLI source changed. The side-panels feature
the task describes was already merged in PR #818 (`8630c9f3`), which is an
ancestor of both `main` and HEAD (`git merge-base --is-ancestor 8630c9f3 main`
→ true), so the implementation phase correctly produced no code delta.

## Findings

Carry-forward: the previous phase's `REVIEW_CODERABBIT_REPORT.md` is present.
It has no `FOREMAN_REVIEW_FINDINGS_START`/`END` markers and records an empty
unresolved-findings block — nothing to carry forward.

New findings this phase: none. The diff contains only point-in-time Markdown
reports; the repository-rules checks (error handling that hides failures,
typed/structured boundary consistency, declared-but-unread config/enum,
documentation reconciliation) apply to code and have no target here.

## Fixed

None — no code to change.

## Declined

- `docs/reports/foreman-coord-3d4dbe8b3af30aad/REVIEW_CODERABBIT_REPORT.md:9`
  — file ends without a trailing newline (MD047). Declined: it is a
  point-in-time report, not repository source, with no behavioral impact, and
  `AGENTS.md` explicitly excludes `docs/reports/*` from the documentation gate;
  editing a sibling phase's artifact is outside this run's scope.

## Verification

- `git diff main...HEAD --name-only` → exit 0 (only the two report files).
- `git merge-base --is-ancestor 8630c9f3 main` → exit 0 (feature already in base).
- No `.ex`/`.exs` changed in range → no `mix test` / `mix format` applies.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
<!-- FOREMAN_REVIEW_FINDINGS_END -->
