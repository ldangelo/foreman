---
Document ID: PRD-2026-f7a50d75
Label: prd-workspace-nav-run-provenance-links
Version: 1.0.0
Status: Draft
Date: 2026-11-04
Scale Depth: STANDARD
Total Requirements: 19
Readiness Score: not yet scored (create-prd draft; no refine pass run)
Supersedes: PRD-2026-7735ac9c REQ-015 / AC-015-1 (the "no run-detail links" boundary only)
---

# PRD: Workspace nav — workflow and jobsite rows that identify the work and link to its run

> Operator request (paraphrased from the 2026-11-04 session): the **Workflows** panel in
> the workspace left nav lists runs as `prd · completed`, `fix · completed`, … which
> tells the operator nothing. Each row should show **the workflow's title (the original
> bead title)** and link to **the run's details, the TRD (when the run is a PRD run), the
> branch, the worktree, and the like.**

> **Note (2026-11-06, run-c5530c375ee791d5dd62d0817eb65f12):** this document was delivered as
> `FOREMAN_SOURCE_PRD_PATH` for a task whose subject is unrelated to it — "Bridge the agent ask
> tool to Telegram/Slack so Foreman can ask the operator a question and get an answer". That run's
> PRD/TRD/implement phases were blocked on the mismatch and landed nothing. The mismatch is in the
> *task's* source-PRD pointer, not here: this PRD is a point-in-time spec for workspace nav run
> provenance links and needs no edits from that run.

## PRD Health

- Requirements by priority: Must (15), Should (3), Could (0), Won't (1)
- AC coverage: 19/19 requirements have acceptance criteria (100%)
- Risk flags: 6 requirements flagged (REQ-005, REQ-010, REQ-011, REQ-013, REQ-014, REQ-019)
- Cross-requirement dependencies: see Dependency Map (REQ-013 constrains REQ-010; REQ-003 gates REQ-001/007/015)
- Open clarifications: 3 (see "Open Questions")

## Relationship to PRD-2026-7735ac9c (already landed)

