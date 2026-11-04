---
Document ID: PRD-2026-7735ac9c
Label: prd-dashboard-jobsite-workflows-nav
Version: 1.0.1
Status: Draft
Date: 2026-11-04
Scale Depth: STANDARD
Total Requirements: 15
Readiness Score: 4.4 (PASS)
---

# PRD: Dashboard nav — add Jobsite and Workflows run profiles

> Subject (FOREMAN_TASK_TITLE): **Dashboard nav: add Jobsite and Workflows run profiles**
>
> Operator request (verbatim): "In addition to projects the dashboard should show
> jobsite runs as well as workflow runs. Underneath projects add jobsite and then
> workflows, wire in their respective run profiles into the dashboard."
>
> Mode: generated under `--foreman` (STANDARD depth auto-selected; no interview run;
> assumptions noted inline and unresolved items marked `[NEEDS CLARIFICATION: ...]`).

## PRD Health

- Requirements by priority: Must (11), Should (3), Could (0), Won't (1)
- AC coverage: 15/15 requirements have acceptance criteria (100%)
- Risk flags: 5 requirements flagged
- Cross-requirement dependencies: 8

## Problem & Context

The Foreman workspace left-navigation sidebar
(`ForemanServerWeb.Workspace.Components.workspace_nav/1`,
`packages/foreman_server/lib/foreman_server_web/workspace/components.ex:210`)
currently renders four read-only panels: **Search**, **Projects**, **Artifacts**,
**Schedules**. An operator orienting in the dashboard can see projects but not the
two other first-class run surfaces the server already projects: **jobsite runs** and
**workflow runs**. Today they must leave the workspace (e.g. the operator run
dashboard at `/dashboard/runs`) to see run activity.

**Who feels the pain:** the operator using the project workspace as their home view,
who wants run visibility alongside projects without navigating away.

**Why existing solutions fall short:** the Projects panel only lists projects; the
Operator Run Dashboard (`OperatorRunDashboardLive`, `/dashboard/runs`) is a separate
page, not part of the sidebar's at-a-glance nav. No sidebar panel surfaces jobsite or
workflow run data.

## Goal & Success

Add two read-only sidebar panels — **Jobsite** then **Workflows** — directly
underneath the **Projects** panel (final order: Search, Projects, Jobsite, Workflows,
Artifacts, Schedules), each sourced from the server's already-exposed run queries, so
an operator sees jobsite runs and workflow runs at a glance inside the workspace nav.

Success looks like: both panels render with live counts and row lists following the
existing `ws-panel` convention; tests cover populated and empty states; no new
command, event, route, or data path is introduced.

