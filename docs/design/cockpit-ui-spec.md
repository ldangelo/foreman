# Foreman Cockpit — UI/UX Design Spec

Status: Draft · Date: 2026-07-09 · Owner: Leo D'Angelo
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
│ RUNNING (3)               │  TRD-2026-014   run a1b2c3d4…            running    │  detail header
│ ▸ TRD-2026-014  developer │  ─────────────────────────────────────────────────│
│   PRD-2026-004  qa        │  explorer ✓─developer ●─documentation ○─qa ○─ …    │  phase rail
│   TASK-338      cr-dev  ↻ │  ─────────────────────────────────────────────────│
│                           │  [summary] messages 3  events 4  logs⧉  reports⧉ files⧉│  tab strip
│ READY (5)                 │  ─────────────────────────────────────────────────│
│   TASK-341  P0            │  Status: implementing auth middleware…             │  drill-down body
│   TASK-342  P1            │  worktree ~/wt/TRD-2026-014                         │
│   …                       │  branch   foreman/TRD-2026-014                     │
│                           │  last     12s ago · progress_update                │
│ RECENT (12)               │                                                    │
│   TASK-330  merged ✓      │                                                    │
│   TASK-329  failed  ✗     │─────────────────────────────────────────────────  │
│                           │  ▸ open DEVELOPER_REPORT.md in nvim (action bar)   │  action bar
├───────────────────────────┴───────────────────────────────────────────────────┤
│ ↑↓/j/k tasks  enter view  esc tasks  o open  d diff  r retry  R reset  q quit │  keybar
└────────────────────────────────────────────────────────────────────────────────┘
```

### Left column — the answer to Q1, Q2, Q3 at a glance

A single scrollable list, always grouped in this fixed order:

- **RUNNING** — runs with status `pending | running | in_progress | cooldown`.
  Each row shows a state glyph, task id, and current phase. (Q1)
- **READY** — dispatchable tasks (`/tasks/dispatchable`). Each row shows task id
  and priority; selecting one explains why it is ready and when it will
  dispatch. (Q2)
- **RECENT** — terminal runs (`completed | merged | pr-created | failed | reset`),
  most-recent first, capped (default 15). (Q3 for finished work)

Groups are collapsible (`RUNNING` never collapses). Attention states color the
row: failed/conflict = red, retrying/cooldown = amber, merged/done = green.
The selected row drives the entire right side.

### Right column — the answer to Q3 detail and Q4

- **Detail header** — task id, run id, and run status (color-coded). For
  attention runs, a second line states the reason (`failed: merge_conflict`,
  `retrying: coderabbit_findings (2)`).
- **Phase rail** — the workflow phases as a horizontal sequence with per-phase
  glyphs: `✓` done, `●` active (breathing/animated), `○` pending, `✗` failed,
  `↻` retrying. Wraps to multiple rows on narrow terminals. This is the
  at-a-glance status. (Q3)
- **Tab strip** — `summary · messages · events · logs · reports · files`. Tabs
  show counts; `logs`, `reports`, and `files` carry an `⧉` marker indicating
  their rows are openable in nvim. (Q4)
- **Drill-down body** — content for the active tab, scoped to the selected run
  (active or past). `summary` is default and needs no fetch beyond the run
  projection.
- **Action bar** — appears only on openable tabs when a row is selected; shows
  the exact resolved command and the open mode (remote vs inline). See nvim
  integration.

## State model

The cockpit is an Elm-architecture app (Bubble Tea `model → update → view`).
The root model owns cross-component orchestration: client refresh, layout size,
selected run/task identity, active tab, focus, notices/errors, animation ticks,
and mutating commands. Local UI mechanics live in small cockpit-owned
components:

| Component | Owns |
|-----------|------|
| `TaskList` | grouped `RUNNING` / `READY` / `RECENT` rows, selected item, collapsed groups, search/filter state, scope, and keep-selection-visible behavior |
| `Viewer` | rendered drill-down lines, cursor, viewport offset, selected line identity, bottom-follow behavior, and cursor clamping across refreshes |
| Tab adapters | conversion of summary/messages/events/logs/reports/files/pr data into stable keyed viewer lines and nvim targets where applicable |

All data is fetched from the Elixir core; the cockpit never infers state the
core has not asserted. A periodic tick (default 2s) refreshes projections and
advances the active-phase animation.

## Keymap

Global:

| Key | Action |
|-----|--------|
| `↑`/`↓`, `j`/`k` | move task selection while the task list is focused |
| `enter` | enter/focus the selected drill-down view |
| `esc` | leave the drill-down view and return focus to the task list; clears search while searching |
| `↑`/`↓`, `j`/`k` | move the highlighted line in the focused messages/events/logs/reports/files/pr view; the viewport keeps the selection near the middle when possible and clamps at the edges |
| message rows | select whole messages by header; show `messages <current>/<total>` in both the tab and run header; keep the selected message body preview visible with the header when space allows |
| mouse wheel | scroll the pane under the pointer: task list on the left, active drill-down view on the right |
| `⇥` / `⇧⇥` | next / previous drill-down tab and focus it |
| `1`–`7` | jump directly to a tab and focus it |
| `space` | collapse/expand the focused group |
| `/` | search; `esc` clears |
| `g` | toggle current-project vs global scope |
| `r` | retry selected run/phase (`POST /commands`) |
| `R` | reset selected task (confirmed) |
| `G` | open `gh dash` when enabled and available |
| `q` | quit |

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
| files | `<worktree>/<relative-path>` from the run's changed-file set |
| pr | PR URL/state/branch metadata projected on `/api/v1/runs`; `o`/`enter` opens the PR URL |

### Files: focused diff preview and handoffs

- `o` opens the file plain (at top of buffer).
- `d` opens the selected file diff in nvim. Remote mode sends a diff command to
  the running session; inline mode uses `nvim -d`. Conflicted files open a
  3-way diff (`Gvdiffsplit!` / merge layout).
- `D` opens a full-run `git diff <base>...HEAD | diffnav` handoff when enabled.
- The files tab also renders an inline preview for the selected file. It uses
  `git diff <base>...HEAD -- <path> | delta` when `delta` is enabled and
  available, and falls back to plain `git diff` output otherwise.
- `C` opens `gh enhance` as a full-screen handoff for the selected run worktree
  when the GitHub CLI and extension are available; use it from the `pr` tab to
  inspect failing/pending Actions checks and rerun jobs.

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
pr:
  provider: github
```

`mode: auto` = remote when a session is found, else inline (the recommended
default). `mode: remote` never suspends; `mode: inline` always suspends.
`COCKPIT_DIFFNAV`, `COCKPIT_DELTA`, `COCKPIT_GHDASH`, and
`COCKPIT_GHENHANCE` override the respective integration `enable` value.

## Non-goals for the POC

- No write/command execution beyond attach + retry/reset stubs.
- No auth token refresh flows; read the token from the environment.
- No pagination controls beyond the RECENT cap.

## Open questions

- Should RECENT be time-boxed (e.g. last 24h) rather than count-capped?
- Should the phase rail collapse to a compact `4/10 · qa` badge on very narrow
  terminals instead of wrapping?
