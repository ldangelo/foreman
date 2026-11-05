---
Document ID: TRD-2026-f7a50d75
Label: trd-workspace-nav-run-provenance-links
PRD: PRD-2026-f7a50d75 (docs/PRD/PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md)
Version: 1.1.0
Status: Draft
Date: 2026-11-04
Design Readiness Score: 4.3 (PASS, self-scored)
kind: trd
ensemble_implement_trd_beads:
  branch_name: feature/trd-2026-f7a50d75-workspace-nav-run-provenance-links
  use_proposed: true
  stacked_prs: false
---

# TRD: Workspace nav — workflow and jobsite rows that identify the work and link to its run

> Source PRD: `docs/PRD/PRD-2026-f7a50d75-workspace-nav-run-provenance-links.md`
> (label `prd-workspace-nav-run-provenance-links`, Draft, 19 requirements; no readiness
> score in its frontmatter, so it was not gate-checked — proceeding with that noted).
>
> Mode: interactive invocation without `--foreman`, but no human choice was needed:
> Options A and B below each violate a PRD requirement, so **Option C** is selected and
> the choice is logged here. No `FOREMAN_*` variables were set. The PRD was named by the
> operator's conversation, not chosen by recency or glob.
>
> Supersession: this TRD supersedes the "no run-detail links" inspection in task TRD-006
> of `TRD-2026-7735ac9c` (PRD REQ-016). `TRD-2026-7735ac9c` is not edited.

## Summary

Make each **Workflows** row (and, where data exists, each **Jobsite** row) identify its
work by the task's title and link to its run, PR, branch, worktree, and TRD/PRD documents,
without making the nav a second run dashboard.

Five shippable PRs, ordered so the operator's actual ask lands first:

1. **Titled, linked rows from one typed read model** — task title, workflow/status/age,
   link to run details, PR link, branch/base, worktree path and state, the task's TRD
   path; bulk reads only (PRD REQ-001–004, 006–009, 011–015).
2. **Conversation links that cannot dead-end** — `Overview.card/2`, a fallback in the
   workspace's thread selection, and the "Conversation" link in rows (REQ-005).
3. **Run dashboard deep links + per-file diff** — `/dashboard/runs` accepts `tab` and
   `file` and renders the file's diff (REQ-019).
4. **Lazy PRD/TRD documents** — on disclosure-open only, off the LiveView process, async
   + timeout, cached per run, linking into PR 3's view (REQ-010, REQ-013).
5. **Final docs pass, supersession audit, real-route smoke** (REQ-016, REQ-017, REQ-018).

No new command, event, aggregate, projection field, config key, env var, CLI verb, MCP tool
or HTTP route. The only new externally visible identifiers are the `tab` and `file` query
parameters of the existing `/dashboard/runs` route (PR 3), the `list_runs/1` `detail`
option (internal facade API), and the internal LiveView event `nav_run_toggle`.

## Findings that change the PRD's picture (verified in source 2026-11-04)

| # | Finding | Evidence | Effect |
| --- | --- | --- | --- |
| F1 | `ChangeEvidence.preview/2` has **no caller**. The Changes tab prints `status path` as plain `<li>` text. | only the definition (`operator_dashboard.ex:445`); `render_changes/1` (`operator_run_dashboard_live.ex:363-372`) | REQ-019 is not "wire a param to an existing view": the per-file view must be **built** (TRD-012–014). PRD REQ-019 text corrected. |
| F2 | The binding cap on thread resolution is `Overview`'s `resolved_limit` (default 20); a second, rarer bound is the 500-thread classification window (`Threads.max_limit/0`). | `overview.ex:49,217`, `:242`; `threads.ex:14` | A thread URL for an old run cannot resolve through `find_card/2`. Fix is a single-thread card build, not a bigger limit (TRD-009/010). |
| F3 | `Threads.by_run_ids/1` and `Threads.get/1` each `build_all` over **every** run/task/jobsite/worktree. | `threads.ex:54-89,93-` | Not used on the refresh path. Titles come from one `list_tasks/0` plus the shared `Thread.title/2`. |
| F4 | The bead's `agent_context.trd_path` reaches the task projection, but only for `implement-trd` / `implement-trd-beads`; for every other workflow the watcher passes `nil`. | `beads_watcher.ex:1274-1290,933-935`; `task_created.ex:27`; `projection_store.ex:2847` | `trd_path` is the primary TRD source for implement-TRD runs; `prd` runs always need branch-diff discovery. |
| F5 | Worktree **state** is projected: `WorktreeCreated` → `status: "created"`, `WorktreeCleaned` → `"cleaned"`. Orphans live in a separate map (`worktree_create_orphans`) that `worktrees_for_run/1` does not read. | `projection_store.ex:3479-3559` | "removed" needs no filesystem check. The nav models only `created`/`cleaned`; orphans are out of scope. |
| F6 | Bulk PR read exists: `ProjectionStore.pr_states_for_project/1` → `%{run_id => pr_state_view}`. | `projection_store.ex:914` | PR link and state for 100 rows in one call. |
| F7 | Jobsite projections carry `branch`, `worktree_path`, `bead_id`; the owning task is found by `task.external_id == bead_id` (as `Thread.from_jobsite/3` does). No cleaned/kept state exists. | `projection_store.ex:3972-4005`, `threads.ex:112-143` | Jobsite rows show title, branch and worktree path as text and **no state claim**. |
| F8 | `OperatorRunDashboardLive` already has the bounded-evidence idiom (`Task.async` + `Task.yield`, 3 000 ms, `{:error, :evidence_timeout}`), private to the module. | `operator_run_dashboard_live.ex:286-303` | Promote it into the `OperatorDashboard` facade so both LiveViews use one implementation (§5.7). |
| F9 | **The nav's existing run read is not cheap.** `list_runs/1` → `run_dto/2` calls `ProjectionStore.phases_for_run/1` for every run (a GenServer call that scans all phases, `projection_store.ex:1998-2005`) and `ProjectionStore.run_repositories/1` for every *completed* run (`operator_dashboard.ex:315-317`). That is up to ~200 calls per refresh at ~4 refreshes/second during an active run (`workspace/refresh.ex:32,75`). The nav row shows no phase information. | `operator_dashboard.ex:265-267,294,336-339` | A `detail: :summary` option on `list_runs/1` (default `:full`, so the operator dashboard is unchanged) skips both reads (TRD-004). The "O(1) bulk reads" claim is only true with it. |
| F10 | `ChangeEvidence.preview/2` returns a **git diff patch** (`git diff base..HEAD -- path`), not the file, and `String.slice(text, 0, 24_000)` cuts it silently — by characters, not bytes, with no truncation flag. | `operator_dashboard.ex:450-451`, `@max_bytes 24_000` | The view is a diff and says so. `preview/2`'s return carries `truncated?` and the byte count, and the UI states truncation (TRD-012/014). It has no caller, so the contract change breaks nothing. |
| F11 | The workspace nav already receives `token` and `project_id` (`components.ex:185`, `project_workspace_live.ex:904-905`). | — | No attr plumbing for the link builders; only the row data is new. |
| F12 | Existing panel tests pin the **old** row label: the `strong` of a Workflows row is the workflow name (`project_workspace_live_test.exs` ~1447–1463 incl. the unnamed `"workflow"` fallback, ~1491–1500 frozen-snapshot name, ~1541–1542 project-scoping by workflow name). Jobsite assertions (`strong` = `bead-new`/`bead-mine`) survive because a task-less jobsite's title falls back to its `bead_id`. | `project_workspace_live_test.exs` | These Workflows assertions are rewritten, not extended (TRD-007-TEST, TRD-008). |
| F13 | **A timed-out `git` is orphaned, not killed.** `Task.shutdown(task, :brutal_kill)` kills the Elixir task, but the OS `git` child that `System.cmd` spawned keeps running: probed with a script that sleeps, the child was still alive after the kill (observed 2026-11-05). The pre-existing `load_changes_bounded/1` idiom had the same behaviour; this TRD reuses it (TRD-012) on disclosure-open, so a genuinely hung `git` leaks one OS process per timed-out open. The bound that protects the LiveView (the Erlang task is gone, asserted in TRD-012-TEST) holds; the OS-process leak is **not fixed here**. | `operator_dashboard.ex` `bounded/2` | Known limitation, out of this TRD's scope. A fix needs a spawned-port `os_pid` and an explicit kill on timeout inside `ChangeEvidence.git/2`; recommended as a follow-up in the PR body, not built. |

## Architecture Decision

### Alternatives considered

| | Option A — projection-only, link out | Option B — project documents as a new fact | **Option C — bulk reads + lazy on-demand discovery (chosen)** |
| --- | --- | --- | --- |
| Row identity | title + links | title + links | title + links |
| PRD/TRD for `prd` runs | none (violates REQ-010 fallback) | new event + projection field written at the phase boundary | branch-diff discovery on disclosure-open only |
| Per-file document view | none (violates REQ-019) | none | built into the run dashboard |
| New events / aggregates | none | yes — violates REQ-018 and the AGENTS.md "last resort" rule | none |
| Refresh cost | O(1) bulk reads | O(1) bulk reads | O(1) bulk reads; git only for one row, on demand |
| Risk | PRD not met | event schema, replay, back-fill of old runs | async plumbing in the workspace LiveView |
| Complexity | Low | High | Medium |

**Chosen: Option C.** It is the only option satisfying every PRD Must. Option B's
back-fill problem (every historical run lacks the new fact) alone rules it out for the
"deep history" rows this panel exists to serve.

### Component boundaries and data flow