**Resolved (refine, `--foreman`):** "dashboard navigation" is the workspace left-nav
sidebar (`workspace_nav/1`) — the panelized navigation that already holds the Projects
entry the operator request anchors on ("underneath projects add jobsite and then
workflows"). The standalone Operator Run Dashboard (`/dashboard/runs`) is explicitly
not the target of this change.

## Research & Reuse (read-only server data already exposed)

The two "run profiles" referenced by the operator map to existing read-only
projection queries — reuse them; do **not** add a parallel data path, command, or
event (AGENTS.md: read-only panels use data the server already exposes).

- **Jobsite runs** → `ForemanServer.ProjectionStore.list_jobsites/0`
  (`packages/foreman_server/lib/foreman_server/projection_store.ex:383`): "Return every
  projected jobsite, newest-started-first", sorted by `started_at_ms` descending. Each
  jobsite is a map with at least `status` and `started_at_ms` keys (per the projection
  at `projection_store.ex:2547`+ — `workflow_name`, `status`, `started_at_ms`).
- **Workflow runs** → `ForemanServer.ProjectionStore.list_runs/1`
  (`packages/foreman_server/lib/foreman_server/projection_store.ex:1073`), surfaced to
  the web layer today via `ForemanServerWeb.OperatorDashboard.list_runs/1`
  (`operator_dashboard.ex:60`), which already applies bounded filters. Run rows carry a
  `workflow` name and `status`.
- **Existing nav wiring to mirror:** `ProjectWorkspaceLive` computes nav assigns on
  refresh (`project_workspace_live.ex:616`–`634`: `library_entries`, `nav_schedules`,
  `projects` via `ProjectStore.list/0` at `:746`) and passes them to `workspace_nav`
  (`project_workspace_live.ex:862`). The two new assigns plug in the same way.
- **CSS:** reuse existing sidebar classes (`ws-panel`, `ws-panel-head`, `ws-count`,
  `ws-panel-list`, `ws-muted`, `ws-ellipsis`, `ws-clamp-1`) defined in the root layout
  `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex`. There is no
  asset pipeline; any new CSS goes in that root layout only.

**Technical constraints:** read-only (no new command/event/route/config/env/CLI verb/
MCP tool); bounded lists (no unbounded fan-out in the sidebar); follow the existing
`ws-panel` markup and the panel ordering rule; tests run under
`MIX_ENV=test ... --warnings-as-errors`.

## Requirements

### Navigation structure

### REQ-001: Add a "Jobsite" nav panel directly under Projects
**Priority:** Must · **Complexity:** Low

A new `ws-panel` section titled "Jobsite" renders in the workspace nav immediately
after the Projects panel and before the Workflows panel.

- AC-001-1: Given the workspace nav renders, when the DOM is inspected, then a panel
  labelled "Jobsite" appears after the "Projects" panel and before the "Workflows" panel.
- AC-001-2: Given the nav order, then the full panel order is Search, Projects,
  Jobsite, Workflows, Artifacts, Schedules.

### REQ-002: Add a "Workflows" nav panel directly under Jobsite
**Priority:** Must · **Complexity:** Low

A new `ws-panel` section titled "Workflows" renders in the workspace nav immediately
after the Jobsite panel.

- AC-002-1: Given the workspace nav renders, when the DOM is inspected, then a panel
  labelled "Workflows" appears immediately after the "Jobsite" panel.
- AC-002-2: Given the Artifacts and Schedules panels, then they still render after
  Workflows, unchanged.

### REQ-003: Preserve the existing Projects panel unchanged
**Priority:** Must · **Complexity:** Low · Depends on: none

The existing Projects panel keeps its current label, count, list markup, and link
behavior.

- AC-003-1: Given the Projects panel, when rendered, then its heading, count badge, and
  per-project links are byte-for-byte the same as before this change (only new sibling
  panels are added).
- AC-003-2: Given an existing workspace nav test, when re-run, then it still passes.

### Jobsite run profile (data source)

### REQ-004: Jobsite panel lists jobsite runs from the existing projection
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-001

The Jobsite panel's data source is `ProjectionStore.list_jobsites/0` (reused as-is);
no new query or command is introduced. [RISK: must not add a command/event for display.]

- AC-004-1: Given jobsite projections exist, when the nav renders, then each jobsite run
  appears as a list row in the Jobsite panel.
- AC-004-2: Given the panel builds its list, when the data path is inspected, then it
  reads only `ProjectionStore.list_jobsites/0` (or an existing read-only facade over it)
  and defines no new command, event, or route.

### REQ-005: Jobsite panel shows a count and preserves newest-first order
**Priority:** Must · **Complexity:** Low · Depends on: REQ-004

The Jobsite panel shows a `ws-count` badge equal to the number of jobsite runs and
renders rows in the projection's newest-started-first order.

- AC-005-1: Given N jobsite runs, when the nav renders, then the Jobsite count badge
  reads N.
- AC-005-2: Given multiple jobsite runs with different `started_at_ms`, when listed,
  then the newest-started run appears first (the order `list_jobsites/0` already returns).

### REQ-006: Jobsite panel empty state
**Priority:** Should · **Complexity:** Low · Depends on: REQ-004

When there are no jobsite runs, the panel shows a muted empty message, matching the
Schedules/Projects empty-state convention (`ws-muted`).

- AC-006-1: Given zero jobsite runs, when the nav renders, then the Jobsite panel shows a
  `ws-muted` "No jobsite runs." message and no list.

### Workflow run profile (data source)

### REQ-007: Workflows panel lists workflow runs from the existing projection
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-002

The Workflows panel's data source is the existing workflow-run query
(`ProjectionStore.list_runs/1`, via `OperatorDashboard.list_runs/1`); no new query or
command is introduced. [RISK: must not add a command/event for display.]

- AC-007-1: Given workflow runs exist, when the nav renders, then each workflow run
  appears as a list row in the Workflows panel.
- AC-007-2: Given the panel builds its list, when the data path is inspected, then it
  reads only the existing run-list query/facade and defines no new command, event, or route.

### REQ-008: Workflows panel shows a count and a bounded list
**Priority:** Must · **Complexity:** Low · Depends on: REQ-007

The Workflows panel shows a `ws-count` badge and renders a bounded number of rows (the
sidebar is a glance surface, not the full run dashboard).

- AC-008-1: Given N workflow runs, when the nav renders, then the Workflows count badge
  reflects the run count.
- AC-008-2: Given many workflow runs, when listed, then the sidebar applies the same
  bound the existing run-list query exposes (no unbounded fan-out in the nav).
  **Resolved (refine, `--foreman`):** the sidebar reuses the existing bounded
  `list_runs/1` default and shows all rows that query returns; it introduces no new,
  sidebar-specific row cap. If `list_runs/1` grows a smaller default later, the sidebar
  inherits it automatically.)

