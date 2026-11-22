# CodeRabbit review — task `beads:foreman:foreman-odxs7`

Phase 3 of run `run-e334fe4eda7d653789b3c8b5e5caa71f`. Review target: this run's
committed work (Phases 1 and 2). Nothing in this phase changed source code; the
single CodeRabbit finding was triaged and declined (see `Declined`).

## Review engine

- Engine: CodeRabbit CLI (`coderabbit`, `/Users/ldangelo/.local/bin/coderabbit`,
  v unknown — `coderabbit version` is not a supported subcommand), run locally
  against this worktree. No push was required.
- `FOREMAN_BASE_BRANCH` is set to `main` (non-empty), so the review base was
  `main`; no substitute base was used.
- Exact command (both successful rounds):

  ```
  coderabbit review --agent --base main --committed
  ```

  `--committed` restricts the review to the run's committed work (Phase 1 and 2
  artifacts), matching this phase's remit.

- Run 1 (detached so the CLI's own 2–15 minute budget is not cut short):
  `nohup env CODERABBIT_FORCE_COLOR=0 coderabbit review --agent --base main --committed > ~/.cr_review_odxs7.log 2>&1 &`
  → completed on its own, `{"type":"complete","status":"review_completed","findings":1,"outcome":"completed"}`.
- Run 2 (independent re-run, same command, exit code captured):
  `nohup bash -c 'coderabbit review --agent --base main --committed > ~/.cr_review_odxs7_r2.log 2>&1; echo "CODERABBIT_EXIT=$?" >> ~/.cr_review_odxs7_r2.log' &`
  → `CODERABBIT_EXIT=0`.
- Two earlier foreground attempts of `coderabbit review --agent --base main`
  were killed by my own shell timeout (exit 124) before the CLI's stated budget
  elapsed ("Reviews usually take 2-6 minutes and can take up to 15 minutes ...
  stopping it early discards review"). Those were harness timeouts, not engine
  or authentication failures: the same command completed twice with exit 0.
- Files the engine reported as reviewed:
  `docs/reports/foreman-beads:foreman:foreman-odxs7/FIX_REPORT.md`,
  `docs/reports/foreman-beads:foreman:foreman-odxs7/PLAN.md`,
  `packages/foreman_server/priv/defaults/workflows/fix.yaml`.
  The third file is unchanged in this run's diff — see `Declined` item 1.

## Rounds

### Round 1

- Findings received: 1 (major).
  - `packages/foreman_server/priv/defaults/workflows/fix.yaml:35` —
    "Do not dispatch `/enseble:merge-pr` from the `pr-review` phase."
    (The CLI returned this finding's comment body as an opaque `<<ccr:…>>`
    blob that could not be decoded; the title and the file/line were readable.)
- Fixed: 0. Declined: 1.

### Round 2 (re-run for reproducibility)

- Findings received: 1 (major), same file and line:
  `packages/foreman_server/priv/defaults/workflows/fix.yaml:35` —
  "Use a command name that `pi` resolves in the `pr-review` phase."
  Comment (decoded): the `pr-review` phase runs `/enseble:merge-pr --foreman`;
  the repository defines neither that command nor an alias for it; the
  neighbouring phase uses the `ensemble` namespace, so the `enseble` spelling
  is a likely typo; if `pi` cannot resolve the command the review phase fails
  and the default `fix` workflow cannot complete; the repository's own TRD
  completion report records this same command as nonexistent and says it caused
  test failures in an earlier revision; confirm the registered name of the
  merge-review skill in the installed `ensemble` catalog before changing the
  phase (the catalog is not in this repository, so the engine could not confirm
  whether `ensemble:merge-pr` exists).
- Fixed: 0. Declined: 1 (same finding, same triage).
- Stopped after round 2: the finding reproduced with identical file, line and
  severity, the reviewed file set did not change, and the triage cannot change
  between identical rounds — a third round would repeat the same review of the
  same three files.

## Fixed

None. No file in this run's diff needed a change: the one CodeRabbit finding is
declined below, and the task's own request targets code that does not exist on
this branch.

## Declined

### 1. `packages/foreman_server/priv/defaults/workflows/fix.yaml:35` (major, CodeRabbit)

**Finding.** The `pr-review` phase dispatches
`command: "/enseble:merge-pr --foreman"`. `/enseble` is not a registered
command in this repository (the sibling phase uses the `ensemble` namespace),
so `pi` cannot resolve the command and the phase cannot run.

**Reason: real defect, but not this run's work, and already repaired upstream.**

- `git diff --name-status main...HEAD` lists only
  `docs/reports/foreman-beads:foreman:foreman-odxs7/FIX_REPORT.md` and
  `docs/reports/foreman-beads:foreman:foreman-odxs7/PLAN.md` (both added).
  `fix.yaml` is byte-identical in `HEAD` and in `main`: the defect arrived with
  upstream commit `dd0c239b` ("[pi] Work in progress", 2025-11-08) and is
  inherited by this branch from `main`, not introduced here.
- Upstream already repaired it. Commit `51311def` ("fix(workflows): restore
  prompt-driven fix.yaml") restores the pre-`dd0c239b` prompt-driven workflow;
  that content is what `origin/main` carries (its last change to `fix.yaml` is
  `e89fa4da`, PR #920) and what the installed `~/.foreman/workflows/fix.yaml`
  already contains — the plan / fix / coderabbit-review / repo-rules-review
  prompt workflow with no merge-command phase. The run itself executed that
  installed, prompt-driven workflow, not the stale bundled copy on this branch.
- The remedy is **not** a namespace typo fix. Upstream's canonical repair
  removes the merge-capable command phase entirely, because the merge gate is
  operator-only (`merge_approve` / `run.pr.merge` are never exposed as an MCP
  tool or an agent path — AGENTS.md invariant, CLAUDE.md §26). Repointing the
  phase at `/ensemble:pr-merge` would introduce exactly the agent-executable
  merge path that invariant forbids.
- Fixing it here would also edit a file outside this run's diff and would
  conflict with the already-merged upstream restoration (AGENTS.md §4 surgical
  changes; §5.7 one boundary, one implementation).

### 2. Task request: single-writer guard in `packages/foreman_server/lib/foreman_server/overwatch.ex` (major, task)

**Finding.** `ensure_single_writer/1` (~:199), `live_workers_for/1` (:225),
`wait_for_worker_to_exit/2` (:205) and the helpers `inspect_run/1` and
`pids_live/1` are broken: with no live worker `live_workers_for/1` returns
`nil`, so `ensure_single_writer/1` returns `nil` and the
`with :ok <- ensure_single_writer(run_id)` in `start_phase/2` makes it return
`nil` instead of `{:ok, map}`; with a live worker `wait_for_worker_to_exit/2`
calls `Process.alive?/1` on a keyword list (ArgumentError) and the refusal
branch calls `Keyword.get(live, :run_id)` on a pid list, so
`{:error, {:worker_already_running, run_id}}` is never returned.

**Reason: the described code does not exist on this branch — stale here, and the
canonical implementation already exists elsewhere.**

- `packages/foreman_server/lib/foreman_server/overwatch.ex` is 209 lines with a
  single public function, `start_phase/2` at line 113. Grepping that file for
  `ensure_single_writer|live_workers_for|wait_for_worker_to_exit|pids_live|worker_already_running|await_run_workers_exit`
  finds no match, and `git diff main HEAD -- …/overwatch.ex` is empty.
  `start_phase/2`'s only `with` arm is `build_launch_env/2`, so neither
  symptom (a) nor (b) can occur on this tree.
- The broken code exists only in abandoned commit `b8cb4484` on branch
  `foreman/foreman-ws23g/run-2944c1407c448e4481b3017f8606ed76` (PR #922,
  CLOSED, not an ancestor of `main` or of this branch).
- The requested rewrite already exists correctly in commit `a01459d1` on branch
  `fix/worker-stop-single-writer` = PR #923 (OPEN, base `main`): `start_phase/2`
  gains the `with :ok <- ensure_single_writer(run_id),` arm,
  `ensure_single_writer/1` calls `WorkerSupervisor.await_run_workers_exit(run_id, @single_writer_wait_ms)`
  and returns `{:error, {:worker_already_running, run_id}}` on timeout after
  logging, and `WorkerSupervisor.await_run_workers_exit/2` is added there.
  Porting that into this branch would duplicate a boundary an open PR already
  owns (§5.7) and would also need `WorkerSupervisor.await_run_workers_exit/2`,
  which is likewise absent from `main`.
- Still needs a human: PR #923 requires operator review and merge.
  `gh pr view 923` reports `mergeable: "UNKNOWN"` (GitHub had not finished
  computing mergeability at check time). Phase 1's report recorded
  "MERGEABLE"; that claim is stale and is not reproduced here.
- Note: `ForemanServer.Operations.inspect_run/1`
  (`packages/foreman_server/lib/foreman_server/operations.ex:21`) is a real but
  unrelated public function reading `ProjectionStore.run/1`. The task's
  `inspect_run/1` overwatch helper does not exist.

## Verification

- `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test test/foreman_server/overwatch_test.exs test/foreman_server/overwatch/worker_supervisor_test.exs --warnings-as-errors'`
  → exit 0, `Result: 10 passed`. (Same command and result as Phase 1; the
  overwatch surface this run touched is green on this branch.)
- `git status --short` → clean before this report was written; this report is
  the only file this phase writes, and it is left uncommitted for Foreman.
- Formatter/linter: no Elixir source file was changed by this phase, so
  `mix format --check-formatted` has nothing to check; the only file written is
  this Markdown report.
- Documentation gate: no externally visible identifier (route, event type, MCP
  tool, CLI verb or flag, env var, config key, workflow/prompt name) was added,
  removed or renamed by this phase — it writes one Markdown report only.
  `CLAUDE.md`, `README.md`, `docs/user-guide.md` and `docs/cli-reference.md`
  therefore need no edits. The declined finding names a bundled workflow phase
  command, but no workflow file was changed, so no doc file describes it.
- Operator progress tools: `foreman_inbox_send` and
  `foreman_task_add_comment` are not exposed to this phase, so no progress
  notes were sent; this does not affect the review evidence above.

<!-- FOREMAN_REVIEW_FINDINGS_START -->
{"schema": "foreman.review_findings/1", "reviewed": true, "findings": [{"severity": "major", "path": "packages/foreman_server/priv/defaults/workflows/fix.yaml", "line": 35, "description": "The pr-review phase of the bundled fix workflow dispatches the unregistered command \"/enseble:merge-pr --foreman\"; the defect predates this run (it is identical in main and HEAD, was introduced upstream by dd0c239b, and upstream already restored the prompt-driven workflow in 51311def / origin/main e89fa4da), and the operator-only merge-gate invariant forbids replacing it with an agent-runnable merge command.", "disposition": "declined", "source": "coderabbit"}, {"severity": "major", "path": "packages/foreman_server/lib/foreman_server/overwatch.ex", "line": null, "description": "The reported broken single-writer guard (ensure_single_writer/1, live_workers_for/1, wait_for_worker_to_exit/2) does not exist on this branch, so there is nothing here to rewrite; the canonical implementation is open PR #923 (fix/worker-stop-single-writer, a01459d1), which still needs operator review and merge.", "disposition": "declined", "source": "task"}]}
<!-- FOREMAN_REVIEW_FINDINGS_END -->

<!-- FOREMAN_RISK_JUDGEMENT_START -->
{"schema": "foreman.risk_judgement/1", "level": "LOW", "rationale": "This run's whole change is two Markdown reports (PLAN.md, FIX_REPORT.md) in docs/reports; no runtime code, config, route or CLI surface changed, and the overwatch surface it names is green (10 passed, exit 0). The requested single-writer guard is absent from this branch and already implemented in open PR #923, so the residual risk is the operator merge of that PR, not this diff."}
<!-- FOREMAN_RISK_JUDGEMENT_END -->
