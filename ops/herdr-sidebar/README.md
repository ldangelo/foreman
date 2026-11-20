# ops/herdr-sidebar/

Two optional pieces for the [Herdr](https://herdr.dev) desktop app: a sidebar
panel that lists Foreman runs, grouped by project and status, next to your
terminals and agents, and a **run-detail tab** the panel opens for a run, with
its phases, a live activity feed (the agent's output, your steers, status and
review verdicts), its code changes and anything waiting on you. Both are Herdr
"mods" (small JavaScript programs) plus a layout and a set of keyboard
shortcuts. They only read from Foreman, through the `foreman` CLI and the
server's read-only HTTP API; they change nothing in the server.

```
FOREMAN   4 failed  0 active  13:22:22  ↻
▾ foreman                       2 failed  21
   ▾ ● failed                              2
        prd                              16d
        coord-f9ed0677b3cb784
   ▾ ● completed                          15
        assess                            1h
        otel-phase-probe-1
▾ ensemble                      2 failed   8
   …
⇧⌘J select  ⇧⌘O open PR  ⇧⌘Y copy id  …
```

## Requirements

| Needs | Why |
|---|---|
| The Herdr desktop app (`herdr-app` on your `PATH`) | Hosts the panel. Start it once so `~/.config/herdr-app` exists. |
| `foreman` on the `PATH` the Herdr app sees | The panel runs `foreman run list` and `foreman project list`. A GUI app inherits your login shell's `PATH`, so `~/bin` or `/usr/local/bin` is fine. |
| `curl`, `git` (and `gh` for finished runs) | The run-detail tab reads the activity feed over HTTP, runs `git` in the run's worktree for its changes, and falls back to `gh pr view` for a run whose worktree is gone. |
| A server with `GET /api/runs/:id/phases` | `foreman run phases`, added with the run-detail tab. An older server answers 404: the tab still works, the phase strip loses its per-phase status and says so. |
| `jq` | Used by `install.sh` to edit the layout and `keys.json`. |
| A running Foreman server | Default `http://127.0.0.1:4766` (`devbox run server`). With the server down the panel shows the CLI's error (for example "connection refused") and keeps the time of the last good refresh. |

## Install

From the repository root:

```sh
ops/herdr-sidebar/install.sh --switch
```

That does four things, all under `~/.config/herdr-app` (or `$HERDR_APP_HOME`):

1. Copies `mods/foreman-runs/` and `mods/foreman-run/` into Herdr's `mods/`,
   each with its own copy of `common.js` (a mod can only import from its own
   folder). Only one line of `common.js` is rewritten: `ENV_FILE` is pointed at
   this checkout's `.env` (see [Authentication](#authentication)).
2. Creates `layouts/foreman.json`, a copy of Herdr's `main` layout with the panel
   added between Spaces and Agents. Your other layouts are not touched.
3. Binds the shortcuts below in the `layout:foreman` section of `keys.json`.
   A chord you already use for something else is left alone and reported.
4. Runs `herdr-app check` on the installed mod, then (with `--switch`) switches
   Herdr to the `foreman` layout. Without `--switch` it prints the command, or
   press `cmd-shift-l` to cycle layouts.

Options: `--no-keys` (skip `keys.json`), `--no-check`, `--switch`, `--uninstall`.
Environment: `HERDR_APP_HOME` (Herdr's home) and `FOREMAN_ENV_FILE` (the `.env`
to read the token from). The installer is idempotent; re-run it after pulling
changes here to update. Herdr hot-reloads the mods, so no restart is needed.

> **`keys.json` becomes yours.** Herdr only updates `keys.json` for you while it
> is untouched. Once the installer has added the shortcuts, new default shortcuts
> in later Herdr releases will not appear in that file; copy them in by hand.
> Use `--no-keys` to avoid this and run the panel without shortcuts.

## Authentication

When the server has `FOREMAN_API_TOKEN` configured, `/api` requires it. The Herdr
app does not carry your shell's variables, so the panel takes the token from the
environment if present and otherwise from `FOREMAN_API_TOKEN=` in the checkout's
`.env`. It is read inside the shell that runs the CLI, so it never appears in a
process argument list. To use a different file, install with
`FOREMAN_ENV_FILE=/path/to/.env ops/herdr-sidebar/install.sh`.

The mod only supplies the token. A non-default server address
(`FOREMAN_API_URL`) must be in the Herdr app's own environment.

## Use

Rows show the workflow, how long ago the run last had an event, and its task id.
Project headers show a `N failed` count and `active/total`; counters always
describe all runs, even while the failed filter hides rows. The header shows the
time of the last successful refresh (red while the latest refresh is failing).

**The queue.** Under each project, above its running and finished runs, a `queued` group lists the
work that is waiting, in the order the server will start it:

- `#N … waiting for a slot`: a run the server has admitted but has no free run slot for yet, with its
  place in the server's global slot queue (`GET /api/queue`, `waiting`). The title is its task's.
- `… not started`: a task that exists in the project but has no run yet (`GET /api/tasks?status=open`),
  oldest first, with how long ago it was created.
- `… stale`: an entry still in the server's queue whose run has ended or no longer exists, so it can
  never start. It is shown dimmed and is not counted: the group header reads `N · M stale`. When the
  server cannot say which project such an entry belonged to it is listed under "Unresolved queue
  entries". The compact rail shows the total of the live ones as `⧖N`.

Queue rows are display only: a queued run has no transcript or phases to open yet. The queue is read
every 30 s (a manual refresh reads it at once), and if reading it fails the runs still show, with a
one-line "Queue unavailable: …" note under the header. The failed filter hides the queue. Work the
server is holding back (daily thread cap, run limit, a paused project) is not in the slot queue and is
not shown; `GET /api/projects/<id>/usage` reports it as `limits.deferred_tasks`.

| Action | Mouse | Shortcut |
|---|---|---|
| Open a run in its detail tab | click the row | `⏎` while navigating |
| Collapse / expand a project or status group | click its header | |
| Collapse / expand every project | | `⇧⌘E` |
| Collapse / expand every status group | | `⇧⌘S` |
| Show only failed runs | click `N failed` in the header | `⇧⌘F`, `Esc` clears |
| Reload now (it also polls every 10 s) | click `↻` | `⇧⌘R` |
| Move the keyboard to the panel and select a run | | `⇧⌘J`, then `↑` / `↓`; `Esc` leaves |
| Open the selected run's pull request in the browser | | `⇧⌘O` |
| Copy the selected run's id | | `⇧⌘Y` |
| Copy the selected run's PR URL | | `⇧⌘U` |
| Switch the sidebar between the full panel and a compact rail | | `⇧⌘B` |

On macOS the shortcuts are `cmd-shift-<letter>`; the footer under the list shows
whichever chords are actually bound in your `keys.json`. Collapsed groups are
remembered across restarts. While the panel holds the keyboard (after `⇧⌘J` or
turning the filter on) typing goes to the panel, not your terminal; `Esc`
hands it back to the pane that had it.

**The rail.** When the sidebar is narrower than 160 px (the shipped chrome's fold
button, or `⇧⌘B`) the panel draws a compact rail: a failed / active summary and
one tile per project, outlined red while it has failed runs. Clicking it widens
the sidebar again. `cmd-b` is Herdr's own show/hide for the whole sidebar and is
unchanged.

## The run-detail tab

```
● running  fix  Make approval-gated skills detect a Foreman dispatch…        PR ↗  raw  16:44:32  ↻
run-d0f4…  ·  ensemble  ·  foreman/…/run-d0f4…  ·  base dev
elapsed 2h 17m  ·  last event 16s ago  ·  74.8k in · 1.4k out · 399.4k cached
✓ fix › ▶ coderabbit-review › ○ repo-rules-review
Activity (31)   Changes (3)                                              following
```

- **Phases.** The phases the server has started, each with its own status
  (`foreman run phases <id>`: `✓` done, `▶` running, `Ⅱ` paused, `✕` failed, `–`
  cancelled or skipped, `×N` after a retry), then the workflow's remaining phases as `○` pending. A phase a
  cancelled or failed run stopped in shows the run's outcome.
- **Activity.** The run's transcript (`GET /api/threads/run:<id>/transcript`),
  polled every 3 s while the run is active and every 30 s once it is not:
  agent output (stderr dimmed), your steers, run status changes and the review
  verdict. Long turns fold to 8 lines (`… N more lines`). Scrolling up stops
  the auto-follow; `follow` turns it on again. The server's log window is
  bounded, so a very long run shows `N earlier turns are not shown`.
- **Changes.** For a run with a worktree: the commits since it branched, every
  changed file with `+added −removed` (uncommitted work and new files
  included), and a click on a file shows its patch. Once the worktree is gone,
  the pull request's file list stands in; with neither, the tab says why.
- **Waiting on you.** A pending tool approval or an open question for the run
  is a banner above the tabs, and a failure reason or stall is a red one.
  If approvals or questions cannot be read, the tab says so rather than
  showing nothing.
- `PR ↗` opens the pull request, `raw` opens `foreman run get`, the id line
  copies the run id.

Open it from the panel, or directly:
`herdr-app do tab.new '{"name":"run","mod":"foreman-run","props":{"run_id":"run-…","tab":"changes"}}'`
(`tab` is optional: `activity` or `changes`).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `HTTP 401: unauthorized` in the panel | The server has a token and none was found. Check `FOREMAN_API_TOKEN=` in the `.env` named by `ENV_FILE` in `mods/foreman-runs/common.js`. |
| `connection refused` | The server is not running on `FOREMAN_API_URL` (default `127.0.0.1:4766`). |
| `foreman: command not found` | `foreman` is not on the `PATH` the Herdr app inherits. |
| No panel | The `foreman` layout is not showing: `herdr-app do layout.switch '{"name":"foreman"}'`. |
| Shortcuts do nothing | They apply only while the `foreman` layout is showing. If they still do nothing with a terminal focused, move the entries of `layout:foreman` into the `global` section of `keys.json`. |
| Panel errors after a Herdr update | `herdr-app status` lists mod errors; `herdr-app check ~/.config/herdr-app/mods/foreman-runs` (or `…/foreman-run`) prints the exact one. |

## Uninstall

```sh
ops/herdr-sidebar/install.sh --uninstall
```

Removes `mods/foreman-runs/` and `mods/foreman-run/`, their saved state and the shortcut bindings the
installer added (bindings you changed or added yourself are kept), and switches
Herdr back to `main`. `layouts/foreman.json` is deleted only if it is still
identical to Herdr's `main` layout apart from the panel; if you changed it (for
example the sidebar width) it is kept and only the panel's block is removed.

