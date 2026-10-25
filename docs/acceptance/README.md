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
| `github-live-run.md` | Stage 8 on a real private GitHub repo: PR created by a run, checks, a real webhook through a `cloudflared` tunnel, Fix CI, Address comments, Resolve conflicts, force-push, check re-run, operator merge (36 PASS). Branch protection UNVERIFIED (HTTP 403 on that plan). |
| `combined-flow-live-run.md` | The whole flow in one stack with the GitHub stage on (`E2E_GH_THREE_PRS=1`): three tasks in one coordinator message, three overlapping runs, each opening its own real PR, a failing check on one, Waiting on you, Fix CI, Ready for review, operator `approve-merge` + `merge` to Resolved, usage per thread, then the failure-injection pass. One FAIL: no `PR ready for review` notification on the auto-PR path (`foreman-ehz7l`). |
| `live-github-protection-ui-autofix.md` + `live-github-ui-*.png` | The workspace Fix CI, Address comments, Resolve conflicts and Create PR buttons clicked on real PRs, `pr_auto_fix` off, on and bounded, a push after merge approval (observed on the build before #650), GitHub's refusal text for an operator merge, and the Create PR merge-gate defect found and fixed there (`foreman-ksy0q`). Merge under branch protection UNVERIFIED. |
| `parity-gaps-live-run.md` | Live proof of the parity-gap beads with real `claude` (haiku) and pi: claude coordinator and thread, project env and secrets on both doors, setup script, docker network shim, schedules, adopt (move, mint, continue), recommend, per-thread usage, multi-repo self-add and fanout. |
| `live-steering-live-run.md` | Live in-session steering for claude and pi, the pause/resume fallback, `RunSteerUndelivered` on cancel. |
| `inflight-approvals-live-run.md` | Per-call approvals for claude (`--permission-prompt-tool`): approve from the CLI, deny from the workspace UI, timeout deny. |
| `pr-actions-live-view.md` + `02-` to `08-*.png` | Workspace PR action buttons in headless Chromium, and the Overview/Settings/Library screenshots. |
| `review-claude-reviewer-live-run.md`, `review-gap-beads-live-run.md`, `review-gap-guard-retest.md`, `review-jobsite-live-run.md` | Archive plus auto-review on both doors, with a claude and a pi reviewer, gap beads and the depth-1 loop guard against a real `br`. |
| `coordinator-crash-turn-fence-live-run.md` | The coordinator turn fence (`foreman-42t7a`): deterministic test plus three clean live runs. |
| `claude-phase-model-pin-live-run.md` | A `provider: claude` phase pins a bare model; a slashed value is refused at manifest load. |
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
drop the database yourself with `DROP DATABASE IF EXISTS <name> WITH (FORCE)`).

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
  failed once and passed on re-run (`foreman-3ll3t`).
- pi on MiniMax carries almost all of the evidence; `claude` is proven only for short haiku sessions (coordinator, thread, reviewer,
  in-flight approvals, steering). Claude paths beyond that (for example fix-thread resume) are tracked in `foreman-nufr9`.
- GitHub is proven on a real private repo except merge under branch protection (HTTP 403 on a private repo of that plan; the temporary public
  window was not taken because the pre-flip content scan found a real identity in the history, see `live-github-protection-ui-autofix.md`,
  `foreman-ksy0q`). A push after merge approval stranded the PR on the build before #650 (observed live); #650 now voids the approval and holds the gate again (`foreman-ehxy6`), covered by tests and not re-run live.
- Telegram and Slack were never run against the real APIs; this is deferred by the user (`foreman-mivo7`). Only the signed webhook
  is live-verified.
- Not seen live: blocking inside a real container and the Scheduled tab (`foreman-8vf0s`); project archive and delete. Restart while a call
  is blocked is only PARTIAL (a stale pre-restart request stays actionable, `foreman-u0646`). The in-flight approvals UI Approve and Deny,
  stop while blocked, the approval timeout and a block longer than 60 s were verified live on claude (#654,
  `live-claude-and-approvals.md`); the 30 min default timeout was not waited.
- `scripts/e2e` has no schedule step.
- Per-phase repo selection and multi-repo on real GitHub were not exercised (`foreman-he4yf`); multi-repo was proven with a fake `gh`.
- Not built: the first-turn setup proposal and `apply_recommendation` (`foreman-4orxm`), coordinator `add_repo` and `schedule`
  actions (`foreman-tdjj8`), coordinator usage recording (`foreman-ba4y4`), library upload in the workspace (`foreman-8ervf`),
  running a thread on the user's own machine (C13, `foreman-zn7de`, deferred by the user).
- LiteLLM is not used by any script and is not reachable from the acceptance host.
