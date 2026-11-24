# ops/herdr-sidebar/

Two optional pieces for the [Herdr](https://herdr.dev) desktop app: a sidebar
panel that lists Foreman runs, grouped by project and status, next to your
terminals and agents, and a **run-detail tab** the panel opens for a run: what it
is doing right now or how it ended, its phases and their reports, a live activity
feed (the agent's output, your steers, status and review verdicts), its code
changes, its pull request's evidence and anything waiting on you, and it can merge
that pull request. Both are Herdr "mods" (small JavaScript programs) plus a layout
and a set of keyboard shortcuts. The panel also raises a notification when a run
completes. They read from Foreman through the `foreman` CLI and `GET` requests to the
server's HTTP API, and change the server only through buttons that ask first:
resetting a failed run (`foreman run reset`), approving a task that is awaiting
approval (`POST /api/commands`) and merging a run's pull request (`foreman run
approve-merge` and `foreman run merge`); all three are described below.

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
| `foreman` on the `PATH` the Herdr app sees | The panel runs `foreman run list` and `foreman project list`; the run-detail tab's merge button runs `foreman run approve-merge` and `foreman run merge` (a `foreman` without them gets a toast saying so and nothing is sent). A GUI app inherits your login shell's `PATH`, so `~/bin` or `/usr/local/bin` is fine. |
| `curl`, `git` (and `gh` for finished runs and for merging) | The run-detail tab reads the activity feed over HTTP, runs `git` in the run's worktree for its changes, and falls back to `gh pr view` for a run whose worktree is gone. Merging a PR asks `gh api user` who you are on GitHub: that login is the approver. |
| A server with `GET /api/runs/:id/phases` | `foreman run phases`, added with the run-detail tab. An older server answers 404: the tab still works, the phase strip loses its per-phase status and says so. |
| A server with `GET /api/runs/:id/artifacts` and `/artifacts/:phase_id` | The recorded phase reports of the Phases tab (original file or the server's archived copy, with a digest check). An older server answers 404: the tab says so and reads each finished phase's report from this machine instead: the run's own files under `~/.foreman/runs/<run-id>/`, else the commit Foreman made for the phase (see below). A report that exists in neither place shows `not found` until the server has the route. |
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
| Copy the selected run's bead id (`foreman-jzycy` of `beads:foreman:foreman-jzycy`) | click the bead id under a run or a queued item | `⇧⌘I` |
| Copy the selected run's PR URL | | `⇧⌘U` |
| Clear a failed, stuck or cancelled run from the panel | click the `✕` on its row | `⇧⌘X` (or `⌫` / `Del` while navigating); the selection moves to the next run |
| Clear every failed, stuck and cancelled run the panel shows | click `clear` on a status header (that group), or `✕ clear N` under the list (all) | `⇧⌘K` |
| Bring cleared runs back | click `↺ N cleared` under the list | `⇧⌘T` |
| Reset a failed run (asks first) | click `reset` on its row | `⇧⌘H` on the selected run |
| Approve a task that is awaiting approval (asks first) | click `approve` on its row in the queue | `⇧⌘A` for the task that has waited longest |
| Switch the sidebar between the full panel and a compact rail | | `⇧⌘B` |
| Next / previous tab of the run-detail view on screen | click a tab | `⌃⌥→` / `⌃⌥←` (`ctrl-alt-right` / `ctrl-alt-left`) |

On macOS the shortcuts are `cmd-shift-<letter>`, except the two tab chords, which act on the run-detail
view (`foreman-run.next-tab` / `foreman-run.prev-tab`, wrapping around); the footer under the list shows
whichever panel chords are actually bound in your `keys.json` (it does not list the tab chords). Collapsed
groups are remembered across restarts. While the panel holds the keyboard (after `⇧⌘J` or
turning the filter on) typing goes to the panel, not your terminal; `Esc`
hands it back to the pane that had it.

**Clearing runs.** Clearing a failed, stuck or cancelled run only hides it from this
panel. Nothing is deleted or changed: the run, its events, its files and its pull
request are exactly as before, `foreman run get` and the run-detail tab still show
them, and the counts in the header and the `failed` filter simply stop counting it.
`↺ N cleared` under the list shows how many are hidden and brings all of them back.
A cleared run comes back by itself when its status changes (it is retried or
resumed, or a stuck run turns failed), since that is news again. The cleared list is
kept across restarts in the panel's own local storage (the same place as collapsed
groups), per machine. Every 10 s the panel reads the 40 newest runs overall; once a
minute (or on `↻`) it also reads up to the 500 newest runs of each project, the older
history the overall list never reaches (a busy project would otherwise crowd a quiet
one out, and `N failed` would count a window, not the failed runs). An entry for a run
that has left those lists is dropped so the stored list cannot grow forever: a cleared
run that falls out of the window and later returns to it shows again. A completed run
cannot be cleared. If a project's run list cannot be read, a note under the header says
that some runs may be missing and why. A run that was reset or changed since the last
history read can show its old state for up to a minute; `↻` re-reads it at once.

**Resetting a run.** Unlike clearing, a reset changes the server. `reset` on a failed row
(or `⇧⌘H` on the selected failed run) opens Herdr's confirmation dialog; confirming
runs `foreman run reset --id <run-id>`. The server then drops that run's record from
Foreman's run list (its event history stays) and does **not** restart the work: to try
again, submit the work as a new run. Foreman has no command to bring a reset run back.
Only failed runs are offered it here (the server also accepts stuck, blocked and paused
runs; use `foreman run reset` for those). A confirmation that is answered more than a
minute after it was asked is ignored.

**Approving tasks.** A task that is awaiting approval is an `open` task with no run yet; it
shows in its project's `queued` group as "awaiting approval", oldest first. (The other
queued rows, "waiting for a slot", are already approved and wait for a free run slot: they
need nothing from you.) `approve` on the row, or `⇧⌘A` for the one that has waited longest,
opens Herdr's confirmation dialog, which names the task and its project; confirming sends
`POST /api/commands` with
`{"type":"task.approve","payload":{"task_id":…,"approved_by":"herdr-sidebar"}}`, the
request `foreman task approve` sent before TRD-018 removed that verb. **Approving starts a
run**: an agent works on the task, once the project is not paused and has a free run slot.
The server picks the workflow from the task and refuses the approval when a dependency of
the task is not closed or the task is no longer `open` (only an `open` task can be
approved); its own error is shown, and so is any answer that is not an accepted command:
the panel never assumes success. The panel reloads after the answer either way. A task is
normally approved by itself at bead import, so these are tasks created without
auto-approve, such as a scheduled task with `auto_approve: false`. (A bead's task is also
`open` for a moment before BeadsWatcher approves it, and after a `task.retry` until its next
rescan: approving it yourself then is harmless, the first approval wins and the server
refuses the other.) Only `open` tasks are listed.

**The rail.** When the sidebar is narrower than 160 px (the shipped chrome's fold
button, or `⇧⌘B`) the panel draws a compact rail: a failed / active summary and
one tile per project, outlined red while it has failed runs. Clicking it widens
the sidebar again. `cmd-b` is Herdr's own show/hide for the whole sidebar and is
unchanged.

**Completion notifications.** When a run goes from running, queued or paused to `completed`, the panel
raises a Herdr notification, `fix foreman-vbfmo.12 completed` (the workflow, then the bead id, else the
task id, else the title). Clicking it opens that run's detail tab on **Activity**.

- The first poll after the panel starts only records what is there: runs that were already completed, or
  that completed while Herdr was closed, are not announced.
- A run is announced once per session, however its status flaps between the sources the list is built from (the
  panel remembers an announced run only while the listing still has it, so that memory stays as small as the listing).
  Only `completed` is announced (not failed or cancelled), and only a run that was seen running: one that
  started and completed between two 10 s polls, or that first shows up already completed, is not.
- The notification is Herdr's own toast, so it shows in the Herdr window (for 30 s: a default toast lasts about
  6 s, too short to click if you are looking elsewhere), and the panel posts it: it comes while the panel is
  loaded (the `foreman` layout is showing), with the sidebar folded or not.
- `herdr-app do 'foreman-runs.open-run-activity:<run-id>'` does what the click does. Herdr delivers only the
  *name* of a mod command to the mod and drops its `args`, so the run id travels in the name after a colon
  (a notification's `action: {name, args}` is that same command). Each click opens a new tab: Herdr does not
  tell a mod which run a tab shows, so an open tab for the run cannot be found and focused.

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
one that is going on Activity; the tab you click stays. `⌃⌥→` / `⌃⌥←` (`ctrl-alt-right` /
`ctrl-alt-left`, bound to `foreman-run.next-tab` / `prev-tab` in the `layout:foreman` section of
`keys.json`) step to the next / previous tab and wrap around. The `tab` prop (see the end of this
section) picks the tab it opens on; a completion notification opens `activity`.

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
  available`. While the run's pull request may be merged, a banner under the tab bar offers **Approve &
  merge** (see "Merging the pull request"); it sits outside the scrolling feed so that following the feed
  does not scroll it away.
- **Phases.** One section per phase; click to open. Open: when it started and ended, its provider and
  model, attempts, failure reason or stall, then its **phase report** (the markdown the agent wrote,
  from `GET /api/runs/:id/artifacts/:phase_id`, fetched when you open the phase and kept per sha256):
  name and size, `copy path`, `open` (a document opens in your default app), the path, a badge saying
  whether the file's sha256 still matches what the phase recorded (`✓` / `✕ … changed after the phase
  wrote it`), a notice when the server cut it at 256 KiB, and the text itself with headings, bullets,
  `**Label**:` lead-ins, tables and code blocks drawn plainly (120 rows, then `show more`). A report whose file is
  `missing` or `unreadable` says so with the server's reason (a report whose original file is gone or has been
  overwritten since the phase, but which the server archived at phase completion, is shown from that copy, with a line saying so); a phase with no report says that, but only once the
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
  The row under the PR's title is its **Approve & merge** button (**Merge** once the PR is approved): live
  only when the server says the PR may be merged, otherwise dimmed with the reason beside it.

**Merging the pull request.** This is the one thing the run-detail tab does that changes anything on GitHub,
so it is narrow, asks first and trusts the server over itself. Merging is two operator-only steps on the
server, run through the `foreman` CLI so that its error text is the server's own.

- *When the button is live.* The PR is `open`; its head is a full commit SHA; the server's
  `eligibility.status` is exactly `eligible` (its values are `off`, `eligible`, `ineligible`, `waived` and
  `unknown`); no check is failing; and its merge gate is `pending` (or already `approved`: the button then
  says **Merge** and skips the approval). Otherwise it is dimmed and says why: `off` (the project has no
  required checks, so no CI evidence was checked: approving that needs the explicit
  `foreman run approve-merge --acknowledge-gate-off`, which this button never sends), `waived` (an
  operator's waiver, not passing evidence), not eligible (with the evidence codes), merged, closed,
  conflicted, no full head SHA, or a gate that is not pending. Only the run's primary PR can be merged
  here: the server reports a merge gate for that one only. It is also dimmed while the last read of the PR
  evidence has failed, because what is on screen may be old.
- *Who approves.* You, as the GitHub login that `gh api user --jq .login` prints on this machine
  (`--approver <login> --identity github:<login>`). If it cannot be read, an error toast says so and
  nothing is sent. The server accepts an approval only from identities on its approver allowlist; its refusal
  is shown in the toast with an explanation.
- *The confirmation.* A click first checks that the installed `foreman` has `run approve-merge` and
  `run merge` (it reads `foreman run --help`, which only prints usage; a `foreman` without them gets the toast
  "installed foreman lacks `run approve-merge`; update it" and nothing is sent), then reads your login, then
  opens Herdr's confirmation dialog: the PR number, its base, the short head SHA, who approves, and "squash
  merge on GitHub; this cannot be undone". Esc cancels, and nothing has been sent at that point. A
  confirmation answered more than a minute after it was asked is ignored.
- *On confirm* the tab reads the PR from the server again and stops with an info toast if it is no longer
  mergeable or its head is not the commit the dialog showed. Otherwise it runs
  `foreman run approve-merge --id <run> --approver <login> --identity github:<login> --head-sha <FULL sha>`
  (the server reads the PR's head back from GitHub and refuses any other commit, then pins the merge to it)
  and, only if that was accepted, `foreman run merge --id <run>` (the server squash-merges on GitHub only
  the pinned head, and checks its gate again). The result is a toast and a reload. A busy flag makes a
  second click or a second confirmation do nothing while one is under way.
- *If the second step fails* the first stands: the toast says "Approved …, but the merge failed: …" and the
  button reads **Merge**, to retry. A push after the approval voids it (the gate is held again), and the new
  head then needs a new approval, which the dialog shows.

**What is read, and how often.** The run, its phases and the transcript every 3 s while the run is going
(30 s once it is over); approvals and questions only while it is going; PR evidence and the report list
at most every 10 s (30 s once over; `↻` reads them at once); a report's text only when its phase is open,
once per sha256; git every 10 s for a run that is going. Everything is read-only except the merge above. A read that fails is
shown with its reason and never turned into "nothing there"; a server that lacks a route is told as
that. All text that came from an agent or from GitHub is drawn as plain text: nothing in it is
interpreted, linked or loaded.

`PR ↗` opens the pull request, `raw` opens `foreman run get`, the id line copies the run id. A run for a bead shows the bead id as a chip beside the workflow name (on every tab, Activity included): click it to copy the bead id. A run that is not for a bead (`coord-…`, `adhoc-…`) has no chip.

Open it from the panel, or directly:
`herdr-app do tab.new '{"name":"run","mod":"foreman-run","props":{"run_id":"run-…","tab":"phases","phase":"fix"}}'`
(`tab` is optional: `overview`, `activity`, `phases`, `changes` or `pr`; `phase` is optional too, a phase name or its number: that phase opens in the Phases tab, which then becomes the starting tab unless `tab` says otherwise).

The panel opens it that way for a click on a run (no `tab`: the run's state decides) and for a completion
notification (`tab: "activity"`).

## Troubleshooting

| Symptom | Likely cause |
|---|---|
| `HTTP 401: unauthorized` in the panel | The server has a token and none was found. Check `FOREMAN_API_TOKEN=` in the `.env` named by `ENV_FILE` in `mods/foreman-runs/common.js`. |
| `connection refused` | The server is not running on `FOREMAN_API_URL` (default `127.0.0.1:4766`). |
| `foreman: command not found` | `foreman` is not on the `PATH` the Herdr app inherits. |
| No panel | The `foreman` layout is not showing: `herdr-app do layout.switch '{"name":"foreman"}'`. |
| Shortcuts do nothing | They apply only while the `foreman` layout is showing. If they still do nothing with a terminal focused, move the entries of `layout:foreman` into the `global` section of `keys.json`. |
| Panel errors after a Herdr update | `herdr-app status` lists mod errors; `herdr-app check ~/.config/herdr-app/mods/foreman-runs` (or `…/foreman-run`) prints the exact one. |
| "This server has no /api/runs/:id/artifacts route (HTTP 404), so each report is read from this machine instead" | The server predates the report routes. For each finished phase the tab reads, in order: the server's archived copy at `~/.foreman/runs/<run-id>/archive/phase-<n>.md` (any phase; header `report 4.9 KB · archive`); for a phase with no `artifact:` template, the file it wrote at `~/.foreman/runs/<run-id>/phase-<n>.md` (header `· disk`); otherwise the commit Foreman made for the phase (`Foreman run <run-id> phase <n>`), or, for a phase that declared `commit: false`, the later phase's commit that carries the file the workflow names, read with `git` in the run's repository (its thread's `repo_path`, else its project's registered path; archived projects included), header `report 1.1 KB · git`. None of these are checked against a recorded digest. A report in none of these places reads `not found`. Update and restart the server to get the recorded, digest-checked copies. |
| "Could not read the PR evidence: projection_unavailable: …" | The server's store did not answer, so the PR's status is *unknown*, not clean. `↻` once it is healthy. The last good answer stays on screen, marked old. |
| "The report file is missing" | The report was written under a worktree or report directory that has been cleaned up and the server holds no archived copy of it. The tab then also looks in the run's git commits and shows the report from there when the phase committed it (a line says which commit). The server archives a report when its phase completes (and, at boot, those whose file still exists), so only runs that finished and were cleaned up before that was in place, and whose phase never committed its report, stay missing. The listing still knows the path and size. |
| "No readable output: the log holds only N blank chunks" | The agent wrote nothing but blank chunks into the part of the log the server keeps (about the newest 500 entries). |
| "unmerged chunks" on a turn | The turn ends with fragments of a message whose whole text has not arrived (or is outside the server's log window); they are shown as sent. |
| "the server has no thread for this run" | The run failed before its thread existed: no transcript, title or branch. The other tabs still work. |
| "installed foreman lacks `run approve-merge`; update it" | The `foreman` on the Herdr app's `PATH` predates the merge verbs. Update it; the merge button sends nothing until the installed binary has both. |
| "Could not read your GitHub login" | `gh` is not on the `PATH` the Herdr app sees, or is not logged in (`gh auth status`). The merge needs your login as the approver; nothing was sent. |
| "the server does not accept this GitHub identity as a merge approver" | `github:<your login>` is not on the server's approver allowlist (`ForemanServer.Workflow.ApproverAuthorizer`). Nothing was approved or merged. |
| **Approve & merge** is dimmed | The reason is written beside it. `off` means the project has no `required_checks` (a project setting: `foreman project update --required-checks '<json>'`, see "Enabling the gate for a project" in `docs/user-guide.md`): the server then has no CI evidence to call a PR eligible, so the button stays dimmed for that project and approving its PRs remains the deliberate `foreman run approve-merge --acknowledge-gate-off`. `waived` evidence is never one-click either; see "Merging the pull request". |
| No notification when a run completes | The panel has to be loaded (the `foreman` layout showing); the first poll only records a baseline; a run that completed while Herdr was closed, between two polls or before it was first seen running is not announced; failed and cancelled runs never are. The notification is a toast in the Herdr window. |

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
| `test/common.test.js` | Regression tests for `common.js`'s pure helpers (clearing, the reset, approval and merge confirmations, approving a task, completion tracking, `canMerge`, the argument builders). `bun:test`, the `herdr` module stubbed, no network or filesystem. Not installed. |
| `common.js` | Helpers both mods share: status styling, the CLI and HTTP callers (`api()` and `apiPost()` report the HTTP status), the token lookup, the approval of a task, the completion tracking behind the notifications, the merge decision (`canMerge`) and the `foreman` argument builders of the two merge steps. Copied into each mod by `install.sh`. |
| `keys.layout-foreman.json` | The `layout:foreman` shortcut section merged into `keys.json`. |
| `install.sh` | Installer / uninstaller. |

## Tests

`test/model.test.js` covers the pure logic of `mods/foreman-run/model.js` (transcript reassembly, phase rows and durations, outcome and PR-evidence summaries, report markdown, fetch-error classification). It uses `bun:test` with inline fixtures and a fixed clock; it reads no network or files and does not touch `main.js` (drawing is not covered). Run it from the repository root:

```sh
bun test ops/herdr-sidebar/test
```

`bun` is not a devbox package and CI does not run this suite: it is a local check you run when you change `model.js` or `common.js`. The same command runs
`test/common.test.js` too: the pure helpers of `common.js`, namely clearing and resetting runs, the completion
tracking and the notification it builds, the parsing of a click's command, `canMerge` for every eligibility state and
PR status, the `foreman` argument builders (full head SHA, identity, no gate-off acknowledgement), the missing-verb
check and the wording of the server's refusals.

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
| `/api/runs/:id/artifacts/:phase_id` | `state` (`ok`, `missing`, `unreadable`), `source` (`recorded` or `archive`: where the content came from; absent on a server that predates archiving), `content`, `content_bytes`, `truncated`, `sha_matches`, `error`, `path`, `bytes`. A `missing` or `unreadable` file is a **200** that carries `error` as data | the report shows the error; `source: "archive"` adds a line saying the shown text is the archived copy |
| `/api/runs/:id/prs` | per PR: `pr_url`, `status`, `head_sha`, `base_branch`, `branch_name`, `merge_gate`, `checks_state`, `failing`, `checks.items[]` (`name`, `state` `passing`/`failing`/`pending`, `conclusion`), `review_decision`, `comment_count`, `fixes`, `agent_review`, `eligibility` (`status`, `reasons[]`, `waived[]`), `findings` (`status`, `total`, `unresolved` **as a map by severity**, `items[]`, `judgement`), `risk` (`level`, `rationale[]`, `instructions[]`), `waiver`, `report`, `delivery_issue`, `next_actions[]`; shapes in the moduledoc of `ForemanServer.PrWatch.DTO` | PR sections say the server lacks the route |
| `/api/runs/:id/approvals`, `/api/projects/:id/questions` | `approvals[]`: `tool_call_id`, `tool_name`, `input_summary`, `requested_at`; `questions[]`: `run_id`, `question_id`, `text` | banner says they could not be read |
| `/api/threads/run:<id>` and `/transcript` | `repo_path`, `title`, `branch`; `turns[]`: `seq`, `at`, `kind`, `source`, `text`, `omitted_entries` (invalidates cursors). A run that failed before its thread existed answers `thread_not_found` | the feed says there is no transcript |

`api()` (and `apiPost()`, which shares its response handling) appends curl's HTTP status to the response and throws an `Error` with `.status` (and `.code` when
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

The panel posts one command itself, `task.approve` (`apiPost()` in `common.js`, `POST /api/commands`): the body is
`{type, payload: {task_id, approved_by}}` and nothing the gateway reserves (`approval_id`, `approved_at`, `run_id`,
`workflow_snapshot`; the controller mints the command id). Only HTTP 201 with `status: "accepted"` counts as approved.
A refusal is `422 {"error": "<inspect(reason)>"}` (`{:task_not_found, id}`, `{:task_not_approvable, status}`,
`{:task_dependencies_unsatisfied, …}`), shown as it came; so is any other answer.

The merge button reads the same PR records (`ForemanServer.PrWatch.DTO`): `status` (`open`, `conflicted`,
`merged`, `closed`; only `open` merges), `head_sha`, `repo_id` (null for the run's primary PR), `merge_gate`
(`none`, `pending`, `approved`; present only for the run's primary PR) and `eligibility.status` (`off`,
`eligible`, `ineligible`, `waived`, `unknown`; `ForemanServer.PrEvidence`). The server decides an approval on
`off` (only with `acknowledge_gate_off`), `eligible` and `waived`; the tab offers `eligible` alone, so
`--acknowledge-gate-off` and waived evidence stay deliberate CLI acts. The steps are `foreman run
approve-merge` and `foreman run merge` (`packages/foreman_cli/cmd/foreman/run.go`: `merge_approve` and
`run.pr.merge` on `POST /api/commands`). The CLI prints a refusal as `foreman: HTTP 422: {"error":
"<inspect(reason)>"}`; the ones this flow meets are `:unauthorized_approver` (the allowlist is
`Workflow.ApproverAuthorizer`'s), `{:head_sha_mismatch, named, live}`, `{:head_moved_since_approval, approved,
live}`, `{:evidence_ineligible, head, codes}`, `:merge_gate_already_approved` and `:pr_not_acceptable`.

A completion notification's `action: {name, args}` is run by Herdr's `toast` mod as `run(name, args)`. For a mod
command Herdr delivers `<command>[:<value>]` to the mod's `nextCommand()` (the mod's name stripped) and drops
`args` (checked with a probe mod: `run("m.c:x.y", {a: 1})` delivers `c:x.y`), which is why the panel's
`open-run-activity` command carries the run id after a colon (`parseActivityCommand` in `common.js`).

Verification so far: the panel was exercised against a live server and against
stub servers, and the commands behind each shortcut were driven with
`herdr-app do foreman-runs.<command>`. The run-detail tab's logic (`model.js`) was exercised with plain
fixtures and with transcripts captured from a live server; its views were rendered against a recording
stand-in for `gpui-kit` (every element method checked against `gpui-kit.d.ts`) with a live server, a
server without the new routes and fixture servers; both mods pass `herdr-app check`. The key chords,
mouse clicks, scrolling and how it looks in a real window were not exercised by an automated check.

The completion notification and the merge flow were checked three ways. `test/common.test.js` covers their pure
logic. Their `main.js` code (the poll that announces, the command a click delivers, the asking and confirming
steps with every refusal path, the double-click guard) was driven through the real files against a recording
stand-in for `gpui-kit` and for the `herdr` module, with a fake `exec`: no server was contacted and no merge could
be sent. A copy of the detail tab, pointed at a fixture server and at a stub `foreman` that only logged what
it would have run, was opened in a real Herdr window: the banner, the live button and the confirmation dialog
rendered, nothing ran before the dialog was answered, and answering it (with the command the
Confirm button runs) ran approve-merge and then merge, in that order, with the full head SHA. Not exercised: a
click on a notification's toast (the toast mod runs `run(name, args)`, and a probe mod confirmed that this
delivers `<command>:<value>` to a mod and drops `args`) and a real merge. The dimmed button, with its reason beside
it, was also seen in the installed tab on a real run's PR tab (its project has no required checks).
