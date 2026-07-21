# Foreman Cockpit — UI/UX Design Spec

Status: Implemented in `clients/cockpit/`; scope boundaries are explicit non-goals · Date: 2026-07-11 · Owner: Leo D'Angelo
Related: ADR 0001 (Go clients over Elixir core), current `src/cli/super-tui`

## Goal

A single-pane cockpit that answers four operator questions without mode-hunting:

1. What's currently running?
2. What's available to run?
3. What's the status of the run(s)?
4. What messages, events, logs, reports, and file changes exist per run
   (active or past)?

The current `super-tui` answers these but forces the operator to choose across
five independent navigation axes at once — view (overview/inbox/status/board),
scope, filter, focus, and detail tab. This spec collapses navigation to **two
axes**: which item (board/list), and which activity/detail tab.

## Layout

One screen. No view switching. Wide terminals default to a top/bottom board
layout with status chrome:

```
┌ foreman watch — cockpit ─────────────────────────────────────────────────────┐
│ foreman  3 running · 5 ready · 2 blocked · 14 done  focus: board · ↻ 2s      │ status
├────────────┬────────────┬────────────┬────────────┬──────────────────────────┤
│ Backlog 12 │ Ready 5    │ In Prog 3  │ Blocked 2  │ Done 14                  │ board
│ ─────────  │ ─────────  │ ─────────  │ ─────────  │ ─────────                │ top
│ ▸TRD-…     │ TASK-341   │ ●TRD-…     │ ✗TASK-329  │ ✓TRD-…                   │
│  auth      │ add OAuth  │ developer  │ conflict   │ merged #482              │
│  P0 · task │ P0 · task  │ P1 · 4m12s │ P2 · bug   │ …11 more                 │
├────────────┴────────────┴────────────┴────────────┴──────────────────────────┤
│ TRD-2026-014   run a1b2c3d4…          running                                │ activities
│ ───────────────────────────────────────────────────────────────────────────── │ bottom
│ explorer ✓─developer ●─documentation ○─qa ○…                                  │ phase rail
│ [summary] messages 3 events 4 logs⧉ reports⧉ files⧉ pr 1 metrics 2          │ tabs
│ Status: implementing auth middleware…    worktree ~/wt/TRD-2026-014          │ body
│ ▸ open DEVELOPER_REPORT.md in nvim                                           │ actions
├───────────────────────────────────────────────────────────────────────────────┤
│ ←→/h l board  ↑↓/j k card  enter activities  esc board  a approve  ? help    │ keybar
└───────────────────────────────────────────────────────────────────────────────┘
```

`cockpit.layout.mode: auto` uses the board when the terminal is at least
`cockpit.layout.narrowThreshold` columns wide (default 100). Below that threshold,
or when `cockpit.layout.mode: list`, the cockpit keeps the existing left/right
section-tab task list and detail pane. `cockpit.layout.mode: board` forces the
top/bottom board. The board/detail height split comes from `cockpit.layout.split`
(default `0.55`, sanitized to a safe range).

### Top board — fleet overview

The board columns are:

- **Backlog** — `open`, `todo`.
- **Ready** — `ready`, `pending`.
- **In Progress** — `running`, `in_progress`, `cooldown`, plus live phase names
  such as `explorer`, `developer`, `qa`, `reviewer`, and `finalize`.
- **Blocked** — failed/stuck/conflict/blocked/review/test-failed statuses,
  unknown statuses, any non-empty attention reason, or verdict `fail|blocked`.
- **Done** — `merged`, `completed`, `done`, `closed`, `reset`, `pr_created`.

Headers show true counts. Columns render at most `cockpit.board.cardCap` visible
cards (default 12) before a `… N more` overflow row. v1 ordering is
last-activity first; `cockpit.board.order` normalizes `activity|priority`, but
priority-first ordering is not required unless the board core supports it.
Board cards are three-line entries: `line1` is the state glyph + id plus a
right-aligned metadata column (status, counts, etc.); `line2` is the title;
`line3` is a compact meta line of `priority · type · age` where `age` is the
activity stamp (`Updated` for tasks, `Last` for runs, falling back to
`Created`). The age-bearing `line3` is always rendered — narrow columns like `Done`
no longer squeeze it out of the squeezed `line1` right column.
Long fields are truncated with an ellipsis (`…`), never word-wrapped, so
each card is exactly 3 physical lines and `line3` stays visible. Within
`line3`, priority and type come first; the trailing age is itself truncated
with an ellipsis if the column is extremely narrow.

