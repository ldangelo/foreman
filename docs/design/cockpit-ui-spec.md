# Foreman Cockpit — UI/UX Design Spec

Status: Implemented in `clients/cockpit/` with documented POC caveats · Date: 2026-07-11 · Owner: Leo D'Angelo
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
axes**: which item (left), and which drill-down (right).

## Layout

One screen. No view switching. Three regions plus chrome.

```
┌ foreman watch — cockpit ─────────────────────────────────────────────────────┐
│ foreman  3 running · 5 ready · 14 done      nvim ⇄ attached · dev · ↻ 2s      │  status bar
├───────────────────────────┬───────────────────────────────────────────────────┤
│ Running 3  Ready 5  Failed 1 │  TRD-2026-014   run a1b2c3d4…          running │  detail header
│ filter: current project      │  ───────────────────────────────────────────── │
│ ● TRD-2026-014 · task · P0   │  explorer ✓─developer ●─documentation ○─qa ○… │  phase rail
│   implement auth middleware  │  ───────────────────────────────────────────── │
│ ▸ TASK-338 · bug · P1    qa  │  [summary] messages 3 events 4 logs⧉ reports⧉ │  tab strip
│   fix flaky retry handling   │  files⧉ pr 1 metrics 2                        │
│ Ready  Failed  Recent  All   │                                                │
│ ○ TASK-341 · feature · P0    │  Status: implementing auth middleware…         │  drill-down body
│   add OAuth provider config  │  worktree ~/wt/TRD-2026-014                    │
│ ✗ TASK-329 · bug · P2 failed │  branch   foreman/TRD-2026-014                 │
│   rebase conflict in finalize│  last     12s ago · progress_update            │
│                              │                                                │
│                              │ ─────────────────────────────────────────────  │
│                              │ ▸ open DEVELOPER_REPORT.md in nvim            │  action bar
├───────────────────────────┴───────────────────────────────────────────────────┤
│ ↑↓/j/k tasks  enter view  ctrl+d/u page  D diffnav  G gh dash  C enhance  ? help │  keybar
└────────────────────────────────────────────────────────────────────────────────┘
```

### Left column — the answer to Q1, Q2, Q3 at a glance

The task list is organized as a gh-dash-style section strip with counts:

- **Running** — runs with status `pending | running | in_progress | cooldown`.
  Each row shows a state glyph, id/type/priority/phase metadata, and a second
  title/summary line. (Q1)
- **Ready** — current-project tasks that are not terminal/running. Each row
  shows a state glyph, id/type/priority/status metadata, and a second
  title/summary line; selecting one shows an aligned field table with id, status,
  workflow, dependencies, project, and description, plus approve, edit, and create
  actions. Wrapped detail text must respect terminal display cell width, including
  ANSI styling and wide glyphs. (Q2)
- **Failed** — failed/stuck/conflict/test-failed tasks or runs needing attention.
- **Recent** — terminal runs (`completed | merged | pr-created | failed | reset`),
  most-recent first, capped (default 15). (Q3 for finished work)
- **All** — the combined task/run list.

The selected row drives the entire right side.

### Right column — the answer to Q3 detail and Q4

- **Detail header** — task id, run id, and run status (color-coded). For
  attention runs, a second line states the reason (`failed: merge_conflict`,
  `retrying: coderabbit_findings (2)`).
- **Phase rail** — the workflow phases as a horizontal sequence with per-phase
  glyphs: `✓` done, `●` active (breathing/animated), `○` pending, `✗` failed,
  `↻` retrying. It wraps on normal narrow panes and collapses to a compact
  `4/10 · qa` badge on very narrow panes. This is the at-a-glance status. (Q3)
- **Tab strip** — `summary · messages · events · logs · reports · files`. Tabs
  show counts; `logs`, `reports`, and `files` carry an `⧉` marker indicating
  their rows are openable in nvim. (Q4)
- **Drill-down body** — content for the active tab, scoped to the selected run
  (active or past). `summary` is default and needs no fetch beyond the run
  projection.
- **Action bar** — appears only on openable tabs when a row is selected; shows
  the exact resolved command and the open mode (remote vs inline). The run action
  row exposes attach/retry/reset, `omp`, `gh dash`, and `gh enhance` for both
  keyboard and mouse hit-testing. See nvim integration.

## State model

The cockpit is an Elm-architecture app (Bubble Tea `model → update → view`).
The root model owns cross-component orchestration: client refresh, layout size,
selected run/task identity, active tab, focus, notices/errors, spinner state,
selected-running-run stopwatch state, and mutating commands. Local UI mechanics
live in small cockpit-owned components:

| Component | Owns |
|-----------|------|
| `TaskList` | configurable section tabs mapped into a `filterableviewport` left pane, selected item, sticky section/filter header, case-insensitive substring search, and scope |
| `Viewer` | keyed drill-down rows mapped into `robinovitch61/viewport` items, selected line identity, bottom-follow behavior, and packed unselectable child rows (message bodies / diff previews) |
| Tab adapters | conversion of summary/messages/events/logs/reports/files/pr/metrics data into stable keyed viewer lines and nvim/browser targets where applicable |

