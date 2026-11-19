# ops/herdr-sidebar/

An optional sidebar panel for the [Herdr](https://herdr.dev) desktop app that
lists Foreman runs, grouped by project and status, next to your terminals and
agents. It is a Herdr "mod" (a small JavaScript program) plus a layout and a set
of keyboard shortcuts. It only reads from Foreman, through the `foreman` CLI; it
changes nothing in the server.

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
| `jq` | Used by `install.sh` to edit the layout and `keys.json`. |
| A running Foreman server | Default `http://127.0.0.1:4766` (`devbox run server`). With the server down the panel shows the CLI's error (for example "connection refused") and keeps the time of the last good refresh. |

## Install

From the repository root:

```sh
ops/herdr-sidebar/install.sh --switch
```

That does four things, all under `~/.config/herdr-app` (or `$HERDR_APP_HOME`):

1. Copies `mod/` to `mods/foreman-runs/`. Only one line is rewritten: `ENV_FILE`
   is pointed at this checkout's `.env` (see [Authentication](#authentication)).
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
changes to `mod/` to update. Herdr hot-reloads the mod, so no restart is needed.

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

| Action | Mouse | Shortcut |
|---|---|---|
| Open a run (a tab running `foreman run get <id>`) | click the row | `⏎` while navigating |
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

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `HTTP 401: unauthorized` in the panel | The server has a token and none was found. Check `FOREMAN_API_TOKEN=` in the `.env` named by `ENV_FILE` in `mods/foreman-runs/main.js`. |
| `connection refused` | The server is not running on `FOREMAN_API_URL` (default `127.0.0.1:4766`). |
| `foreman: command not found` | `foreman` is not on the `PATH` the Herdr app inherits. |
| No panel | The `foreman` layout is not showing: `herdr-app do layout.switch '{"name":"foreman"}'`. |
| Shortcuts do nothing | They apply only while the `foreman` layout is showing. If they still do nothing with a terminal focused, move the entries of `layout:foreman` into the `global` section of `keys.json`. |
| Panel errors after a Herdr update | `herdr-app status` lists mod errors; `herdr-app check ~/.config/herdr-app/mods/foreman-runs` prints the exact one. |

## Uninstall

```sh
ops/herdr-sidebar/install.sh --uninstall
```

Removes `mods/foreman-runs/`, its saved state and the shortcut bindings the
installer added (bindings you changed or added yourself are kept), and switches
Herdr back to `main`. `layouts/foreman.json` is deleted only if it is still
identical to Herdr's `main` layout apart from the panel; if you changed it (for
example the sidebar width) it is kept and only the panel's block is removed.

## Files

| Path | Role |
|---|---|
| `mod/main.js`, `mod/mod.json` | The panel. No dependencies beyond Herdr's `gpui-kit` / `herdr` modules. |
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
run projection changes, update `mod/main.js` and re-run the installer.

Verification so far: the panel was exercised against a live server and against
stub servers, and the commands behind each shortcut were driven with
`herdr-app do foreman-runs.<command>`. The key chords themselves, and mouse
clicks, were not exercised by an automated check.