The selected card drives the entire activities region through the same selected
`TaskList` item identity used by the list fallback, so approve/edit/create,
attach/retry/reset, nvim/diffnav, PR, and OMP actions continue to target the
selected item.

### List fallback — narrow or explicit list mode

The fallback task list is organized as a gh-dash-style section strip with counts:

- **Running** — tasks and runs whose task/run status is active (`pending | running | in_progress | cooldown`).
- **Ready** — current-project tasks that are not terminal/running.
- **Failed** — failed/stuck/conflict/test-failed tasks or runs with any non-empty
  attention reason.
- **Recent** — projected runs that are not currently active, most-recent first,
  capped in the default Recent section while counts keep the full total.
- **All** — the combined task/run list.

### Activities/detail region — Q3 detail and Q4

- **Detail header** — task id, run id, and run status (color-coded). For
  attention runs, a second line states the reason (`failed: merge_conflict`,
  `retrying: coderabbit_findings (2)`).
- **Phase rail** — the selected run or task's workflow phases as a horizontal
  sequence with per-phase retry counts and glyphs: `✓` done, `●` active
  (breathing/animated), `○` pending, `✗` failed, `↻` retrying. For tasks
  without an active run, phases are derived from the workflow YAML and shown as
  pending. It wraps on normal narrow panes and collapses to a compact
  `4/10 · qa r2` badge on very narrow panes. This is the at-a-glance status. (Q3)
- **Tab strip** — `summary · messages · events · logs · reports · files · pr ·
  metrics`. Tabs show counts; `logs`, `reports`, and `files` carry an `⧉` marker
  indicating their rows are openable in nvim. (Q4)
- **Drill-down body** — content for the active tab, scoped to the selected run
  (active or past). `summary` is default and needs no fetch beyond the run
  projection. The summary tab renders all available run fields as key-value rows:
  title, current phase/status, verdict, elapsed time, created time, message/event
  counts, PR state, diff stats (+/-), checks summary (✓/✗/●), attention indicator,
  and the pre-existing worktree/branch/last fields. Fields with empty values are
  omitted. No additional API calls are required.
- **Action bar** — shows the exact resolved command and open mode for openable
  rows, and also exposes run/task/PR action rows. Run actions include
  attach/retry/reset, `omp`, `gh dash`, and `gh enhance` for both keyboard and
  mouse hit-testing. See nvim integration.

## State model

The cockpit is an Elm-architecture app (Bubble Tea `model → update → view`).
The root model owns cross-component orchestration: client refresh, layout size,
selected run/task identity, active tab, focus, notices/errors, spinner state,
selected-running-run stopwatch state, and mutating commands. Local UI mechanics
live in small cockpit-owned components:

| Component | Owns |
|-----------|------|
| `Board` | five Kanban columns derived from filtered `TaskList` items, selected column/card identity, per-column card caps, and activity-first ordering |
| `TaskList` | source of truth for scope, search/filter grammar, selected item identity, configurable section tabs, active-section collapse, and the narrow/list-mode `filterableviewport` fallback |
| `Viewer` | keyed drill-down rows mapped into `robinovitch61/viewport` items, selected line identity, bottom-follow behavior, and packed unselectable child rows (message bodies / diff previews) |
| Tab adapters | conversion of summary/messages/events/logs/reports/files/pr/metrics data into stable keyed viewer lines and nvim/browser targets where applicable |

All data is fetched from the Elixir core; the cockpit only derives presentation
state from asserted task/run status, phase, and projection fields. A periodic
tick (default 2s) refreshes projections. The status bar, active phase rail,
diff-loading rows, and metrics refresh rows use a `bubbles/v2/spinner` only while
runs or loading states are active, and the selected running run gets a lightweight
`bubbles/v2/stopwatch` elapsed indicator. `cockpit.reducedMotion` disables spinner
frames and stopwatch display for accessibility / low-power terminals. The metrics
tab consumes `/api/v1/metrics` and renders counters, gauges, and phase-duration
bars without client-side authoritative aggregation.