All data is fetched from the Elixir core; the cockpit never infers state the
core has not asserted. A periodic tick (default 2s) refreshes projections. The
status bar, active phase rail, diff-loading rows, and metrics refresh rows use a
`bubbles/v2/spinner` only while runs or loading states are active, and the
selected running run gets a lightweight `bubbles/v2/stopwatch` elapsed indicator.
`cockpit.reducedMotion` disables spinner frames and stopwatch display for
accessibility / low-power terminals. The metrics tab consumes `/api/v1/metrics`
and renders counters, gauges, and phase-duration bars without client-side
authoritative aggregation.

The keybar includes an explicit `focus: tasks` / `focus: details` label. The
focused pane uses the accent border; the inactive pane uses the blur border and,
by default, a muted content palette controlled by `cockpit.focus`.
Mouse input mirrors keyboard targets for visible task-list sections, task/run
rows, and drill-down tabs; wheel routing remains pane-sensitive.


## Keymap

Global:

| Key | Action |
|-----|--------|
| `↑`/`↓`, `j`/`k` | move task selection while the task list is focused |
| `enter` | enter/focus the selected drill-down view; focus label changes to `details` |
| `esc` | leave the drill-down view and return focus to the task list; clears search while searching |
| `↑`/`↓`, `j`/`k` | move the highlighted line in the focused messages/events/logs/reports/files/pr view; the viewport keeps the selection near the middle when possible and clamps at the edges |
| message rows | select whole messages by header; show `messages <current>/<total>` in both the tab and run header; keep the selected message body preview visible with the header when space allows |
| mouse wheel | scroll the pane under the pointer: task list on the left, active drill-down view on the right |
| `ctrl+d` / `ctrl+u` | half-page down/up in the focused drill-down view |
| `←` / `→` | pan long unwrapped rows in the focused logs view |
| `s` | save the currently visible focused drill-down rows to `cockpit.exportDir` |
| `⇥` / `⇧⇥` | next / previous drill-down tab and focus it |
| `1`–`8` | jump directly to a tab and focus it |
| `[`/`]`, `H`/`L` | move between task-list sections while the task list is focused |
| `/` | search the task list when the left side is focused; search the focused drill-down pane when the right side is focused |
| `g` | toggle current-project vs global scope |
| `enter` | focus details; on PR, open the PR in a browser |
| `A` | attach the selected run through `GET /api/v1/runs/:id/attach` |
| `p` | attach an `omp` session to the selected run worktree with a generated triage brief; refuses actively running workers |
| `P` | attach plain `omp` to the selected run worktree without a brief |
| `r` | retry the selected run through the command bus |
| `R` | reset the selected run through the command bus |
| `G` | open `gh dash` when enabled and available |
| `C` | open `gh enhance` for the selected run when enabled and available |
| `?` | toggle generated keymap help in the right detail pane; `esc` closes it |
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

READY task rows add:

| Key | Action |
|-----|--------|
| `y` | copy the selected task id |
| `a` | approve the selected READY task (`task.approve`) |
| `e` | edit the selected READY task JSON in nvim and submit changed fields (`task.update`) |

Openable tabs (`logs`, `reports`, `files`) add:

| Key | Action |
|-----|--------|
| `o` | open the selected row in nvim; on `pr`, open the PR URL in a browser |
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
| files | `<worktree>/<relative-path>` from the selected run worktree diff (`git diff --numstat`/`--name-status` against the projected base branch), otherwise best-effort paths derived from `/runs/:id/debug` timeline payloads |

### Files: focused diff preview and handoffs

- `o` opens the file plain in nvim.
- `d` opens the selected file as an nvim diff against the projected base. Remote
  mode sends a diff command to the running session; inline mode uses `nvim -d`.
  Conflicted files open a 3-way diff (`Gvdiffsplit!` / merge layout).
- `D` opens a full-run `git diff <base>...HEAD | diffnav` handoff when enabled.
- The files tab also renders an inline preview for the selected file. It uses
  `git diff <base>...HEAD -- <path> | delta` when `delta` is enabled and
  available, and falls back to plain `git diff` output otherwise.
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
  remote:
    autodetect: true     # use $NVIM / discovered --listen socket
    server: ""           # explicit socket/address override
  diff:
    files: diff          # diff | edit  (default action for the files tab)
    tool: ""             # git difftool name; empty = nvim -d
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
pr:
  provider: github
cockpit:
  exportDir: ~/.foreman/cockpit-exports
  focus:
    style: both          # both | border | dim
    dimInactive: true
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

## Non-goals for the POC

- No write/command execution beyond READY task mutations, task creation, selected-run
  attach/retry/reset, PR opens, and tool handoffs.
- No auth token refresh flows; read the token from the environment.
- No pagination controls beyond the RECENT cap.

## Resolved questions

- RECENT remains projection/count scoped for the POC; auth token refresh and
  RECENT pagination controls are explicit non-goals.
- Resolved: the phase rail collapses to a compact `4/10 · qa` badge on very
  narrow terminals instead of consuming multiple wrapped rows.
