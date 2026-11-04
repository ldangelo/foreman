# Repository-rules review — dashboard nav Jobsite/Workflows panels

## Review engine

Reviewer: repository-rules pass against the repo-root `AGENTS.md` / `CLAUDE.md`
(no external CLI). Diff range: `git diff "main"...HEAD` (`$FOREMAN_BASE_BRANCH=main`,
confirmed set). One review pass, no fixes needed, one confirming re-read.

Carry-forward source `REVIEW_CODERABBIT_REPORT.md` is present beside this file but
carries **no** `FOREMAN_REVIEW_FINDINGS_START/END` marker block — it is a prose
summary. Its one declined, still-unresolved finding (cross-project refresh
staleness on the global nav panels) is carried forward below.

Code under review (non-report files):
- `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex`
- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`
- `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs`
- `CLAUDE.md`, `docs/user-guide.md`

## Findings

- **Error handling hides failure** — not found. `nav_workflow_runs/0` matches the
  documented `{:ok, rows} | {:error, _}` result of `OperatorDashboard.list_runs/0`
  totally (§5.2); `{:error, _}` degrades the glance panel to its empty state with
  an explanatory comment, it does not wrap an unknown value as success. Declined
  (no action).
- **Untyped/ad-hoc boundary** — not found. Workflow rows are the `RunDTO` struct
  (`@enforce_keys [:run_id, :status]`); jobsite rows are the projection's open map,
  matching the existing Projects/Schedules nav-panel idiom. Declined (no action).
- **Declared config/enum nobody reads** — not found. The one new module attribute
  `@nav_jobsite_limit 100` is read at `project_workspace_live.ex:640`
  (`Enum.take(ProjectionStore.list_jobsites(), @nav_jobsite_limit)`). Declined.
- **Documentation drift** — not found. `CLAUDE.md` and `docs/user-guide.md` are
  both updated from "four" to "six" read-only nav panels and name the two new data
  sources (`ProjectionStore.list_jobsites/0`, `OperatorDashboard.list_runs/1`). No
  new externally visible identifier (route/config key/env var/CLI verb/MCP tool) is
  introduced; the two referenced server functions pre-existed. Declined.
- **Carried forward (CodeRabbit phase, declined there):** cross-project refresh
  staleness — the new Jobsite/Workflows panels are global (not project-scoped) and
  ride the existing shared refresh path, so another project's run activity is
  reflected only on the next recompute. Real but out of this run's scope (the
  PRD/TRD deliberately reused the shared refresh path); surfaced below, not fixed.

## Fixed

None. The pass found no repository-rule violation to fix.

## Declined

- `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex:745`
  (`nav_workflow_runs/0`) — error-to-empty-state degradation: **declined**, it is a
  total, documented match on `{:ok,_}|{:error,_}` for a read-only glance panel, not
  concealed failure.
- Cross-project refresh staleness on the global nav panels — **declined** (carried
  forward): out of this run's scope per the PRD/TRD's deliberate reuse of the shared
  refresh path; recorded in the unresolved block.

## Verification

- `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors test/foreman_server_web/live/project_workspace_live_test.exs'`
  (with `DATABASE_URL`/`EVENTSTORE_URL` unset so test config uses the foreman
  Postgres) → **58 passed**, exit 0.
- `mix format --check-formatted` on the three changed source/test files → exit 0.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
- `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex:640` Minor — the Jobsite and Workflows nav panels are global (not project-scoped) and refresh only via the existing shared recompute path, so another project's run activity is reflected only on the next refresh (declined as out of scope by the PRD/TRD's deliberate reuse of that path).
<!-- FOREMAN_REVIEW_FINDINGS_END -->