## Files

| Path | Role |
|---|---|
| `mods/foreman-runs/`, `mods/foreman-run/` | The panel and the run-detail tab (`main.js`, `mod.json`). No dependencies beyond Herdr's `gpui-kit` / `herdr` modules. |
| `common.js` | Helpers both mods share: status styling, the CLI and HTTP callers, the token lookup. Copied into each mod by `install.sh`. |
| `keys.layout-foreman.json` | The `layout:foreman` shortcut section merged into `keys.json`. |
| `install.sh` | Installer / uninstaller. |

## For maintainers

The panel depends on these fields of `GET /api/runs` (via `foreman run list`):
`run_id`, `project_id`, `status`, `task_id`, `last_event_at_ms`, `pr_url` and
`workflow_snapshot.workflow_name` (the top-level `workflow_name` is null on
current runs). Project names come from `foreman project list --format=json`
(a bare array; `name` is often null, so the project id is the fallback).
Statuses it colours: `in_progress`, `awaiting_worker`, `paused`, `failed`,
`completed`, `cancelled`; anything else gets a neutral style. If the server's
run projection changes, update `mods/foreman-runs/main.js` and re-run the installer.
The run-detail tab also reads `GET /api/runs/:id`, `/phases`, `/approvals`,
`/api/projects/:id/questions`, `/api/threads/run:<id>` (`repo_path`, `title`,
`branch`) and its `/transcript` (`turns`: `seq`, `at`, `kind`, `source`, `text`;
`omitted_entries` invalidates cursors).

The queue reads `GET /api/queue` (`capacity`, `running`, `waiting`) and `GET /api/tasks` (`status`,
`task_id`, `project_id`, `title`, `run_id`, `created_at_ms`); a waiting run is matched to its task by
`run_id`, and an unmatched one is looked up with `GET /api/runs/<id>`.

Verification so far: the panel was exercised against a live server and against
stub servers, and the commands behind each shortcut were driven with
`herdr-app do foreman-runs.<command>`. The key chords themselves, and mouse
clicks, were not exercised by an automated check.
