# Fix report — `adhoc-4f35b3c7` (run `run-30ab70c9019bd2df980642a0c395e65f`)

Phase: `fix` / 1. Scope per operator: **align `/dashboard/runs` with the project workspace's UI
vocabulary** (code change + tests). No functional bug in the run pipeline was reported.

## 1. Root cause

`packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex` was written as a
standalone page with its own invented CSS vocabulary (`operator-run-dashboard`, `dashboard-layout`,
`dashboard-detail-error`, `dashboard-stale`, `focus-marker`, `run-list`, `run-detail`) and with
raw struct/term interpolation (`{inspect(@detail.run.pr_url)}`, `[:status]` brackets, `artifact=`
from `inspect/1`).

Two consequences:

- The page is **unstyled** for those class names. The only stylesheet in this app is the one heredoc
  in `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex`, and it defines none of
  them, so the operator run dashboard renders as browser-default markup while the project workspace
  (`ForemanServerWeb.ProjectWorkspaceLive` + `workspace/components.ex`) renders as the designed UI.
- It does not reuse the workspace's shared primitives (`.ws-layout`, `.ws-header`, `.ws-card`,
  `.thread-row`, `.chip--*`, `.msg--*`, `.conv-transcript`) that exist precisely so operator surfaces
  look like one product.

The workspace's own tab list is rendered with a module attribute (`@tabs`) — in this file that same
pattern is a latent bug: inside `~H`, `@name` compiles to `assigns.name`, not the module attribute.

## 2. Change

- `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex` — markup/classes
  only. Same landmarks as the workspace (`main#main.ws-main`, `header.ws-header`,
  `nav#run-list.ws-threads` + `ul.thread-rows` + `.thread-row` rows with `.thread-dot`/`.chip`,
  `div[role=tablist]` + four `#dash-tab-*`/`#dash-panel-*` tabpanels, `.ws-card`, `.ws-panel-list`,
  `.conv-transcript` log pane, `.msg`/`.msg-meta`/`.msg-sender`/`.msg-text`, `.ws-error`,
  `.ws-muted`, `.btn.ws-btn`, `.btn--link.ws-ellipsis`). Added private `describe/1` (absent values
  read as "not available" instead of `:absent`/`nil`), `chip_kind/1`, `entry_kind/1`,
  `change_kind/1`, `run_row/1`. `mount/1`, `handle_params/3`, every `handle_event/2`
  (filters, tab, select-run, file preview, stop/resume/reset/abandon + `intent-key`) and the
  `/dashboard/runs?run_id=R[&tab=T&file=F]` deep link are unchanged, as are all
  `OperatorDashboard` calls — no data the server did not already expose was invented.
- `packages/foreman_server/lib/foreman_server_web/workspace/layouts.ex` — two additive rules, no
  existing rule edited: `.thread-dot--muted` (the modifier `.thread-row` uses for a completed run,
  which the base `.thread-dot` already coloured) and `.ws-layout--runs { grid-template-columns:
  300px minmax(0, 1fr); }` inside the existing `@media (min-width: 1100px)` block, because the
  dashboard reuses the workspace shell with two children rather than four.
- `packages/foreman_server/test/foreman_server_web/operator_run_dashboard_ui_test.exs` — new.

**Process note the operator asked me to record:** the first restyle attempt truncated this file to
~140 lines (a blanket script appended ` />` to already-closed tags and a later edit swallowed the
`~H` heredoc terminator, so it did not compile). It was discarded with
`git checkout HEAD -- .../operator_run_dashboard_live.ex` and redone as small edits against the
525-line original, compiling after every batch. The diff in this report is the redone version.

## 3. Tests

Failing check established **before** the fix (recorded, then re-run after):