`PRD-2026-7735ac9c-dashboard-jobsite-workflows-nav.md` added the **Jobsite** and
**Workflows** panels. Its REQ-015 (Won't, this release) and AC-015-1 state the panels are
"glance-only … no run-detail links", and its TRD-006 is an inspection check asserting the
absence of detail links. **That document is left unedited.** This PRD deliberately reverses
only that one boundary, for the reason in Problem & Context. Every other decision of the
earlier PRD (panel order, read-only, newest-first / most-recently-active ordering, the
100-row cap and `100+` badge, empty states, reuse of `ws-panel*` CSS, no new command or
event) stays in force unless a requirement below says otherwise. The TRD derived from this
PRD MUST retire the old TRD-006 "no detail links" inspection by superseding it, not by
editing the old TRD (REQ-016).

## Problem & Context

The Workflows panel (`workspace/components.ex:325-337`) renders each row as
`<strong>{nav_workflow_label(r.workflow)}</strong> · {r.status}` — nothing else. The row
data is a `RunDTO` built by `OperatorDashboard.run_dto/2` (`operator_dashboard.ex:265`) and
read by `ProjectWorkspaceLive.nav_workflow_runs/1` (`project_workspace_live.ex:785`). The
Jobsite panel (`components.ex:312-324`) is the same: `bead_id || jobsite_id` and a status.

What the operator sees is therefore a column of identical labels. In the observed project
there are eleven rows reading `prd`, `fix`, `assess` and `completed`/`failed`; none says
*which task* the run was for, and none can be clicked.

**Where the label comes from.** `RunDTO.workflow` is the workflow **manifest name frozen in
the run's `workflow_snapshot` at dispatch** (`operator_dashboard.ex:307`; the run
projection's own `workflow_name` is nil on dispatched runs). The names are those of the
installed catalog (the six bundled templates in `priv/defaults/workflows/` — `prd`, `fix`,
`assess`, `review`, `implement-trd`, `implement-trd-beads` — unless the operator's catalog
root differs). It is a *kind of workflow*, not an identity; many runs share it, and the
snapshot can differ from today's catalog.

**Where the identity already lives.** The thread list in the middle column shows a real
title for the very same runs, because `ForemanServer.Threads.Thread` derives one from the
task (`thread.ex:156`: task `title` → first line of `prompt` → first line of `description`
→ `task_id` → run id). For a bead-sourced task that title is the bead title. The Workflows
panel simply never reads the task.

**Where the provenance already lives.** All of the requested links are already projected
or derivable read-only:

| Operator wants | Existing source |
| --- | --- |
| Original bead title | `ProjectionStore.task_projection/1` (`projection_store.ex:248`) via `run.task_id`; same derivation as `Thread.title/2` |
| Run details | `OperatorRunDashboardLive` at `/dashboard/runs?run_id=<id>` (`mount/3` reads `params["run_id"]`, `operator_run_dashboard_live.ex:19`) — phases, logs, changed files, PR association, actions |
| Branch, base ref, worktree path and state | `ProjectionStore.worktrees_for_run/1` (`projection_store.ex:1136`): `branch`, `base_ref`, `worktree_path`, `repo_path`, `status`, `cleanup` |
| PR | run `pr_url` and per-phase `phase_prs` (`PhasePrRecorded`), `OperatorDashboard.pr_association/1` |
| TRD for an implement-TRD task (primary TRD source) | the task projection's `trd_path` (`projection_store.ex:2847`, frozen at `task.create`/approval; a project-relative path). Read it with ONE bulk `ProjectionStore.list_tasks/0` (`projection_store.ex:288`) indexed by `task_id`, not 100 `task_projection/1` calls. `docs/user-guide.md` documents that the bead's `agent_context.trd_path` is what populates it; the TRD must confirm that field reaches the projection for bead-sourced tasks. |
| PRD/TRD written by a planning run (fallback) | no projected field names the document. The `prd` workflow (`priv/defaults/workflows/prd.yaml`) commits `docs/PRD/*` and `docs/TRD/*` on the run branch and declares no `requiredFile:`. Discoverable only from the branch diff: `OperatorDashboard.ChangeEvidence.for_run/1` → `git diff --name-status base..HEAD` (`operator_dashboard.ex:530`) filtered to `docs/PRD/PRD-*.md` / `docs/TRD/TRD-*.md`. This shells out via `System.cmd`. |
| Phase artifact (a different thing) | `ProjectionStore.phases_for_run/1` phase maps carry `:artifact => %{path, sha256, bytes}` (`projection_store.ex:2790`, phase DTO `operator_dashboard.ex:384`). In the bundled workflows that is the phase's **report** (`REVIEW_REPORT.md`, `REVIEW_CODERABBIT_REPORT.md`, assess/fix reports, `prd.yaml:66,76`), not the PRD/TRD. It MAY be shown as text; it MUST NOT be presented as the TRD. |
| Conversation | `/dashboard/projects/:id/threads/run:<id>` (`Components.thread_path/3`) |

**Two constraints discovered while scoping.**

1. *Cross-live-session link.* `/dashboard/runs` is in `live_session :operator_runs`; the
   workspace is in `:project_workspace` (`router.ex:155-168`). A `patch`/`navigate` link
   between them fails; the link must be a full page load. The dashboard accepts its token
   only as a header or `?token=` (no cookie), so the URL must carry it, as
   `Components.project_path/2` does.
2. *The conversation link can dead-end.* A thread pane resolves its id only through
   `Overview` groups (`ThreadView.find_card/2`, `thread_view.ex:204`). The workspace builds
   the Overview with `include_resolved: true` but the default `resolved_limit` of 20
   (`project_workspace_live.ex:631`, `overview.ex:49,217`). The 21st-oldest resolved run —
   exactly the deep history a 100-row panel surfaces — would land on "This project has no
   thread with that id." The run-details route has no such limit.

**Who feels the pain:** the operator using the workspace as their home view, scanning for
"which of these runs was the dashboard-nav task, and where did it put its TRD?"

## Goal & Success

Each row of the **Workflows** panel (and, where the data exists, the **Jobsite** panel)
identifies the work by its **task/bead title** and gives one-click access to **that run's
details**, its **PR**, its **branch and worktree**, and, for PRD runs, its **PRD and TRD
documents** — without the nav becoming a second run dashboard.

Success looks like:

- Eleven `prd · completed` rows become eleven distinguishable rows titled by their beads.
- The title links to run details; a disclosure on the row exposes branch, base, worktree
  (with whether it still exists), PR, and PRD/TRD links.
- A link never silently leads nowhere: unavailable items are shown as unavailable, with a
  reason (REQ-011).
- Refreshing the nav stays cheap: no filesystem or `git` work per row per refresh
  (REQ-013).
- No new command, event, aggregate or HTTP route is required to *display* any of this
  (read-only, as before).

## Research & Reuse

Reuse; do **not** build a parallel data path.

- **Row read model.** `ProjectWorkspaceLive` already assigns `nav_workflow_runs` /
  `nav_jobsites`. Extend what those assigns carry; the panel template should receive a
  typed row, not raw maps (REQ-015).
- **One title function.** `Thread.title/2` is private. Promote its derivation into a
  single shared function used by both `Thread` and the nav row, rather than copy it
  (REQ-003; AGENTS.md §5.7 "never duplicate a boundary").
- **Link builders.** `Components.thread_path/3`, `Components.project_path/2` and
  `Components.safe_url/1` (blocks `javascript:` URLs) exist. A sibling builder for the
  run-details URL belongs next to them; every link of the page is built there so the token
  is carried uniformly.
- **Worktree and branch.** `worktrees_for_run/1` already feeds `Thread.from_run/6` (it
  picks the newest record with a branch). Reuse that selection rule.
- **Documents.** `OperatorDashboard`'s evidence helpers already list a run's changed files
  from its worktree against a validated base, with `safe_relative?`/`safe_git_ref?` guards
  and a read-only preview. That is the only existing mechanism that knows a PRD run's
  document paths; it shells out to `git`, which drives REQ-013.
- **AGENTS.md constraints in force:** typed returns with `@enforce_keys` (§5.1); absent ≠
  malformed (§5.3); the merge gate is operator-only — the nav MUST NOT expose
  `merge_approve`/`run.pr.merge`; documentation gate.

## Requirements

### Row identity

### REQ-001: A run row is titled by its task's original title
**Priority:** Must · **Complexity:** Low · Depends on: REQ-003

Each Workflows row's primary text is the **title of the task the run was dispatched for**
(for a bead-sourced task, the original bead title), not the workflow name.

- AC-001-1: Given a run whose task has `title: "Dashboard nav: add Jobsite and Workflows
  run profiles"`, when the panel renders, then that exact text is the row's primary label.
- AC-001-2: Given two runs of the same workflow for different tasks, when rendered, then
  their primary labels differ.
- AC-001-3: Given a very long title, when rendered, then the label is visually truncated
  (`ws-ellipsis`) and the full title is available as the element's `title` attribute.

### REQ-002: The workflow name and status stay visible as secondary information
**Priority:** Must · **Complexity:** Low · Depends on: REQ-001

The workflow name (`RunDTO.workflow`, via the existing `nav_workflow_label/1`) and the run
status remain on the row, de-emphasised, so the operator can still tell a `prd` run from a
`fix` run and a completed run from a failed one.

- AC-002-1: Given a `fix` run with status `failed`, when rendered, then the row shows the
  title, the text `fix` and the text `failed`.
- AC-002-2: Given the workflow name is absent (`:absent`), when rendered, then the row
  renders the title and status and the existing fallback label for the workflow, and does
  not crash.

### REQ-003: One title derivation shared with threads
**Priority:** Must · **Complexity:** Low · Depends on: none

The nav row and `Threads.Thread` MUST derive a run's title through the same function, with
this fallback order: task `title` → first non-blank line of `prompt` → first non-blank
line of `description` → `task_id` → run id. [RISK: a second copy would drift and the
panel and the thread list would show different names for one run.]

- AC-003-1: Given a task with only a `prompt`, when both the thread list and the nav row
  render the run, then both show the prompt's first non-blank line.
- AC-003-2: Given a run with no task (an ad-hoc run), when rendered, then the label is the
  run id, matching the thread list, and the row remains linkable.
- AC-003-3: Given the shared function is changed, when the suite runs, then a test fails
  for **both** surfaces (they cannot diverge silently).

### Links

### REQ-004: The row links to the run's details
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-001

The row's primary label links to the operator run dashboard for that run:
`/dashboard/runs?run_id=<run_id>` plus the dashboard token. The link is a full page load
(plain `href`/`redirect`), because the target is in a different `live_session`.

- AC-004-1: Given a run `R` and a workspace opened with `?token=T`, when rendered, then
  the label's `href` is `/dashboard/runs?run_id=R&token=T` with both values correctly
  encoded.
- AC-004-2: Given a workspace opened without a token (test/dev), when rendered, then the
  `href` carries no `token` parameter and no `token=` literal.
- AC-004-3: Given the link is followed, when the page loads, then the run dashboard
  selects and shows run `R`'s detail pane (verified through the real route).
- AC-004-4: Given a run with no `run_id` (malformed projection row), when the panel
  renders, then it raises (loud failure per AGENTS.md §5.2/§5.3), not an empty `href`.

### REQ-005: A conversation link that cannot dead-end
**Priority:** Should · **Complexity:** Medium · Depends on: REQ-004 · [RISK: see Problem & Context, constraint 2]

Where the row offers a link to the run's conversation (`/dashboard/projects/:id/threads/run:<id>`),
that link MUST resolve for **every** run listed in the panel, including resolved runs
beyond the Overview's `resolved_limit`. The TRD chooses the mechanism (resolve an
out-of-Overview thread directly by id from the projections, or raise the Overview bound);
the panel MUST NOT ship a link that can land on "This project has no thread with that id."

