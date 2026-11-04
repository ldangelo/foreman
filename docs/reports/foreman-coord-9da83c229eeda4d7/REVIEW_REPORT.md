# Repository-rules review

## Review engine

Reviewer: Claude Code repository-rules review phase (phase 7), against the
repo-root `AGENTS.md` conventions. Diff range: `git diff "main"...HEAD`
(`$FOREMAN_BASE_BRANCH=main`, confirmed set; `origin/main` == `main` ==
`85e76e4a`). Diff touches: `CLAUDE.md`, `docs/user-guide.md`,
`docs/PRD/PRD-2026-94f379ec-agent-scoped-mcp-credential.md`, the workspace
LiveView + its components/layout, and `project_workspace_live_test.exs`.

Previous phase's `REVIEW_CODERABBIT_REPORT.md` is present beside this file. It
carries **no** `FOREMAN_REVIEW_FINDINGS_START/END` block: it reports 2 Minor
findings, both fixed in that phase (search over library file paths;
Projects panel keeping archived projects), 0 declined, and an intentionally
empty unresolved set. Nothing to carry forward.

## Findings

1. **`nav_cadence` handled impossible spec kinds** (`components.ex`) — fixed.
2. `nav_projects` uses `Map.get(projection, :project_id) || Map.get(projection, :id)` — declined (established codebase idiom).
3. `nav_schedules` loaded eagerly while the Scheduled tab's `@schedules` is lazy — declined (different lifecycles, not duplication of a boundary).
4. Documentation gate on new identifiers — no action required (see Declined).

## Fixed

- `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`
  (`nav_cadence/1`, `nav_cadence_fallback/1`). **Wrong:** the cadence helper
  probed `Map.get(spec, "rrule")` and fell back to `nav_cadence_fallback/1`
  reading `Map.get(spec, "type")`. A schedule `spec` can only hold `"every"`
  or `"cron"` (+ `"timezone"`/`"anchor"`); `Schedule.Spec.parse/1` rejects any
  other field with `{:unknown_field, _}` (`schedule/spec.ex:198`), so `"rrule"`
  and `"type"` can never be present. Those branches were dead code handling
  impossible cases — AGENTS.md working rule 3 ("no error handling for
  impossible cases"). **Change:** dropped the `"rrule"` alternative and removed
  `nav_cadence_fallback/1`; the `case` now matches `cron`/`every` with a plain
  `"schedule"` default. Behaviour for every real spec is unchanged.

## Declined

- `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex:748`
  — `Map.get(projection, :project_id) || Map.get(projection, :id)`. Not a
  §5.4 violation (that rule bans atom-vs-string probing of one key); this is
  the established idiom for reading a project id off a `ProjectStore.list/0`
  projection, used verbatim at `project_controller.ex:170`. Following existing
  code; no change.
- `nav_schedules` is loaded in `load_state/1` on every render while the
  Scheduled-tab `@schedules` is loaded only on that tab. Not a duplicated
  boundary (both call `ScheduleDTO.list/1`, the single typed read); the nav
  needs the list on every route, the tab does not. No change.
- Documentation gate: the diff adds internal identifiers only —
  `Components.workspace_nav/1` (a function component) and the `"ws_search"`
  LiveView event. Neither is an externally visible route/config key/env
  var/CLI verb/MCP tool, so `README.md` and `docs/cli-reference.md` need no
  edit. `CLAUDE.md` and `docs/user-guide.md` were already updated in this run
  to describe the new leftmost workspace-nav sidebar and its four panels;
  verified those edits match the shipped behaviour. No action.

## Verification

- `mix format lib/foreman_server_web/workspace/components.ex` then
  `mix format --check-formatted lib/foreman_server_web/workspace/components.ex`
  → exit 0.
- `MIX_ENV=test mix test --warnings-as-errors`
  `test/foreman_server_web/live/project_workspace_live_test.exs`
  → **54 passed**, exit 0 (run with `DATABASE_URL`/`EVENTSTORE_URL` unset).
- Re-read `git diff "main"...HEAD` after the fix: the change only removes dead
  branches; no new violation introduced.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
<!-- FOREMAN_REVIEW_FINDINGS_END -->
