# Foreman cockpit — Bubble Tea client

The Go implementation of the single-pane Foreman cockpit is built with
`charm.land/bubbletea/v2 v2.0.8`, `charm.land/lipgloss/v2 v2.0.5`,
`charm.land/bubbles/v2 v2.1.0`, [Glamour](https://github.com/charmbracelet/glamour),
and [`robinovitch61/viewport`](https://github.com/robinovitch61/viewport).

The nested Go module targets the Bubble Tea v2 `tea.View` API: alt-screen and
mouse mode are requested from `View()` rather than program options. Because this
client is on Bubble Tea v2, Charm TUI imports use the `charm.land/.../v2` module
paths rather than the pre-v2 GitHub import paths.

It implements the redesign in `docs/design/cockpit-ui-spec.md` and the
architecture direction in `docs/adr/0001-go-clients-elixir-core-runtime.md`:
a Go client that reads the Elixir core's `/api/v1` projections and holds no
authoritative state.

## What it shows

- Wide terminals default to a top/bottom Kanban cockpit: pick a task/run card
  from the board (top), then inspect its activity drill-down (bottom). The board
  columns are `Backlog`, `Ready`, `In Progress`, `Blocked`, and `Done`.
- Narrow terminals, or `cockpit.layout.mode: list`, keep the existing left/right
  task list. That fallback uses gh-dash-style section tabs (`Running`, `Ready`,
  `Failed`, `Recent`, `All`) with per-section counts. `Ready` is derived from
  current-project task state (`backlog`, `ready`, `failed`, etc.), not just
  scheduler-dispatchable rows; `Failed` includes failed/stuck/conflict tasks and
  runs with any non-empty attention reason.
- The status bar shows aggregate run counts and focus (`board` / `activities` in
  board mode, `tasks` / `details` in list fallback). In list fallback it also
  includes the active section and selected position (for example `Ready 2/5`).
- Live runs default to the current project (or `COCKPIT_PROJECT_ID`) and are
  deduplicated by task. The `g` scope toggle filters any mixed-project
  projection data by project id in current scope and shows all supplied
  projects in global scope. A task is `RUNNING` when both the task state and run
  state are active (`in-progress` and `in_progress` are treated the same), or
  when an active task projection has no run row yet. Stale in-progress run
  projections for closed/failed tasks are shown as
  recent, not running.
- Board cards are three-line entries: `line1` is the state glyph + id plus a
  right-aligned metadata column (status and other counts); `line2` is the
  title; `line3` is a compact meta line of `priority · type · age` where `age`
  is the activity stamp (`Updated` for tasks, `Last` for runs, falling back to
  `Created`). The age-bearing `line3` is always rendered — narrow columns like
  `Done` no longer squeeze it out of the squeezed `line1` right column.
  Long fields are truncated with an ellipsis (`…`), never word-wrapped,
  so each card is exactly 3 physical lines and `line3` stays visible.
  Within `line3`, priority and type come first; the trailing age is
  itself truncated with an ellipsis if the column is extremely narrow.
- Task/run rows are richer two-line entries: metadata (id, type, priority,
  phase/status, and available counts/checks/PR/diff/age columns) on the first
  line and the title/summary on the second.
  The selected task detail is scrollable and renders id, status, workflow,
  dependencies, project, and description as an aligned field table. Task rows
  support `y` to copy the task id and `c` to close via `task.close`. READY task
  rows also support `a` to approve via `task.approve`, `e` to edit task JSON via
  `task.update`, `n` to open an in-pane `textinput` / `textarea` create form
  that posts `task.create` with `ctrl+s`, and `N` for a one-line quick-add task
  title submitted with `enter`.
- Activities/detail region: color-coded run header, live elapsed clock for
  selected running runs, and an animated workflow phase rail with per-phase retry
  counts that collapses to a compact `4/10 · qa r2` badge on very narrow panes.
  It includes a drill-down tab strip (`summary · messages · events · logs ·
  reports · files · pr · metrics`). Log and report open targets prefer
  explicit paths returned by the live `/logs` and `/report` endpoints, falling
  back to the historical `.foreman/logs` and `docs/reports` paths when omitted.
  Message rows render oldest-first (newest at bottom) as a table (local `date/time` in
  `mm/dd hh:mm`, sender, receiver, message); event and log tabs use specialized
  selectable rows. The selected row is marked with `▶` and expands with packed
  metadata/body, event metadata/detail, or log line/text while preserving
  row-based navigation and search.
  The files tab exposes conflict-aware changed-file metadata, plain nvim open
  (`o`/focused `enter`), selected-file nvim diff against the projected base
  (`d`), and full-run `diffnav` (`D`). The metrics tab reads `/api/v1/metrics`,
  while refresh data is in flight, counts counters, gauges, and phase durations
  in the tab badge, and renders all three as bounded rows. In board mode the
  active region is called out as `focus: board` or `focus: activities`; in list
  fallback it remains `focus: tasks` or `focus: details`. Focus uses an accent
  frame, non-color active-tab brackets, and non-color selection markers; inactive
  regions can be dimmed via `cockpit.focus`.
  Set `cockpit.reducedMotion` (or
  `COCKPIT_REDUCED_MOTION=true`) to keep static live/loading indicators.
- `/` searches the activities drill-down when activities/details are focused;
  board/list search remains on `/` while the board or fallback list is focused.
  Task-list search uses a `filterableviewport` input with
  case-insensitive substring filtering over task/run ids and row text.
  Drill-down search uses `filterableviewport` exact matching, `enter` applies,
  `esc` clears, `n` / `N` jump between matches, and `o` toggles matches-only view
  while a filter is active.
- Mouse clicks can select visible board cards or fallback list rows, switch
  task-list sections and drill-down tabs, trigger visible action-bar actions, and
  open PR links; keyboard behavior remains canonical.
- The focused logs pane pans long unwrapped rows with `left` / `right`. Logs
  render line numbers. Any drill-down pane can save currently visible viewer
  rows with `s` under `cockpit.exportDir` (`COCKPIT_EXPORT_DIR` overrides it).
- Panes are height-bounded to the current terminal; task detail wrapping is
  ANSI/Unicode cell-width aware. Board mode splits the body vertically using
  `cockpit.layout.split` (default 55% board / 45% activities). Auto mode falls
  back to the left/right task list below `cockpit.layout.narrowThreshold`
  columns so the existing section-tab list remains usable on narrow terminals.
- `logs` / `reports` / `files` rows open in **nvim**: remote into a running
  session when `$NVIM` is set, otherwise suspend-and-launch inline. `files`
  offers a selected-file nvim diff (`d`), an inline selected-file side-by-side
  preview backed by `delta` when available, and a full-run `diffnav` handoff
  (`D`) when enabled.
  Conflicts open a 3-way diff.
- The `pr` tab shows Foreman-projected PR URL/state/branch metadata plus an
  aligned check summary table, and opens the PR in a browser with `o`/`enter`
  when a PR URL is present.
- Reports render as markdown via Glamour in the drill-down.

## Run it

Requires Go 1.26+.

Optional integrations are discovered at runtime and fail closed with a notice:
`diffnav` for full-run file review, `delta` for side-by-side inline selected-file
previews, `gh` plus the `gh dash` extension for repo-wide triage, `gh` plus the
`gh enhance` extension for GitHub Actions triage, `omp` for live worktree triage
in a tmux pane or inline handoff, and a platform browser opener (`open` on macOS
or `xdg-open` on Linux) for PR links. Cockpit ships generated theme fragments
under `theme/`, passes the packaged `diffnav`/`gh enhance` theme environment
when launching those tools, and can install generated fragments with
`--install-themes`. `diffnav` looks best with the tokenized `CommitMono Nerd Font`
and `nerd-fonts-status` icon set because its file tree uses icon glyphs.

```bash
cd clients/cockpit
go mod tidy                  # resolves deps + writes go.sum (needs network once)
go build -o foreman-cockpit .
./foreman-cockpit            # or: go run .
```

Install generated integration theme fragments into the current user config
locations with:

```bash
./foreman-cockpit --install-themes
```

By default the client reads the local Foreman server at
`http://127.0.0.1:4766`. Override it, or force the mock backend, with:

```bash
FOREMAN_SERVER_URL=http://127.0.0.1:4766 \
FOREMAN_SERVER_AUTH_TOKEN=$FOREMAN_SERVER_AUTH_TOKEN \
./foreman-cockpit

COCKPIT_BACKEND=mock ./foreman-cockpit
```

Optional showcase recording (requires developer-installed `vhs` and `ttyd`);
`demo.tape` sets `COCKPIT_DEMO=1`, which forces a deterministic Bubble Tea
window size and truecolor profile via v2 program options:

```bash
vhs demo.tape
```

Non-interactive live-backend smoke check:

```bash
FOREMAN_SERVER_URL=http://127.0.0.1:4766 COCKPIT_DUMP=1 ./foreman-cockpit
```

## Keys

Board mode (default on wide terminals):

```
←/→ / h/l move board columns              ↑↓ / j/k  move card in column
enter     focus activities for selected card
esc       return focus from activities to board
g         toggle current-project/global scope
/         search board/list or focused activities
mouse     click board cards/columns; wheel board columns or activities by pointer
⇥ / ⇧⇥    next / previous drill-down tab and focus it; 1–8 jump to a tab
o         open selected row in nvim; focused files enter opens the selected file
d         selected file diff in nvim          D    full run diff in diffnav
y         copy selected task ID               n/N  create task form / quick add
a         approve READY task                  e    edit READY task JSON in nvim
C         inspect CI in gh enhance            p/P  attach omp triage / plain omp
A         attach selected run                  r/R  retry / reset selected run
R         task cards reset their latest run when one is available
←/→       pan focused logs while activities are focused
s         save visible viewer rows            ?    generated keymap help
```

List fallback (`cockpit.layout.mode: list` or narrow `auto`) keeps the original
left/right list keys:

```
[ / ]     previous / next task-list section (H/L also work)
↑↓ / j/k  move task selection inside the active section
space     collapse/expand the active task-list section
enter     enter/focus the selected drill-down view; focused files opens selected row
esc       leave the drill-down view and return focus to the task list
↑↓ / j/k  move the highlighted row; messages/events/logs mark selection with `▶`
ctrl+d/u  half-page down/up in the focused drill-down view
mouse     wheel over task list moves tasks; wheel over drill-down tabs scrolls that view
          click section tabs, visible task/run rows, or drill-down tabs to select them
```

Opening a drill-down view with `enter`, `tab`, or `1`–`8` selects its newest
rendered line. Moving inside a drill-down keeps the selected row near the middle
of the viewport when there is room; near the top or bottom it clamps to the edge.
Live updates keep a manually moved viewer cursor on the same rendered line when
possible instead of snapping back to the bottom.
In `messages`, the cursor moves by whole messages: the header is selected, the
tab and run header show the current position (`messages 12/50`), and the body
preview is kept in the viewport with the header when there is room for both.

## Integrations

Controlled by `.foreman/config.yaml` (all optional) and `COCKPIT_DIFFNAV`,
`COCKPIT_DELTA`, `COCKPIT_GHDASH`, `COCKPIT_GHENHANCE`, `COCKPIT_OMP`,
`COCKPIT_OMP_MODE`, `COCKPIT_EXPORT_DIR`, `COCKPIT_FOCUS_STYLE`,
`COCKPIT_FOCUS_DIM_INACTIVE`, and `COCKPIT_REDUCED_MOTION` env overrides
(`auto` / `on` / `off` where applicable):

```yaml
editor:
  cmd: nvim
  mode: auto
  remoteServer: ""   # explicit socket/address; empty = autodetect $NVIM
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
  omp:
    enable: auto
    cmd: omp
    mode: auto        # auto | tmux | inline | window
    tmux:
      split: horizontal
    keepShell: true
    session: per-task
    args: []
cockpit:
  exportDir: ~/.foreman/cockpit-exports
  focus:
    style: both         # both | border | dim
    dimInactive: true
  reducedMotion: false
  layout:
    mode: auto            # auto | board | list
    split: 0.55           # board height fraction; sanitized to a safe range
    narrowThreshold: 100  # columns below which auto uses the list fallback
  board:
    cardCap: 12           # visible cards per column before "… N more"
    order: activity       # activity | priority (activity ordering is wired in v1)
  taskList:
    width: auto          # auto | columns | percentage, e.g. 58%
    sections: []         # optional [{name, filter}] task/run section strip
```

The cockpit only uses these tools as full-screen Bubble Tea handoffs or cached
command output. `diffnav`, `gh dash`, `gh enhance`, and inline `omp` run through
`tea.ExecProcess`; `omp` prefers a non-suspending tmux pane when `$TMUX` is set.
`p` writes a triage brief for the selected failed/stuck run and starts `omp`;
secret-like lines (`token`, `secret`, `authorization`/`bearer`, API/private keys,
passwords, credentials, and common GitHub PAT prefixes) are redacted before the
brief is written. `P` opens plain `omp` without a brief. The brief's opening
instruction references the exact written path, including the temp-dir fallback
used when the worktree does not ignore `.foreman/`. With `session: per-task`,
each task uses a
stable `--session-dir` under the user state directory and adds `--continue` when
a prior session exists. The brief includes PR state, recent signals, conflicted
files, targeted report excerpts, and error-like log lines.
Active-looking runs (`running`, `in_progress`, `pending`) are refused even if a
projection group is stale, avoiding two agents mutating the same worktree.
Inline file previews read a completed `git diff | delta --config
theme/delta.gitconfig`/plain `git diff` command. Generated theme fragments live
in `theme/`: `tokens.yaml` drives cockpit color constants, `gh-dash.yml`,
`enhance.env`, `diffnav/config.yml`, `delta.gitconfig`, and `glamour.json`.
`foreman-cockpit --install-themes` writes those generated fragments to the
current config home, backing up existing differing files with `.bak`; `delta`
still requires including the installed fragment from git config for external
tools outside cockpit-managed previews.

`gh dash` can also point back into the cockpit workflow through custom PR
keybindings. Configure `repoPaths` so `{{.RepoPath}}` resolves locally, then add
commands such as:

```yaml
keybindings:
  prs:
    - key: f
      name: foreman cockpit
      command: >
        cd {{.RepoPath}} && foreman-cockpit
    - key: d
      name: foreman diffnav
      command: >
        cd {{.RepoPath}} && git diff {{.BaseRefName}}...HEAD | diffnav
    - key: c
      name: gh enhance
      command: >
        cd {{.RepoPath}} && gh enhance
```

The template fields come from `gh dash`; `{{.RepoPath}}` is resolved by its
`repoPaths` config and `{{.PrNumber}}`/`{{.BaseRefName}}` describe the selected
PR. Keep these as operator-local commands rather than cockpit runtime behavior.

## nvim open modes

In this client the editor mode is inferred from config/env: `auto` uses a remote
session when `editor.remoteServer` or `$NVIM` is present, otherwise `inline`.
`remote` always targets the configured/discovered session, and `inline` always
suspends the cockpit. The editor binary comes from `editor.cmd` or `$EDITOR`
(falling back to `nvim`).

## Status / scope

- READY task approval/edit/create, selected-run attach, `omp`
  triage/plain handoffs, `gh dash`, `gh enhance`, and PR browser opens are live
  actions through the cockpit client, command bus, and tool handoffs. Selected-run
  retry/reset post `run.retry`/`run.reset`; selected task cards can also reset
  their latest known run. The server requeues the associated task to `ready`
  without mutating the terminal run record.
- The `httpClient` field mapping accepts the current `/api/v1` wrapper shapes
  (`inbox`, `logs.entries`, `report`, `metrics`) and surfaces HTTP/JSON failures
  in the cockpit notice bar. If the aggregate `/api/v1/events` endpoint fails for
  a run, the client falls back to `/api/v1/runs/:run_id/debug` for the events tab.
  Foreman-projected worktree/branch/base metadata, row counts, diff totals, and
  PR fields are read from `/api/v1/runs`, including PR URL, state, mergeability,
  review decision, and check summary; if a legacy run lacks those projected PR
  fields, `httpClient.PR` folds `/api/v1/events` and then debug timeline PR
  payloads. ADR phase 2 will replace the hand mapping with generated client code
  when a published OpenAPI schema is available.
- No dedicated file-change endpoint is required; `httpClient.Files` prefers the
  selected run worktree and projected base branch from `/api/v1/runs`, runs
  `git diff --numstat`/`--name-status`, then falls back to structured or legacy
  `/api/v1/runs/:run_id/debug` timeline `payload` / `file_changes` fields when
  no worktree diff is available.

## Architecture

The root Bubble Tea model orchestrates client refresh, layout, focus, active tab,
notices, and actions. Component state lives in small cockpit-owned types:

- `board.go` derives the five Kanban columns from the filtered `TaskList` item
  set, tracks selected column/card identity, and applies the configured card cap.
- `task_list.go` remains the source of truth for gh-dash-style `Running` /
  `Ready` / `Failed` / `Recent` / `All` section tabs, active-section collapse,
  configurable field-token filters (including `attention`, `pr`, and
  `messages`), current/global project scope, selected-row identity, and the list
  fallback's `filterableviewport` pane with a sticky section/filter header and
  case-insensitive substring search over rendered row metadata.
- `viewer.go` maps keyed drill-down rows into `robinovitch61/viewport` and
  `filterableviewport` items, preserving selected-row identity across refreshes.
  Immediately following unselectable rows (message bodies, diff previews) are
  packed with their parent selectable row when the viewport is tall enough, so
  navigation lands only on actionable/header rows while the viewport component
  handles rendering, ANSI/Unicode cell-width-safe wrapping, scrolling,
  horizontal panning, match highlighting, and bottom-follow behavior.

## Layout

```
main.go          program entry + client selection
client.go        Client interface, types, mock + HTTP implementations
config.go        cockpit config loading and env overrides
tools.go         executable availability checks
model.go         root Elm orchestration: refresh, focus, active tab, actions
task_list.go     scope/search/filter, selected item, and fallback grouped list state
board.go         Kanban column derivation, selection, caps, and board state
viewer.go        drill-down row/cursor/viewport state
view.go          Lip Gloss rendering (status bar, board/list, rail, tabs, body, action bar)
nvim.go          open-in-nvim resolution (remote vs inline) + editor config
diffnav.go       full-run diffnav handoff
delta_preview.go selected-file inline diff preview
gh_dash.go       gh dash handoff
pr.go            PR projection rendering and browser opener
styles.go        palette + shared styles
```