```
 REFRESH PATH (every ≤250 ms coalesced; projection reads only — NO git, NO FS, NO per-run reads)
ProjectWorkspaceLive.load_state/1
   ├─ OperatorDashboard.list_runs(%{project_id: P, detail: :summary})   (NEW option)  1 call
   ├─ ProjectionStore.list_jobsites/0 (existing, filtered to P)                       1 call
   ├─ ProjectionStore.list_tasks/0 ──────────────► tasks by task_id / external_id     1 call
   ├─ ProjectionStore.worktrees_for_runs/1 (NEW) ─► %{run_id => [worktree]}           1 call
   ├─ ProjectionStore.pr_states_for_project/1 ───► %{run_id => pr_state_view}         1 call
   └─ NavRuns.build_runs/4 | build_jobsites/2 (pure) ─► [NavRuns.Run] | [NavRuns.Jobsite]
          │  title via Thread.title/2 (shared with Threads.Thread)
          ▼
   assign nav_runs, nav_jobsites, nav_now_ms
          ▼
   Components.workspace_nav/1 ─► nav_run_row/1, nav_jobsite_row/1
          │  href:  Components.run_detail_path/3  (plain <a>, cross live_session, token)
          │  patch: Components.thread_path/3      (conversation, PR 2)
          ▼
   <details> disclosure: branch, base, worktree path+state, PR, task trd_path  (all projected)

 DISCLOSURE-OPEN PATH (PR 4: one row, on demand, OFF the LiveView process)
phx-click "nav_run_toggle" ─► start_async({:nav_docs, id}, fn ->
      OperatorDashboard.planning_documents_bounded(id, trd_path) end)
        inside: Task.async + Task.yield(3_000) + Task.shutdown   (git diff --name-status)
   handle_async ─► nav_docs[id] = {:ok, docs} | {:unavailable, reason}   (cached; refresh never touches)

 RUN DASHBOARD (PR 3)
/dashboard/runs?run_id=R&tab=changes&file=P[&token=T]
   mount (connected only) applies tab/file BEFORE refresh() ─► change_evidence_bounded/1 in the same pass
   handle_params/3 (patch navigation; no-op when already applied)
   Changes tab: each file ─► <.link patch> (same route, file=…); <pre> of the diff patch (+ truncation notice)
```

### Interface contracts

| Producer | Function | Returns | Consumer |
| --- | --- | --- | --- |
| `Components` | `run_detail_path(run_id, token, opts)` — `opts`: `tab:` (`"summary"\|"logs"\|"changes"\|"actions"`), `file:` (string) | `String.t()` (relative URL; params in order `run_id, tab, file, token`, each `URI.encode_www_form`-encoded; `tab`/`file`/`token` omitted when nil) | nav rows, run dashboard Changes tab |
| `OperatorDashboard` | `list_runs(params)` — new key `detail: :full \| :summary` (default `:full`; any other value → `{:error, {:malformed_detail, v}}`) | `{:ok, [RunDTO.t()]}`. `:summary` makes **no** `phases_for_run/1` or `run_repositories/1` call; `current_phase_id/name/status` and `latest_stall` are `:absent` (run-level stall kept), `completed_with_errors` is `:absent` (typed `boolean() \| :absent`) | operator dashboard (`:full`), workspace nav (`:summary`) |
| `OperatorDashboard` | `change_evidence_bounded(run_id, timeout_ms \\ 3_000)` | `ChangeEvidence.for_run/1`'s result, or `{:error, :evidence_timeout}` | `OperatorRunDashboardLive`, `planning_documents_bounded/3` |
| `OperatorDashboard` | `preview_bounded(run_id, rel_path, timeout_ms \\ 3_000)` | `{:ok, %{diff: String.t(), truncated?: boolean(), bytes: non_neg_integer()}} \| {:error, :malformed_path \| :git_unavailable \| :unavailable \| :evidence_timeout}` | `OperatorRunDashboardLive` |
| `ChangeEvidence` | `preview(run_id, rel_path)` (existing; **contract changed**, no callers) | same map as above; `diff` cut on a UTF-8 **byte** boundary at `@max_bytes`, `bytes` = full patch size | facade |
| `ChangeEvidence` | `planning_documents(run_id, extra_path)` | `{:ok, [%{kind: :prd \| :trd, path: String.t()}]} \| {:unavailable, :worktree_missing \| :base_unavailable \| :git_unavailable \| :run_not_found}` | facade |
| `OperatorDashboard` | `planning_documents_bounded(run_id, extra_path, timeout_ms \\ 3_000)` | as above plus `{:unavailable, :evidence_timeout}` | `ProjectWorkspaceLive` |
| `ProjectionStore` | `worktrees_for_runs([run_id])` (NEW) | `%{run_id => [map()]}`, each list in `worktrees_for_run/1`'s order (`operation_id` ascending); `[]` for a run with none | `NavRuns` read |
| `Threads.Thread` | `title(task \| nil, fallback_id)` (was `defp`, now `def`) | `String.t()` | `Thread.from_run/6`, `from_jobsite/3`, `NavRuns` |
| `Overview` | `card(project_id, thread_id)` (NEW) | `{:ok, ThreadCard.t()} \| {:error, :thread_not_found}` | `ProjectWorkspaceLive.select_card/1` fallback |
| `Workspace.NavRuns` (NEW) | `read(project_id)` (one `list_tasks/0` shared by both builders); pure `build_runs/4`, `build_jobsites/2` | `%{runs: [NavRuns.Run.t()], jobsites: [NavRuns.Jobsite.t()]}`, `[NavRuns.Run.t()]`, `[NavRuns.Jobsite.t()]` | `load_state/1` |

**`NavRuns.Run`** (`@enforce_keys [:run_id, :status]`, `@type t`): `run_id`, `status`,
`workflow` (`String.t() \| :absent`), `title` (`String.t()`, never nil — falls back to the
run id), `started_at_ms` (`integer \| :absent`), `branch` (`%{name, base} \| :none`),
`worktree` (`%{path, state :: :kept \| :active \| :removed, cleanup} \| :none`),
`pr` (`%{url, state} \| :none`; `url` already through `Components.safe_url/1`),
`trd_path` (`String.t() \| :none`), `thread_id` (`"run:" <> run_id`).
**`NavRuns.Jobsite`**: `jobsite_id`, `status`, `bead_id \| :none`, `title` (task title →
`bead_id` → `jobsite_id`, so a task-less jobsite reads exactly as today), `branch`
(`String.t() \| :none`), `worktree_path` (`String.t() \| :none`), `thread_id`.
One key convention: projections are atom-keyed; `RunDTO` and `NavRuns.*` are structs; no
`Map.get(m,:k) || Map.get(m,"k")`. A missing `run_id`/`status` raises.

### Key decisions

1. **One title function.** `Thread.title/2` becomes public and is the only derivation (REQ-003).
2. **No filesystem, git or per-run read on the refresh path.** Worktree state comes from the
   projection (F5); runs come from `list_runs(detail: :summary)` (F9). The PRD's on-demand
   "worktree directory exists" check folds into disclosure-open discovery: if the directory
   is gone, `for_run/1` already answers `:worktree_missing`. A directory deleted by hand
   while the projection says `created` therefore reads "kept" until the disclosure is opened
   — accepted, and the UI labels the state as the projection's claim.
3. **Separate narrow bulk reads, not `ProjectionStore.thread_inputs/0`.** `thread_inputs`
   returns every run, task, jobsite, worktree, PR association and review of *every project*
   in one message — one copy of the whole store per refresh. The nav needs the tasks, the
   worktrees of ≤100 runs and one project's PR states; three narrow calls copy strictly less
   (and `Overview.build/2` already pays for `thread_inputs` once per refresh).
4. **`<details>` is server-controlled, per row.** `open={MapSet.member?(@nav_open, run_id)}`;
   `<summary phx-click="nav_run_toggle" phx-value-run-id>` carries the event. Because `open`
   is derived from `nav_open` on every render, a 250 ms refresh or an async document result
   for one row can neither collapse nor open any other row: results touch only
   `nav_docs[run_id]`. All projected fields sit *inside* the `<details>` and render
   server-side regardless of JS; only the lazily discovered Documents section needs the socket.
5. **Async with the dashboard's own shape.** `start_async/3` runs the read off the LiveView
   process; inside it `Task.async` + `Task.yield(timeout)` + `Task.shutdown(:brutal_kill)`
   (the `load_changes_bounded/1` idiom, now one facade function) turns a hung `git` into
   `{:unavailable, :evidence_timeout}` for that row only.
6. **Cache = socket assign, cleared on close.** `nav_docs :: %{run_id => result}`. Refresh
   never reads or writes it beyond pruning to the ids still listed, so there is no per-refresh
   git. A still-running run's documents can be stale while its disclosure stays open;
   closing and reopening refetches.
7. **Document links only for changed files.** `planning_documents/2` derives every `path`
   from the run's changed-file list, so each emitted link is one the run dashboard will
   serve. A task `trd_path` not among the changed files (the TRD pre-existed the run) is
   shown as text, not a link.
8. **Conversation fix is a single-thread card build,** not a larger `resolved_limit` (F2).
   While the operator views a thread outside the Overview window each refresh runs
   `Threads.get/1` once more — at most ~2× the work `Overview.build/2` already does, only
   while such a thread is open. No cache: a cached card goes stale on reopen or re-state.
9. **Branch/worktree rule = `Thread.from_run/6`'s**, so the nav and the thread sidebar cannot
   disagree: the **last** worktree record in `operation_id` order **that has a branch**
   (`Enum.reverse |> Enum.find`). This differs from `ChangeEvidence.evidence_source/2`, which
   prefers the `primary?` record; for a multi-repo run the nav's branch/path may name a
   non-primary repository while the Documents area (PR 4) reads the primary. Recorded as a
   known divergence, not unified here.
10. **Dashboard `tab`/`file` are applied in `mount/3` (connected only) *and* in
    `handle_params/3`.** The nav link is a full page load, and `mount` assigns `active_tab`
    before `refresh/2`, so applying the tab there loads the Changes evidence in that same pass
    instead of a second read after a click. `handle_params/3` serves `patch` navigation (file
    links) and is an idempotent no-op when `tab`/`file` already match the assigns (it also runs
    after the initial mount). The **dead render skips the git read** (changes stay `:absent`,
    which `render_changes/1` already renders) so first paint is never stalled up to 3 s; the
    connected mount does the read.
