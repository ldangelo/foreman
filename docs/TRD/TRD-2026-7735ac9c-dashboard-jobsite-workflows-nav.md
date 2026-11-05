---
Document ID: TRD-2026-7735ac9c
Label: trd-dashboard-jobsite-workflows-nav
PRD: PRD-2026-7735ac9c (docs/PRD/PRD-2026-7735ac9c-dashboard-jobsite-workflows-nav.md)
Version: 1.0.1
Status: Draft
Date: 2026-11-04
Design Readiness Score: 4.4 (PASS)
kind: trd
---

# TRD: Dashboard nav — add Jobsite and Workflows run profiles

> Subject (FOREMAN_TASK_TITLE): **Dashboard nav: add Jobsite and Workflows run profiles**
>
> Source PRD: `docs/PRD/PRD-2026-7735ac9c-dashboard-jobsite-workflows-nav.md`
> (label `prd-dashboard-jobsite-workflows-nav`, readiness 4.4 PASS). Subject confirmed
> to match the dispatched task title before this TRD was written.
>
> Mode: generated under `--foreman` (architecture Option C auto-selected; CONCERNS-band
> prompts auto-proceed with the choice logged).

## Summary

Add two read-only panels — **Jobsite** then **Workflows** — to the workspace left-nav
sidebar, directly beneath the existing **Projects** panel, each sourced from a read-only
projection query the server already exposes. No new command, event, route, config key,
env var, CLI verb, or MCP tool is introduced. This is pure reuse of existing read models
and existing `ws-panel*` CSS, wired through `ProjectWorkspaceLive`'s existing refresh path
exactly like the current `projects`/`nav_schedules`/`library_entries` assigns.

Final panel order: **Search, Projects, Jobsite, Workflows, Artifacts, Schedules**.

## Architecture Decision

### Chosen approach (Option C — best fit for existing codebase)

Brownfield change. The sidebar already renders panelized read-only data assembled in
`ProjectWorkspaceLive.load_state/1` and passed to `Components.workspace_nav/1`. The two
new panels follow that identical pattern: compute two new assigns on the same refresh
path, declare two new `attr`s on `workspace_nav/1`, render two new `<section class="ws-panel">`
blocks between the Projects and Artifacts panels, pass the two assigns at the call site.

**Data sources (reused as-is, read-only):**

- **Jobsite panel** → `ForemanServer.ProjectionStore.list_jobsites/0`
  (`packages/foreman_server/lib/foreman_server/projection_store.ex:383`, handler at
  `:1461`). Returns a list of jobsite maps, already sorted newest-`started_at_ms`-first
  (descending). Each map is built with **atom keys** by the `JobsiteStarted` projection
  at `projection_store.ex:3963`; its keys include `jobsite_id`, `bead_id`, `branch`,
  `strategy`, `status`, `started_at_ms` — **there is no `workflow_name` key** (that field
  exists only on the *run* projection at `:2547`, not on jobsites). The row's primary
  label is therefore `bead_id` (falling back to `jobsite_id` when the jobsite has no
  bead), with `status` as the muted secondary. Read via plain atom-key access — never a
  `Map.get(a,:k) || Map.get(a,"k")` dual-key lookup.
- **Workflows panel** → `ForemanServerWeb.OperatorDashboard.list_runs/1`
  (`packages/foreman_server/lib/foreman_server_web/operator_dashboard.ex:60`), which wraps
  `ProjectionStore.list_runs/1` and maps each row through `run_dto/1` to a typed
  `OperatorDashboard.RunDTO` struct (`operator_dashboard.ex:17`). `list_runs/1` returns
  `{:ok, [RunDTO.t()]} | {:error, term}` and already applies the bounded default filters;
  the sidebar inherits that bound and adds no sidebar-specific row cap (PRD REQ-008
  resolution). `RunDTO` fields used: `workflow` (`:absent` when nil) and `status`.