The keybar includes an explicit focus label: `focus: board` / `focus:
activities` in board mode and `focus: tasks` / `focus: details` in the
list fallback. In board mode the right pane splits vertically into
board cards (top) and tab content (bottom) on every tab; the board
stays visible so the user always has task context, and the status
bar surfaces the selected task ID with a `▶` marker so selection is
visible regardless of which tab is active. The focused region uses
the accent border; inactive regions use the blur border and, by
default, a muted content palette controlled by `cockpit.focus`.
Mouse input mirrors keyboard targets for visible board cards,
fallback task-list sections/rows, and drill-down tabs; wheel routing remains
region-sensitive.

## Keymap

Global:

| Key | Action |
|-----|--------|
| `←`/`→`, `h`/`l` | board focused: move between Kanban columns; activities focused on logs: pan long rows |
| `↑`/`↓`, `j`/`k` | board/list focused: move card or fallback task selection; activities focused: move the highlighted row in messages/events/logs/reports/files/pr |
| `enter` | board/list focused: focus activities/details for the selected item; in focused files, open the selected file |
| `esc` | activities/details focused: return focus to board/list; clears search while searching |
| message/event/log rows | messages render oldest-first (chronological) as selectable table rows with local `date/time` (`mm/dd hh:mm`), sender, receiver, and message columns; event/log rows select one signal row at a time with a visible `▶` marker; selected messages show metadata/body detail, selected events show time/type/detail, selected logs show line/text detail; message tabs also show `messages <current>/<total>` in both the tab and run header |
| mouse wheel | scroll the region under the pointer: active board column/list fallback or activities/details |
| `ctrl+d` / `ctrl+u` | half-page down/up in the focused drill-down view |
| `s` | save the currently visible focused drill-down rows to `cockpit.exportDir` |
| `⇥` / `⇧⇥` | next / previous drill-down tab and focus it |
| `1`–`8` | jump directly to a tab and focus it |
| `[`/`]`, `H`/`L` | move between task-list sections while the task list is focused; `space` collapses or expands the active section |
| `/` | search the board/list when that region is focused; search the focused activities/details pane otherwise |
| `g` | toggle current-project vs global scope |
| `o` / focused `enter` | on PR, open the PR in a browser; in focused files, open the selected file |
| `A` | attach the selected run through `GET /api/v1/runs/:id/attach` |
| `p` | attach an `omp` session to the selected run worktree with a generated triage brief; refuses actively running workers |
| `P` | attach plain `omp` to the selected run worktree without a brief |
| `r` | retry the selected run through the command bus |
| `R` | reset the selected run through the command bus |
| `G` | open `gh dash` when enabled and available |
| `C` | open `gh enhance` for the selected run when enabled and available |
| `?` | toggle generated keymap help in the activities/details pane; `esc` closes it |
| `q` | quit |


Focused task-list search:

| Key | Action |
|-----|--------|
| `/` | open the task-list filter input while the task list is focused |
| `enter` | apply the task-list filter |
| `esc` | clear the active/applied task-list filter |

Focused drill-down search:

| Key | Action |
|-----|--------|
| `/` | open exact-match filter input for the focused messages/events/logs/reports/files pane |
| `enter` | apply the filter and keep match navigation active |
| `esc` | clear the active drill-down filter before leaving view focus |
| `n` / `N` | jump to the next / previous match while a drill-down filter is active |
| `o` | toggle matches-only rows while a drill-down filter is active |

Entering a view selects its newest rendered line. Live updates preserve a moved viewer cursor by rendered line identity when possible instead of snapping back to the bottom.

Task rows add:

| Key | Action |
|-----|--------|
| `y` | copy the selected task id |
| `c` | close the selected task through the command bus (`task.close`) |
| `a` | approve the selected READY task (`task.approve`) |
| `e` | edit the selected READY task JSON in nvim and submit changed fields (`task.update`) |

Openable tabs (`logs`, `reports`, `files`) add:

| Key | Action |
|-----|--------|
| `o` / focused `enter` | open the selected file row in nvim; on `pr`, open the PR URL in a browser |
| `d` | open a selected-file diff in nvim (files only; conflicts open 3-way) |
| `D` | open the full run diff in `diffnav` from the files tab |

## nvim integration

The killer feature: open any log, report, or changed file directly in nvim from
the drill-down. Because the cockpit is itself a full-screen terminal app, the
default avoids nesting a TUI inside a TUI.

### Open modes

- **Remote (preferred).** If a running nvim is detected — `$NVIM` socket set
  inside an embedded terminal, or a configured `--listen` server address — the
  file opens *there* via `nvim --server <addr> --remote <path>`. The cockpit
  keeps running and refreshing; the file appears in the operator's existing
  editor (ideal for tmux / multi-pane setups).
- **Inline (fallback).** If no session is found, the cockpit suspends, launches
  `nvim <path>` in the same terminal, and resumes on exit. In Bubble Tea this is
  `tea.ExecProcess`.

### Target resolution

| Tab | Target |
|-----|--------|
| logs | `~/.foreman/logs/<run-id>.log` (or the path from `/runs/:id/logs`) |
| reports | the artifact path from `/runs/:id/report` (e.g. `docs/reports/<task>/DEVELOPER_REPORT.md`) |
| files | `<worktree>/<relative-path>` from the selected run worktree/base metadata exposed by `/api/v1/runs`, or the local `.foreman/worktrees/<project-id>/<task-id>` fallback when the run projection omits a worktree; file rows prefer `git diff --numstat`/`--name-status` against the projected base branch and otherwise fall back to best-effort paths derived from `/runs/:id/debug` timeline payloads |

### Files: focused diff preview and handoffs

- `o` or focused `enter` opens the file plain in nvim.
- `d` opens the selected file as an nvim diff against the projected base. Remote
  mode sends a diff command to the running session; inline mode uses `nvim -d`.
  Conflicted files open a 3-way diff (`Gvdiffsplit!` / merge layout).
- `D` opens a full-run `git diff <base>...HEAD | diffnav` handoff when enabled.
- The files tab also renders an inline preview for the selected file. It uses
  `git diff <base>...HEAD -- <path> | delta --side-by-side` when `delta` is
  enabled and available, and falls back to plain `git diff` output otherwise.
- `C` opens `gh enhance` as a full-screen handoff for the selected run worktree
  when the GitHub CLI and extension are available; use it from the `pr` tab to
  inspect failing/pending Actions checks and rerun jobs.
- The `pr` tab renders PR URL/branch/review metadata and passed/failed/pending
  checks as aligned field rows so the check summary scans vertically.
- `p` attaches `omp` to the selected run worktree for live human triage. In
  `auto` mode it opens a tmux pane when `$TMUX` is present; otherwise it suspends
  the cockpit and runs inline. The triage path writes a non-secret brief with run
  status, failure signals, PR state, and conflicted files; `P` opens plain `omp`.
  Active running workers are refused to avoid concurrent mutations.
- The `metrics` tab renders `/api/v1/metrics` counters, gauges, and phase
  durations as bounded rows, counts all three in the tab badge, and shows a
  spinner while refresh data is in flight.
  Empty/missing metrics render a static empty state.
- The cockpit uses generated theme artifacts from `clients/cockpit/theme/`:
  `tokens.yaml` drives Lip Gloss constants, Glamour JSON, `gh-dash.yml`,
  `enhance.env`, `diffnav/config.yml`, and `delta.gitconfig`. Handoffs pass
  packaged env for `diffnav` (`DIFFNAV_CONFIG_DIR`) and `gh enhance`
  (`ENHANCE_THEME`) where supported; inline delta previews pass
  `theme/delta.gitconfig` via `delta --config`; `--install-themes` writes
  generated fragments to the operator config home with `.bak` backups.
- The Go cockpit targets Bubble Tea v2. `View()` returns `tea.View`, with
  alt-screen and cell-motion mouse mode declared on the view rather than passed
  as `NewProgram` options.
