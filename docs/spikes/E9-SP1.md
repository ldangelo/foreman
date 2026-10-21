# Spike E9-SP1: where PR watch state lives

Question: which stream owns per-PR observation, fix-attempt counters and
watch on/off state, given jobsite PRs, multi-repo runs (E12, not built) and
terminal run streams?

## Verified facts (code at the time of writing)

| # | Fact | Where |
|---|------|-------|
| 1 | PR events already attach to `run:<id>` AFTER `run.complete`: the allow-list `allow_pr_lifecycle_on_terminal_runs/2` lists exactly `run.pr.update/ready/retarget/reset/merge`; it has no fallback clause, so any new PR command type raises `FunctionClauseError` unless added there. | `aggregates/run.ex` (`allow_pr_lifecycle_on_terminal_runs`) |
| 2 | `Aggregates.Run.apply_event/2` has NO catch-all clause: an event type it does not list raises on replay. E9 adds `_ -> state` so future event types on a run stream replay safely. | `aggregates/run.ex` `apply_event/2` |
| 3 | `pr_association:<run_id>` holds ONE `pr_url` per run; `ProjectionStore.run_ids_for_pr_url/1` maps a URL back to runs. | `pr_associate.ex`, `projection_store.ex` |
| 4 | The jobsite door never opens a PR (`Jobsite.Executor` has no `gh` call) and a jobsite has no run stream. A jobsite thread that pushed a branch has `branch` + `repo_path` on its projection, nothing PR-shaped. | `jobsite/executor.ex` |
| 5 | S3 decided multi-repo as: `repo_id` absent == the run's PRIMARY repo; every new optional `repo_id` is absent for the primary so ids/events stay byte-identical; PR association is keyed `{run_id, repo}`. | `docs/spikes/S3.md` 4.1, row 14, row 17 |
| 6 | E7's `PrFold` already keeps `state.pr_states[run_id]` (PR state, merge gate) for the Overview. E9 must not duplicate that read model. | `overview/pr_fold.ex` |

## Options

* **A. Everything on `run:<id>`**, observations keyed by `pr_url` (+ nullable `repo_id`). Jobsite-originated PRs unsupported in v1.
* B. New aggregate `pr_watch:<sha1(pr_url)>`, subject `{kind, id}`. Needs a second watch registry, a second terminal-run exemption story, and a cross-stream join for every Overview/MCP read.
* C. Hybrid (A for runs, B for jobsites).

## Decision: A

* `PrChecksChanged`, `PrReviewChanged`, `PrFixRequested`, `PrFixStarted`,
  `PrFixFinished`, `PrFixExhausted`, `PrWatchStopped`, `PrWatchStarted` are
  events on `run:<run_id>`. Every payload carries `pr_url` and a nullable
  `repo_id` (absent == primary repo, S3 rule), so the future multi-repo key
  `{run_id, repo_id}` is a pure addition and the v1 key `{run_id, pr_url}` is
  already unique per PR.
* The watch read model is `ProjectionStore.pr_watch/1` = `%{pr_url => record}`
  per run (separate from E7's `pr_states`, which keeps owning merge-gate state;
  field names agree: `pr_url, head_sha, base_branch, status`).
* The aggregate keeps authoritative per-PR state in `State.pr_watch`
  (`%{pr_url => %{checks_state, review_decision, last_digest...}}`) and
  `State.pr_fixes` (`%{pr_url => %{attempts: %{kind => n}, in_flight: id | nil,
  last_fix_head_sha, exhausted: [kind]}}`). Guards (watch must exist, PR must
  be open, one fix in flight, attempt caps) read aggregate state, not the
  projection, so they survive restarts and version conflicts.
* **Terminal runs**: the allow-list is widened by exactly the new PR command
  types (below) and nothing else. Mutation check: deleting one type from the
  list makes the command fail with a `FunctionClauseError`-free
  `{:error, ...}` test (the list now has a catch-all that returns
  `{:error, {:run_terminal, status}}`, so an omission is a typed refusal
  instead of a crash).
* **Jobsite PRs**: unsupported in v1, honestly. A jobsite has no run stream, the
  jobsite door has no `gh pr create`, and a synthetic run would invent a second
  lifecycle. `run.pr.create` on a `jobsite:<id>` thread returns
  `{:error, {:unsupported_subject, :jobsite}}`. What a future change needs: a
  `jobsite.pr.associate` command emitting a `PrAssociated`-equivalent on the
  jobsite stream plus a `pr_watch` fold keyed `{jobsite, id}`; the PrWatcher
  record key already carries `run_id`, so it would become `subject_id`.
* **Multi-repo (E12)**: not built. One PR per run today; code reads
  `Map.get(payload, :repo_id)` and passes it through, never defaults it.

## Commands/events enumerated (names used by E9-S1..S6)

| Command (type) | Origin | Event on `run:<id>` |
|---|---|---|
| `run.pr.checks` | system (PrWatcher) | `PrChecksChanged` |
| `run.pr.review` | system (PrWatcher) | `PrReviewChanged` |
| `run.pr.fix_ci` / `run.pr.address_comments` / `run.pr.resolve_conflicts` | operator or system (auto-fix) | `PrFixRequested` |
| `run.pr.fix_started` | system (PrWatcher reactor) | `PrFixStarted` |
| `run.pr.fix_finished` | system (PrWatcher reactor) | `PrFixFinished` |
| `run.pr.fix_exhausted` | system (PrWatcher policy) | `PrFixExhausted` |
| `run.pr.watch_stop` | operator or system (PR merged/closed) | `PrWatchStopped` |
| `run.pr.watch_start` | operator or system (reopened) | `PrWatchStarted` |
| `run.pr.create` | operator (side effect before dispatch, like `run.pr.merge`) | `PrAssociated` on `pr_association:<run>` plus `PrCreated` on the run stream |
