# Fix report — workspace redesign gap fixes (coord-e992a1910e5cc00b)

## Base-branch reconciliation (read first)

The task says to base the gap fixes on the branch of PR #822
(`foreman/coord-2982ba63f6435212/run-f9e7ac6b6c65fb226c0067fc60641ee6`) — "the
delivered redesign" the reviewer scored PARTIALLY_MET.

Git archaeology of that branch:

- The reviewed "per spec" snapshot is commit `929e3997` (phase-3 review). It
  genuinely has **all four gaps** (operator bubble `var(--card)`, no
  `<nav aria-label="Project">`, thread controls rendered expanded, three run
  reports committed under `docs/reports/foreman-coord-2982ba63f6435212/`).
- `929e3997` is an **ancestor of the same branch's evolved tip** (`origin`
  `0aba667d`), which was merged to `main` as **PR #822** ("thread sidebar and
  per-thread conversation"). This run's worktree HEAD == `main` == the
  **delivered/merged redesign**.
- On the continued (merged) branch, later commits already closed three gaps:
  - Gap 2: operator bubble changed to `var(--card-2)`.
  - Gap 3: `<nav aria-label="Project">` present.
  - Gap 4: run reports dropped by commit `e8b5215a` ("chore: drop run reports
    from the delivered diff").

Basing on the stale `929e3997` instead of HEAD would **revert merged features**
(the thread sidebar, `thread_view.ex`, `Transcript.full` chunking), which
violates "keep the redesign's changes intact" and the project's surgical-change
rule. So the work was done on current HEAD — the delivered redesign — per the
task's escape clause ("if any gap is impossible as described, do the closest
correct implementation and explain"). Only **Gap 1 was still open** on the
delivered redesign; it is fixed here. Gaps 2–4 were verified already-satisfied
and left unchanged.

## 1. Root cause

- **Gap 1 (fixed).** In `ForemanServerWeb.Workspace.Components.thread_pane/1`
  (`packages/foreman_server/lib/foreman_server_web/workspace/components.ex:354`)
  the per-thread controls (`.thread-actions` + `.thread-pr-actions`) were
  rendered inside a plain `<div class="thread-controls">`, always expanded. The
  spec requires them inside a collapsed `<details>` labelled "Actions".
- **Gap 2 (already satisfied).** `.msg--operator` in `layouts.ex:123` already
  uses `background: var(--card-2)`.
- **Gap 3 (already satisfied).** `<nav class="ws-header-actions"
  aria-label="Project">` is present in `project_workspace_live.ex:830`.
- **Gap 4 (already satisfied).** No `docs/reports/` files are part of the
  delivered diff; none are tracked for the redesign branches, and this run does
  not add any to the committed diff.

## 2. Change

- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex` —
  wrapped the thread controls in `<details class="thread-controls-details"
  id="thread-controls-<thread_id>">` with `<summary>Actions</summary>`,
  collapsed by default; `phx-mounted={JS.ignore_attributes("open")}` preserves
  client open-state across LiveView refreshes (same pattern as the redesign's
  other collapsibles). The inner `.thread-controls` flex container and both
  control groups are unchanged.
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex` — two
  CSS lines in the single inline `<style>`: muted summary text and an 8px top
  margin on the controls when the details is open. No new tokens/colours.
- `packages/foreman_server/test/foreman_server_web/live/project_workspace_pr_actions_live_test.exs`
  — added a regression test asserting the controls live inside a collapsed
  `details#thread-controls-run:<id>` whose `<summary>` reads "Actions" and which
  contains the PR-action button.

No change was made for gaps 2–4 (already satisfied in the delivered redesign).

## 3. Tests

- **Failing-before / passing-after:** new test
  "the thread controls live inside a collapsed \"Actions\" details" in
  `project_workspace_pr_actions_live_test.exs`. It fails on the pre-fix markup
  (no `details#thread-controls-*` element) and passes after the fix.

## 4. Local verification

- `mix format` + `mix format --check-formatted` on the three changed files →
  **exit 0** (no formatting churn).
- `MIX_ENV=test mix test --warnings-as-errors` on the five affected LiveView
  test files (pr_actions, threads, approvals, attention, project_workspace_live)
  → **113 passed**, exit 0. Run with `DATABASE_URL`/`EVENTSTORE_URL` unset so
  the suite uses the foreman test Postgres on :55432.
- Doc gate: no externally visible identifier changed (routes, config keys, env
  vars, CLI verbs, MCP tools, command/event types, workflow/prompt names). The
  only new identifiers are the CSS class `thread-controls-details` and the DOM
  id `thread-controls-<thread_id>` — neither is a doc-gate category. `grep` of
  `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` for
  them → no hits. No doc edits needed.

## 5. Follow-ups

- **PR / commit:** the detailed Task Prompt asked to "open ONE pull request",
  but the governing `fix` workflow mission and the project invariant state that
  Foreman owns this worktree/branch — do not commit, push, or open a PR; Foreman
  commits the phase and opens the PR after review. Changes are left uncommitted
  per that invariant. This report is written under `docs/reports/` and must NOT
  be committed/staged (gap 4).
- Gaps 2–4 required no code change on the delivered redesign; if the operator
  instead intended to resurrect and ship the stale `929e3997` "per spec"
  redesign (discarding the merged thread-sidebar work), that is a different,
  destructive task and was not done — flag for operator decision.