11. **Row layout.** Collapsed: `<strong>` title link (`ws-ellipsis`, full title in `title=`),
    then muted `<span class="ws-nav-workflow">` workflow · status · age (`age` from `nav_now_ms`,
    captured once per refresh so the template is pure). Summary text: "Details".

### Failure modes

| Situation | Behaviour |
| --- | --- |
| `list_runs/1` returns `{:error, _}` | unchanged: `nav_workflow_runs/1` keeps its documented total match (an error is a defect in a self-built filter) |
| Run with no worktree record | `branch: :none`, `worktree: :none` → "no worktree recorded for this run" |
| Task absent for a run | title = run id (`Thread.title(nil, run_id)`); run still linkable |
| Task has `trd_path`, no worktree | text only; discovery on open → "unavailable: worktree directory missing" |
| `git` missing / hangs / base unresolvable | Documents area: "unavailable: git" / "timed out" / "base ref unavailable"; branch, worktree, PR rows unaffected |
| Diff larger than `@max_bytes` | preview shows the cut diff plus "Diff truncated: showing N of M bytes" |
| `file=` unsafe or not a changed file | preview's refusal state; the path is never read |
| Unknown `tab=` | summary tab |
| Unknown `run_id=` | the dashboard's existing `{run_id, :run_not_found}` state |
| `pr_url` not http(s) | no PR link (existing `safe_url/1`) |
| Unknown worktree `status` string | raises (§5.2/§5.3): a new status must be a visible defect |

## Reused Capabilities

| Capability | Provided by (existing) |
| --- | --- |
| Run rows (typed, bounded) | `OperatorDashboard.list_runs/1`, `RunDTO` (+ the `detail` option) |
| Task, worktree, PR bulk reads | `ProjectionStore.list_tasks/0`, `pr_states_for_project/1` (+ the one new `worktrees_for_runs/1`) |
| Title derivation | `Threads.Thread.title/2` |
| Safe external URL | `Components.safe_url/1` |
| Token-carrying links | `project_path/2` / `thread_path/3` convention (`?token=`, `URI.encode_www_form`) |
| Bounded git evidence + path safety | `ChangeEvidence.for_run/1`, `preview/2` (`safe_relative?`, changed-files membership), the `load_changes_bounded/1` idiom |
| Card construction | `ThreadCard.build/4`, `Overview` classification helpers |
| Panel CSS | `ws-panel*`, `ws-muted`, `ws-ellipsis` in `workspace/layouts.ex` |

(Capability Reuse Check: `trd-graph-cli capabilities docs/TRD --json` → `[]`; `overlap` →
"No overlapping target files across TRDs." No foundational TRD exists to reference.)

**Observed, out of scope:** `ForemanServer.Jobsite.Git.changed_files/3` and `diff/3`
(`jobsite/git.ex:356-365`) implement the same two git calls as `ChangeEvidence` with a
different error shape (`{:error, %Error{}}`). Adopting them would change `ChangeEvidence`'s
error contract; the duplication is recorded, not resolved, here.

## Master Task List

### PR 1: Titled, linked rows from one typed read model

**Shippable State:** In the project workspace, each Workflows row shows its task's title (the bead title) with the workflow, status and age, and links to that run's details page; a per-row "Details" section shows the branch and base, worktree path and state, PR link and the task's TRD path; Jobsite rows show the bead's title with its branch and worktree path. The nav refresh now makes a fixed handful of bulk reads. Conversation links and discovered documents are not yet shown.

- [x] **TRD-001** Add `Components.run_detail_path(run_id, token, opts \\ [])` beside `project_path/2`/`thread_path/3` in `workspace/components.ex`: builds `/dashboard/runs?run_id=…`, then `tab=…` and `file=…` when given, then `token=…` when non-nil, each value `URI.encode_www_form`-encoded; raises `ArgumentError` on a non-binary or empty `run_id` and on a `tab` outside `summary|logs|changes|actions`. Document it in the link-builder moduledoc. (2h) [satisfies REQ-004] [satisfies REQ-014] [satisfies REQ-019]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-4, AC-019-1
  - Implementation AC:
    - Given `run_detail_path("R", "T", tab: "changes", file: "docs/TRD/a b.md")`, when called, then it returns `/dashboard/runs?run_id=R&tab=changes&file=docs%2FTRD%2Fa+b.md&token=T`.
    - Given a nil token and no opts, when called, then the result is `/dashboard/runs?run_id=R` with no `token` text.
    - Given `run_id` nil or `""`, or `tab: "bogus"`, when called, then it raises (no empty `href`).

- [x] **TRD-001-TEST** Unit tests for `run_detail_path/3` in `test/foreman_server_web/workspace/components_test.exs` (create the file): encoding of `&`, `=`, space, `/`, unicode in `run_id`/`file`/`token`; parameter order; omission rules; the three raise cases. (1h) [verifies TRD-001] [satisfies REQ-004] [satisfies REQ-014] [satisfies REQ-019] [depends: TRD-001]
  - Target Files: `packages/foreman_server/test/foreman_server_web/workspace/components_test.exs`
  - Validates PRD ACs: AC-004-1, AC-004-2, AC-004-4
  - Implementation AC:
    - Given a `file` containing `&token=evil`, when built, then the text is percent-encoded inside `file` and exactly one real `token` parameter exists.
    - Given the narrowest file, when run with `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors test/foreman_server_web/workspace/components_test.exs'`, then it passes with zero warnings.

- [x] **TRD-002** Make `Threads.Thread.title/2` public (`def title(task, fallback_id)` with `@doc` and `@spec`), keep its fallback order (task `title` → first non-blank line of `prompt` → of `description` → `task_id` → `fallback_id`), and leave `from_run/6` and `from_jobsite/3` calling it. (1h) [satisfies REQ-003] [satisfies REQ-001]
  - Target Files: `packages/foreman_server/lib/foreman_server/threads/thread.ex`
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-001-1
  - Implementation AC:
    - Given the module, when compiled, then `Thread.title/2` is public with a spec and no second title-deriving function exists in `lib/`.

- [x] **TRD-002-TEST** Create `test/foreman_server/threads/thread_title_test.exs` with `Thread.title/2` cases: title wins; blank title falls to prompt first line; prompt blank falls to description; none → `task_id`; nil task → fallback id; plus a test that `Thread.from_run/6` and `Thread.from_jobsite/3` produce the same title as `Thread.title/2` for the same task (they cannot diverge). (1h) [verifies TRD-002] [satisfies REQ-003] [depends: TRD-002]
  - Target Files: `packages/foreman_server/test/foreman_server/threads/thread_title_test.exs`
  - Validates PRD ACs: AC-003-1, AC-003-2, AC-003-3
  - Implementation AC:
    - Given each of the five task shapes, when `title/2` is called, then it returns the documented value.

- [x] **TRD-003** Add `ProjectionStore.worktrees_for_runs(run_ids)` (public function + one `handle_call`): a single pass over `state.worktrees`, grouped by `run_id`, each group sorted by `operation_id` — the same order as `worktrees_for_run/1` — every requested id present (`[]` when none). Share the sort with `worktrees_for_run/1` through one private helper so the two cannot disagree. `@spec`, `@doc`. Reads `state.worktrees` only (orphans are a separate map and out of scope, F5). (2h) [satisfies REQ-009] [satisfies REQ-013]
  - Target Files: `packages/foreman_server/lib/foreman_server/projection_store.ex`
  - Validates PRD ACs: AC-009-1, AC-013-5
  - Implementation AC:
    - Given runs A (two worktrees) and B (none), when `worktrees_for_runs(["A","B"])` is called, then A's list equals `worktrees_for_run("A")` and B maps to `[]`.
    - Given `[]`, when called, then it returns `%{}` without a store scan.

