# Foreman cockpit — Bubble Tea POC

A proof-of-concept of the single-pane Foreman cockpit, built with
[Bubble Tea](https://github.com/charmbracelet/bubbletea) +
[Lip Gloss](https://github.com/charmbracelet/lipgloss) +
[Glamour](https://github.com/charmbracelet/glamour).

It demonstrates the redesign in `docs/design/cockpit-ui-spec.md` and the
architecture direction in `docs/adr/0001-go-clients-elixir-core-runtime.md`:
a Go client that reads the Elixir core's `/api/v1` projections and holds no
authoritative state.

## What it shows

- One screen, two navigation axes: pick an item (left), pick a drill-down (right).
- Left column grouped `RUNNING` / `READY` / `RECENT` — `READY` is derived
  from current-project task state (`backlog`, `ready`, `failed`, etc.), not just
  scheduler-dispatchable rows.
- Live runs are scoped to the current project (or `COCKPIT_PROJECT_ID`) and
  deduplicated by task. A task is `RUNNING` when both the task state and run
  state are active (`in-progress` and `in_progress` are treated the same);
  stale in-progress run projections for closed/failed tasks are shown as
  recent, not running.
- Run rows show the task title when available, falling back to the task id; task
  rows show priority, title, and type. The selected task detail shows id, status,
  workflow, dependencies, project, and description. READY task
  rows support `y` to copy the task id, `a` to approve via `task.approve`, `e` to
  edit task JSON via `task.update`, and `n` to create a new task JSON draft via
  `task.create`.
- Right column: color-coded run header, an animated phase rail, and a
  drill-down tab strip (`summary · messages · events · logs · reports · files · pr`).
- Panes are height-bounded to the current terminal; the left list keeps the
  selected row visible and expands up to 40 columns without starving the right pane.
- `logs` / `reports` / `files` rows open in **nvim**: remote into a running
  session when `$NVIM` is set, otherwise suspend-and-launch inline. `files`
  offers a selected-file nvim diff (`d`), an inline selected-file preview backed
  by `delta` when available, and a full-run `diffnav` handoff (`D`) when enabled.
  Conflicts open a 3-way diff.
- The `pr` tab shows Foreman-projected PR URL/state/branch metadata and opens the
  PR in a browser with `o`/`enter` when a PR URL is present.
- Reports render as markdown via Glamour in the drill-down.

## Run it

Requires Go 1.23+.

Optional integrations are discovered at runtime and fail closed with a notice:
`diffnav` for full-run file review, `delta` for inline selected-file previews,
`gh` plus the `gh dash` extension for repo-wide triage, `gh` plus the
`gh enhance` extension for GitHub Actions triage, and a platform browser opener
(`open` on macOS or `xdg-open` on Linux) for PR links. Cockpit ships generated
theme fragments under `theme/` and passes the packaged `diffnav`/`gh enhance`
theme environment when launching those tools. `diffnav` looks best with a Nerd
Font because its file tree uses icon glyphs.

```bash
cd clients/cockpit
go mod tidy                  # resolves deps + writes go.sum (needs network once)
go build -o foreman-cockpit .
./foreman-cockpit            # or: go run .
```

By default the client reads the local Foreman server at
`http://127.0.0.1:4766`. Override it, or force the mock backend, with:

```bash
FOREMAN_SERVER_URL=http://127.0.0.1:4766 \
FOREMAN_SERVER_AUTH_TOKEN=$FOREMAN_SERVER_AUTH_TOKEN \
./foreman-cockpit

COCKPIT_BACKEND=mock ./foreman-cockpit
```

Non-interactive live-backend smoke check:

```bash
FOREMAN_SERVER_URL=http://127.0.0.1:4766 COCKPIT_DUMP=1 ./foreman-cockpit
```

## Keys

```
↑↓ / j/k  move task selection while the task list is focused
enter     enter/focus the selected drill-down view
esc       leave the drill-down view and return focus to the task list
↑↓ / j/k  move the highlighted line in focused messages/events/logs/reports/files/pr
ctrl+d/u  half-page down/up in the focused drill-down view
mouse     wheel over task list moves tasks; wheel over drill-down tabs scrolls that view
⇥ / ⇧⇥    next / previous drill-down tab and focus it; 1–7 jump to a tab and focus it
o/enter   open selected row in nvim; on pr, open PR in browser
d         selected file diff in nvim          D    full run diff in diffnav
y         copy selected task ID               n    create task JSON in nvim
a         approve READY task                  e    edit READY task JSON in nvim
C         inspect CI in gh enhance            r/R  retry / reset
/         search                              space collapse/expand group     ? help     q quit
```

Opening a drill-down view with `enter`, `tab`, or `1`–`7` selects its newest
rendered line. Moving inside a drill-down keeps the selected row near the middle
of the viewport when there is room; near the top or bottom it clamps to the edge.
Live updates keep a manually moved viewer cursor on the same rendered line when
possible instead of snapping back to the bottom.
In `messages`, the cursor moves by whole messages: the header is selected, the
tab and run header show the current position (`messages 12/50`), and the body
preview is kept in the viewport with the header when there is room for both.

## Integrations

Controlled by `.foreman/config.yaml` (all optional) and `COCKPIT_DIFFNAV`,
`COCKPIT_DELTA`, `COCKPIT_GHDASH`, and `COCKPIT_GHENHANCE` env overrides
(`auto` / `on` / `off`):

```yaml
editor:
  cmd: nvim
  mode: auto
integrations:
  diffnav:
    enable: auto
    base: origin/dev
    watch: false
  delta:
    enable: auto
  ghDash:
    enable: auto
    args: []
  ghEnhance:
    enable: auto
    args: []
pr:
  provider: github
```

The cockpit only uses these tools as full-screen Bubble Tea handoffs or cached
command output: `diffnav`, `gh dash`, and `gh enhance` run through
`tea.ExecProcess`, and inline file previews read a completed
`git diff | delta`/plain `git diff` command. Generated theme fragments live in
`theme/`: `tokens.yaml` drives cockpit color constants, `gh-dash.yml`,
`enhance.env`, `diffnav/config.yml`, `delta.gitconfig`, and `glamour.json`.
There is not yet a global theme installer; handoffs use packaged env where the
tool supports it.

## nvim open modes

In this POC the editor mode is inferred from config/env: `remote` when `$NVIM` is
present in `auto`, otherwise `inline`. The editor binary comes from `editor.cmd`
or `$EDITOR` (falling back to `nvim`).

## Status / caveats

- POC quality: READY task approval/edit/create and PR browser opens are live
  actions. `r` / `R` / attach still show the command they *would* send
  (`POST /api/v1/commands`, `GET /runs/:id/attach`) rather than executing.
- The `httpClient` field mapping accepts the current `/api/v1` wrapper shapes
  (`inbox`, `logs.entries`, `report`) and surfaces HTTP/JSON failures in the
  cockpit notice bar. If the aggregate `/api/v1/events` endpoint fails for a
  run, the client falls back to `/api/v1/runs/:run_id/debug` for the events tab.
  Foreman-projected PR fields are read from `/api/v1/runs`; richer PR checks or
  review state would require backend projection fields or optional `gh` enrichment.
  The contract should still be regenerated from a published OpenAPI schema
  (ADR phase 2).
- File-change data has no dedicated endpoint yet; `httpClient.Files` returns
  empty pending that work. The mock client shows the intended UX.

## Architecture

The root Bubble Tea model orchestrates client refresh, layout, focus, active tab,
notices, and actions. Component state lives in small cockpit-owned types:

- `task_list.go` owns grouped `RUNNING` / `READY` / `RECENT` rows, selection,
  collapsed groups, search/filter state, scope, and keeping the selected row
  visible.
- `viewer.go` owns drill-down rows, cursor, viewport offset, selected row
  identity, bottom-follow behavior, and cursor clamping across refreshes.
- `view.go` adapts summary/messages/events/logs/reports/files/pr into keyed
  viewer rows and renders the shell with Lip Gloss.

No Bubbles dependency is used in this pass; `go.mod` stays on the existing
GitHub Bubble Tea/Lip Gloss/Glamour import paths.

## Layout

```
main.go          program entry + client selection
client.go        Client interface, types, mock + HTTP implementations
config.go        cockpit config loading and env overrides
tools.go         executable availability checks
model.go         root Elm orchestration: refresh, focus, active tab, actions
task_list.go     left-pane grouped task/run list state
viewer.go        drill-down row/cursor/viewport state
view.go          Lip Gloss rendering (status bar, list, rail, tabs, body, action bar)
nvim.go          open-in-nvim resolution (remote vs inline) + editor config
diffnav.go       full-run diffnav handoff
delta_preview.go selected-file inline diff preview
gh_dash.go       gh dash handoff
pr.go            PR projection rendering and browser opener
styles.go        palette + shared styles
```
