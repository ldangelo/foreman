# ops/herdr-sidebar/

Two optional pieces for the [Herdr](https://herdr.dev) desktop app: a sidebar
panel that lists Foreman runs, grouped by project and status, next to your
terminals and agents, and a **run-detail tab** the panel opens for a run: what it
is doing right now or how it ended, its phases and their reports, a live activity
feed (the agent's output, your steers, status and review verdicts), its code
changes, its pull request's evidence and anything waiting on you. Both are Herdr
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
| A server with `GET /api/runs/:id/artifacts` and `/artifacts/:phase_id` | The phase reports of the Phases tab. An older server answers 404: the tab says the server lacks the route (never "no report") and everything else works. |
| A server with `GET /api/runs/:id/prs` | The PR evidence of the Overview and the PR tab. Without it they say so. |
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
  place in its project's own slot queue (`GET /api/queue?project_id=<id>`, `waiting`; run slots are per
  project, so the mod reads one queue per project and the server has no machine-wide one). The title is
  its task's. `N` is the server's own 1-based position in that project's queue, so it counts entries
  that can no longer start (see "stale"); the group header counts only the live ones.
- `… awaiting approval`: a task in the project that is still `open`, i.e. not yet approved and with no
  run (`GET /api/tasks?status=open`), oldest first, with how long ago it was created. Not counted
  as queued: the group header shows it separately as `N awaiting`.
- `… stale`: an entry still in the server's slot queue whose run has ended or no longer exists, so it can
  never start. It is shown dimmed and is not counted: the group header reads `N · M stale`. When the
  server cannot say which project such an entry belonged to it is listed under "Unresolved queue
  entries". The compact rail shows the total of the live ones as `⧖N`.

A run that is already listed as a run is not repeated here. A run the server resumed after a pause
waits for a slot with its run record, so it shows under its status (`starting`) with the other runs
and not as a queue row; only a run that was never started (no run record) is a queue row. `#N` stays
the server's position in the project's queue, so the rows that remain can have gaps (a lone row may
read `#3`).

Queue rows are display only: a queued run has no transcript or phases to open yet. The queue is read
every 30 s (a manual refresh reads it at once), and if reading it fails the runs still show, with a
one-line "Queue unavailable: …" note under the header (a project whose queue cannot be read is named
in that note while the other projects' queues still show). The failed filter hides the queue. Work the
server is holding back (daily thread cap, a paused project) is not in the slot queue and is
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
run-d0f4…  ·  ensemble  ·  foreman/…/run-d0f4…
▶ coderabbit-review  attempt 1  ·  in phase 19m 58s  ·  phase 2 of 3            last event 4s ago
agent  Reading the diff of lib/toolchain/status-overrides.js …                           12s ago
elapsed 2h 17m  ·  base dev  ·  74.8k in · 1.4k out · 399.4k cached  ·  litellm-stack/smart_router
✓ fix › ▶ coderabbit-review › ○ repo-rules-review
Overview   Activity (31)   Phases (1/3)   Changes (3)   PR (1)
```

**The header is always there.** Whatever tab is open it shows the status line: for a run that is
going, the phase it is in (attempt, time in phase, `phase 2 of 3`), how long since the last event
(grey, yellow with `(quiet)` after 2 minutes, red after 10, red as soon as the server has reported a
stall) and, on the next line, the newest thing the run said (the newest turn's last line, its thinking
dimmed, and how long ago that turn started); for a run that is over, its outcome instead (`✕ failed
in 6m 47s at review · 2/4 phases done · PR #12 open · gate pending`). Under it: elapsed time,
base branch, tokens, cost and the model; the phase strip (click a phase to open it in the Phases
tab); and banners for the failure reason, a stall (its reason and idle time), what waits on you and
every read that failed.

**Tabs.** `Overview`, `Activity`, `Phases`, `Changes`, `PR`. A run that is over opens on Overview,
one that is going on Activity; the tab you click stays.

- **Overview.** *Outcome*: how it ended (or, for a run that is going, what it is doing now with its
  newest output), the failure reason in full (six lines, `show more`, `copy`; a cancelled run has none
  on the projection, so it is read from the transcript's `Run cancelled: …` turn), phases done, the PR
  line. *Needs you*: pending tool approvals and open questions, with the CLI line that answers them
  (the tab itself changes nothing). *Phases*: one row per phase of the workflow with its status
  (`✓` done, `▶` running, `Ⅱ` paused, `✕` failed, `–` cancelled or not run, `○` pending, `×N` after a
  retry), duration, the size of its report and its failure reason; a click opens the phase. *Pull
  request*: per PR its state, merge gate, checks (passing / failing / pending), review decision,
  eligibility and its reasons, findings, risk and next actions; a click opens the PR tab. *Recent
  events*: phase starts and ends, your steers, review verdicts, run status changes, stalls and the
  newest stderr lines.
- **Activity.** The run's transcript (`GET /api/threads/run:<id>/transcript`), polled every 3 s while the
  run is going and every 30 s once it is not. Chips filter it: `All`, `Agent`, `Steers & status`
  (your steers, run status changes, review verdicts), `Errors` (stderr and failed or cancelled
  status). Turns are grouped under their phase: a header with its state, duration and turn count that
  folds the group, and the failure reason under a failed phase. Review verdicts are cards in the
  verdict's colour. Long turns fold to 8 lines (`… N more lines`), neighbouring one-word turns fold
  into one row (`×N`), blank chunks are left out, `<think>` blocks are dimmed. A streamed message
  is shown once, whole: the server stores it as hard-wrapped fragments followed by the message again, and
  the tab keeps the whole one when the fragments are provably its own; whatever it cannot prove is shown
  as sent, marked `unmerged chunks`. Scrolling up stops the auto-follow; `jump to latest` turns it on
  again. The server's log window is bounded, so a long run shows `N earlier log entries are not
  available`.
- **Phases.** One section per phase; click to open. Open: when it started and ended, its provider and
  model, attempts, failure reason or stall, then its **phase report** (the markdown the agent wrote,
  from `GET /api/runs/:id/artifacts/:phase_id`, fetched when you open the phase and kept per sha256):
  name and size, `copy path`, `open` (a document opens in your default app), the path, a badge saying
  whether the file's sha256 still matches what the phase recorded (`✓` / `✕ … changed after the phase
  wrote it`), a notice when the server cut it at 256 KiB, and the text itself with headings, bullets,
  `**Label**:` lead-ins, tables and code blocks drawn plainly (120 rows, then `show more`). A report whose file is
  `missing` or `unreadable` says so with the server's reason; a phase with no report says that, but only once the
  server has answered that it has none. Last, `Agent output (N turns)`, that phase's slice of the
  transcript, closed by default.
- **Changes.** For a run with a worktree: the commits since it branched, every
  changed file with `+added −removed` (uncommitted work and new files
  included), and a click on a file shows its patch. Once the worktree is gone,
  the pull request's file list stands in; with neither, the tab says why.
- **PR.** Per pull request: `Open PR ↗` and `copy URL`; every check with its state and conclusion
  (failing in red), and an explicit "no checks have been observed" when there are none (that is not
  passing); review decision and comments; fix attempts per kind, the fix in flight, last outcomes and
  exhausted kinds; merge gate; eligibility with every reason and waiver; the findings (severity,
  disposition, source, description, `path:line`) and the review's judgement; risk level, rationale and
  instructions; the agent review's verdict and gaps, the published report, a delivery issue; next
  actions. Anything the server could not read is a line saying so; `unknown` is never shown as clean.

**What is read, and how often.** The run, its phases and the transcript every 3 s while the run is going
(30 s once it is over); approvals and questions only while it is going; PR evidence and the report list
at most every 10 s (30 s once over; `↻` reads them at once); a report's text only when its phase is open,
once per sha256; git every 10 s for a run that is going. Everything is read-only. A read that fails is
shown with its reason and never turned into "nothing there"; a server that lacks a route is told as
that. All text that came from an agent or from GitHub is drawn as plain text: nothing in it is
interpreted, linked or loaded.

`PR ↗` opens the pull request, `raw` opens `foreman run get`, the id line copies the run id.

Open it from the panel, or directly:
`herdr-app do tab.new '{"name":"run","mod":"foreman-run","props":{"run_id":"run-…","tab":"phases"}}'`
(`tab` is optional: `overview`, `activity`, `phases`, `changes` or `pr`).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `HTTP 401: unauthorized` in the panel | The server has a token and none was found. Check `FOREMAN_API_TOKEN=` in the `.env` named by `ENV_FILE` in `mods/foreman-runs/common.js`. |
| `connection refused` | The server is not running on `FOREMAN_API_URL` (default `127.0.0.1:4766`). |
| `foreman: command not found` | `foreman` is not on the `PATH` the Herdr app inherits. |
| No panel | The `foreman` layout is not showing: `herdr-app do layout.switch '{"name":"foreman"}'`. |
| Shortcuts do nothing | They apply only while the `foreman` layout is showing. If they still do nothing with a terminal focused, move the entries of `layout:foreman` into the `global` section of `keys.json`. |
| Panel errors after a Herdr update | `herdr-app status` lists mod errors; `herdr-app check ~/.config/herdr-app/mods/foreman-runs` (or `…/foreman-run`) prints the exact one. |
| "Phase reports are unavailable: this server has no /api/runs/:id/artifacts route" | The server predates the report routes. Update and restart it; the rest of the tab works meanwhile. The tab never says "no report" when it could not ask. |
| "Could not read the PR evidence: projection_unavailable: …" | The server's store did not answer, so the PR's status is *unknown*, not clean. `↻` once it is healthy. The last good answer stays on screen, marked old. |
| "The report file is missing" | The report was written under a worktree or report directory that has been cleaned up; the listing still knows its path and size. |
| "No readable output: the log holds only N blank chunks" | The agent wrote nothing but blank chunks into the part of the log the server keeps (about the newest 500 entries). |
| "unmerged chunks" on a turn | The turn ends with fragments of a message whose whole text has not arrived (or is outside the server's log window); they are shown as sent. |
| "the server has no thread for this run" | The run failed before its thread existed: no transcript, title or branch. The other tabs still work. |

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
| `mods/foreman-run/model.js` | The run-detail tab's logic without any drawing: duration math, phase rows, transcript clean-up and grouping, report markdown, PR evidence reduction, the status and outcome summaries. No imports; `install.sh` copies every `*.js` of a mod's folder. |
| `test/model.test.js` | Regression tests for `model.js` (`bun:test`, plain fixtures, fixed clock, no network or filesystem). Not installed. See [Tests](#tests). |
| `common.js` | Helpers both mods share: status styling, the CLI and HTTP callers (`api()` reports the HTTP status), the token lookup. Copied into each mod by `install.sh`. |
| `keys.layout-foreman.json` | The `layout:foreman` shortcut section merged into `keys.json`. |
| `install.sh` | Installer / uninstaller. |

## Tests

`test/model.test.js` covers the pure logic of `mods/foreman-run/model.js` (transcript reassembly, phase rows and durations, outcome and PR-evidence summaries, report markdown, fetch-error classification). It uses `bun:test` with inline fixtures and a fixed clock; it reads no network or files and does not touch `main.js` (drawing is not covered). Run it from the repository root:

```sh
bun test ops/herdr-sidebar/test
```

`bun` is not a devbox package and CI does not run this suite: it is a local check you run when you change `model.js`.

## For maintainers

The panel depends on these fields of `GET /api/runs` (via `foreman run list`):
`run_id`, `project_id`, `status`, `task_id`, `last_event_at_ms`, `pr_url` and
`workflow_snapshot.workflow_name` (the top-level `workflow_name` is null on
current runs). Project names come from `foreman project list --format=json`
(a bare array; `name` is often null, so the project id is the fallback).
Statuses it colours: `in_progress`, `awaiting_worker`, `paused`, `failed`,
`completed`, `cancelled`; anything else gets a neutral style. If the server's
run projection changes, update `mods/foreman-runs/main.js` and re-run the installer.

The run-detail tab reads these endpoints (all `GET`, all through `api()` in `common.js`):

| Endpoint | Fields it uses | If the server lacks it |
|---|---|---|
| `/api/runs/:id` | `status`, `terminal?`, `failure_reason`, `latest_stall` (`reason`, `stall_kind`, `idle_ms`, `phase_name`, `detected_at_ms`), `usage`, `pr_url`, `base_branch`, `project_id`, `started_at_ms`, `last_event_at_ms`, `provider_sessions[].model`, `workflow_snapshot.phases[]` (`name`, `phase_id`, `provider`, `command`, `action`, `models.default`, `artifact`) | the tab shows the error |
| `/api/runs/:id/phases` | `phases[]`: `phase_id`, `index`, `name`, `attempt`, `status` (`in_progress`, `completed`, `failed`, `skipped`, `cancelled`), `started_at_ms`, `last_event_at_ms`, `failure_reason`, `latest_stall` | strip loses per-phase status, banner says why |
| `/api/runs/:id/artifacts` | `artifacts[]`: `phase_id`, `index`, `name`, `attempt`, `status`, `path`, `sha256`, `bytes`; only phases that recorded a report, no content | Phases tab says the server lacks the route |
| `/api/runs/:id/artifacts/:phase_id` | `state` (`ok`, `missing`, `unreadable`), `content`, `content_bytes`, `truncated`, `sha_matches`, `error`, `path`, `bytes`. A `missing` or `unreadable` file is a **200** that carries `error` as data | the report shows the error |
| `/api/runs/:id/prs` | per PR: `pr_url`, `status`, `head_sha`, `base_branch`, `branch_name`, `merge_gate`, `checks_state`, `failing`, `checks.items[]` (`name`, `state` `passing`/`failing`/`pending`, `conclusion`), `review_decision`, `comment_count`, `fixes`, `agent_review`, `eligibility` (`status`, `reasons[]`, `waived[]`), `findings` (`status`, `total`, `unresolved` **as a map by severity**, `items[]`, `judgement`), `risk` (`level`, `rationale[]`, `instructions[]`), `waiver`, `report`, `delivery_issue`, `next_actions[]`; shapes in the moduledoc of `ForemanServer.PrWatch.DTO` | PR sections say the server lacks the route |
| `/api/runs/:id/approvals`, `/api/projects/:id/questions` | `approvals[]`: `tool_call_id`, `tool_name`, `input_summary`, `requested_at`; `questions[]`: `run_id`, `question_id`, `text` | banner says they could not be read |
| `/api/threads/run:<id>` and `/transcript` | `repo_path`, `title`, `branch`; `turns[]`: `seq`, `at`, `kind`, `source`, `text`, `omitted_entries` (invalidates cursors). A run that failed before its thread existed answers `thread_not_found` | the feed says there is no transcript |

`api()` appends curl's HTTP status to the response and throws an `Error` with `.status` (and `.code` when
the body was `{error: code}`). That is how the tab tells a server that has no such route (a 404 with
its own HTML page and no code) from an answer, and why a **200** body with an `error` field is data
while a 4xx/5xx body is a failure. A failed read keeps its reason in `this.warn.<source>` and is shown;
the last good PR answer stays on screen, marked old, while a refresh fails.

The server's transcript joins a run's stored log chunks with newlines, and a streamed message is stored
as its fragments and then once more whole (`ForemanServer.Threads.Transcript`, "Chunks"). `model.js`
(`reassemble`) keeps the whole message only when the fragments before it, minus the joining newlines,
are exactly that message, and only for an agent's `stdout` in a phase that runs a harness (never a
`command:` phase). If the server ever adds a final-only transcript mode, drop `reassemble`.

The queue reads `GET /api/queue?project_id=<id>` once per project from `foreman project list` (`limit`,
`running`, `waiting` as `{run_id, position, waited_ms}`) and `GET /api/tasks` (`status`,
`task_id`, `project_id`, `title`, `run_id`, `created_at_ms`); a waiting run is matched to its task by
`run_id`, and an unmatched one is looked up with `GET /api/runs/<id>`.

Verification so far: the panel was exercised against a live server and against
stub servers, and the commands behind each shortcut were driven with
`herdr-app do foreman-runs.<command>`. The run-detail tab's logic (`model.js`) was exercised with plain
fixtures and with transcripts captured from a live server; its views were rendered against a recording
stand-in for `gpui-kit` (every element method checked against `gpui-kit.d.ts`) with a live server, a
server without the new routes and fixture servers; both mods pass `herdr-app check`. The key chords,
mouse clicks, scrolling and how it looks in a real window were not exercised by an automated check.