- [x] **TRD-003-TEST** Create `test/foreman_server/projection_store_worktrees_for_runs_test.exs` (seed through `ProjectionStore.apply_events/1` with `WorktreeCreated`/`WorktreeCleaned` events, resetting with `ProjectionStoreReset`): order parity with `worktrees_for_run/1`, empty-list handling, missing-run `[]`. (1h) [verifies TRD-003] [satisfies REQ-009] [satisfies REQ-013] [depends: TRD-003]
  - Target Files: `packages/foreman_server/test/foreman_server/projection_store_worktrees_for_runs_test.exs`
  - Validates PRD ACs: AC-009-1, AC-013-5
  - Implementation AC:
    - Given 3 worktrees across 2 runs, when compared, then bulk and per-run reads are equal for every run.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-004** `OperatorDashboard.list_runs/1`: accept `detail: :full | :summary` (default `:full`) through `normalize_params`/`query_opts` (any other value → `{:error, {:malformed_detail, value}}`, like `:malformed_limit`). `:summary` calls `run_dto(run, :summary)`: **no** `phases_for_run/1` and **no** `run_repositories/1`; `current_phase_id/name/status` → `:absent`, `latest_stall` → the run-level value only, `completed_with_errors` → `:absent` (update `RunDTO`'s type to `boolean() | :absent`; the operator dashboard uses `:full` and is unchanged). One flag, one DTO — no second row builder (§5.7). Update the `list_runs/1` `@doc`. (3h) [satisfies REQ-013] [satisfies REQ-015]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/operator_dashboard.ex`
  - Validates PRD ACs: AC-013-1, AC-013-5, AC-015-2
  - Implementation AC:
    - Given `list_runs(%{project_id: P, detail: :summary})` over 100 runs, when instrumented, then `ProjectionStore.phases_for_run/1` and `run_repositories/1` are called zero times.
    - Given `list_runs(%{})` and `list_runs(%{detail: :full})`, when compared with the pre-change behaviour, then rows are identical (the operator dashboard is unchanged).
    - Given `detail: "bogus"`, when called, then `{:error, {:malformed_detail, "bogus"}}`.

- [x] **TRD-004-TEST** In `test/foreman_server_web/operator_dashboard_test.exs`: `:full` rows equal the existing expectations (current-phase fields populated for a multi-phase run, `completed_with_errors` boolean); `:summary` rows carry `:absent` in the five derived fields and equal `:full` rows in `run_id`, `status`, `workflow`, `task_id`, `pr_url`; the call counters above; the malformed value. (2h) [verifies TRD-004] [satisfies REQ-013] [satisfies REQ-015] [depends: TRD-004]
  - Target Files: `packages/foreman_server/test/foreman_server_web/operator_dashboard_test.exs`
  - Validates PRD ACs: AC-013-5, AC-015-2
  - Implementation AC:
    - Given a mutation that makes `:summary` call `phases_for_run/1`, when the file runs, then a test fails.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-005** Create `lib/foreman_server_web/workspace/nav_runs.ex` (`ForemanServerWeb.Workspace.NavRuns`) with `Run` and `Jobsite` structs (fields, types and sentinels exactly as in "Interface contracts"), pure `build_runs(run_dtos, tasks_by_id, worktrees_by_run, pr_states)` and `build_jobsites(jobsites, tasks_by_external_id)`, and `read/1` (replacing the planned `read_runs/1` / `read_jobsites/1`, so `list_tasks/0` is read once) that performs the bulk reads (`list_runs(%{project_id:, detail: :summary})`, `list_tasks/0` filtered with `is_map_key(&1, :task_id)`, `worktrees_for_runs/1`, `pr_states_for_project/1`) and delegate. Rules: title via `Thread.title/2` (jobsite: task title → `bead_id` → `jobsite_id`); branch = the **last** worktree record in `operation_id` order that has a branch (`Enum.reverse |> Enum.find`, key decision 9); worktree state: `"cleaned"` → `:removed`, `"created"` with `cleanup == "never"` → `:kept`, `"created"` otherwise → `:active`, any other status raises `ArgumentError`; `pr.url` through `Components.safe_url/1` (nil when unsafe → `:none`); `trd_path` from the task (`:none` when nil/blank); missing `run_id`/`status` raises. Jobsite task lookup by `external_id == bead_id`. (6h) [satisfies REQ-001] [satisfies REQ-003] [satisfies REQ-006] [satisfies REQ-007] [satisfies REQ-008] [satisfies REQ-009] [satisfies REQ-010] [satisfies REQ-011] [satisfies REQ-015] [depends: TRD-002, TRD-003, TRD-004]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/workspace/nav_runs.ex`
  - Validates PRD ACs: AC-001-1, AC-001-2, AC-003-2, AC-006-1, AC-006-2, AC-006-3, AC-007-1, AC-007-2, AC-008-1, AC-008-2, AC-008-3, AC-009-1, AC-009-2, AC-010-2, AC-011-3, AC-015-1, AC-015-2, AC-015-3
  - Implementation AC:
    - Given a `RunDTO` with `task_id` whose task has `title`, when built, then `title` equals it; with no task, then `title == run_id`.
    - Given worktree records `cleanup: "never"`/status `"created"`, `"cleaned"`, and none, when built, then `worktree.state` is `:kept`, `:removed`, and `worktree == :none`.
    - Given a record with an unknown status string, when built, then it raises naming the status.
    - Given `pr_url: "javascript:alert(1)"`, when built, then `pr == :none`.
    - Given a `RunDTO` with `run_id` `nil`, when built, then it raises.
    - Given a task-less jobsite with a `bead_id`, when built, then `title == bead_id`.
    - Given `grep -n 'Map.get(.*||' lib/foreman_server_web/workspace/nav_runs.ex`, when run, then there are zero dual-key fallbacks.

- [x] **TRD-005-TEST** `test/foreman_server_web/workspace/nav_runs_test.exs`: pure-function tests of `build_runs/4` and `build_jobsites/2` over hand-built maps — every sentinel (`:none`, `:absent`), worktree-state mapping, branch selection with several records (last with a branch wins; a later record without a branch is skipped), PR safety, jobsite bead→task title, task-less run/jobsite fallbacks, and both raise cases. (4h) [verifies TRD-005] [satisfies REQ-001] [satisfies REQ-003] [satisfies REQ-006] [satisfies REQ-007] [satisfies REQ-008] [satisfies REQ-009] [satisfies REQ-011] [satisfies REQ-015] [depends: TRD-005]
  - Target Files: `packages/foreman_server/test/foreman_server_web/workspace/nav_runs_test.exs`
  - Validates PRD ACs: AC-001-1, AC-003-2, AC-006-2, AC-007-2, AC-008-2, AC-008-3, AC-009-2, AC-011-3, AC-015-1, AC-015-2
  - Implementation AC:
    - Given every sentinel case, when built, then no field is `nil`.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-006** `ProjectWorkspaceLive.load_state/1`: replace the raw `nav_jobsites`/`nav_workflow_runs` payloads with `NavRuns.read/1` (keeping the 100-row cap, `nav_count/2` badges, ordering and the total `{:ok, rows}` match), and assign `nav_now_ms` once per refresh (`System.os_time(:millisecond)`). Initialise `nav_open: MapSet.new()` and `nav_docs: %{}` in `mount/3`; on every refresh prune both to the run ids still listed. (3h) [satisfies REQ-012] [satisfies REQ-013] [satisfies REQ-015] [depends: TRD-004, TRD-005]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex`
  - Validates PRD ACs: AC-012-3, AC-013-1, AC-013-5
  - Implementation AC:
    - Given a refresh with 100 listed runs, when `ProjectionStore` calls are counted, then the nav path issues exactly five reads (`list_runs`, `list_jobsites`, `list_tasks`, `worktrees_for_runs`, `pr_states_for_project`) and zero `phases_for_run`, `run_repositories`, `worktrees_for_run`, `task_projection`.
    - Given a refresh, when `System.cmd`/`File` use is traced for the nav code path, then none occurs.

- [x] **TRD-006-TEST** In `project_workspace_live_test.exs`: seed 100 runs for one project and assert (a) the five-read count above by tracing messages sent to the `ProjectionStore` process (`:erlang.trace(pid, true, [:receive])`, tallying the `GenServer` call tags), (b) a counting fake `git` on `PATH` (shell script appending its args to a log file; `PATH` restored in `on_exit`) shows an empty log across a refresh triggered by a new event, (c) `nav_open`/`nav_docs` are pruned when a run leaves the list. There is no injectable command runner — `ChangeEvidence.git/2` calls `System.cmd("git", …)` directly — so the `PATH` shim is the spy. (3h) [verifies TRD-006] [satisfies REQ-012] [satisfies REQ-013] [depends: TRD-006, TRD-007]
  - Target Files: `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs`
  - Validates PRD ACs: AC-013-1, AC-013-5, AC-012-3
  - Implementation AC:
    - Given 100 runs and a refresh, when the shim log is read, then it is empty.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-007** `Components`: declare `attr(:workflow_runs, :list)` / `attr(:jobsites, :list)` as `NavRuns.Run` / `NavRuns.Jobsite` lists and `attr(:now_ms, :integer, required: true)` (`token`/`project_id` already exist, F11); replace the two `<li>` bodies with private function components `nav_run_row/1` and `nav_jobsite_row/1`. Run row: `<.link href={run_detail_path(r.run_id, @token)}>` around `<strong class="ws-ellipsis" title={r.title}>{r.title}</strong>`; muted `<span class="ws-nav-workflow">` with `{nav_workflow_label(r.workflow)} · {r.status} · {age}`; `<details open={...}>` whose `<summary phx-click="nav_run_toggle" phx-value-run-id={r.run_id}>Details</summary>` contains, in order: Branch (`name` and `base`, or "no branch recorded"); Worktree (absolute path as `<code>` text with state label "kept"/"active"/"removed" — labelled as the projection's claim — or "no worktree recorded for this run"; **never inside an `<a>`**); PR (`target="_blank" rel="noopener noreferrer"` link plus `pr.state`, or nothing); TRD (`trd_path` text, "from the task", no link yet). Jobsite row: `<strong>` title, muted `{bead_id|jobsite_id} · {status}`, details with branch and worktree path text (no state, F7). No conversation link in this PR. `age` helper: `"<1m"`, `"Nm"`, `"Nh"`, `"Nd"` from `@now_ms - started_at_ms`, `"—"` for `:absent`. Update the `workspace_nav/1` `@doc` (it says rows show only the workflow name and status) and the call site (`project_workspace_live.ex:~904`). **Documentation gate for this PR:** edit the `CLAUDE.md` "Workspace nav" paragraph (`~608-620`) and the `docs/user-guide.md` "Workspace nav" paragraph (`~2559`) to describe titled rows, the run-details link and the Details content. (5h) [satisfies REQ-001] [satisfies REQ-002] [satisfies REQ-004] [satisfies REQ-006] [satisfies REQ-007] [satisfies REQ-008] [satisfies REQ-009] [satisfies REQ-011] [satisfies REQ-012] [satisfies REQ-014] [depends: TRD-001, TRD-005, TRD-006]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`, `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex`, `CLAUDE.md`, `docs/user-guide.md`
  - Validates PRD ACs: AC-001-1, AC-001-3, AC-002-1, AC-002-2, AC-004-1, AC-004-2, AC-006-1, AC-006-3, AC-006-4, AC-007-1, AC-008-1, AC-009-1, AC-009-2, AC-009-3, AC-011-1, AC-011-3, AC-012-1, AC-012-2, AC-014-1, AC-014-2
  - Implementation AC:
    - Given a run titled `T` of workflow `fix` with status `failed`, when rendered, then the row contains `T` as the primary link, the text `fix` and `failed`, and `href` `/dashboard/runs?run_id=…&token=…`.
    - Given a title containing `<script>`, when rendered, then it is escaped.
    - Given the rendered nav, when searched, then no worktree path is inside an `<a>`, the token appears only in same-origin `href`s (never in the PR link), and no element carries a merge/approve control.
    - Given 100 runs, when the page loads, then every `<details>` is closed (no `open` attribute).
    - Given `grep -n "glance\|workflow name and status" CLAUDE.md docs/user-guide.md` over the nav passages, when run, then none still claims rows are name-and-status only.

- [x] **TRD-007-TEST** Rewrite the Workflows/Jobsite panel tests in `project_workspace_live_test.exs`: two runs of one workflow for different tasks render different primary labels; title link `href` and token handling (with and without `?token=`); workflow/status/age text in `.ws-nav-workflow`; branch/base/worktree/PR/`trd_path` inside the details; removed vs kept vs no-worktree wording; XSS title; PR `javascript:` URL emits no link; no `<a>` around the path; all details closed; jobsite title/bead/branch rendering (task-less jobsite still shows its `bead_id`). Keep the existing order, count, `100+` badge and empty-state assertions unchanged. (4h) [verifies TRD-007] [satisfies REQ-001] [satisfies REQ-002] [satisfies REQ-004] [satisfies REQ-006] [satisfies REQ-007] [satisfies REQ-008] [satisfies REQ-009] [satisfies REQ-011] [satisfies REQ-012] [satisfies REQ-014] [depends: TRD-007]
  - Target Files: `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs`
  - Validates PRD ACs: AC-001-2, AC-002-1, AC-002-2, AC-004-1, AC-004-2, AC-006-2, AC-007-1, AC-008-3, AC-009-3, AC-011-3, AC-012-1, AC-014-1, AC-014-2
  - Implementation AC:
    - Given the seeded runs, when the nav renders, then every PRD AC above is asserted at least once by a distinct assertion.
    - Given a mutation that renders `r.workflow` instead of `r.title` as the primary label, when the file runs, then at least one test fails.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-008** Rewrite the existing Workflows-panel assertions that pin the old row label (F12) in `project_workspace_live_test.exs`: the test "lists runs after Jobsite with workflow name and status" (`strong` = `implement-trd`, and the unnamed-run `"workflow"` fallback: both move to `.ws-nav-workflow`), "a dispatched run's row shows the name from its frozen workflow snapshot" (`strong` = `prd` → `.ws-nav-workflow`), and the project-scoping test (`strong` = `mine-workflow`/`their-workflow` → `.ws-nav-workflow`, with a task title asserted in `strong`). Audit with `grep -rn "workflows-panel\|nav-workflows-title\|nav-jobsite-title\|workspace_nav" packages/foreman_server/test`; delete assertions that pin only the old wording, never skip or loosen. (2h) [satisfies REQ-016] [depends: TRD-007-TEST]
  - Target Files: `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs`
  - Validates PRD ACs: AC-012-3, AC-016-2
  - Implementation AC:
    - Given the grep, when run after the change, then every hit asserts current behaviour and no test asserts that these panels have no links.
    - Given `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors test/foreman_server_web'`, when run, then it is green.

### PR 2: Conversation links that cannot dead-end

**Shippable State:** Each Workflows and Jobsite row has a "Conversation" link, and the thread URL of any run of the project — including a resolved run older than the Overview window — opens that run's conversation instead of "This project has no thread with that id"; unknown and other-project thread ids still show the not-found state.

- [x] **TRD-009** Add `Overview.card(project_id, thread_id)` → `{:ok, ThreadCard.t()} | {:error, :thread_not_found}`: `Threads.get/1`, reject a thread whose `project_id` differs, run it through the existing `classify_threads/3` (a one-element list: thread → PR rollup → `Input` → `Group.classify/1`) and `ThreadCard.build/4` exactly as `build/2` does. No second classification path. Cost note in the `@doc`: `Threads.get/1` rebuilds every thread (F3). (3h) [satisfies REQ-005]
  - Target Files: `packages/foreman_server/lib/foreman_server/overview.ex`
  - Validates PRD ACs: AC-005-1, AC-005-2
  - Implementation AC:
    - Given a resolved run outside the newest-20 resolved window, when `Overview.card/2` is called with its thread id, then it returns a card whose `thread_id`/`title` match and whose group is the one `build/2` would have given it.
    - Given another project's thread id, an unknown id and a malformed id, when called, then each returns `{:error, :thread_not_found}`.
    - Given a thread present in `build/2`'s groups, when `card/2` is called, then both cards are equal (`==`).

- [x] **TRD-009-TEST** `test/foreman_server/overview_card_test.exs` (follow `test/foreman_server/overview/*_test.exs` conventions): the three AC cases above, with a project of 30 resolved runs seeded through `ProjectionStore.apply_events/1`. (2h) [verifies TRD-009] [satisfies REQ-005] [depends: TRD-009]
  - Target Files: `packages/foreman_server/test/foreman_server/overview_card_test.exs`
  - Validates PRD ACs: AC-005-1, AC-005-2
  - Implementation AC:
    - Given 30 resolved runs, when `build(project, include_resolved: true)` is compared with `card/2` for the 25th, then the former omits it and the latter returns it.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-010** `ProjectWorkspaceLive.select_card/1`: when `ThreadView.find_card/2` returns nil and `thread_id` is non-nil, call `Overview.card(project_id, thread_id)`; `{:ok, card}` → assign it and `ensure_log/1`; `{:error, :thread_not_found}` → the current nil-card behaviour. No other change to thread selection. (2h) [satisfies REQ-005] [depends: TRD-009]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex`
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-005-3
  - Implementation AC:
    - Given the URL of a resolved run older than the Overview window, when the workspace mounts, then the thread pane (not `thread_missing`) renders.
    - Given an unknown thread id, when the workspace mounts, then `Components.thread_missing` still renders.

- [x] **TRD-010-TEST** In `test/foreman_server_web/live/project_workspace_threads_live_test.exs` (`live/2` over a seeded project): seed 30 resolved runs, mount the thread URL of the oldest, assert the conversation pane; unknown id and other project's id → not-found text; loop over all 30 thread URLs asserting none renders the not-found message. (3h) [verifies TRD-010] [satisfies REQ-005] [depends: TRD-010]
  - Target Files: `packages/foreman_server/test/foreman_server_web/live/project_workspace_threads_live_test.exs`
  - Validates PRD ACs: AC-005-1, AC-005-2, AC-005-3
  - Implementation AC:
    - Given 30 resolved runs, when each thread URL is mounted, then `refute html =~ "no thread with that id"` for all 30.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-011** Add the conversation link to rows: in each run row's details a "Conversation" `<.link patch={thread_path(@project_id, r.thread_id, @token)}>`; in each jobsite row's details the same with the jobsite's `thread_id`. Update the `CLAUDE.md`/`docs/user-guide.md` nav passages edited in TRD-007 with one sentence on the link. (2h) [satisfies REQ-005] [satisfies REQ-007] [depends: TRD-007, TRD-010]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`, `CLAUDE.md`, `docs/user-guide.md`
  - Validates PRD ACs: AC-005-1, AC-007-1
  - Implementation AC:
    - Given a rendered row, when its Conversation `href` is followed in a LiveView test, then the thread pane for that run renders.
    - Given the token, when the link renders, then it carries `?token=` exactly as the thread-list links do.

- [x] **TRD-011-TEST** In `project_workspace_live_test.exs`: the Conversation link of the oldest of 30 resolved runs renders its pane when followed (`live_patch`/`render_patch`); jobsite rows link to `jobsite:<id>` threads; link carries the token. (2h) [verifies TRD-011] [satisfies REQ-005] [satisfies REQ-007] [depends: TRD-011]
  - Target Files: `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs`
  - Validates PRD ACs: AC-005-1, AC-005-3, AC-007-1
  - Implementation AC:
    - Given 30 resolved runs, when every row's Conversation link is followed, then none shows the not-found state.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

### PR 3: Run dashboard deep links and a per-file diff view

**Shippable State:** An operator opening `/dashboard/runs?run_id=…&tab=changes&file=…` lands on that run's Changes tab with the selected file's diff shown (with an explicit notice if the diff was truncated), and every file in the Changes tab is clickable to its diff; with no extra parameters the dashboard behaves exactly as before.

- [x] **TRD-012** Move the bounded-evidence idiom into the facade: add `OperatorDashboard.change_evidence_bounded(run_id, timeout_ms \\ 3_000)` (the body of `load_changes_bounded/1`) and `preview_bounded(run_id, rel_path, timeout_ms \\ 3_000)` wrapping `ChangeEvidence.preview/2` the same way. Change `ChangeEvidence.preview/2` to return `{:ok, %{diff, truncated?, bytes}}`, cutting `diff` on a UTF-8 **byte** boundary at `@max_bytes` (F10; it has no callers, so this is a clean cutover). Delete the private `load_changes_bounded/1` and `@evidence_timeout_ms` from `OperatorRunDashboardLive`; its call sites use the facade. (3h) [satisfies REQ-019] [satisfies REQ-013] [satisfies REQ-011]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/operator_dashboard.ex`, `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex`
  - Validates PRD ACs: AC-019-1, AC-019-2, AC-013-3
  - Implementation AC:
    - Given a `ChangeEvidence` call that exceeds `timeout_ms`, when `change_evidence_bounded/2` runs, then it returns `{:error, :evidence_timeout}` and the task process is dead.
    - Given `grep -n load_changes_bounded` over `lib/`, when run, then there are zero matches (one implementation, §5.7).
    - Given a path with `..`, when `preview_bounded/3` runs, then `{:error, :malformed_path}` and no `git` process starts.
    - Given a patch over `@max_bytes`, when previewed, then `truncated? == true`, `byte_size(diff) <= @max_bytes`, `diff` is valid UTF-8 and `bytes` is the full size.

- [x] **TRD-012-TEST** Facade tests in `test/foreman_server_web/operator_dashboard_test.exs` (reuse its tmp-git-repo seeding, ~line 223): timeout (a fake `git` shell script that sleeps, placed on `PATH` for the test and restored in `on_exit`; pass `timeout_ms: 100`), a successful preview of a changed file, truncation of a >24 000-byte added file including a multibyte boundary, `:malformed_path`, a file not among the changed files (`:unavailable`), unknown run. (2h) [verifies TRD-012] [satisfies REQ-019] [satisfies REQ-013] [satisfies REQ-011] [depends: TRD-012]
  - Target Files: `packages/foreman_server/test/foreman_server_web/operator_dashboard_test.exs`
  - Validates PRD ACs: AC-019-2, AC-013-3
  - Implementation AC:
    - Given the sleeping fake `git` and `timeout_ms: 100`, when called, then the result arrives in under 1 s and is `{:error, :evidence_timeout}`.
    - Given `rel_path` `../../etc/passwd`, when previewed, then the fake `git` records zero invocations.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-013** `OperatorRunDashboardLive`: assign `:token` (from `params["token"]`), `:selected_file` and `:file_preview` (`:absent`) in `mount/3`. In `mount/3`, **before** calling `refresh/2`, assign `active_tab` from `params["tab"]` (an unknown or missing value → `"summary"`) and `selected_file` from `params["file"]`; when `connected?(socket)` the same refresh pass loads the changes (`change_evidence_bounded/1`) and the file preview (`preview_bounded/2`) — on the **dead render** changes stay `:absent` so no git runs and first paint is not stalled (key decision 10). Add `handle_params/3` for `patch` navigation: re-apply `tab`/`file`, loading changes/preview only when the requested state differs from the assigns (idempotent, so it is a no-op right after mount); a missing `file` clears `selected_file`/`file_preview`. `select-run` and `tab` events clear the file selection. The periodic `:refresh` tick never re-reads the preview. (4h) [satisfies REQ-019] [depends: TRD-001, TRD-012]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex`
  - Validates PRD ACs: AC-019-1, AC-019-2
  - Implementation AC:
    - Given `?run_id=R&tab=changes&file=docs/TRD/x.md` on a connected load, when `mount` then `handle_params` run, then `active_tab == "changes"`, changes are loaded once and `file_preview` is `{:ok, %{diff: _, truncated?: _, bytes: _}}`.
    - Given the dead (HTTP) render of the same URL, when it runs, then no `git` process starts.
    - Given `?tab=bogus`, when loaded, then `active_tab == "summary"` and no `git` runs.
    - Given a `file` not among the changed files, when loaded, then `file_preview == {:error, :unavailable}`, the page renders and nothing raises.
    - Given the 2 s refresh tick, when it fires, then `preview_bounded` is not called (spy via the `PATH` shim).

- [x] **TRD-013-TEST** Create `test/foreman_server_web/operator_run_dashboard_live_test.exs` — the dashboard has **no LiveView test today** (only the ConnTest/facade tests in `operator_dashboard_test.exs`); follow the workspace LiveView test setup (`ConnCase`, the api bearer-token env, `ProjectionStoreReset`, a tmp git repo for the worktree) and `Phoenix.LiveViewTest.live/2`: deep link opens the Changes tab and shows the diff; `?run_id=R` alone shows run R's detail (PRD AC-004-3); unknown tab → Summary; `file=../../etc/passwd` and a non-changed file → refusal text and no `git` invocation for the unsafe path; switching run clears the file; the dead render (`get/2`) runs no git; reload with the same URL reproduces the state. (3h) [verifies TRD-013] [satisfies REQ-019] [satisfies REQ-004] [depends: TRD-013, TRD-014]
  - Target Files: `packages/foreman_server/test/foreman_server_web/operator_run_dashboard_live_test.exs`
  - Validates PRD ACs: AC-004-3, AC-019-1, AC-019-2
  - Implementation AC:
    - Given a seeded run whose worktree added `docs/TRD/TRD-x.md`, when `live(conn, "/dashboard/runs?run_id=R&tab=changes&file=docs/TRD/TRD-x.md&token=T")` mounts, then the HTML contains the added file's text inside the preview.
    - Given the unsafe-path case, when mounted, then the fake `git` log has no entry mentioning `etc/passwd`.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-014** Render the per-file view in the Changes tab: each `render_changes/1` file entry becomes `<.link patch={Components.run_detail_path(run_id, @token, tab: "changes", file: file.path)}>`; `<section id="change-preview">` shows a heading "Diff of <path>" and `<pre>` of the diff **patch** (HEEx-escaped, no `raw/1`) — it is a diff, not the file, and says so — followed, when `truncated?`, by "Diff truncated: showing N of M bytes", or a typed message for `:malformed_path`, `:unavailable`, `:git_unavailable`, `:evidence_timeout`. The link carries the token only when one was supplied. **Documentation gate for this PR:** document the `tab` and `file` parameters, the diff view and the token note in `docs/user-guide.md` (find with `grep -n "/dashboard/runs" docs/user-guide.md`) and update the `OperatorRunDashboardLive` moduledoc. (3h) [satisfies REQ-019] [satisfies REQ-014] [satisfies REQ-011] [depends: TRD-013]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex`, `docs/user-guide.md`
  - Validates PRD ACs: AC-019-1, AC-019-2, AC-019-3, AC-014-1
  - Implementation AC:
    - Given a changed file named `<script>x</script>.md` and a diff containing `<script>`, when rendered, then the HTML has the escaped text and no executable script element.
    - Given a dashboard opened without a token, when the file links render, then no `token=` appears in any `href`.
    - Given each of the four error atoms and a truncated diff, when rendered, then a distinct, human-readable message appears.

- [x] **TRD-014-TEST** In `operator_run_dashboard_live_test.exs`: escaping of an XSS-named file and diff body; each error atom renders its message (drive `file_preview` via `handle_params`); a >24 000-byte added file renders the truncation notice with the byte counts; no-token links; clicking a file entry patches to the `file=` URL and shows its diff. (2h) [verifies TRD-014] [satisfies REQ-019] [satisfies REQ-014] [satisfies REQ-011] [depends: TRD-014]
  - Target Files: `packages/foreman_server/test/foreman_server_web/operator_run_dashboard_live_test.exs`
  - Validates PRD ACs: AC-014-1, AC-019-2
  - Implementation AC:
    - Given the XSS fixtures, when rendered, then `refute html =~ "<script>x</script>"` and `assert html =~ "&lt;script&gt;"`.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

### PR 4: Lazy PRD/TRD documents on disclosure-open

**Shippable State:** Opening a run's "Details" in the Workflows panel now also lists the PRD and TRD files that run wrote (or its task's TRD), each linking to that file's diff in the run dashboard; if `git` or the worktree is unavailable the section says why, and no other row or panel is affected.

- [x] **TRD-015** `ChangeEvidence.planning_documents(run_id, extra_path)`: from `for_run/1`'s `files` (already capped at 200), keep entries whose `path` matches `^docs/PRD/PRD-[^/]+\.md$` → `kind: :prd`, `^docs/TRD/TRD-[^/]+\.md$` → `kind: :trd`, plus `extra_path` (the task's `trd_path`, or nil) as `:trd` **only if** it is among the changed files; every path passes `safe_relative?/1`; added/modified/renamed statuses only (deleted files dropped). Map `for_run/1` states to `{:unavailable, :worktree_missing | :base_unavailable | :git_unavailable | :run_not_found}`. Facade `OperatorDashboard.planning_documents_bounded(run_id, extra_path, timeout_ms \\ 3_000)` wraps it with the TRD-012 idiom (`{:unavailable, :evidence_timeout}`). (4h) [satisfies REQ-010] [satisfies REQ-011] [satisfies REQ-013] [satisfies REQ-014] [depends: TRD-012]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/operator_dashboard.ex`
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-010-3, AC-011-2, AC-013-3, AC-014-3
  - Implementation AC:
    - Given a run branch that added `docs/PRD/PRD-a.md`, `docs/TRD/TRD-a.md` and `README.md`, when called, then exactly the two documents are returned with kinds `:prd` and `:trd`.
    - Given a run that changed only `lib/x.ex`, when called, then `{:ok, []}`.
    - Given `extra_path` `docs/TRD/pre-existing.md` not among the changed files, when called, then it is not returned.
    - Given a deleted `docs/TRD/old.md`, when called, then it is not returned.

- [x] **TRD-015-TEST** Tests in `operator_dashboard_test.exs` using the tmp-git-repo seeding: the four AC cases, `:worktree_missing`, a stubbed hanging `git` → `{:unavailable, :evidence_timeout}`, and a path-safety case (`planning_documents` never returns a path failing `safe_relative?`, asserted through a unit-level seam since git cannot create a `..` path). (3h) [verifies TRD-015] [satisfies REQ-010] [satisfies REQ-011] [satisfies REQ-013] [satisfies REQ-014] [depends: TRD-015]
  - Target Files: `packages/foreman_server/test/foreman_server_web/operator_dashboard_test.exs`
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-010-3, AC-011-2, AC-013-3, AC-014-3
  - Implementation AC:
    - Given a real throwaway repo with a `prd`-shaped branch, when run, then the PRD and TRD paths are found by the real code path (no mocking of `ChangeEvidence`).
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-016** `ProjectWorkspaceLive`: handle `"nav_run_toggle"` (`%{"run-id" => id}`): ignore ids not in `nav_runs` (never mints state for an unlisted id); closing removes the id from `nav_open` and `nav_docs`; opening adds it to `nav_open`, sets `nav_docs[id] = :loading`, and calls `start_async(socket, {:nav_docs, id}, fn -> OperatorDashboard.planning_documents_bounded(id, trd_path) end)` with `trd_path` taken from the listed row (`nil` when `:none`). `handle_async({:nav_docs, id}, {:ok, result}, socket)` stores `{:ok, docs}` / `{:unavailable, reason}` only if the id is still open and only under `nav_docs[id]`; `{:exit, reason}` stores `{:unavailable, :crashed}` and logs a warning. `refresh`/`load_state` neither read nor write `nav_docs` beyond the TRD-006 pruning. (5h) [satisfies REQ-010] [satisfies REQ-012] [satisfies REQ-013] [depends: TRD-006, TRD-015]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/project_workspace_live.ex`
  - Validates PRD ACs: AC-013-2, AC-013-3, AC-013-4, AC-012-2
  - Implementation AC:
    - Given a click on one row, when handled, then exactly one `planning_documents_bounded` call starts, for that run, and the LiveView process is not blocked while it runs (another event is handled during the wait).
    - Given a refresh after the result arrived, when it runs, then `planning_documents_bounded` is not called again for that run.
    - Given a toggle for an id not in the list, when handled, then no state changes and no read starts.
    - Given two open rows, when one row's result lands, then the other row's `open` state and content are unchanged.
    - Given the same row closed and reopened, when reopened, then discovery re-runs once.

- [x] **TRD-016-TEST** `project_workspace_live_test.exs` additions using `render_click` on the summary and `render_async/2`: single-row discovery; the 100-row refresh issues zero `git` calls before any click and exactly one after one click (`PATH`-shim log); a hanging shim yields "timed out" for that row within the timeout window (one test waits the real 3 s, `@tag timeout: 15_000`) while another event is answered during the wait; cache hit on refresh; toggle of an unlisted id is ignored; two open rows are independent; crash path stores `:crashed`. If `start_async` results interleave badly with refreshes, fall back to `Task.Supervisor.async_nolink` + `handle_info` under the same cache rules (this TRD's main unverified risk). (4h) [verifies TRD-016] [satisfies REQ-010] [satisfies REQ-012] [satisfies REQ-013] [depends: TRD-016, TRD-017]
  - Target Files: `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs`
  - Validates PRD ACs: AC-013-1, AC-013-2, AC-013-3, AC-013-4
  - Implementation AC:
    - Given a hanging `git` and the real 3 000 ms timeout, when a row is opened, then the row shows the timed-out state while the socket still answers a `ws_search` event sent during the wait.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

- [x] **TRD-017** Render the Documents area in the run row's details from `@nav_docs[run_id]` (new `attr(:nav_docs, :map)` on `workspace_nav/1`, passed from the live): `:loading` → "Looking for documents…" (`aria-live="polite"`); `{:ok, [..]}` → PRD then TRD entries, each `<.link href={run_detail_path(run_id, @token, tab: "changes", file: path)}>` with the project-relative path as text; `{:ok, []}` with no task `trd_path` → nothing (absence is not an error); `{:unavailable, reason}` → "Documents unavailable: <worktree directory missing | base ref unavailable | git unavailable | timed out | run not found | lookup failed>". The task `trd_path` line from TRD-007 becomes a link when its path is in the discovered list, text otherwise. A phase `:artifact` is never rendered as a document. Add one sentence on the on-demand documents to the `CLAUDE.md`/`docs/user-guide.md` nav passages. (3h) [satisfies REQ-010] [satisfies REQ-011] [satisfies REQ-014] [depends: TRD-007, TRD-014, TRD-016]
  - Target Files: `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`, `CLAUDE.md`, `docs/user-guide.md`
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-010-3, AC-010-4, AC-010-5, AC-011-1, AC-011-2, AC-014-3
  - Implementation AC:
    - Given discovered `docs/TRD/TRD-a.md`, when rendered, then its `href` is `/dashboard/runs?run_id=R&tab=changes&file=docs%2FTRD%2FTRD-a.md&token=T` and following it (PR 3) shows the diff.
    - Given each `{:unavailable, reason}` atom, when rendered, then a distinct message appears and branch/worktree/PR rows still render.
    - Given a phase artifact `REVIEW_REPORT.md`, when the details render, then it is not labelled or linked as the TRD.

- [x] **TRD-017-TEST** `project_workspace_live_test.exs`: a seeded `prd`-shaped run in a real tmp repo → both documents appear with correct `href`s after a click; an implement-TRD task's `trd_path` is shown with no git call before the click and linked only if changed; each unavailable reason's message; a `fix` run shows no documents section; phase-artifact exclusion; and a follow-the-link check that `live(conn, href)` renders the diff. (2h) [verifies TRD-017] [satisfies REQ-010] [satisfies REQ-011] [satisfies REQ-014] [depends: TRD-017]
  - Target Files: `packages/foreman_server/test/foreman_server_web/live/project_workspace_live_test.exs`
  - Validates PRD ACs: AC-010-1, AC-010-2, AC-010-3, AC-010-4, AC-010-5, AC-011-1, AC-011-2
  - Implementation AC:
    - Given the real tmp repo, when the click and link-follow run, then the end-to-end path (nav → run dashboard → diff) renders the TRD's text.
    - Given the file, when run with `--warnings-as-errors`, then it passes with zero warnings.

### PR 5: Final docs pass, supersession audit, real-route smoke

**Shippable State:** The operator documentation consistently describes the titled, linked rows and the run dashboard's `tab`/`file` parameters with no leftover "name-and-status only" wording, the superseded boundary is audited, and the whole path from the nav to a TRD's diff has been exercised against the running server.

- [x] **TRD-018** Final documentation consistency pass over what PRs 1–4 each edited: `CLAUDE.md` "Workspace nav" paragraph, `docs/user-guide.md` nav paragraph and run-dashboard section, the `workspace_nav/1` and `OperatorRunDashboardLive` moduledocs. Fix any drift between them (same panel description, same parameter names, same token note). Do not edit `docs/PRD/*` or `docs/TRD/*`. (2h) [satisfies REQ-016] [depends: TRD-017]
  - Target Files: `CLAUDE.md`, `docs/user-guide.md`, `packages/foreman_server/lib/foreman_server_web/workspace/components.ex`, `packages/foreman_server/lib/foreman_server_web/operator_run_dashboard_live.ex`
  - Validates PRD ACs: AC-016-3, AC-019-3
  - Implementation AC:
    - Given `grep -n "glance" CLAUDE.md docs/user-guide.md` for the workspace-nav passages, when run, then no passage still claims the rows are name-and-status only.
    - Given the user guide, when read, then it documents `/dashboard/runs?run_id=…&tab=changes&file=…` and that the token is required in the URL.

- [x] **TRD-019** Supersession and documentation-gate audit (inspection, recorded in the PR body): list added/removed externally visible identifiers (expected added: query params `tab`, `file` on `/dashboard/runs`; LiveView event `nav_run_toggle`; internal facade option `detail`; expected removed: none), `grep` each in `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md` and state which of the four were edited and which were not, and why; confirm `git diff` is empty for the old PRD/TRD files of `7735ac9c`; confirm no new module under `lib/foreman_server/{commands,events,aggregates}` and no nav `phx-click` that dispatches a command (PRD REQ-018). (2h) [satisfies REQ-016] [satisfies REQ-018] [depends: TRD-018]
  - Target Files: `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`
  - Validates PRD ACs: AC-016-1, AC-016-3, AC-018-1, AC-018-2
  - Implementation AC:
    - Given `git diff --stat origin/main -- docs/PRD/PRD-2026-7735ac9c-dashboard-jobsite-workflows-nav.md docs/TRD/TRD-2026-7735ac9c-dashboard-jobsite-workflows-nav.md`, when run, then it is empty.
    - Given the doc-gate report, when read, then it names each of the four docs as edited or not edited with a reason.

- [x] **TRD-020** Real-route smoke run, done as a manual checklist (no script is committed): start the dev server per `docs/lessons/operator-reference.md` (`devbox run server`), use a project with more than 20 resolved runs including a `prd` run with committed PRD/TRD files, then in a real browser session: open the workspace with `?token=`; confirm titles replace `prd · completed`; follow a title link and see the run's detail pane; open a "Details" and see branch, worktree, PR; confirm Documents appears after the click and not before; follow a TRD link and see its diff; follow the Conversation link of the oldest resolved run; reload each page and confirm no 401. Notes, logs and screenshots go under `~/.omp/foreman-nav-smoke/` — never `/tmp`, per the standing AGENTS.md rule — and the checklist result is summarised in the PR body. (4h) [satisfies REQ-017] [depends: TRD-018]
  - Target Files: `~/.omp/foreman-nav-smoke/checklist.md`
  - Validates PRD ACs: AC-004-3, AC-017-1, AC-017-2
  - Implementation AC:
    - Given the seeded project, when the smoke path is executed, then every link renders its target with no 401, no "no thread with that id", and no empty detail pane.
    - Given each followed URL, when reloaded, then the page is still answered (token carried in the URL).

## Acceptance Criteria Traceability

| REQ-NNN | Description | Implementation Tasks | Test Tasks |
| --- | --- | --- | --- |
| REQ-001 | Task/bead title as primary label | TRD-002, TRD-005, TRD-007 | TRD-002-TEST, TRD-005-TEST, TRD-007-TEST |
| REQ-002 | Workflow name and status secondary | TRD-007 | TRD-007-TEST |
| REQ-003 | One shared title derivation | TRD-002, TRD-005 | TRD-002-TEST, TRD-005-TEST |
| REQ-004 | Link to run details | TRD-001, TRD-007 | TRD-001-TEST, TRD-007-TEST, TRD-013-TEST |
| REQ-005 | Conversation link never dead-ends | TRD-009, TRD-010, TRD-011 | TRD-009-TEST, TRD-010-TEST, TRD-011-TEST |
| REQ-006 | PR link | TRD-005, TRD-007 | TRD-005-TEST, TRD-007-TEST |
| REQ-007 | Jobsite rows: title and link | TRD-005, TRD-007, TRD-011 | TRD-005-TEST, TRD-007-TEST, TRD-011-TEST |
| REQ-008 | Branch and base | TRD-005, TRD-007 | TRD-005-TEST, TRD-007-TEST |
| REQ-009 | Worktree path and state | TRD-003, TRD-005, TRD-007 | TRD-003-TEST, TRD-005-TEST, TRD-007-TEST |
| REQ-010 | TRD and PRD/TRD documents | TRD-005, TRD-015, TRD-016, TRD-017 | TRD-015-TEST, TRD-016-TEST, TRD-017-TEST |
| REQ-011 | Missing data shown with reason | TRD-005, TRD-007, TRD-012, TRD-014, TRD-015, TRD-017 | TRD-005-TEST, TRD-007-TEST, TRD-012-TEST, TRD-014-TEST, TRD-015-TEST, TRD-017-TEST |
| REQ-012 | Compact row, disclosure | TRD-006, TRD-007, TRD-016 | TRD-006-TEST, TRD-007-TEST, TRD-016-TEST |
| REQ-013 | Bounded cost: refresh path and disclosure-open | TRD-003, TRD-004, TRD-006, TRD-012, TRD-015, TRD-016 | TRD-003-TEST, TRD-004-TEST, TRD-006-TEST, TRD-012-TEST, TRD-015-TEST, TRD-016-TEST |
| REQ-014 | Link and display safety | TRD-001, TRD-007, TRD-014, TRD-015, TRD-017 | TRD-001-TEST, TRD-007-TEST, TRD-014-TEST, TRD-015-TEST, TRD-017-TEST |
| REQ-015 | Typed read model | TRD-004, TRD-005, TRD-006 | TRD-004-TEST, TRD-005-TEST |
| REQ-016 | Supersede, tests, docs | TRD-008, TRD-018, TRD-019 | — (inspection; TRD-008 is a test-suite audit) |
| REQ-017 | Real-route smoke | TRD-020 | — (manual smoke) |
| REQ-018 | No actions/filters/write paths (Won't) | TRD-019 | — (inspection) |
| REQ-019 | Run dashboard `tab`/`file` params | TRD-001, TRD-012, TRD-013, TRD-014 | TRD-001-TEST, TRD-012-TEST, TRD-013-TEST, TRD-014-TEST |

All 19 PRD requirements are covered. **Tasks deliberately without a `-TEST` pair:** TRD-008
(it *is* a test rewrite), TRD-018 (docs), TRD-019 (inspection / documentation gate) and
TRD-020 (manual smoke) — the repo's precedent for absence-type and proof work
(`TRD-2026-7735ac9c` traceability, "— (diff/grep/inspection)"). REQ-016/REQ-017/REQ-018 are
verified by inspection, the documentation-gate audit and the smoke run — the right
verification for a supersession rule, a real-route proof and a negative requirement.

## Sprint Planning

### Sprint 1: The operator's ask (PR 1, ~40h)

TRD-001, TRD-002, TRD-003, TRD-004 in parallel → TRD-005 → TRD-006 → TRD-007 → TRD-008.

### Sprint 2: Conversation fix and dashboard deep link (PR 2 + PR 3, ~31h)

PR 2 (TRD-009 → 010 → 011) and PR 3 (TRD-012 → 013 → 014) are independent of each other
(TRD-011 needs PR 1's rows, TRD-013 needs only TRD-001) and can be built in parallel.

### Sprint 3: Lazy documents and proof (PR 4 + PR 5, ~29h)

TRD-015 → TRD-016 → TRD-017; then TRD-018 → TRD-019 and TRD-020. This section is
informational; `implement-trd-beads` parses the `### PR N:` sections, not this one.

## Adversarial Review (self-critique)

1. **Architecture — the PRD's "reuse the existing preview" premise was false (F1).** Resolved:
   TRD-012–014 build the per-file view; PRD REQ-019 was corrected. Largest unplanned scope.
2. **Architecture — the nav's existing run read was not O(1) (F9).** `list_runs/1` made up to
   ~200 per-run GenServer calls per refresh. Resolved by one `detail` option on the existing
   facade (not a second row builder), default `:full` so the operator dashboard is unchanged,
   with call-count assertions (TRD-004-TEST, TRD-006-TEST) so it cannot regress.
3. **Architecture — `Threads.by_run_ids/1` looked like the title source and is not (F3).**
   Resolved: one `list_tasks/0` plus the shared `Thread.title/2`. `thread_inputs/0` was also
   rejected (key decision 3).
4. **Failure path — the conversation-link fix has a worst case.** One extra `Threads.get/1`
   per refresh while an out-of-window thread is open (decision 8). Bounded at ~2× the existing
   cost; no cache because a cached card goes stale.
5. **Failure path — the dead render could stall first paint up to 3 s.** Resolved: the dead
   render never reads git (decision 10); the connected mount does, in the same pass.
6. **Failure path — silent truncation (F10).** Resolved: `preview/2` returns `truncated?` and
   the byte count, cuts on a byte boundary, and the UI says so (REQ-011).
7. **Interface — `<details>` and server state can disagree.** A user click toggles the DOM
   natively and sends the event; a dropped event leaves them apart until the next patch.
   Resolved: `open` is derived from `nav_open` on every render and results touch only their
   own row (decision 4), so the next patch reconciles and rows cannot affect each other.
8. **Interface — typed worktree state raises on an unknown status.** Deliberate (§5.2/§5.3).
   The projection only produces `created` and `cleaned`; orphans are a separate map and are
   not modelled (F5).
9. **Interface — nav branch rule vs. evidence rule.** The nav follows `Thread.from_run/6`
   (last record with a branch); `ChangeEvidence` prefers `primary?`. They can differ for
   multi-repo runs. Recorded (decision 9), not unified.
10. **Coverage — jobsite worktree state is not projected (F7).** Jobsite rows show the path
    with no state; resolved by omission, not by guessing.
11. **Estimate / unknown — `start_async` under test.** `render_async/2` with the 250 ms
    refresh coalescer is unverified (tests already set `coalesce_ms: 20`). The fallback is
    `Task.Supervisor.async_nolink` + `handle_info` under the same cache rules; TRD-016/-TEST
    carry that risk.
12. **Testability — no command-runner seam; the hung-`git` case needs a real 3 s wait.**
    `ChangeEvidence.git/2` calls `System.cmd("git", …)` directly. Rather than add a seam (or
    a config key, which would trigger the documentation gate for a test hook), tests use a
    counting/sleeping `git` on `PATH`, and the timeout is a function argument. Only the single
    LiveView-level hang test waits the full 3 s.
13. **Testability — the run dashboard had no LiveView test (F-note on TRD-013-TEST).**
    A new `operator_run_dashboard_live_test.exs` is part of PR 3.
14. **Dependency — rows ship before the pieces their links target.** PR 1's run-details link
    needs nothing from PRs 2–4 (the dashboard already resolves `run_id`); the Conversation
    link (PR 2) and document links (PR 4) are added only after their targets are safe (TRD-011
    depends on TRD-010; TRD-017 on TRD-014).

## Dependency and Estimate Review

- **Critical path:** TRD-002/003/004 → TRD-005 (6h) → TRD-006 → TRD-007 (5h) → TRD-016 (5h) →
  TRD-017 → TRD-018 → TRD-020. PRs are independently shippable, so no single review carries
  the whole chain; PR 1 alone delivers the operator's core ask.
- **No task is estimated at 8h or more.** The largest are TRD-005 (6h, pure functions with an
  exhaustive pure test) and TRD-007/TRD-016 (5h).
- **Estimate confidence is the weak dimension:** `start_async` interplay (item 11) and the
  size of the TRD-008 test rewrite are not measured. TRD-008 is bounded by a `grep` that can
  be run first.
- **Acyclic:** the only test-to-test dependencies are TRD-008 → TRD-007-TEST, TRD-006-TEST →
  TRD-007, TRD-013-TEST → TRD-014, TRD-016-TEST → TRD-017; none loops back.

## Design Readiness Scorecard

| Dimension | Score | Notes |
| --- | --- | --- |
| Architecture completeness | 4.4 | Components, contracts, data flow, failure matrix and four PRD-premise corrections (F1, F2, F9, F10) defined; `start_async` interplay unverified |
| Task coverage | 4.6 | 19/19 REQs and 59/59 ACs mapped; every user-facing task has a paired test; negative/proof tasks stated as inspection-verified |
| Dependency clarity | 4.5 | Explicit `[depends:]`, acyclic, five independently shippable PRs, core ask first |
| Estimate confidence | 3.8 | Reuse-heavy and granular, but LiveView async test behaviour and the existing-test rewrite are unmeasured |

**Overall: 4.3 → PASS** (self-scored; no external reviewer).

## Next Steps

- `/ensemble-configure-team docs/TRD/TRD-2026-f7a50d75-workspace-nav-run-provenance-links.md`
- `/ensemble-implement-trd-beads docs/TRD/TRD-2026-f7a50d75-workspace-nav-run-provenance-links.md`

## Changelog

- **2026-11-04 — v1.1.0:** Review pass. PRs reordered so the titled/linked rows ship first;
  conversation fix second; dashboard deep link + diff view third; lazy documents fourth.
  Added `list_runs/1` `detail: :summary` (F9), the `preview/2` truncation contract (F10), a
  dedicated dashboard LiveView test file, connected-only evidence loading in `mount/3`, the
  nav-vs-evidence worktree rule note, the explicit list of existing tests to rewrite (F12),
  per-PR documentation-gate edits, and the smoke checklist location. Tasks renumbered
  (36 tasks); `trd-cli parse` clean.
- **2026-11-04 — v1.0.0:** Initial TRD from `PRD-2026-f7a50d75`. Option C selected. Found and
  recorded F1–F8. Supersedes only the "no run-detail links" inspection in task TRD-006 of
  `TRD-2026-7735ac9c`; that document is not edited.