- AC-005-1: Given a project with more than 20 resolved runs, when the link for the oldest
  listed run is followed, then the thread pane shows that run's conversation.
- AC-005-2: Given a run id that does not exist, when its thread URL is requested, then the
  existing "no thread with that id" message still appears (unknown stays unknown).
- AC-005-3: Given a project with exactly 100 listed runs, when every conversation link is
  followed in a test, then none renders the not-found state.

### REQ-006: The row links to the run's PR when it has one
**Priority:** Must · **Complexity:** Low · Depends on: REQ-001

If the run has a PR (`pr_url`, or a PR association/phase PR), the row exposes an external
link to it (`target=_blank`, `rel="noopener noreferrer"`), passed through
`Components.safe_url/1`. Runs without a PR show no PR link and no broken placeholder.

- AC-006-1: Given a run with `pr_url: "https://github.com/o/r/pull/12"`, when rendered,
  then the PR link points there with `rel="noopener noreferrer"`.
- AC-006-2: Given `pr_url: "javascript:alert(1)"`, when rendered, then no link is emitted.
- AC-006-3: Given a run with no PR, when rendered, then no PR element is present.
- AC-006-4: Given the nav is rendered, when its markup is searched, then it contains no
  merge or approve control or link (the merge gate stays operator-only).

