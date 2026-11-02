Done. Layout shell implemented.

**Changes** (5 files, nothing under `.beads/`, left uncommitted for Foreman):
- `workspace/project_view.ex` — `ProjectView.build/2` now returns `goal` (read from existing config, atom/string keys, blank→nil). No new command/event.
- `project_workspace_live.ex` — header renders project name + goal (goal only when present); chat wrapped in `<section class="ws-main-col">`; right region is `<aside class="ws-side">` with an empty structured `<section class="ws-panels">` shell for the follow-up read-only panels. Existing questions/overview/tabs preserved.
- `workspace/layouts.ex` — inline CSS (no asset pipeline) for header/goal/main-col/side/panels; main column widened to `3fr minmax(300px,1fr)`; responsive breakpoint kept.
- 2 test files — goal present/absent header tests, ProjectView goal tests, side-panel shell structure test.

**Behavior preserved:** chat send, overview, library upload, PR buttons untouched.

**Test result:**
`devbox run -- bash -c 'cd packages/foreman_server && unset DATABASE_URL && MIX_ENV=test mix test --warnings-as-errors <project_view_test> <project_workspace_live_test>'` → **50 passed**, clean compile under `--warnings-as-errors`.

**Doc gate:** no externally-visible identifiers (routes/config/env/CLI/tools) added or renamed — only internal CSS classes + internal `ProjectView.t` `goal` field. CLAUDE.md/README.md/docs need no edits.

Report: `docs/reports/foreman-coord-322b62d929d673ec/FIX_REPORT.md`.

Note: DATABASE_URL in shell pointed at dev-stack DB (55434); unset it so tests use default `foreman_test` (55432). Changes left uncommitted — Foreman owns commit + PR.