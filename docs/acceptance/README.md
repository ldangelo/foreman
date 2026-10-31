# Claude Projects acceptance: how to run it and what the evidence says

This is the how-to-run document for the live acceptance of the Claude Projects feature set (bead `foreman-nb8w2.9.4`, epic E16-S8).
The verdict per capability (C1-C13) is in [`parity-audit.md`](parity-audit.md); the older narrative audit is
[`../audit/claude-projects-parity-audit.md`](../audit/claude-projects-parity-audit.md). Nothing here is run by CI (CI runs
`mix test`, `mix doctor`, `mix format --check-formatted` and the Go checks); these scripts and write-ups are the live evidence
that CI cannot give.

## Evidence in this directory

| File | What it proves |
|---|---|
| `claude-projects-live-run.md` | First manual end-to-end run on pi with a faked `gh`: instructions, memory, library, parallel threads, steer, stop, resolve, Overview groups, pause/resume, webhook notifications, review verdict, usage. Findings F1-F10 and their fixes. |
| `claude-projects-acceptance-2026-10-22.md` | The scripted flow (`claude_projects_flow.sh`, 7 stages) plus the failure injection table (`failure_injection.sh`), transcript and defects filed as beads. |
| `three-task-overlap-live-run.md` | Step 5b of the flow: three tasks pasted in one coordinator message, three threads, the printed `RunStarted`/terminal intervals and the overlap assertion (PASS at cap 3; FAIL when the project is forced to one run at a time). |
| `github-live-run.md` | Stage 8 on a real private GitHub repo: PR created by a run, checks, a real webhook through a `cloudflared` tunnel, Fix CI, Address comments, Resolve conflicts, force-push, check re-run, operator merge (36 PASS). Branch protection was UNVERIFIED there (HTTP 403 on that plan); see `live-github-branch-protection.md`. |
| `combined-flow-live-run.md` | The whole flow in one stack with the GitHub stage on (`E2E_GH_THREE_PRS=1`): three tasks in one coordinator message, three overlapping runs, each opening its own real PR, a failing check on one, Waiting on you, Fix CI, Ready for review, operator `approve-merge` + `merge` to Resolved, usage per thread, then the failure-injection pass. One FAIL: no `PR ready for review` notification on the auto-PR path (`foreman-ehz7l`). |
| `live-github-protection-ui-autofix.md` + `live-github-ui-*.png` | The workspace Fix CI, Address comments, Resolve conflicts and Create PR buttons clicked on real PRs, `pr_auto_fix` off, on and bounded, a push after merge approval (observed on the build before #650), GitHub's refusal text for an operator merge, and the Create PR merge-gate defect found and fixed there (`foreman-ksy0q`). Merge under branch protection was UNVERIFIED there; see the next row. |
| `live-github-branch-protection.md` | Operator merge under REAL branch protection (`github_live_extras.sh stage protection`, `foreman-ksy0q`): a required review, a required status check (absent, failing) and a squash-forbidding repository each refused the merge with GitHub's text reaching the operator verbatim, the PR stayed open and the gate approved, and the same approval and head pin merged once every rule was met (the squash results had one parent; a refusal by `required_linear_history` itself was not tested). The repository was public for two short windows (38 s, 94 s) after the whole-history content scan of the time (every branch and PR ref; the account's own public profile identity allowed in commit identity fields); the visibility-lock defect found live. **Not part of that live scan**, added afterwards and proved on a local history only (`claude_projects/github_scan_proof.sh`, 61 expectations) and read-only on the archived repository: binary-blob rejection, fetching tags and every other ref class, annotated tag messages and taggers, refs that are not commits. |
| `live-claude-prfix-resume.md` | The PR fix thread of a REAL claude run resumes that run's claude session, on a real private GitHub PR (`github_live_extras.sh stage claude_fix_ci`, `foreman-nufr9`): `PrFixStarted.resumed_session`, the fix jobsite's `resumed_session_id`, the head moved and CI green, claude's own transcript of the session grew with no new session. The first run resumed but could not fix anything (the fix agent had no approval mode, so the resumed claude was refused its first `Edit`/`Bash`); root cause, fix with tests, then 31 PASS twice. |
| `parity-gaps-live-run.md` | Live proof of the parity-gap beads with real `claude` (haiku) and pi: claude coordinator and thread, project env and secrets on both doors, setup script, docker network shim, schedules, adopt (move, mint, continue), recommend, per-thread usage, multi-repo self-add and fanout. |
| `multi-repo-agent-live-run.md` | A real claude (haiku) and a real pi calling Foreman's own `/mcp` on a harness-booted server: per-phase repository selection, an agent adding a registered and an unregistered repository to its own run (`foreman_run_request_repo`), `FOREMAN_REPOS` as each phase's agent saw it, agent-driven `foreman_task_fanout` and its approved single-repository runs, and the typed refusal of a multi-repo jobsite (`multi_repo_agent.sh`, passed=52 failed=0 on each). Root cause and fix of `foreman-cnn1l` (`/mcp` answered HTTP 500 off `mix phx.server`). |
| `live-steering-live-run.md` | Live in-session steering for claude and pi, the pause/resume fallback, `RunSteerUndelivered` on cancel. |
| `inflight-approvals-live-run.md` | Per-call approvals for claude (`--permission-prompt-tool`): approve from the CLI, deny from the workspace UI, timeout deny. |
| `pr-actions-live-view.md` + `02-` to `08-*.png` | Workspace PR action buttons in headless Chromium, and the Overview/Settings/Library screenshots. |
| `review-claude-reviewer-live-run.md`, `review-gap-beads-live-run.md`, `review-gap-guard-retest.md`, `review-jobsite-live-run.md` | Archive plus auto-review on both doors, with a claude and a pi reviewer, gap beads and the depth-1 loop guard against a real `br`. |
| `coordinator-crash-turn-fence-live-run.md` | The coordinator turn fence (`foreman-42t7a`): deterministic test plus three clean live runs. |
| `claude-phase-model-pin-live-run.md` | A `provider: claude` phase pins a bare model; a slashed value is refused at manifest load. |
| `e2e-live-verify-2026-10-30.md` | Three new live scripts on a real throwaway server (pi only): `project_archive_flow.sh` (project archive, reactivate and delete: a workflow run in flight blocks the archive, a running jobsite does not; nothing is purged; passed=55 failed=0 unverified=0; a first run's transient failure at kickoff is recorded), `mcp_schedule_update.sh` (MCP `foreman_schedule_update` over `/mcp`: write-gated like `foreman_schedule_create`, typed errors; passed=84 failed=0 unverified=0; the `question.answer` half of `foreman-7c191` not run) and `redaction_value_live.sh` (a stored secret with a non-secret name redacted by value from agent-written memory, chat, project context and hand edits, byte-searched in the event store, the whole database and the work dir: passed=62 failed=2 unverified=1; the 22-character value reached the server log, `foreman-mw5rz`, open). |
| `coordinator-live-actions-live-run.md` | `coordinator_live_actions.sh` with a real claude (haiku) coordinator (31 assertions pass): setup proposal without a model turn, `apply N` for an applicable fix (and honest refusal for the manual AGENTS.md item), `add_repo` and `schedule` operator-grade actions, the machine-turn and sub-300 s refusals, coordinator usage equal to the recorded events. pi/minimax, invented quote and null cost UNVERIFIED. |
| `notifier-live-negative-run.md` | `notifier_live_negative.sh` (C12, `foreman-mivo7`, no model): the REAL Telegram and Slack hosts with deliberately FAKE credentials. A forced `RunFailed` (a `broken-model` run, preflight failure) is delivered to each host, which answers 401 (`telegram_http_401`) and 404 `no_team` (`slack_http_404`), recorded as one non-retryable `NotificationDeliveryFailed` each; the fake token, chat id and webhook URL have 0 hits in the events table, a whole-database dump, the server logs, the work dir and `/api/doctor`; the doctor row names the provider and no destination; a half-set Telegram pair and a provider mix abort boot naming the variables only. passed=82 failed=0 unverified=0. **Proves no delivery**: the happy path needs the owner's real credentials and stays open. |
| `parity-audit.md` | The C1-C13 verdicts, the residual gaps with bead ids and the closed-bead cross-check. |

Related evidence outside this directory: `docs/lessons/multi-repo-e2e-2026-10-21.md` (`scripts/e2e/multi_repo.sh`, 110
assertions on pi with a fake `gh`) and `docs/lessons/ui-a11y-report-2026-10-22.md` (axe, keyboard order, idle traffic).

## Prerequisites

- Run from a checkout of `foreman` inside `devbox run --` so the pinned Elixir, `mix`, `go`, `git`, `jq`, `curl`, `psql`,
  `python3`, `br` (beads_rust) and `pi` are on `PATH`. The scripts check the environment first and exit 1 when something is missing.
- Postgres reachable at `localhost:55432` (user and password `postgres`; override with `E2E_PG_HOST`, `E2E_PG_PORT`,
  `E2E_PG_USER`, `E2E_PG_PASSWORD`). The harness creates its own database and drops it when it finishes.
- A real `pi` with credentials for `minimax/MiniMax-M2.7-highspeed` (`E2E_MODEL` overrides). For anything that needs the `claude`
  CLI, run the server with a redirected `HOME` that symlinks `~/.claude`, `~/.claude.json` and `~/Library/Keychains`.
- Stage 8 only: an authenticated `gh` (scopes `repo`, `workflow`), `cloudflared`, and an existing private scratch repository
  named `<owner>/foreman-scratch-<suffix>` seeded from `scripts/e2e/claude_projects/github-fixture/`. The harness never creates
  a GitHub repository: `E2E_GITHUB=1` is refused.
- Never point `E2E_WORK_DIR` at `/tmp`, `/private/tmp` or `/var/folders`; the harness refuses them. The default is
  `<checkout>/tmp/e2e-claude-projects-<name>`.

## Run the flow (stages 1-7, optional stage 8)

```
devbox run -- bash scripts/e2e/claude_projects_flow.sh
```

It starts its own server (own port, own database, own scratch repo, own `br` database) and drives the real Go CLI and HTTP API:
project, goal and instructions, memory, library, a thread started from a bead, the thread seeing instructions, memory and library,
steer a running thread, stop one, resolve one, Overview groups, coordinator chat, three tasks pasted in one message that must run in
parallel (step 5b), approvals and questions surfaces, notifications reaching a local webhook sink, and the review archive and
verdict (seven archive files, verdict, comment on the bead). Nothing is pushed anywhere but a local bare origin.

Stage 8 (real GitHub) is opt-in:

```
FOREMAN_E2E_GITHUB_REPO=<owner>/foreman-scratch-<suffix> devbox run -- bash scripts/e2e/claude_projects_flow.sh
FOREMAN_E2E_GITHUB_REPO=<owner>/foreman-scratch-<suffix> E2E_GH_ONLY=1 devbox run -- bash scripts/e2e/claude_projects_flow.sh
```

Unset, the stage prints an explicit SKIP and counts as UNVERIFIED. `E2E_GH_ONLY=1` runs only setup plus stage 8. `E2E_GH_TUNNEL=0`
and `E2E_GH_STAGE_TIMEOUT` tune the tunnel and the stage timeout; `scripts/e2e/claude_projects/github.sh` is the stage's source.
`E2E_GH_THREE_PRS=1` runs the combined flow instead of the single-PR stage: one coordinator message starts three threads that each
open a real PR, one PR gets the injected CI failure and the Fix CI / approve-merge / merge path, and the notification sink and usage per thread are
asserted (address comments, conflicts and force-push are then recorded UNVERIFIED; run without the flag for those).

Step 5b is the parallelism proof: one coordinator message pastes a to-do list of three distinct small tasks, the step asserts the
coordinator started exactly three threads (distinct titles), each delivered its file on its branch, and then reads `RunStarted` and the
first terminal event of each thread's run from the event store (`claude_projects/run_interval.exs`, via the server node) and asserts
that at least two intervals overlap (`start_i < finish_j and start_j < finish_i`) and that the project cap was respected. It prints the
intervals. Each file is read from the branch the thread projection names (`await_thread_file` in `claude_projects/overlap.sh`): while
it is unreadable the read is repeated for up to 30 s, a file that only appears after waiting is recorded UNVERIFIED (a commit landing
after `completed` is a server defect the wait must not hide), and an unconfirmed file prints the `foreman-2onq1` diagnostics: git's own
error, the thread projection, the branch tip, its commits ahead of the main checkout and its files, the foreman branches, the main
checkout's status, where the file is on disk, the task prompt, what the agent said and the run's commit lines of the server log.
Parallelism needs a project `max_concurrent_runs` and a global RunSlots `max_concurrent_runs` of at least 3 (the flow sets
the project to 3 in step 1; the global default is 3) and no `coordinator_max_active_threads` below 3 (unset). The assertion can fail:
`bash scripts/e2e/claude_projects/overlap.sh` runs its stack-free self-test (serial, touching, overlapping and unfinished intervals, the
exact-file-content comparison, the paste/nudge branch against a stubbed coordinator, and the branch read against a throwaway repository
and a stubbed thread projection: exact, wrong, missing, no branch, late; `sh scripts/e2e/exact_content.sh` runs the
comparison probes alone),
`E2E_THREE_ONLY=1` runs only setup, step 1 and step 5b, and `E2E_THREE_TASK_MAX_RUNS=1` forces one run at a time for that step,
which must (and does) make the overlap assertion FAIL.

Environment (all optional): `E2E_MODEL`, `E2E_WORK_DIR`, `E2E_DB_NAME` (lower case letters, digits, underscore), `E2E_PORT`,
`E2E_HOOK_PORT`, `E2E_API_TOKEN`, `E2E_RUN_TIMEOUT` (seconds, default 600), `E2E_POLL_SECS`, `E2E_REVIEW=0` (skip the review archive
step), `E2E_TRANSCRIPT=<file>` (tee every line), `E2E_KEEP=1` (keep the server, database and work dir for a post-mortem; then
drop the database yourself with `DROP DATABASE IF EXISTS <name> WITH (FORCE)`), `E2E_FIRST_THREAD_ONLY=1` (setup and steps 1-3
only, about 30 s: the loop for the intermittent first-thread failure of `foreman-azc2o`), `E2E_FAILED_GRACE` (seconds, default 20: a
thread that sits in `failed` or `cancelled` ends the wait for another status after that long instead of after `E2E_RUN_TIMEOUT`),
`E2E_EVIDENCE_DIR` (default `<checkout>/tmp/e2e-evidence`) and `E2E_EVIDENCE` (`1` default, `always`, `0`).

A run that exits non-zero or fails an assertion keeps its evidence BEFORE the stack is torn down, because the work dir is removed and the
database dropped at exit: in `E2E_EVIDENCE_DIR/<name>-<UTC start time>-<pid>/`, start with `summary.txt` (the failed assertions, every run that
did not complete with its `failure_reason`, the failure events, the server log's errors), then `api/` (the project, threads, Overview, runs and each
thread's projection, transcript and task), `events.jsonl` (every event of the event store, decoded; `jq -c 'select(.stream | contains("<run id>"))'`
is one run's), `server.log`, `agent-sessions/` (pi's own session files), `run-artifacts/`, `worktrees/`, `repo-beads/`, `repo.bundle` (every ref of the scratch repository: `git clone repo.bundle`), `environment.txt`,
`processes.txt` and `database.dump` (`pg_restore` it into any Postgres). A passing run keeps nothing; `E2E_EVIDENCE=always` keeps it anyway
(to compare a failing run with a passing one) and `E2E_EVIDENCE=0` switches it off. To hunt an intermittent failure of the first thread:
`for i in $(seq 20); do E2E_FIRST_THREAD_ONLY=1 devbox run -- bash scripts/e2e/claude_projects_flow.sh || break; done` (one stack at a time).

## Run the failure injection

```
devbox run -- bash scripts/e2e/failure_injection.sh                    # every scenario
devbox run -- bash scripts/e2e/failure_injection.sh coordinator-crash  # one or more by name
```

Each scenario injects one real failure into a real throwaway server and asserts the typed failure and the recovery. The scenarios the
acceptance documents report are `provider-down`, `agent-crash`, `coordinator-crash`, `server-crash`, `port-closed`, `br-down` and
`project-paused`; the header of the script is the authoritative list and says what each expects. Every assertion prints `EXPECTED`
against `ACTUAL`. It takes the same environment variables as the flow (`E2E_WORK_DIR`, `E2E_DB_NAME`, `E2E_PORT`, `E2E_KEEP`, ...).
The review analyzer runs as usual and is not asserted here.

## Other scripts

- `scripts/e2e/multi_repo.sh` (POSIX `sh`): the two-repository proof, stages `gate green gates failure legacy`, provider via
  `E2E_PROVIDER`, pi isolation via `E2E_PI_ISOLATE`, own database `foreman_e2e_multi_repo`. Run it as
  `devbox run -- sh scripts/e2e/multi_repo.sh [stage ...]`. Write-up: `docs/lessons/multi-repo-e2e-2026-10-21.md`.
- `scripts/e2e/multi_repo_agent.sh` (bash): the same multi-repository paths with a REAL agent reaching Foreman through `/mcp`, stages
  `phases fanout jobsite`, `E2E_PROVIDER=claude` (default, haiku) or `pi`, own database `foreman_e2e_multi_repo_agent`. Run it as
  `devbox run -- bash scripts/e2e/multi_repo_agent.sh`. Write-up: `multi-repo-agent-live-run.md`.
- `scripts/e2e/project_archive_flow.sh` (bash; `pi` with working credentials; own database `foreman_e2e_claude_projects_parch`, ports 4880/4980; shim `project_archive/pi-held.sh`): `project delete` (archive) with a real workflow run in flight (refused 409 `project_has_active_runs`), after the run ends (accepted, hidden from the list, new work refused `project_archived`, nothing purged, `reactivate`) and with a running jobsite (accepted, the jobsite keeps running, new jobsites refused `spec_project_unavailable`). Run it as `devbox run -- bash scripts/e2e/project_archive_flow.sh`. Write-up: `e2e-live-verify-2026-10-30.md`.
- `scripts/e2e/mcp_schedule_update.sh` (bash; no model; own database `foreman_e2e_claude_projects_mcpsched`, ports 4890/4990): MCP `foreman_schedule_update` through plain JSON-RPC over `/mcp` against the real CLI and projection (write-tool gating, update results, typed errors). Run it as `devbox run -- bash scripts/e2e/mcp_schedule_update.sh`. Write-up: `e2e-live-verify-2026-10-30.md`.
- `scripts/e2e/redaction_value_live.sh` (bash; pi only, `E2E_PROVIDER=claude` is refused; needs `psql` and `pg_dump`; own database `foreman_e2e_redaction_value`, ports 4840/4940; `E2E_AGENT_ATTEMPTS` default 2): value-based redaction end to end with a real pi agent and coordinator and a byte search of every durable surface before cleanup. Run it as `devbox run -- bash scripts/e2e/redaction_value_live.sh`; it currently exits 3 on the server-log leak `foreman-mw5rz`. Write-up: `e2e-live-verify-2026-10-30.md`.
- `scripts/e2e/notifier_live_negative.sh` (bash; no model; needs outbound HTTPS to `api.telegram.org` and `hooks.slack.com`, `psql`, `pg_dump`; own database `foreman_e2e_notifier_live_negative`, ports 4860/4960): the C12 live NEGATIVE path with fake credentials against the real Telegram and Slack hosts (status classification, redaction on every durable surface, doctor row, boot refusals). It never delivers a message. Run it as `devbox run -- bash scripts/e2e/notifier_live_negative.sh`. Write-up: `notifier-live-negative-run.md`.
- `scripts/e2e/github_live_extras.sh` (bash): the real-GitHub stages beyond stage 8 of the flow, over an existing PRIVATE
  `<owner>/foreman-scratch-<suffix>` repository (`FOREMAN_E2E_GITHUB_REPO`), modes `all | serve | stage <name>... | stop`; stages
  `pr_a ui_baseline policy_off_and_fix_ci ui_address ui_conflicts claude_fix_ci autofix createpr postapproval merge_refusal prot_prepare
  protection` (plus the read-only `safety`). `claude_fix_ci` runs a REAL claude (haiku, through a private `HOME`; `UNVERIFIED` without a
  logged-in claude): `serve` once, then `stage claude_fix_ci` (about 2 minutes). `protection` runs only with `E2E_GH_ALLOW_PUBLIC=1`: it makes the
  repository public for about two minutes after the `safety` scan passes and private again (GitHub locks the repository for a few seconds after each visibility
  change: the harness retries those refusals for up to `E2E_GH_LOCK_SECS`, default 240, and a `stage` process unwinds the window when it exits). Write-ups:
  `live-github-protection-ui-autofix.md`, `live-claude-prfix-resume.md`, `live-github-branch-protection.md`.
- `scripts/e2e/claude_projects/github_scan_proof.sh` (bash; git, jq, a logged-in `gh`; no devbox, no GitHub write): the mutation proof of the `safety` scan, run on a
  local history whose operator clone is made before anything is planted: the scan must pass the clean history and fail a planted token, foreign identity, local path, binary blob
  (a NUL byte anywhere, also one reachable only from `refs/pull/*`), a commit reachable only from a tag or from another ref class, an annotated tag (message, tagger), a tag that
  points at a blob and the other classes; it also checks the identity allowlist line by line, the derivation of the account identity and `gh_retry_locked`. Nothing in it reads the
  operator's git configuration, and it fails (rather than shrinks) when the number of expectations differs from `PROOF_EXPECTED`. Exit 0 = `expectations held: 61, broken: 0 (documented: 61)`.
- `scripts/e2e/ui-a11y/ui_a11y.mjs`: axe-core and keyboard-order checks of the workspace and settings pages plus idle LiveView traffic
  (needs the packages in `scripts/e2e/ui-a11y/package.json` installed and a browser for Playwright). Flags `--base`, `--token`,
  `--project`, `--idle-seconds`, `--max-idle-frames`, `--report`; environment `FOREMAN_UI_BASE`, `FOREMAN_API_TOKEN`,
  `FOREMAN_UI_PROJECT`. Exits 0 only when no un-deferred violation remains.
- `scripts/e2e/acceptance-start-server.sh`, `acceptance-webhook-listener.py`, `fake-gh-for-acceptance.py`: the server start,
  webhook sink and fake `gh` helpers used by the first manual run (`claude-projects-live-run.md`).

## Reading the result

Every step prints `PASS`, `FAIL` or `UNVERIFIED` (a thing this host cannot exercise, for example pi has no tool-permission
mechanism so no approval can be raised). The final line counts them. Exit status: `0` all passed, `1` environment problem, `2` setup
failed, `3` one or more assertions failed. A run that ends in `1` or `2` proved nothing about the product.

## Adding evidence

A new write-up in this directory states: the environment (worktree and commit, port, private database, provider and model, whether
`HOME` was redirected), the exact commands, the transcript lines, expected against actual, and what was **not** exercised, labelled
`UNVERIFIED`. A defect found by the run is filed as a bead (`br create`, label `parity-gap` or `bug`, never `foreman-exec`, so the
watcher does not dispatch it) and cited by id. The run cleans up only what it started: its own PIDs, port, scratch directory and
database.

## Known limitations (from the audit)

Details and bead ids are in [`parity-audit.md`](parity-audit.md).

- The merged flow and failure-injection scripts, including the `cancel-strays` and `shutdown-strays` scenarios, ran green once on the
  fix for `foreman-zmhzw`: see [`p2m2t-live-run.md`](p2m2t-live-run.md) (`foreman-p2m2t`).
- The combined flow (three tasks, three PRs, CI failure and fix, merge, usage, failure injection) was run once in one stack: see
  [`combined-flow-live-run.md`](combined-flow-live-run.md). It found that no `PR ready for review` notification reaches the sink when a run opens
  its PR itself (`foreman-ehz7l`); the `port-closed` orphan assertion is now conditional like `server-crash` (an agent that dies with its exec-port leaves nothing to reap, reported UNVERIFIED; `foreman-e01a1`); `cancel-strays` and `shutdown-strays` cover the `OrphanReaper` sweep after cancel, thread stop and graceful shutdown (`foreman-zmhzw`) and `br-down`
  failed once and passed on re-run (`foreman-3ll3t`, root cause and fix: `foreman-w29up`, below).
- pi on MiniMax carries almost all of the evidence; `claude` is proven for short haiku sessions (coordinator, thread, reviewer,
  in-flight approvals, steering, a PR fix thread resuming its run's session, `live-claude-prfix-resume.md`). A fix thread of a `prompt`-mode claude phase, a docker-sandbox fix thread and models other than haiku stay unrun.
- GitHub is proven on a real private repo, including merge under real branch protection (a required review and a required status check; the squash results had one parent, but a refusal by `required_linear_history` itself was not tested; in a temporary
  public window of a scratch repository after a content scan of every branch and PR ref: `live-github-branch-protection.md`, `foreman-ksy0q`). A push after merge approval stranded the PR on the build before #650 (observed live); #650 now voids the approval and holds the gate again (`foreman-ehxy6`), covered by tests and not re-run live.
- Telegram and Slack were never run against the real APIs with real credentials; the happy path is deferred by the user (`foreman-mivo7`). Only the signed webhook is live-verified for delivery. The negative path (fake credentials, real hosts: 401 / 404, redaction, boot refusals) was run live 2026-10-30, `notifier-live-negative-run.md`; it proves no delivery.
- Seen live 2026-10-25 (`foreman-8vf0s`, `p2m2t-live-run.md`): blocking inside a real container (allowlist and none, simulated pi actor) and the Scheduled tab. Project archive, reactivate and delete were seen live 2026-10-30 (`e2e-live-verify-2026-10-30.md`: refused while a workflow run is in flight, accepted while a jobsite runs, nothing purged; only a multi-iteration jobsite inside an archived project is not seen, `foreman-7p068`). Restart while a call
  is blocked is only PARTIAL (a stale pre-restart request stays actionable, `foreman-u0646`). The in-flight approvals UI Approve and Deny,
  stop while blocked, the approval timeout and a block longer than 60 s were verified live on claude (#654,
  `live-claude-and-approvals.md`); the 30 min default timeout was not waited.
- `claude_projects_flow.sh` has a schedule step (step 8, quick mode `E2E_SCHEDULE_ONLY=1`, `foreman-q9zzo`); the Scheduled tab has its own `scheduled_tab_flow.sh`.
- Run live 2026-10-30 (`e2e-live-verify-2026-10-30.md`, pi only): project archive, reactivate and delete (`foreman-5fqso`, closed; `project_archive_flow.sh` passed=55 failed=0 unverified=0), MCP `foreman_schedule_update` over `/mcp` (`mcp_schedule_update.sh` passed=84 failed=0 unverified=0; the `question.answer` boundary through a real run is not run, `foreman-7c191` stays open) and value-based redaction (`redaction_value_live.sh` passed=62 failed=2 unverified=1): a 22-character secret with a non-secret name was redacted from agent-written memory, chat, project context and a hand edit, and found 0 times in the event store, a whole-database dump, memory, the run archive and the webhook capture, but it IS in the server log, in debug `Parameters:` lines of the MCP call and the chat request (`foreman-mw5rz`, open), and in the `jido_harness` cache (`foreman-4ohex`, INFO). Not covered: the claude provider, a coordinator reply that echoes the value, a re-sweep after `foreman-mw5rz` (`foreman-ngky4` stays open).
- Multi-repo on real GitHub was not exercised (`foreman-he4yf`, closed); multi-repo was proven with a fake `gh`, with pi and with a real claude.
- Not built: running a thread on the user's own machine (C13, `foreman-zn7de`, deferred by the user).
- Forked-session continue (`project adopt --continue --fork`), the new worktree cut from the source session's branch (`--from-source-branch`) and the `--add-repo` move (`foreman-kgqqz`) were run live with real claude: `scripts/e2e/fork_live.sh`
  passed=48 failed=0 (`p2m2t-live-run.md`, section "Forked continue").
- Fixed on branch `foreman/parity-gaps`, tested but not run against a live provider: first-turn setup proposal and `apply_recommendation`
  (`foreman-4orxm`), coordinator `add_repo` and `schedule` actions (`foreman-tdjj8`) and usage recording (`foreman-ba4y4`), PR-ready and
  blocked/stuck notifications with webhook URL safety (`foreman-ehz7l`, `foreman-ireii`), expiry of orphaned in-flight approvals
  (`foreman-u0646`), the claude permission-flag probe (`foreman-dc618`), session recording so a jobsite resume never runs blank
  (`foreman-cm8nv`, open until a live resume proves it), UTC-rollover re-admission (`foreman-7wsyx`), the `/dashboard/runs` layout
  (`foreman-70eq6`) and the bundled `fix` prompt (`foreman-nhe4v`).
- Fixed on branch `foreman/parity-gaps`, unit/HTTP/Go tests only (not run against a live provider): the residual CodeRabbit findings of #573/#577/#579/#583 (`foreman-3xrtg`: memory error classifier and `forget/2` order, MCP project-memory argument types, overview batching, `truncated` and duplicate-tab refusal, one command allowlist, typed MCP schedule results, `schedule create --idempotency-key`, ticker exactly-once recovery), the test-hygiene negative waits and wildcard refutes (`foreman-bsp5f`), the S4/S5 spike review items (`foreman-i97tz`, the S5 items are design text because no remote-worker code exists) and the test event store emptied before the app boots (`foreman-a4ec2`, the `test` alias in `mix.exs`).
- Fixed on branch `foreman/parity-gaps`, unit/HTTP/Go tests only (not run against a live provider): the remaining CodeRabbit findings of #586/#587/#589/#591/#592 (`foreman-27ayh`: library projection and audit author, upload cap in `limits` and the CLI pre-check, notifier unknown project, empty `key_fields` and one payload key convention, approvals/questions deliverer recovery and typed listings, one `needs_you_counts/1` read, `ProjectSettings`/`Workspace.Refresh` key conventions, `retry-pr` surplus arguments, PrFix/PrMonitor/`Worktree.attach` residuals); the Claude post-hoc approval stays a documented phase-wide grant.
- Fixed on branch `foreman/parity-gaps`, found by the automated-test gaps of `foreman-q9zzo` (unit/LiveView/HTTP tests, not run against a live provider; the redaction items were later run live, see the 2026-10-30 bullet below): `ProjectContext` caps and budget count characters like the settings limits (the config key is `max_chars`), secret-store values with a non-secret name are redacted from the standing context, `Catalog` keeps a workflow's `operator_timeout_ms`, and the dashboard words an archive refused for active runs. Flow step 6 now asserts a `run_update` delivery for the first thread's run (`claude_projects/notifications.sh`, with a stack-free self-test); in the full flow it passed live in two of three runs, and in the third the webhook sink received no request at all (cause not established, `p2m2t-live-run.md`). The live schedule step (C9) exists: `claude_projects_flow.sh` step 8, quick mode `E2E_SCHEDULE_ONLY=1` passed=32 failed=0 (the UTC-only 422 through the CLI, the Ticker fires an every-minute cron, pause/resume/delete); see `p2m2t-live-run.md` for the full-flow runs.
- Fixed on branch `foreman/parity-gaps` AND driven in real Chromium against the e2e stack (`foreman-8ervf`): the project settings page edits plain environment variables (`project.environment.set`; a secret-looking name is refused and the value box is cleared) and write-only secrets (`ProjectSecrets`; the value is never in the page, the event store or the server log, only in the 0600 store file), and the Library tab adds a folder or files, replaces an entry, lists its files and downloads one byte-identical, with the 100-file, per-folder and 512 MiB limits enforced for socket uploads. The browser tool's directory upload registered once per tab, so the folder replace was run in a fresh tab.
- Fixed on branch `foreman/parity-gaps` AND run live with real claude: the workspace answers agent questions (`foreman-exofh`, a "Questions
  for you" pane with an answer box, the operator `question.answer` command). The answer typed in a real browser
  (`scripts/e2e/live_claude/questions_ui.mjs`) reached the running claude session and the agent acted on it; evidence in
  `live-claude-and-approvals.md`, section "foreman-exofh: operator questions in the workspace". pi never raises approvals or questions
  (it has no per-tool permission prompts).
- Fixed on branch `foreman/parity-gaps` AND measured on the real coordinator (pi/MiniMax, `foreman-ig27o`, flow step 5b): a three-item paste started no thread when the
  model's `start_thread` actions named neither `workflow` nor `task_type`. The action schema marks both optional but `WorkflowSelector`
  refuses an action with neither, so all three were rejected with `no workflow could be chosen` (captured in a live flow run: turn log
  `start_thread=rejected (...)` three times, no thread, the nudge paste then started three). A probe that builds the coordinator's context with
  `Context.build/2` and calls `Agent.Harness.turn/2` on a live node answered a lone paste with no selector in 7 of 88 samples (8%, all with
  `workflow` and `task_type` absent where printed); a paste coalesced with queued review reports was handled as well as a lone one (35 of 36
  started three threads). The coordinator prompt now says a thread needs `workflow` or `task_type` (at least one) and each WORKFLOWS line
  lists the task types that resolve to it (`Sources.Live.workflows/0` from `Catalog.type_to_workflow_map/0`); 0 of 40 samples lacked a
  selector afterwards. Tests: `thread_workflow_contract_test.exs`, `context_test.exs`. `foreman-2onq1` (no file on three branches, once) did
  not recur and stays open: of 15 ad-hoc runs whose brief names the primary checkout's absolute path, 14 wrote and committed in their own
  worktree and the 15th wrote its file there too but its pi agent hung before finishing; none wrote into the main checkout.
- Fixed on branch `foreman/parity-gaps` AND run live (`foreman-w29up`, root cause of `foreman-3ll3t`): a server killed or shut down
  inside a `br` call strands that call's `BeadsDbLease` hold, and the restarted `BeadsWatcher` skipped every read cycle
  (`lease_acquire failed reason=:lease_timeout`) so no bead was imported. Holds taken for one call now carry the server incarnation
  (`ForemanServer.Incarnation`): the next server takes them over at once and boot reconciliation releases them (it now lists every
  lease stream in the event store). Live evidence: a two-VM run with a real SIGKILL inside the call failed before the fix
  (`{:error, :lease_timeout}` after 5151 ms, hold left by boot reconciliation) and passed after (read in 46 ms, hold released), and
  `scripts/e2e/failure_injection.sh` (all nine scenarios) ran three times on the fix, each `passed=45 failed=0 unverified=2`. A
  process killed inside a live server (same incarnation) keeps its hold until the next restart.
- Fixed on branch `foreman/parity-gaps` AND run live on a real docker host (OrbStack, docker 29.8.2; `foreman-q8ufk`, `foreman-mr5b1`, found by
  `scripts/e2e/network_policy_flow.sh crash` and `hook-env`): a `kill -9` with an allowlist jobsite in flight left the policy network and the
  sandbox container up (the boot sweep removed only the sidecar, by name, and was host-global: another server booting on the same docker
  host removed live sidecars), and sandbox hooks and `docker exec` ran without the policy's proxy variables, so a hook could not reach an
  allowed host (`curl: (6) Could not resolve host`, `hook_failed`). Everything a policy creates or governs is now labelled `foreman.owner`
  (digest of the event store's host/port/database) and `foreman.jobsite`; the cleanup and `NetworkPolicy.sweep_orphans/1` find objects by
  label only and remove containers before the network; the sandbox's `:env` is the container's own environment (`docker run -e`).
  Evidence: the baseline `hook-env crash` run was passed=3 failed=3 (hook failed; network and sandbox container still up 37 s after the
  restart); after the fix the full script (control allowlist none cancel pause-resume hook-env scope crash) passed=137 failed=0
  unverified=0, `crash` alone passed=30 failed=0 with `docker ps -a` and `docker network ls` holding nothing of Foreman's afterwards, the
  crash scenario also resumes the orphaned jobsite under the same network name, and `scope` shows a sweep for another owner removes
  nothing in flight. Tests: `network_policy_test.exs`, `docker_network_argv_test.exs`, `sandboxes/docker_env_test.exs` (stateful fake
  docker, each mutation-checked) and, with `--include docker`, `network_policy_docker_test.exs` and `sandboxes/docker_test.exs` on the
  real daemon. Docker objects an older Foreman created before it labelled them are not swept.
- Fixed on branch `foreman/parity-gaps` AND run live with real claude and pi (`foreman-cnn1l`, `foreman-he4yf`): `/mcp` answered HTTP 500 on any server not started by `mix phx.server` (Anubis skipped its supervisor: `ForemanServer.MCP` now passes `start: true`), and a token-protected MCP could not boot (Anubis' OAuth `:authorization` option is no longer passed); `test/foreman_server/mcp/http_boot_test.exs` fails without either change. `scripts/e2e/multi_repo_agent.sh` then ran per-phase repository selection, thread self-add, agent-driven fanout and the jobsite refusal: passed=52 failed=0 on claude and on pi (`multi-repo-agent-live-run.md`). Multi-repo on real GitHub stays unrun.
- LiteLLM is not used by any script and is not reachable from the acceptance host.
- 2026-10-30 (`foreman-l2ab7`, `scheduled-delete-settings-live-run.md`): Scheduled-tab Delete -> Confirm/Cancel (active + paused, negative control, ticker quiet for 2 slots) and Settings editors (allowlist, max repos, notification, setup script, proposal Decline) in real Chromium: 87 pass.