### REQ-007: Jobsite rows show the task title and link to their conversation
**Priority:** Should · **Complexity:** Low · Depends on: REQ-003, REQ-005

A Jobsite row's primary text is the owning task's title (falling back to the `bead_id`,
then the `jobsite_id`, as today), and it links to the jobsite thread
(`/dashboard/projects/:id/threads/jobsite:<id>`, subject to REQ-005's no-dead-end rule).
There is no standalone jobsite detail page; none is introduced.

- AC-007-1: Given a jobsite whose bead has a title, when rendered, then the title is the
  label and the bead id remains visible secondarily.
- AC-007-2: Given a jobsite with no task, when rendered, then the row shows
  `bead_id || jobsite_id` exactly as today.

### Provenance

### REQ-008: The row exposes the branch and its base
**Priority:** Must · **Complexity:** Low · Depends on: REQ-001

The row's disclosure (REQ-012) shows the run's branch and the base ref it was cut from,
with the branch name selectable/copyable as text. Selection follows `Thread.from_run/6`:
the newest worktree record that has a branch.

- AC-008-1: Given a run whose worktree record has `branch: "foreman/foreman-ab12/run-7"`
  and `base_ref: "main"`, when the disclosure is open, then both strings are shown.
- AC-008-2: Given a run with several worktree records, when rendered, then the branch of
  the newest record that has one is shown.
- AC-008-3: Given a run with no worktree record, when rendered, then the branch area shows
  a distinct "no branch recorded" state (REQ-011), not blank text.

### REQ-009: The row exposes the worktree path and whether it still exists
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-008

The disclosure shows the worktree's absolute path **as selectable text** (not a hyperlink:
a browser cannot open a `file://` path from this page and the link would look live and
do nothing) together with its state from the projection (`created`, `cleaned`, removed, or
unknown) and the configured `cleanup` policy. Branch names, worktree paths and phase-artifact
paths are server-side filesystem/git values with no HTTP surface; every one of them is
displayed text only. The worktree path is shown absolute; artifact and document paths are
shown project-relative. The nav adds no file-serving route.

- AC-009-1: Given a worktree record `status: "created"`, `cleanup: "never"`, when rendered,
  then the path and "kept" state are shown.
- AC-009-2: Given a run whose worktree was cleaned up, when rendered, then the path is
  shown marked as removed, not presented as live.
- AC-009-3: Given the markup, when searched, then the path is not inside an `<a href>`.

### REQ-010: Runs expose their TRD (and, for planning runs, their PRD and TRD)
**Priority:** Must · **Complexity:** High · Depends on: REQ-004, REQ-013, REQ-019 · [RISK: no projected document path exists for `prd` runs]

The disclosure shows the run's TRD, resolved in this order:

1. **Task `trd_path`** (primary): when the run's task carries one, show that project-relative
   path as the run's TRD. Read from the bulk task read (see Research), never from a
   per-row projection call or from Overview cards.
2. **Planning-run discovery** (fallback): for a run whose task has no `trd_path`, the PRD and
   TRD files the run wrote, found by the branch-diff rule in Research (`docs/PRD/PRD-*.md`,
   `docs/TRD/TRD-*.md`, project-relative, `safe_relative?`). This path runs ONLY on
   disclosure-open and ONLY under the REQ-013 execution rules.

Each document that has a readable source links to
`/dashboard/runs?run_id=<id>&tab=changes&file=<project-relative path>` (REQ-019). Until
REQ-019 is implemented no document link is emitted; the path is shown as text. A task
`trd_path` that is not among the run's changed files (the TRD pre-existed the run) is
shown as text without a link: the dashboard serves only a run's changed files, and the nav
does not widen that.