> Forward pointer (added after implementation review; the design above stands as written):
> review changed both data sources to be **project-scoped** — the Jobsite panel keeps only
> `list_jobsites/0` rows whose `:project_id` is the open project (then caps at 100 rows, with
> the badge showing the project's real total), and the Workflows panel calls
> `list_runs(%{project_id: project_id})`, matching `{:ok, rows}` only (its `{:error, _}`
> fallback to `[]` was removed) and showing `100+` when that read comes back at its limit.

**Why Option C over A/B:** Option A (inline raw projection calls in the component) would
duplicate the OperatorDashboard facade and bypass its typed `RunDTO`, violating §5.7
(never duplicate a boundary). Option B (a new dashboard-wide run aggregation service) adds
infrastructure the request explicitly forbids (read-only, no new data path). Option C
mirrors the proven existing wiring with zero new boundaries.

### Component boundaries & data flow

```
ProjectWorkspaceLive.load_state/1
  ├─ nav_jobsites  = ProjectionStore.list_jobsites/0          (list of maps, newest-first)
  └─ nav_workflow_runs = <OperatorDashboard.list_runs/1 unwrapped>  ([RunDTO] | [])
        │  {:ok, rows} -> rows ; {:error, _} -> []   (total result handling, §5.2)
        ▼
  assign(socket, nav_jobsites: ..., nav_workflow_runs: ...)
        ▼
  <Components.workspace_nav jobsites={@nav_jobsites} workflow_runs={@nav_workflow_runs} .../>
        ▼
  workspace_nav/1 renders Jobsite panel (after Projects) + Workflows panel (after Jobsite)
```

**Error handling / failure paths:**
- `list_runs/1` `{:error, _}` → treat as empty list (no crash; the glance panel degrades to
  its empty state). The error branch is only reachable via malformed filter params, which
  the sidebar never passes, so the empty default is a safe total match, not a swallowed error.
- `list_jobsites/0` returns a plain list (no error tuple); empty list → empty state.
- `RunDTO.workflow == :absent` → row renders a fallback label (e.g. the run status alone or
  `"workflow"`), never a raw `:absent` atom in the DOM.

### Interface contracts

| Producer | Function | Returns | Consumer |
| --- | --- | --- | --- |
| `ProjectionStore` | `list_jobsites/0` | `[map()]` newest-first, atom keys incl. `jobsite_id`/`bead_id`/`status`/`started_at_ms` (no `workflow_name`) | `load_state/1` → `nav_jobsites` |
| `OperatorDashboard` | `list_runs/1` | `{:ok, [RunDTO.t()]} \| {:error, term}` | `load_state/1` → `nav_workflow_runs` (unwrapped) |
| `Components` | `workspace_nav/1` | HEEx | render both panels |

### Reused Capabilities

| Capability | Provided by (existing) |
| --- | --- |
| Jobsite run list (read-only, newest-first) | `ProjectionStore.list_jobsites/0` |
| Workflow run list (read-only, bounded, typed) | `OperatorDashboard.list_runs/1` → `ProjectionStore.list_runs/1` |
| Sidebar panel CSS | `ws-panel`, `ws-panel-head`, `ws-count`, `ws-panel-list`, `ws-muted`, `ws-ellipsis`, `ws-clamp-1` in `workspace/layouts.ex` |
| Refresh/assign wiring pattern | `ProjectWorkspaceLive.load_state/1` (`project_workspace_live.ex:617`) |

(No foundational TRD registry consulted — this change introduces no reusable capability of
its own; it is a leaf UI change over existing read models.)

## Master Task List

### PR 1: Jobsite and Workflows sidebar panels wired to existing run profiles

**Shippable State:** An operator opening the project workspace sees two new read-only
panels — **Jobsite** and **Workflows** — directly beneath **Projects** in the left nav,
each showing a live count and a newest-first list of its runs (with muted empty states
when there are none); Projects, Artifacts, and Schedules are unchanged. No other surface
changes.

- [ ] **TRD-001** Declare two new `attr`s on `workspace_nav/1` — `attr(:jobsites, :list, required: true)` and `attr(:workflow_runs, :list, required: true)` — in the attr block above `components.ex:210`, and extend the `@doc` panel list to describe the two new panels and their data sources. 1h [satisfies REQ-001, REQ-002, REQ-012]
  - Validates PRD ACs: AC-012-2
  - Implementation AC:
    - Given `workspace_nav/1`, when compiled, then both new required attrs exist and the component raises if either assign is omitted at a call site.
    - Given the `@doc`, when read, then it names Jobsite→`list_jobsites/0` and Workflows→`OperatorDashboard.list_runs/1` as the data sources, mirroring the existing Projects/Schedules doc entries.

- [ ] **TRD-002** Render the **Jobsite** `ws-panel` in `workspace_nav/1` immediately after the Projects `<section>` (`components.ex:287`–`298`) and before the Artifacts section: `ws-panel-head` with `<h2 id="nav-jobsite-title">Jobsite</h2>` and a `ws-count` badge = `length(@jobsites)`; a `ws-panel-list` of rows (one per jobsite, order preserved from the query) showing `bead_id` (fallback `jobsite_id` when `bead_id` is nil) as `<strong>` primary label and `status` as `ws-muted` secondary text; a `ws-muted` "No jobsite runs." message when `@jobsites == []`. 2h [satisfies REQ-001, REQ-004, REQ-005, REQ-006]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-004-1, AC-005-1, AC-005-2, AC-006-1
  - Implementation AC:
    - Given a rendered nav, when the DOM is inspected, then a panel labelled "Jobsite" appears after "Projects" and before "Workflows".
    - Given N jobsite maps, when rendered, then the count badge reads N and one row per jobsite appears in the order `list_jobsites/0` returned (newest `started_at_ms` first).
    - Given `@jobsites == []`, when rendered, then a `ws-muted` "No jobsite runs." message shows and no `ws-panel-list` is rendered.
    - Given a jobsite map, when a row renders, then its `bead_id`/`status` are read via the jobsite projection's atom-key convention; a nil `bead_id` falls back to `jobsite_id`, never a raw atom or a reference to the non-existent `workflow_name` key.

- [ ] **TRD-003** Render the **Workflows** `ws-panel` in `workspace_nav/1` immediately after the Jobsite `<section>` (and before Artifacts): `ws-panel-head` with `<h2 id="nav-workflows-title">Workflows</h2>` and a `ws-count` badge = `length(@workflow_runs)`; a `ws-panel-list` of rows (one per `RunDTO`) showing `workflow` as `<strong>` primary label (fallback when `:absent`) and `status` as `ws-muted` secondary text; a `ws-muted` "No workflow runs." message when `@workflow_runs == []`. 2h [satisfies REQ-002, REQ-007, REQ-008, REQ-009, REQ-010]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-007-1, AC-008-1, AC-008-2, AC-009-1, AC-009-2, AC-010-1
  - Implementation AC:
    - Given a rendered nav, when inspected, then a panel labelled "Workflows" appears immediately after "Jobsite" and before "Artifacts"; Artifacts and Schedules still render after it, unchanged.
    - Given N workflow `RunDTO`s, when rendered, then the count badge reflects N and each row shows the run's `workflow` name (primary) and `status` (muted secondary).
    - Given a `RunDTO` whose `workflow` is `:absent`, when rendered, then a safe fallback label shows (never the literal `:absent`).
    - Given `@workflow_runs == []`, when rendered, then a `ws-muted` "No workflow runs." message shows and no list.

- [ ] **TRD-004** Compute the two assigns on the existing refresh path in `ProjectWorkspaceLive.load_state/1` (`project_workspace_live.ex:617`–`634`), in the same `assign/2` keyword block as `projects`/`nav_schedules`/`library_entries`: `nav_jobsites: ProjectionStore.list_jobsites()` and `nav_workflow_runs: nav_workflow_runs()` where a new private `nav_workflow_runs/0` helper calls `OperatorDashboard.list_runs/1` and total-matches its result (`{:ok, rows} -> rows`; `{:error, _} -> []`). Add the `alias ForemanServerWeb.OperatorDashboard` if not already aliased. Pass both assigns at the `workspace_nav` call site (`project_workspace_live.ex:862`). 2h [satisfies REQ-012, REQ-003]
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-012-1, AC-012-2
  - Implementation AC:
    - Given a mounted workspace, when `load_state/1` runs, then `nav_jobsites` and `nav_workflow_runs` are populated from the read-only queries and handed to `workspace_nav`.
    - Given `OperatorDashboard.list_runs/1` returns `{:error, _}`, when `nav_workflow_runs/0` runs, then it returns `[]` (no crash) — a total match on the documented `{:ok,_}|{:error,_}` shape, with no catch-all wrapping an unknown value as success.
    - Given the change, when the Projects panel is diffed, then its heading, count, and per-project links are unchanged (new siblings only).
    - Given the existing `workspace_nav` test, when re-run, then it still passes.

- [ ] **TRD-005** Confirm no new CSS is required (the two panels reuse `ws-panel`/`ws-panel-head`/`ws-count`/`ws-panel-list`/`ws-muted`/`ws-ellipsis`/`ws-clamp-1`); only if a genuinely new rule is unavoidable, add it to the workspace root layout `workspace/layouts.ex` and nowhere else. No `app.js`/`app.css` or asset-pipeline file is created. 0.5h [satisfies REQ-011]
  - Validates PRD ACs: AC-011-1, AC-011-2
  - Implementation AC:
    - Given the two panels' markup, when inspected, then they use only the existing `ws-panel*` classes.
    - Given the diff, when inspected, then no asset-pipeline file is introduced; any new rule (if any) lives only in `layouts.ex`.

- [ ] **TRD-006** Read-only guarantee audit: confirm the diff adds no new HTTP route (`router.ex`), command/event struct, config key, env var, CLI verb, or `foreman_*` MCP tool. Documentation gate: list externally visible identifiers (expected: none) and grep `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`. 0.5h [satisfies REQ-013]
  - Validates PRD ACs: AC-013-1, AC-013-2, AC-015-1
  - Implementation AC:
    - Given the diff, when grepped, then `router.ex` is unchanged and no new command/event/config/env/CLI/MCP identifier appears.
    - Given the doc gate, when the four docs are grepped, then no stale or missing reference results (no externally visible identifier changed).
    - Given the two panels, when inspected, then they expose no action buttons, filters, or run-detail links (glance-only, REQ-015).

- [ ] **TRD-002-TEST** LiveView test for the **Jobsite** panel in `test/foreman_server_web/live/project_workspace_live_test.exs` (existing workspace test conventions): seed ≥2 jobsite projections with distinct, explicit `started_at_ms` and assert the panel renders after Projects / before Workflows, the `ws-count` equals the seeded count, rows appear newest-`started_at_ms`-first, and `bead_id`/`status` show. Add an empty-state case asserting the `ws-muted` "No jobsite runs." message with no list. 2h [verifies TRD-002] [satisfies REQ-004, REQ-005, REQ-006, REQ-014] [depends: TRD-002, TRD-004]
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-005-1, AC-005-2, AC-006-1, AC-014-1, AC-014-2
  - Implementation AC:
    - Given seeded jobsites with distinct timestamps, when the nav renders in the test, then order, count, and rows are asserted deterministically (no reliance on insertion order).
    - Given zero jobsites, when rendered, then the empty-state assertion passes.

- [ ] **TRD-003-TEST** LiveView test for the **Workflows** panel in the same test file: seed ≥2 workflow runs and assert the panel renders immediately after Jobsite, `ws-count` reflects the run count, each row shows its `workflow` name (primary) and `status` (muted), and Artifacts/Schedules still follow. Add an empty-state case asserting the `ws-muted` "No workflow runs." message. Include a case where a run's `workflow_name` is nil to assert the fallback label (no raw `:absent`). 2h [verifies TRD-003] [satisfies REQ-007, REQ-008, REQ-009, REQ-010, REQ-014] [depends: TRD-003, TRD-004]
  - Validates PRD ACs: AC-002-1, AC-002-2, AC-008-1, AC-009-1, AC-009-2, AC-010-1, AC-014-1, AC-014-2, AC-014-3
  - Implementation AC:
    - Given seeded workflow runs, when the nav renders, then order, count, rows, and the nil-workflow fallback are asserted.
    - Given zero workflow runs, when rendered, then the empty-state assertion passes.
    - Given the narrowest affected test file, when run with `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors test/foreman_server_web/live/project_workspace_live_test.exs'`, then it passes with zero warnings.

## Acceptance Criteria Traceability

| REQ-NNN | Description | Implementation Tasks | Test Tasks |
| --- | --- | --- | --- |
| REQ-001 | Jobsite panel under Projects | TRD-001, TRD-002 | TRD-002-TEST |
| REQ-002 | Workflows panel under Jobsite | TRD-001, TRD-003 | TRD-003-TEST |
| REQ-003 | Projects panel unchanged | TRD-004 | TRD-002-TEST (existing nav test re-run) |
| REQ-004 | Jobsite data = `list_jobsites/0` | TRD-002 | TRD-002-TEST |
| REQ-005 | Jobsite count + newest-first | TRD-002 | TRD-002-TEST |
| REQ-006 | Jobsite empty state | TRD-002 | TRD-002-TEST |
| REQ-007 | Workflows data = `list_runs/1` | TRD-003 | TRD-003-TEST |
| REQ-008 | Workflows count + bounded list | TRD-003 | TRD-003-TEST |
| REQ-009 | Workflows row identity | TRD-003 | TRD-003-TEST |
| REQ-010 | Workflows empty state | TRD-003 | TRD-003-TEST |
| REQ-011 | Reuse sidebar CSS / root layout | TRD-005 | — (diff inspection) |
| REQ-012 | Wire assigns via ProjectWorkspaceLive | TRD-001, TRD-004 | TRD-002-TEST, TRD-003-TEST |
| REQ-013 | No new display-only identifiers | TRD-006 | — (doc gate / grep audit) |
| REQ-014 | Tests for both panels | TRD-002-TEST, TRD-003-TEST | TRD-002-TEST, TRD-003-TEST |
| REQ-015 | No actions/detail in sidebar (out of scope) | TRD-006 | — (inspection) |

All 15 PRD requirements covered. REQ-011/REQ-013/REQ-015 are verified by diff/grep/inspection
rather than a seeded test (they assert the absence of change), consistent with their nature.

## Sprint Planning

### Sprint 1: Dashboard nav panels (single PR)

Entire effort is one shippable PR (PR 1, ~14.5h incl. tests). Recommended build order:
TRD-001 (attrs) → TRD-004 (wiring) → TRD-002 + TRD-003 (panels) → TRD-002-TEST + TRD-003-TEST
→ TRD-005 (CSS confirm) → TRD-006 (read-only + doc gate audit). This section is informational;
`implement-trd-beads` parses the `### PR 1:` section, not this one.

## Adversarial Review (self-critique, auto-resolved under --foreman)

1. **Architecture gap — Workflows data path duplication risk.** A naive panel could call
   `ProjectionStore.list_runs/1` directly and re-derive row fields, duplicating the
   `OperatorDashboard.run_dto/1` boundary (§5.7). **Resolved:** TRD-003/TRD-004 pin the
   source to `OperatorDashboard.list_runs/1` and its typed `RunDTO`, the single existing facade.
2. **Failure path — `list_runs/1` error tuple.** `list_runs/1` returns
   `{:ok,_}|{:error,_}`; an incomplete match would crash the whole workspace mount.
   **Resolved:** TRD-004 defines `nav_workflow_runs/0` with a total match (`{:ok,rows}->rows`,
   `{:error,_}->[]`), no catch-all wrapping an unknown value as success (§5.2).
3. **Interface — jobsite map key convention / stale field.** Jobsite rows are atom-keyed
   maps; a dual-key `Map.get(:k)||Map.get("k")` access would violate §5.4, and the original
   draft labelled rows with `workflow_name` — a key the jobsite projection never sets.
   **Resolved (refine, `--foreman`):** the jobsite map is built at `projection_store.ex:3963`
   with no `workflow_name` key; TRD-002/TRD-002-TEST now read the real atom keys
   (`bead_id`/`status`) with `jobsite_id` as the primary-label fallback, single convention,
   no dual-key lookup.
4. **Testability — ordering flakiness.** Newest-first assertions are flaky if seeded runs
   share or lack `started_at_ms`. **Resolved:** TRD-002-TEST seeds distinct explicit
   timestamps (PRD REQ-014 risk note).
5. **Coverage — absence-type REQs.** REQ-011/REQ-013/REQ-015 assert that *nothing* new is
   added, so they have no seeded test. **Resolved:** TRD-005/TRD-006 verify them by diff/grep/
   doc-gate audit, which is the correct verification for a negative requirement.
6. **Dependency clarity.** Both test tasks depend on TRD-004 (the assigns must flow) and on
   their respective panel task. Dependency graph is shallow (depth 2) and acyclic.

## Design Readiness Scorecard

| Dimension | Score | Notes |
| --- | --- | --- |
| Architecture completeness | 4.5 | All components, interfaces, data flow, and failure paths defined; pure reuse |
| Task coverage | 4.5 | Every REQ-NNN mapped to implementation + (where applicable) test tasks; absence-REQs audited |
| Dependency clarity | 4.5 | Explicit `[depends:]` annotations, acyclic, depth ≤ 2 |
| Estimate confidence | 4.0 | Low-complexity reuse; estimates consistent (panels 2h, tests 2h, audits ≤1h) |

**Overall: 4.4 → PASS.**

## Next Steps

- `/ensemble-configure-team docs/TRD/TRD-2026-7735ac9c-dashboard-jobsite-workflows-nav.md`
- `/ensemble-implement-trd-beads docs/TRD/TRD-2026-7735ac9c-dashboard-jobsite-workflows-nav.md`

## Changelog

- **2026-11-04 — v1.0.1 (refine, `--foreman`):** Corrected the Jobsite panel's row data
  contract. The jobsite projection map (built by `JobsiteStarted` at
  `projection_store.ex:3963`) has **no `workflow_name` key** — that field lives only on the
  *run* projection (`:2547`). The draft (inherited from the PRD data-source note) used
  `workflow_name` as the Jobsite row's primary label, which would always render empty.
  Changed the Jobsite row to primary `bead_id` (fallback `jobsite_id`) + muted `status`,
  using existing jobsite keys only. Fixed the stale projection cite (`2547` → `3963`) and
  the interface-contract key list; updated TRD-002, TRD-002-TEST, the Architecture
  data-sources bullet, and Adversarial Review #3. No task-count, hour-estimate, or
  dependency changes. Design Readiness unchanged at **4.4 (PASS)**.
