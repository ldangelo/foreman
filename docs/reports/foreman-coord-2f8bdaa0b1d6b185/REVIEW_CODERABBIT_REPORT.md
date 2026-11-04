# CodeRabbit Review — coord-2f8bdaa0b1d6b185 / run-7ae6206536548c8abc8f55727aa2a356

## Review engine

Command (worktree root, base = `$FOREMAN_BASE_BRANCH` = `main`):

```
coderabbit review --agent --base "main"
```

Exit 0, `review_completed`, 4 findings. Reviewed files: `CLAUDE.md`,
`docs/PRD/PRD-2026-7735ac9c-dashboard-jobsite-workflows-nav.md`,
`docs/TRD/TRD-2026-7735ac9c-dashboard-jobsite-workflows-nav.md`, `docs/user-guide.md`,
`lib/foreman_server_web/project_workspace_live.ex`,
`lib/foreman_server_web/workspace/components.ex`,
`test/foreman_server_web/live/project_workspace_live_test.exs`.

## Rounds

- **Round 1** — received 4 findings; fixed 2 (1 trivial test gap, 1 major unbounded jobsite
  list); declined 2 (one major + its duplicate minor: cross-project refresh staleness).
  No further `Critical`/`Major` finding remained that a fix created, so stopped early (1 of 3
  rounds used).

## Fixed

- **`test/foreman_server_web/live/project_workspace_live_test.exs`** (finding: *trivial* —
  "Assert the workflow count and status in the populated-state test", REQ-014). The populated
  Workflows-panel test asserted labels only; a regression dropping the count badge or the muted
  status would stay green. Added two assertions scoped to
  `section[aria-labelledby="nav-workflows-title"]`: the `.ws-count` badge equals `6` (five
  setup-seeded runs + the test's `r-wf`), and a `.ws-muted` row carries the run's `awaiting_worker`
  status. Both pin observable contract.

- **`lib/foreman_server_web/project_workspace_live.ex`** (finding: *major* — "Bound the Jobsite
  rows rendered in the sidebar", PRD guardrail "bounded lists (no unbounded fan-out in the
  sidebar)"). `ProjectionStore.list_jobsites/0` is unbounded, so the sidebar fanned out as
  jobsite history accumulated, while the sibling Workflows panel is already bounded (it inherits
  `OperatorDashboard`'s default limit of 100). Added `@nav_jobsite_limit 100` and changed
  `load_state/1` to `nav_jobsites: Enum.take(ProjectionStore.list_jobsites(), @nav_jobsite_limit)`.
  `list_jobsites/0` already returns newest-first, so this keeps the 100 most recent — read model
  unchanged (still reads only `list_jobsites/0`, REQ-004), count semantics now identical to the
  Workflows panel the PRD already accepted (REQ-008). The ≥2-jobsite TRD-002-TEST still sees its
  exact seeded count.

## Declined

- **`lib/foreman_server_web/project_workspace_live.ex:636` (`nav_jobsites`/`nav_workflow_runs`
  assigns)** — finding: *major* "Refresh the global panels when another project changes" **and**
  its *minor* duplicate "Refresh global panels for foreign project events." The finding is
  technically accurate: both panels read global data (`list_jobsites/0`, `list_runs/1` with no
  project filter), while `Refresh.note_event/3` → `of_project?/2` refreshes only on events of the
  open project or events with no `project_id`. `RunStarted` carries a non-nil `project_id`
  (`events/run_started.ex:8`), so a foreign project's run leaves this workspace's panels stale
  until a local event or reload. **Declined as out of this run's scope:** the governing PRD/TRD
  deliberately wired both assigns onto the *existing* shared refresh path ("mirror the proven
  existing wiring with zero new boundaries"; AC-012-1 only requires the assigns recompute *on
  refresh*), and both documents explicitly flagged modifying that shared path as the primary
  regression risk. A fix would make every open workspace refresh on every system-wide
  run/jobsite event — a cross-cutting behavior/perf change beyond this leaf UI task and not a
  stated requirement. Surfaced below for a human.

## Verification

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors \
  test/foreman_server_web/live/project_workspace_live_test.exs'
  → 58 passed, exit 0

devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted \
  lib/foreman_server_web/project_workspace_live.ex \
  test/foreman_server_web/live/project_workspace_live_test.exs'
  → exit 0
```

Documentation gate: the only identifier added is the private module attribute
`@nav_jobsite_limit` (not externally visible — no route, config key, env var, CLI verb or tool
changed). No edit to `CLAUDE.md`, `README.md`, `docs/user-guide.md` or `docs/cli-reference.md`
is required.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
- `lib/foreman_server_web/project_workspace_live.ex:636` Major — the global Jobsite/Workflows nav panels can show stale rows/counts after another project starts or finishes a jobsite or workflow run, until a local event or page reload; declined as out of this run's scope (shared-refresh-path change the PRD/TRD deferred).
<!-- FOREMAN_REVIEW_FINDINGS_END -->