### REQ-009: Workflows panel shows workflow identity per row
**Priority:** Should · **Complexity:** Low · Depends on: REQ-007

Each Workflows row shows a human-identifiable label for the run (its workflow name and/
or status), following the Schedules row pattern (`strong` + muted detail).

- AC-009-1: Given a workflow run with a `workflow` name, when rendered, then the row
  shows that workflow name as its primary label.
- AC-009-2: Given a workflow run with a status, when rendered, then the status is shown
  as muted secondary text (consistent with the Schedules row's `ws-muted` detail).

### REQ-010: Workflows panel empty state
**Priority:** Should · **Complexity:** Low · Depends on: REQ-007

When there are no workflow runs, the panel shows a muted empty message.

- AC-010-1: Given zero workflow runs, when the nav renders, then the Workflows panel
  shows a `ws-muted` "No workflow runs." message and no list.

### Styling, wiring & non-functional

### REQ-011: Reuse existing sidebar CSS and the root-layout stylesheet
**Priority:** Must · **Complexity:** Low · Depends on: REQ-001, REQ-002

Both panels reuse the existing `ws-panel*` class set. Any new CSS is added only to the
workspace root layout (`workspace/layouts.ex`); no new asset-pipeline file is created.

- AC-011-1: Given the two new panels, when their markup is inspected, then they use the
  existing `ws-panel`, `ws-panel-head`, `ws-count`, `ws-panel-list`, `ws-muted` classes.
- AC-011-2: Given the change set, when the diff is inspected, then no `app.js`/`app.css`
  or other asset-pipeline file is introduced; any new rule lives in `layouts.ex`.

### REQ-012: Wire the two assigns through ProjectWorkspaceLive like the existing panels
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-004, REQ-007

`ProjectWorkspaceLive` computes the jobsite-run and workflow-run assigns on the same
refresh path that produces `projects`/`nav_schedules`/`library_entries`, and passes them
into `workspace_nav/1`, mirroring the existing wiring.
[RISK: wiring the new assigns onto the shared refresh path could regress the existing
`projects`/`nav_schedules`/`library_entries` assigns if the pattern is not mirrored exactly.]

- AC-012-1: Given a mounted workspace, when it refreshes, then the jobsite-run and
  workflow-run assigns are populated from the read-only queries and handed to
  `workspace_nav`.
- AC-012-2: Given the refresh path, when inspected, then the new assigns follow the same
  pattern as `nav_schedules`/`library_entries` (no new process, timer, or data channel).

### REQ-013: Read-only — no new externally visible identifiers for display
**Priority:** Must · **Complexity:** Low · Depends on: REQ-004, REQ-007

The change introduces no new HTTP route, command/event type, config key, env var, CLI
verb, or MCP tool purely for display. [RISK: AGENTS.md forbids adding commands/events
for read-only panels.]

- AC-013-1: Given the diff, when grepped, then no new route is added to `router.ex`.
- AC-013-2: Given the diff, when reviewed, then no new command/event struct, config key,
  env var, CLI verb, or `foreman_*` MCP tool is added.

### REQ-014: Tests cover populated and empty states for both panels
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-004, REQ-007, REQ-006, REQ-010

Tests follow the existing workspace LiveView test conventions
(`test/foreman_server_web/live/project_workspace_live_test.exs`) and assert the
presence, ordering, counts, and empty states of the Jobsite and Workflows panels.
[RISK: order/count assertions can be flaky if seeded runs do not have deterministic
`started_at_ms`; seed with explicit, distinct timestamps so newest-first order is stable.]

- AC-014-1: Given seeded jobsite and workflow runs, when the workspace nav is rendered in
  a test, then assertions confirm both panels appear in order with correct counts/rows.
- AC-014-2: Given no runs, when rendered in a test, then both panels show their empty-state
  messages.
- AC-014-3: Given the narrowest affected test file(s), when run with
  `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors ...'`,
  then the suite passes with zero warnings.

### Out of scope

### REQ-015: No run actions, detail pages, or filtering in the sidebar panels
**Priority:** Won't (this release) · **Complexity:** Low

The two new panels are glance-only lists. Run actions (pause/resume/abandon/reset),
per-run detail navigation, status filters, and live tabs remain the responsibility of the
existing Operator Run Dashboard and are not added to the sidebar.

- AC-015-1: Given the two new panels, when inspected, then they expose no action buttons,
  filters, or run-detail links beyond a plain glance list.

## Dependency Map

| REQ | Depends On | Notes |
| --- | --- | --- |
| REQ-004 | REQ-001 | Jobsite panel must exist before it can list data |
| REQ-005, REQ-006 | REQ-004 | Count/order and empty state extend the jobsite list |
| REQ-007 | REQ-002 | Workflows panel must exist before it can list data |
| REQ-008, REQ-009, REQ-010 | REQ-007 | Count/row/empty state extend the workflow list |
| REQ-011 | REQ-001, REQ-002 | Styling applies to both new panels |
| REQ-012 | REQ-004, REQ-007 | Wiring depends on both data sources being chosen |
| REQ-013 | REQ-004, REQ-007 | Read-only guarantee spans both data paths |
| REQ-014 | REQ-004, REQ-006, REQ-007, REQ-010 | Tests cover both panels' populated + empty states |

Clusters to implement together: (REQ-001, REQ-004, REQ-005, REQ-006) jobsite panel;
(REQ-002, REQ-007, REQ-008, REQ-009, REQ-010) workflows panel; (REQ-011, REQ-012,
REQ-013) shared wiring/styling/read-only guarantees; (REQ-014) tests. No circular
dependencies.

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
| --- | --- | --- | --- | --- |
| REQ-001 | Jobsite panel under Projects | Must | Low | 2 |
| REQ-002 | Workflows panel under Jobsite | Must | Low | 2 |
| REQ-003 | Projects panel unchanged | Must | Low | 2 |
| REQ-004 | Jobsite data = list_jobsites/0 | Must | Medium | 2 |
| REQ-005 | Jobsite count + newest-first | Must | Low | 2 |
| REQ-006 | Jobsite empty state | Should | Low | 1 |
| REQ-007 | Workflows data = list_runs/1 | Must | Medium | 2 |
| REQ-008 | Workflows count + bounded list | Must | Low | 2 |
| REQ-009 | Workflows row identity | Should | Low | 2 |
| REQ-010 | Workflows empty state | Should | Low | 1 |
| REQ-011 | Reuse sidebar CSS / root layout | Must | Low | 2 |
| REQ-012 | Wire assigns via ProjectWorkspaceLive | Must | Medium | 2 |
| REQ-013 | No new display-only identifiers | Must | Low | 2 |
| REQ-014 | Tests for both panels | Must | Medium | 3 |
| REQ-015 | No actions/detail in sidebar (out of scope) | Won't | Low | 1 |

## Adversarial Review (self-critique, auto-resolved under --foreman)

1. **Ambiguity — "dashboard":** could mean the sidebar nav or the standalone Operator
   Run Dashboard. Resolved (refine, `--foreman`) to the sidebar nav (it holds the
   Projects entry the request anchors on); the Goal-section marker is now closed.
2. **Risk — parallel data path:** a naive implementation might add a new query/command.
   Resolved by REQ-004/REQ-007/REQ-013 pinning the data source to existing read-only
   projections and forbidding new identifiers.
3. **Missing edge case — empty states:** without them the panels render blank. Added
   REQ-006 and REQ-010.
4. **Testability — ordering:** "underneath projects" is only verifiable if ordering is an
   explicit AC. Added AC-001-2 and AC-002-1 asserting panel order.
5. **Unbounded list risk:** the workflow-run list could be large. REQ-008 constrains it to
   the existing bounded query; resolved (refine, `--foreman`) to reuse the `list_runs/1`
   default with no sidebar-specific cap.
6. **Scope creep:** run actions/detail could leak in. REQ-015 fences them out explicitly.

## Implementation Readiness Gate

| Dimension | Score | Notes |
| --- | --- | --- |
| Completeness | 4.5 | Both panels, data sources, ordering, empty states, wiring, tests, and dependency map complete |
| Testability | 4 | Every Must/Should requirement has verifiable ACs; order/counts assertable |
| Clarity | 4.5 | Exact modules/functions/line anchors named; both `[NEEDS CLARIFICATION]` markers now resolved |
| Feasibility | 4.5 | Pure reuse of exposed read-only queries + existing CSS; no new infrastructure |

**Overall: 4.1 → 4.4 (improved) → PASS.** Both inline `[NEEDS CLARIFICATION]` markers
(meaning of "dashboard", sidebar row cap for workflow runs) are resolved in this refine
pass; no clarification markers remain.

## Suggested Next Step

`/ensemble-create-trd docs/PRD/PRD-2026-7735ac9c-dashboard-jobsite-workflows-nav.md`

## Changelog

### 2026-11-04 — v1.0.1 (refine, `--foreman`)

- Resolved both `[NEEDS CLARIFICATION]` markers: "dashboard navigation" scoped to the
  workspace left-nav sidebar (`workspace_nav/1`), not the standalone Operator Run
  Dashboard; workflow-run list reuses the existing bounded `list_runs/1` default with
  no sidebar-specific row cap.
- Corrected the frontmatter requirement count (14 → 15) and the PRD Health summary
  priority split (Must 9→11, Could 2→0) and AC coverage (14/14 → 15/15) to match the
  15 requirements actually present.
- Added the missing REQ-013 row to the Dependency Map and refreshed the dependency
  count (6 → 8).
- Added risk indicators to the two Medium-complexity requirements that lacked them
  (REQ-012 wiring regression, REQ-014 ordering flakiness); risk-flag count 3 → 5.
- Re-scored the Implementation Readiness Gate: Completeness 4→4.5, Clarity 4→4.5;
  overall 4.1 → 4.4 (improved, PASS).