- AC-010-1: Given a completed `prd` run whose branch added `docs/PRD/PRD-…md` and
  `docs/TRD/TRD-…md`, when the disclosure opens, then both paths appear, each linking to the
  run dashboard's `tab=changes&file=` URL for that path.
- AC-010-2: Given an implement-TRD task with `trd_path: "docs/TRD/TRD-x.md"`, when
  rendered, then that path is shown as the TRD without any `git` call, and is linked only
  if it is among the run's changed files.
- AC-010-3: Given a `fix` or `assess` run that wrote no planning document, when rendered,
  then no PRD/TRD section is shown (absence is not an error).
- AC-010-4: Given the run dashboard preview refuses a path (unsafe or outside bounds), when
  its link is followed, then the existing refusal state renders; the nav does not widen
  what the preview serves.
- AC-010-5: Given a phase `:artifact` of `REVIEW_REPORT.md`, when the disclosure renders,
  then it is not labelled or linked as the TRD.

### REQ-011: Missing data is shown as missing, with the reason
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-008, REQ-009, REQ-010 · [RISK: silent omission would be the failure mode the panel already has]

Where the operator would expect a branch, worktree, document or PR and the data cannot be
produced, the disclosure says so with a typed reason (e.g. "worktree removed", "base ref
unavailable", "git unavailable", "no document written"). It does not drop the element,
substitute a guess, or render a link to nowhere. Distinguish **absent** (never existed)
from **unavailable** (exists but could not be read).

- AC-011-1: Given a run whose worktree directory no longer exists but a PR exists, when
  rendered, then the worktree line states it is removed and the PR link remains.
- AC-011-2: Given `git` cannot be executed for document discovery, when the disclosure
  opens, then the Documents area shows "unavailable: git" and the rest of the row renders.
- AC-011-3: Given a run that never had a worktree (`worktree.enabled: false`), when
  rendered, then the state reads "no worktree for this run", distinct from "removed".

### Presentation, cost and safety

### REQ-012: Compact row, details on demand
**Priority:** Should · **Complexity:** Medium · Depends on: REQ-001..REQ-011

The default (collapsed) row stays glance-density: title, workflow name, status chip and
relative start time. Branch, worktree, PR and documents sit in a per-row disclosure
(`<details>`/`<summary>`) that works without client JavaScript (the workspace ships none
beyond the LiveSocket bootstrap). Existing panel conventions are preserved: newest-/most
recently-active-first order, the 100-row cap, the `100+` badge, the empty state, and the
`ws-count`.

- AC-012-1: Given the panel renders 100 runs, when the page loads, then every disclosure is
  closed and the panel's height is bounded by its existing scroll constraint.
- AC-012-2: Given a keyboard user, when tabbing, then each run's title link and its
  disclosure summary are reachable and the disclosure toggles with Enter/Space.
- AC-012-3: Given the existing empty/ordering/cap/badge assertions of
  `project_workspace_live_test.exs`, when the suite runs, then they still pass unchanged.
  The assertions that pin a Workflows row's `strong` text to the **workflow name** are
  inverted by REQ-001 (the task title becomes the primary label) and are rewritten to
  assert the workflow name as secondary text; no test is skipped or loosened.

### REQ-013: Bounded cost on the refresh path and on disclosure-open
**Priority:** Must · **Complexity:** High · Depends on: none · [RISK: the workspace refresh is event-driven with a 250 ms coalesce window (`workspace/refresh.ex:32,75`), i.e. up to ~4 refreshes/second during an active run, each re-reading the whole nav, and the nav lists up to 100 runs]

**Refresh path.** Rendering the panel MUST NOT run `git`, spawn a subprocess, or touch the
filesystem — per row or in total. Title, workflow, status, branch, base, worktree
path/state, PR and the task `trd_path` come from projection reads only, using bulk reads
(`list_tasks/0` indexed by `task_id`, or `Threads.by_run_ids/1`), never one projection call
per row. The title MUST NOT be taken from Overview cards (the workspace builds the Overview
with the default `resolved_limit` of 20, so the oldest rows would lose their titles).

**Disclosure-open path.** Anything that needs `git` or the filesystem (planning-run
PRD/TRD discovery, checking that a worktree directory still exists) runs only when that
row's disclosure is opened, for that one row, and MUST NOT run in the LiveView process: it
uses the shape of `OperatorRunDashboardLive.load_changes_bounded/1`
(`operator_run_dashboard_live.ex:292-296`) — `Task.async` + `Task.yield` with a timeout
(that module's `@evidence_timeout_ms` is 3 000) — so a slow or hung `git` call degrades
one row to a typed "unavailable: timed out" state instead of stalling the 250 ms-coalesced
socket for every panel. The result is cached per `run_id` in the socket and is NOT
recomputed by workspace refreshes.

- AC-013-1: Given a project with 100 listed runs, when the workspace refreshes, then zero
  `git` subprocesses are started and no `File` calls are made (asserted with a counting
  `git` shim on `PATH`; `ChangeEvidence` calls `System.cmd("git", …)` directly, so there is
  no injectable runner to spy on).
- AC-013-2: Given a disclosure is opened, when discovery runs, then it runs for that single
  row, off the LiveView process, and its failure or timeout does not affect other rows.
- AC-013-3: Given a `git` stub that hangs longer than the timeout, when a disclosure is
  opened, then that row shows "unavailable: timed out" within timeout + a documented slack
  and the other panels keep updating during the wait.
- AC-013-4: Given a disclosure was opened and a refresh follows, when the refresh runs,
  then discovery is not re-run for that `run_id` (cache hit), asserted by the command-runner
  spy.
- AC-013-5: Given the number of projection reads per refresh, when measured for 100 runs,
  then it is O(1) bulk reads and the TRD records the measured number.

### REQ-014: Link and display safety
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-004, REQ-006, REQ-009 · [RISK: titles, branches and paths are operator/agent-supplied strings]

All displayed titles, branch names, paths and document names are HTML-escaped by the
template engine (no `raw/1`). External URLs go through `safe_url/1`. The dashboard token
rides only in the same-origin dashboard links, built by the shared link builders, and is
never emitted into external (PR) links or the `title`/text of any element. Document paths
are shown and linked only if project-relative and free of `..` (existing `safe_relative?`).

- AC-014-1: Given a task titled `<script>alert(1)</script>`, when rendered, then the page
  contains the escaped text and no executable script element.
- AC-014-2: Given a workspace opened with a token, when the PR link and every visible text
  node are inspected, then the token appears only in same-origin dashboard `href`s.
- AC-014-3: Given a document path `../../etc/passwd`, when discovered, then it is neither
  shown as a link nor passed to the preview.

### REQ-015: Typed read model; absent is not malformed
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-003 · Per AGENTS.md §5.1–§5.4

The data handed to the template is a struct (`@enforce_keys`, `@type t`) per row — e.g. a
nav-run-row with `run_id`, `title`, `workflow`, `status`, `started_at_ms`, branch/base,
worktree (`path`, `state`, `cleanup`), `pr_url`, documents (`{:ok, [..]} | {:unavailable,
reason}`), links — built in one module that normalizes projection key shapes once, at the
boundary. Required fields (`run_id`, `status`) raise when missing; optional ones are
explicit sentinel values, never `nil`-or-missing guesses; no `Map.get(m, :k) ||
Map.get(m, "k")`.

- AC-015-1: Given a projection row missing `run_id`, when the row is built, then it raises
  naming the field.
- AC-015-2: Given a row missing every optional field, when built, then every optional field
  holds its explicit "absent" sentinel and the panel renders.
- AC-015-3: Given the template, when searched, then it contains no raw-map key fallbacks.

### REQ-016: Supersede the old boundary, update tests and docs — without editing the old PRD/TRD
**Priority:** Must · **Complexity:** Medium · Depends on: all

1. `PRD-2026-7735ac9c` and its TRD are **not modified**. The TRD for this PRD states that it
   supersedes TRD-006's "no run-detail links" inspection and carries the replacement
   check.
2. Any existing test that asserts the *absence* of links in these panels is deleted or
   replaced by this PRD's behavior assertions (it must not be skipped or weakened).
3. Documentation gate (AGENTS.md): list the externally visible identifiers added
   (the `run_id` deep link is **not** new — it already exists; the `tab` and `file` query
   parameters of REQ-019 **are**), grep the removed/replaced wording, and edit
   `CLAUDE.md` and `docs/user-guide.md` where the panels are described as read-only
   glance lists without links (CLAUDE.md "Workspace nav" paragraph; user-guide "Workspace
   nav" paragraph). State explicitly whether `README.md` and `docs/cli-reference.md` needed
   edits.
4. The component's own moduledoc ("glance-only") is updated.

- AC-016-1: Given the repo after the change, when `git diff` is taken for
  `docs/PRD/PRD-2026-7735ac9c-*.md` and its TRD, then both are empty.
- AC-016-2: Given the suite, when run, then no test asserts that these panels have no
  links, and every new behavior in REQ-001..REQ-015 has a test that fails if the behavior
  is removed.
- AC-016-3: Given the documentation gate, when run, then the report names each file edited
  and each not edited with a reason.

### REQ-017: Verified against a real route, not only render tests
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-004, REQ-005, REQ-010

In addition to component-level LiveView tests, the change is smoke-tested through the real
router with a seeded project: open the workspace, follow the run-details link, follow the
conversation link for an old resolved run, open a disclosure, follow a TRD link.

- AC-017-1: Given a seeded project with >20 resolved runs including a `prd` run with a
  committed TRD, when the smoke path is executed, then every link followed renders its
  target — including the `tab=changes&file=` TRD link opening that file's preview — with
  no 401, no "no thread with that id", and no empty detail pane.
- AC-017-2: Given the token is required, when a link is followed from a page opened with
  `?token=`, then the target page is authenticated (reload still works).

### REQ-019: The run dashboard can be deep-linked to a tab and a file
**Priority:** Must · **Complexity:** Medium · Depends on: REQ-004 · [RISK: new externally visible query parameters on `/dashboard/runs`]

`OperatorRunDashboardLive` today reads only `run_id`, `status`, `project_id` and `limit`
in `mount/3`, assigns `active_tab` to `"summary"`, and changes it only through the `tab`
event; it has no `handle_params`, and `ChangeEvidence.preview/2` — the existing read-only
per-file diff — has no caller anywhere: the Changes tab lists `status path` as plain text
with no per-file view. So `/dashboard/runs?run_id=X` can select a run but not the Changes
tab or a file, and there is no file view to select. The dashboard MUST accept `tab` (one of
the existing `summary|logs|changes|actions`) and an optional `file` (project-relative) query
parameter and apply them on load, and MUST render the per-file view the `file` parameter
selects (making each Changes-tab file entry selectable), reusing the existing lazy bounded
evidence path and the existing `safe_relative?` and changed-files membership checks inside
`preview/2`. An unknown `tab`, or a `file` that is unsafe or not among the run's changed
files, falls back to the existing states (summary tab; the preview's refusal state) and
never raises.

- AC-019-1: Given `/dashboard/runs?run_id=R&tab=changes&file=docs/TRD/TRD-x.md` and a run
  whose changed files include that path, when the page loads, then the Changes tab is
  active and that file's preview is shown.
- AC-019-2: Given `tab=bogus` or `file=../../etc/passwd`, when the page loads, then the
  summary tab (or the preview's refusal state) renders and no preview of an unsafe path is
  read.
- AC-019-3: Given the new parameters, when the documentation gate runs, then they are
  listed as added externally visible identifiers and `docs/user-guide.md` documents them
  (and `docs/cli-reference.md`/`README.md` are stated unchanged or edited with a reason).

### Out of scope

### REQ-018: No actions, filters or new write paths in the sidebar
**Priority:** Won't (this release) · **Complexity:** Low

The panels still offer no run actions (pause/resume/stop/abandon/reset/merge/approve),
no status or workflow filters, no live tabs, and no new command, event, aggregate or
projection field whose only purpose is display. Pagination beyond 100 rows, search over
runs, and a workflow-type grouping view are separate work. Opening a worktree in an editor
or Finder is out of scope.

- AC-018-1: Given the panels' markup, when searched, then no `phx-click` that dispatches a
  command exists in them.
- AC-018-2: Given the diff, when reviewed, then no new `Commands`/`Events`/`Aggregates`
  module is added solely for the nav.

## Dependency Map

| REQ | Depends On | Notes |
| --- | --- | --- |
| REQ-001 | REQ-003 | title text |
| REQ-002 | REQ-001 | secondary line |
| REQ-003 | — | shared function with `Thread` |
| REQ-004 | REQ-001 | plain `href`, token |
| REQ-005 | REQ-004 | resolvability fix |
| REQ-006 | REQ-001 | `safe_url/1` |
| REQ-007 | REQ-003, REQ-005 | jobsite parity |
| REQ-008 | REQ-001 | branch/base |
| REQ-009 | REQ-008 | worktree state |
| REQ-010 | REQ-004, REQ-013, REQ-019 | task `trd_path` primary; branch-diff fallback on demand |
| REQ-011 | REQ-008, REQ-009, REQ-010 | typed unavailable states |
| REQ-012 | REQ-001..REQ-011 | disclosure |
| REQ-013 | — | cost bound, constrains REQ-010; async+timeout on disclosure-open |
| REQ-014 | REQ-004, REQ-006, REQ-009 | escaping, token scope |
| REQ-015 | REQ-003 | typed row |
| REQ-016 | all | supersession, docs |
| REQ-017 | REQ-004, REQ-005, REQ-010 | real-route smoke |
| REQ-018 | — | out of scope |
| REQ-019 | REQ-004 | run dashboard `tab`/`file` query params |

## Acceptance Criteria Summary

| REQ | Description | Priority | Complexity | AC Count |
| --- | --- | --- | --- | --- |
| REQ-001 | Task/bead title as primary label | Must | Low | 3 |
| REQ-002 | Workflow name and status secondary | Must | Low | 2 |
| REQ-003 | One shared title derivation | Must | Low | 3 |
| REQ-004 | Link to run details | Must | Medium | 4 |
| REQ-005 | Conversation link never dead-ends | Should | Medium | 3 |
| REQ-006 | PR link | Must | Low | 4 |
| REQ-007 | Jobsite rows: title and link | Should | Low | 2 |
| REQ-008 | Branch and base | Must | Low | 3 |
| REQ-009 | Worktree path and state | Must | Medium | 3 |
| REQ-010 | TRD and PRD/TRD documents | Must | High | 5 |
| REQ-011 | Missing data shown with reason | Must | Medium | 3 |
| REQ-012 | Compact row, disclosure | Should | Medium | 3 |
| REQ-013 | Bounded cost: refresh path and disclosure-open | Must | High | 5 |
| REQ-014 | Link and display safety | Must | Medium | 3 |
| REQ-015 | Typed read model | Must | Medium | 3 |
| REQ-016 | Supersede, tests, docs | Must | Medium | 3 |
| REQ-017 | Real-route smoke | Must | Medium | 2 |
| REQ-018 | No actions/filters/write paths | Won't | Low | 2 |
| REQ-019 | Run dashboard accepts `tab` and `file` query params | Must | Medium | 3 |

## Open Questions

1. **[NEEDS CLARIFICATION: primary link target.]** This PRD links the title to the
   operator run dashboard (`/dashboard/runs?run_id=`), which is the "run details" surface
   and resolves any run, at the cost of leaving the workspace (full page load). The
   alternative — keeping the operator in the workspace on the thread pane — shows the
   conversation, not run details, and is subject to REQ-005. Default taken: run
   dashboard for the title, conversation as a secondary link.
2. **[NEEDS CLARIFICATION: planning-run document source.]** The primary TRD source is the
   task's `trd_path`. For a `prd` run with none, no projected field names the document, and
   REQ-010/REQ-013 fix *how* it may be found (branch diff, disclosure-open only, async with
   timeout, cached). The TRD must still decide between that and (b) a projected
   `planning.*` field, as `PlanContext` captures `planning.prd_path`/`planning.trd_path`
   for the `plan` workflow (not among the bundled templates), and must confirm the bead's
   `agent_context.trd_path` actually reaches the task projection.
3. **[NEEDS CLARIFICATION: ad-hoc runs.]** A run with no task has no bead title. Default
   taken: fall back to the run id (REQ-003 AC-003-2). The operator may prefer
   "ad-hoc run: <first line of prompt>"; `RunDTO.task_label` already uses "ad-hoc run".

## Adversarial Review (self-critique)

1. **This reverses an explicit "Won't".** True; REQ-015 of the earlier PRD excluded detail
   links to keep the sidebar glance-only. The evidence for reversing it is the observed
   panel: eleven indistinguishable rows. The disclosure (REQ-012) keeps the glance density
   of the collapsed row, which is the earlier PRD's intent.
2. **The nav could become a second run dashboard.** Mitigated by REQ-018 (no actions,
   filters, tabs) and by linking *out* to the existing dashboard for everything beyond
   provenance.
3. **Per-row `git`/FS work could make every refresh slow.** The reason REQ-013 exists;
   document discovery is the only part that needs it and is pushed to disclosure-open.
4. **Worktree paths are local and can vanish.** REQ-009/REQ-011 show state and refuse to
   present a removed path as live, and refuse to hyperlink it.
5. **Title divergence between panel and thread list.** REQ-003 forces one function.
6. **Dead conversation links for old runs** are a defect in the *existing* thread pane
   (Overview's resolved cap), surfaced rather than caused by this feature; REQ-005 fixes it
   for any row the panel offers.

## Suggested Next Step

`/ensemble-create-trd docs/PRD/PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md`

## Changelog

### 2026-11-04 — v1.0.0 (create-prd draft)

- Initial draft from the operator's request in the 2026-11-04 session. Supersedes only
  the "no run-detail links" boundary of PRD-2026-7735ac9c (REQ-015 / AC-015-1); that
  document and its TRD are intentionally not edited.

### 2026-11-06 — note added (no requirement change)

- Forward-pointing note under the title recording that run-c5530c375ee791d5dd62d0817eb65f12
  delivered this PRD as `FOREMAN_SOURCE_PRD_PATH` for an unrelated task subject (agent `ask`
  bridge to Telegram/Slack). Requirements, ACs and scores are unchanged.
