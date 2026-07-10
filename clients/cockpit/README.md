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
- Task rows support `y` to copy the task id. READY task rows also expose two
  live actions: `a` approves the task via `task.approve`; `e` opens the task
  JSON in nvim and posts the edited fields via `task.update`.
- Right column: color-coded run header, an animated phase rail, and a
  drill-down tab strip (`summary · messages · events · logs · reports · files`).
- Panes are height-bounded to the current terminal; the left list keeps the
  selected row visible instead of overflowing the screen.
- `logs` / `reports` / `files` rows open in **nvim**: remote into a running
  session when `$NVIM` is set, otherwise suspend-and-launch inline. `files`
  offers a diff (`d`), and conflicts open a 3-way diff.
- Reports render as markdown via Glamour in the drill-down.

## Run it

Requires Go 1.23+.

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
↑↓ / j/k  move the highlighted line in focused messages/events/logs/reports/files
mouse     wheel over task list moves tasks; wheel over messages/events/logs/reports/files scrolls that view
⇥ / ⇧⇥    next / previous drill-down tab and focus it; 1–6  jump to a tab and focus it
o         open selected row in nvim           d    diff in nvim (files)
y         copy selected task ID               a    approve READY task
e         edit READY task JSON in nvim        g    toggle project/global scope
/         search                              space collapse/expand group
r         retry        R  reset               q    quit
```

Opening a drill-down view with `enter`, `tab`, or `1`–`6` selects its newest
rendered line. Moving inside a drill-down keeps the selected row near the middle
of the viewport when there is room; near the top or bottom it clamps to the edge.
Live updates keep a manually moved viewer cursor on the same rendered line when
possible instead of snapping back to the bottom.
In `messages`, the cursor moves by whole messages: the header is selected, the
tab and run header show the current position (`messages 12/50`), and the body
preview is kept in the viewport with the header when there is room for both.

## nvim open modes

Controlled by the `editor` block in `.foreman/config.yaml` (see the spec).
In this POC the mode is inferred: `remote` when `$NVIM` is present, otherwise
`inline`. The editor binary comes from `$EDITOR` (falling back to `nvim`).

## Status / caveats

- POC quality: only READY task approval/edit are live mutations. `r` / `R` /
  attach still show the command they *would* send (`POST /api/v1/commands`,
  `GET /runs/:id/attach`) rather than executing.
- The `httpClient` field mapping accepts the current `/api/v1` wrapper shapes
  (`inbox`, `logs.entries`, `report`) and surfaces HTTP/JSON failures in the
  cockpit notice bar. If the aggregate `/api/v1/events` endpoint fails for a
  run, the client falls back to `/api/v1/runs/:run_id/debug` for the events tab.
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
- `view.go` adapts summary/messages/events/logs/reports/files into keyed viewer
  rows and renders the shell with Lip Gloss.

No Bubbles dependency is used in this pass; `go.mod` stays on the existing
GitHub Bubble Tea/Lip Gloss/Glamour import paths.

## Layout

```
main.go       program entry + client selection
client.go     Client interface, types, mock + HTTP implementations
model.go      root Elm orchestration: refresh, focus, active tab, actions
task_list.go  left-pane grouped task/run list state
viewer.go     drill-down row/cursor/viewport state
view.go       Lip Gloss rendering (status bar, list, rail, tabs, body, action bar)
nvim.go       open-in-nvim resolution (remote vs inline) + editor config
styles.go     palette + shared styles
```