```
# operator_run_dashboard_ui_test.exs, run against HEAD markup
1) test ... every class the dashboard emits is styled by the shared stylesheet
   Assertion with in failed: "operator-run-dashboard" is not in the styled set
2) test ... reuses the workspace landmarks
   code: assert html =~ ~s|<main id="main" class="ws-main">|  →  match failed
6) test ... absent values never render as inspected terms
   2020 bytes matched ~r/:absent|nil|\[:/
```
(after fix: 7/7 pass; before fix the run also 500'd on `render/1` for the tab comprehension)

- Added: 7 parity tests — every emitted class must exist in `layouts.ex`; the workspace landmarks are
  present and the seven old invented names are absent; run rows render `thread-dot--muted` /
  `chip--muted` exactly like `Workspace.Components.thread_row/1` + `thread_chip/1` map `completed`;
  tablist/tabpanel wiring (`id`, `aria-controls`, `aria-selected`) for all four tabs; empty state;
  error state; no `:absent`/`nil` leakage.
- Updated: `test/foreman_server_web/operator_run_dashboard_live_test.exs` — no edits needed; its
  assertions are semantic, and it passes unchanged.
- Formatter: `mix format` on the two touched Elixir files (repo convention, no separate linter).

## 4. Local verification

```
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix compile --warnings-as-errors'   # clean
devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix format --check-formatted'        # clean
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=…:55432/foreman_test MIX_ENV=test \
  mix test test/foreman_server_web/operator_run_dashboard_ui_test.exs \
           test/foreman_server_web/operator_run_dashboard_live_test.exs \
           test/foreman_server_web/operator_dashboard_test.exs'                                        # 49 passed
devbox run -- bash -c 'cd packages/foreman_server && … mix test --warnings-as-errors'                  # 6905/6907, 10 excluded, 529.7s
```

The 2 red in the full suite are **not** from this change:
`test/foreman_server/config_test.exs:73` and `:87` ("dev env (TRD-022) … reads DATABASE_URL with
localhost default") assert `url =~ "localhost"` against the `:dev` config, which resolves
`DATABASE_URL` from the environment. They are only red because the suite was run with
`DATABASE_URL` pointed at the shared test Postgres (`127.0.0.1:55432/foreman_test`) — the worktree's
default dev URL (`localhost:55434/foreman_dev`) is unreachable here, so the tests cannot pass in
this environment either way. Same files, same two failures before and after my diff; unrelated to
`foreman_server_web`. Full-suite output: `~/.omp/fullsuite.log`.

Doc gate — externally visible identifiers touched: **none.** No route, command/event type, MCP tool,
CLI verb, env var or config key was added, removed or renamed; only CSS class names inside one
LiveView's markup changed. Greps of `CLAUDE.md`, `README.md`, `docs/user-guide.md`,
`docs/cli-reference.md` for `operator-run-dashboard`, `dashboard-layout`, `dashboard-detail-error`,
`dashboard-stale`, `focus-marker`, `ws-layout--runs`, `thread-dot--muted`, `run-filters`: **no hits,
so none of the four needed edits.** `docs/PRD/*` and `docs/TRD/*` for
`PRD/TRD-2026-c7977e9d-operator-run-dashboard` do name the removed classes; per AGENTS.md those are
point-in-time specs and were left as written.

## 5. Follow-ups

- **Intentionally not done:** `operator_dashboard_live.ex` (`/dashboard` root) and
  `operator_admin_dashboard_live.ex` (`/admin`) still use the old invented classes
  (`operator-dashboard`, `admin-dashboard`, `dashboard-layout`, `focus-marker`), which
  `layouts.ex` still styles. Restyling them is outside this brief; the new test only asserts the
  names are gone from the run dashboard file, so it stays green either way. Worth a follow-up task
  if the goal is "all operator pages share one vocabulary".
- `layouts.ex` keeps the now-unused-by-the-run-page rules for as long as those two pages exist; they
  should be deleted together with the restyle above, not before.
- `run_row/1` stays a `<button phx-click="select-run">` rather than the workspace's
  `<.link patch=...>`, because there is no per-run route to patch to. If a `/dashboard/runs/:id`
  route is ever added, this becomes a link and the selection state moves into `handle_params`.
- Status note: `foreman_inbox_send` / `foreman_task_add_comment` were not available to this phase, so
  the milestone updates could not be sent; `ask_advisor` is unusable in this worktree
  (`Advisor model not found: openai-codex/gpt-5.5`).