- Drill-down panes use `robinovitch61/viewport` for body rendering and
  scrolling. Cursor identity remains keyed by Foreman data, and unselectable
  child rows are attached to the selected parent row.

Reports are markdown and render with Glamour in the drill-down preview before
the operator chooses to open them in nvim.

### Configuration

`.foreman/config.yaml` may contain cockpit integration blocks (all optional,
sensible defaults shown):

```yaml
editor:
  cmd: nvim              # editor binary
  mode: auto             # auto | remote | inline
  remoteServer: ""       # explicit socket/address override; empty = autodetect $NVIM
integrations:
  diffnav:
    enable: auto         # auto | on | off
    base: origin/dev
    watch: false
  delta:
    enable: auto         # auto | on | off
  ghDash:
    enable: auto         # auto | on | off
    args: []
  ghEnhance:
    enable: auto         # auto | on | off
    args: []
  omp:
    enable: auto         # auto | on | off
    cmd: omp
    mode: auto           # auto | tmux | inline | window
    tmux:
      split: horizontal  # horizontal | vertical | window
    keepShell: true
    session: per-task
    args: []
cockpit:
  exportDir: ~/.foreman/cockpit-exports
  focus:
    style: both          # both | border | dim
    dimInactive: true
  layout:
    mode: auto            # auto | board | list
    split: 0.55           # board height fraction; sanitized to a safe range
    narrowThreshold: 100  # cols below which auto uses the list fallback
  board:
    cardCap: 12           # visible cards per column before "… N more"
    order: activity       # activity | priority (activity ordering is wired in v1)
  taskList:
    width: auto          # auto | columns | percentage, e.g. 58%
    sections: []         # optional [{name, filter}] section strip
  reducedMotion: false
```

`mode: auto` = remote when a session is found, else inline (the recommended
default). `mode: remote` never suspends; `mode: inline` always suspends.
`COCKPIT_DIFFNAV`, `COCKPIT_DELTA`, `COCKPIT_GHDASH`, `COCKPIT_GHENHANCE`,
`COCKPIT_OMP`, `COCKPIT_OMP_MODE`, `COCKPIT_EXPORT_DIR`,
`COCKPIT_FOCUS_STYLE`, `COCKPIT_FOCUS_DIM_INACTIVE`, and
`COCKPIT_REDUCED_MOTION` override the respective integration and cockpit values.

`gh dash` reverse handoffs are operator-local config, not cockpit state. Add
custom PR keybindings in `gh-dash.yml` when desired, using `{{.RepoPath}}` from
`repoPaths` plus selected-PR fields such as `{{.PrNumber}}` and
`{{.BaseRefName}}`, for example to `cd {{.RepoPath}} && foreman-cockpit`,
`git diff {{.BaseRefName}}...HEAD | diffnav`, or `gh enhance`.

## Scope boundaries / non-goals

- No write/command execution beyond READY task mutations, task creation, selected-run
  attach/retry/reset, PR opens, and tool handoffs.
  Retry/reset use `run.retry`/`run.reset` commands that requeue the associated
  task to `ready`; they do not rewrite terminal run lifecycle records.
- `/api/v1/runs` includes selected-run metadata as both canonical VCS projection
  fields (`worktree_path`, `base_ref`, `branch`) and cockpit-friendly aliases
  (`worktree`, `base_branch`, `branch_name`). It also exposes row counts,
  diff totals, and PR readiness fields (`messages_count`, `events_count`,
  `diff_added`, `diff_removed`, `pr_checks`, `pr_review_decision`,
  `pr_mergeable`) so local file diff, diffnav, gh enhance, OMP, and PR handoffs
  do not need separate worktree/PR endpoints.
- No auth token refresh flows; read the token from the environment.
- No pagination controls beyond the RECENT cap.

## Resolved questions

- RECENT remains projection/count scoped; auth token refresh and RECENT
  pagination controls are explicit non-goals.
- Resolved: the phase rail follows the selected run or task's workflow phase order,
  includes retry counts, and collapses to a compact `4/10 · qa r2` badge on very
  narrow terminals instead of consuming multiple wrapped rows. For tasks without an
  active run, phases are derived from the workflow YAML and shown as pending.
