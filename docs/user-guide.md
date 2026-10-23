# Foreman User Guide

This guide explains how to use Foreman day to day. For exact flags and
command syntax, see the [CLI Reference](./cli-reference.md).

## Overview

Foreman orchestrates AI coding agents against a repository through
isolated git worktrees, with an event-sourced Elixir/Phoenix backend as
the single source of truth. It has two runtime pieces:

| Component | Technology | Role |
|-----------|------------|------|
| `foreman` CLI | Go | Thin HTTP client: posts commands to `/api/commands`, reads projections from `/api/*`. Holds no state of its own. |
| Foreman server (`foreman_server`) | Elixir/OTP + Phoenix | Owns everything: event store, CQRS aggregates, projections, the scheduler, worktree/VCS operations, agent dispatch, PR reconciliation, MCP server. |

There is no separate Node CLI or Node worker process. Agents run
**in-process** inside the Elixir server via `ForemanServer.AgentRuntime`
and the vendored `Jido.Harness` package (see
[Agent runtime and Jido Harness](#7-agent-runtime-and-jido-harness)
below).

**Event sourcing:** every state transition is a domain event appended to
`foreman_events`. Projections (task/run/project/queue read models) are
rebuilt from that log and are what `GET /api/*` endpoints and `foreman
project|run get|list` read.

### Task and run lifecycle, at a glance

```text
task.create ──▶ task.approve ──▶ (RunAdmission) ──▶ run dispatched
   open           ready                                in_progress
                                                            │
                                          TaskExecutionCompleted/Failed
                                                            │
                                                      closed | failed
```

A task can be tracker-backed (a Beads/TaskProvider issue drives its
approval and completion callbacks) or **ad-hoc** — a task carrying only a
free-text `prompt`, with no tracker issue at all. Both go through the
same `task.create` → `task.approve` path; see
[Ad-hoc task dispatch](#3-ad-hoc-task-dispatch-unified-with-the-task-path).

Once a run is admitted, its workflow's phases run in the order the
workflow YAML defines. Bundled workflow manifests live in
`packages/foreman_server/priv/defaults/workflows/*.yaml`:
`assess`, `discover`, `fix`, `implement`, `implement-trd`,
`implement-trd-beads`, `plan`, `prd`, `release`, `trd`, `verify`. A
workflow name is a server-side manifest selector, validated by
`Catalog.load/1` at dispatch time — there is no client-side allowlist.
The catalog root defaults to `~/.foreman/workflows` and is overridable
via `config :foreman_server, :workflow_root`.
PR creation is not phase-driven; see
[AutoPR](#pr-creation-and-merge-reconciliation) below.

Each run executes in **one** git worktree, isolating one agent's edits from your
main checkout and from every other concurrent run. Unless the workflow says
otherwise, the worktree is provisioned by the run's first phase at
`~/.foreman/worktrees/<project-id>/<task-id>/<run-id>/workspace` on branch
`foreman/<task-id>/<run-id>` — both path and branch include
`<task-id>/<run-id>` so retries stay unique and easy to navigate; a `worktree:` block may change the path
and branch or switch provisioning off entirely (see below). Every
phase reads an earlier phase's documents as ordinary files. Foreman commits
whatever each phase produced at the phase boundary, so the run branch
accumulates the whole pipeline and is what AutoPR proposes.

The worktree is configured by a **workflow-level** `worktree:` block, declared at
the top of the manifest beside `name:` and `phases:` — not on a phase. A run has
exactly one worktree, so a phase has nothing to decide about it:

```yaml
name: prd
worktree:
  enabled: true            # false opts the whole workflow out
  branch: foreman/{task_id}/{run_id} # {task_id} and {run_id} are placeholders
  path: workspace          # leaf dir under ~/.foreman/worktrees/<project>/<task>/<run>/
  cleanup: never           # never | always | on_success
phases:
  - name: create-prd
    command: "/skill:create-prd"
```

`cleanup` decides when the directory is reclaimed: `never` (the default) keeps
it, `always` reclaims on success and on failure, and `on_success` reclaims only
on success so a failed run's checkout survives for inspection. The default is
`never` because the worktree is the checkout AutoPR pushes from.
`foreman run remove --id <run-id>` reclaims it (and the local branch) whenever
you no longer need it.

`base` may pin the checkout to a specific ref. For `implement-trd` and
`implement-trd-beads` it must resolve to the ImplementationContext's frozen
`source_revision`, and Foreman fails the run if it does not; for every other
workflow the base is the project checkout's `HEAD` when the run's first phase
starts.

## Local Development Environment

`direnv allow` loads Devbox and sources `.env` on entering the
repository. The real script catalog (see `devbox.json`; do not trust an
older list you've seen elsewhere):

```bash
# ONE-TIME:
devbox run setup            # copy .env, install mix deps

# DAILY:
devbox run up                # bring up the Langfuse/otel stack
devbox run server            # start the Phoenix server (foreground)
devbox run iex                # start with iex for interactivity
devbox run ps                 # show service status
devbox run logs                # tail otel-collector logs
devbox run logs:stack          # tail litellm-langfuse stack logs

# DATABASE:
devbox run db:migrate
devbox run db:reset
devbox run db:console

# TESTING:
devbox run test               # all tests
devbox run test:unit          # everything except :langfuse-tagged
devbox run test:langfuse       # only the OTel+Langfuse e2e path
devbox run -- sh scripts/e2e/multi_repo.sh   # live multi-repo e2e: real agent, scratch repos (see "Repositories")
devbox run -- bash scripts/e2e/claude_projects_flow.sh   # live Claude Projects acceptance (see "Running the live acceptance")
devbox run -- bash scripts/e2e/failure_injection.sh      # live failure injection: provider down, crashes, paused project

devbox run info                # command + status summary
devbox run env:list             # current env vars + endpoints
```

The dev Phoenix server listens on `http://127.0.0.1:4766`
(`packages/foreman_server/config/dev.exs`). The Go CLI also defaults to
`http://127.0.0.1:4766`; set `FOREMAN_API_URL` only when you need to
override that endpoint:

```bash
foreman project list
```

### Running the live acceptance

Two scripts prove the Claude Projects flow against a **real, throwaway** server, the real Go CLI and a real
`pi` agent on `minimax/MiniMax-M2.7-highspeed` (no real notification endpoints; GitHub only for the opt-in stage below). Each prints one
`PASS` / `FAIL` / `UNVERIFIED` line per assertion and exits non-zero on any `FAIL`
(`0` all passed, `1` environment problem, `2` setup failed, `3` assertion failed).

```bash
devbox run -- bash scripts/e2e/claude_projects_flow.sh        # ~2 min: project, memory, library, bead -> thread,
                                                              # steer/stop/resolve, Overview, chat, webhook, review archive
devbox run -- bash scripts/e2e/failure_injection.sh           # ~4 min: provider-down agent-crash coordinator-crash
devbox run -- bash scripts/e2e/failure_injection.sh server-crash   # server-crash port-closed project-paused: run one scenario
```

Prerequisites: `pi` (authenticated for the model), `br`, `git`, `jq`, `curl`, `python3`, `psql` on `PATH` (use
`devbox run --`), the dev Postgres reachable (`E2E_PG_HOST/PORT/USER/PASSWORD`, default `localhost:55432`
`postgres/postgres`). Each script owns a private database (`foreman_e2e_claude_projects_<cp|fail>`), port
(`E2E_PORT`, first free from 4810 / 4830), scratch repo (git + local bare origin + its own `br` database) and work
dir under `<checkout>/tmp/e2e-claude-projects-<cp|fail>` (never `/tmp`; the server runs with a redirected `HOME`
and `FOREMAN_VFS_ALLOWED_ROOT`). It removes only that work dir, database and the PIDs it started; `E2E_KEEP=1`
leaves everything for a post-mortem (you then stop the printed server PID and drop the database yourself).
Other knobs: `E2E_MODEL`, `E2E_RUN_TIMEOUT`, `E2E_REVIEW=0` (skip the review-archive step), `E2E_TRANSCRIPT=<file>`.
`E2E_GITHUB=1` is refused (the harness never creates a repository). The scripts use their own workflows pinned to
pi/minimax, not the bundled defaults.

**Real GitHub stage (opt-in).** `claude_projects_flow.sh` ends with stage 8, which drives a real PR when
`FOREMAN_E2E_GITHUB_REPO=<owner>/foreman-scratch-<suffix>` names an existing **private, non-archived** scratch
repository (the name pattern is enforced; seed it from `scripts/e2e/claude_projects/github-fixture/`, which has a tiny
app, unit tests and a `.github/workflows/ci.yml`). It needs `gh` authenticated with `repo` + `workflow` scope and
`cloudflared` (for the real webhook; `E2E_GH_TUNNEL=0` skips only that part). The stage opens a PR from a run, watches
real checks, registers a real webhook through a cloudflared quick tunnel (a bad signature must be 401), injects a
failing check (Waiting on you, then Fix CI), posts a review comment (Address comments), pushes a conflicting commit
to `main` (Resolve conflicts), force-pushes the branch, re-runs the check, and merges only through the operator
`approve-merge` (naming the PR head it reads from GitHub) + `merge` commands; it then restores the repo's `main`. Unset, it prints an explicit `SKIP` and counts
as `UNVERIFIED`. `E2E_GH_ONLY=1` runs only setup plus this stage (about 6 minutes). Evidence:
`docs/acceptance/github-live-run.md`.

The limitations listed next were written for the scripted flow alone; since then the Claude coordinator, thread, reviewer, in-flight approval and steering paths, and a real private GitHub repo (stage 8), were exercised live. The evidence index, the exact commands and the current verified-versus-unverified list are in `docs/acceptance/README.md`; the per-capability verdicts are in `docs/acceptance/parity-audit.md`.

Known limitations: pi has no tool-permission or ask mechanism, so approve/deny and question/answer are reported
`UNVERIFIED` (only the empty list surfaces are checked); PR/CI/merge behaviour is exercised against real GitHub only when
`FOREMAN_E2E_GITHUB_REPO` is set (stage 8; branch protection is not, see the evidence doc), and otherwise not at all
(see `scripts/e2e/multi_repo.sh` for the fake-`gh` PR flow); the Claude provider paths are not exercised; the
coordinator and reviewer are real LLM turns, so a wording-dependent assertion can in principle flake, and the
coordinator-crash scenario's duplicate-action check is probabilistic (see the evidence doc,
`docs/acceptance/claude-projects-acceptance-2026-10-22.md`). Layout: `scripts/e2e/claude_projects/` (`lib.sh`, `boot.exs`,
`webhook_listener.py`, `workflows/`).


### Authentication

- Set `FOREMAN_API_TOKEN` (CLI) and the server's
  `:foreman_server, :api_bearer_token` config to require
  `Authorization: Bearer <token>` on every `/api/*` request.
- `/api/*` also accepts `?token=<token>` for narrow tooling only (the token
  ends up in URLs and logs).
- When the server has no token configured, `/api/*` **fails closed**: every
  request gets `401` with `{"error":"unauthorized","detail":"no API token is
  configured on the server ..."}`. Set `FOREMAN_API_TOKEN` before exposing the
  server. For token-less local use, opt in explicitly with
  `config :foreman_server, :api, allow_insecure_local: true` (already set in the
  dev and test environments) or, in a release, `FOREMAN_API_ALLOW_INSECURE_LOCAL=true`
  (only the exact value `true`). A configured token is always enforced; the
  opt-in never weakens it. `foreman init --force` calls
  `POST /api/admin/workflows/install`, so it needs the token (or the opt-in)
  too. See "Auth postures" in `docs/lessons/operator-reference.md`.

## Projects workflow

This chapter is the guided path through a project's whole life, from setup to
merge. Each step names the detailed section that holds the exact rules, limits
and endpoints. Two invariants run through every step:

- **The merge gate is operator-only.** Only `foreman run approve-merge` and
  `foreman run merge` (commands `merge_approve`, `run.pr.merge`) merge a PR. The
  coordinator, the PR watcher, auto-fix, notifications and every MCP tool can
  observe, propose and fix, but cannot approve or merge.
- **Everything is a command or a projection read.** The CLI, the LiveView
  workspace and MCP all use the same `POST /api/commands` allowlist and
  `GET /api/*` reads ([Operator API surface](#2-operator-api-surface)).

### Set up a project

Start the server (`devbox run server`), then register the project and link its
task provider (see [Create a project](#create-a-project) and
[Task-provider (Beads) enablement](#10-task-provider-beads-enablement)). Ask the
server what is missing or misconfigured:

```bash
foreman project recommend project-123
foreman doctor --project project-123
```

Recommendations are read-only checks with a severity and a fix
([Setup recommendations](#setup-recommendations)). To bring existing work into a
project, use `foreman project adopt --kind run|jobsite|task --id <id> --into project-123`
(move, continue, or `--new-project` to mint; see
[Moving a session into a project](#moving-a-session-into-a-project)).

### Instructions, memory and library

Three kinds of standing context reach every agent launch on both doors through
one producer, `ForemanServer.ProjectContext.build/2`
([Standing context](#13-standing-context)):

| What | Who writes it | Command | Detail |
|------|---------------|---------|--------|
| Goal and instructions (16000-character limit) | Operator | `foreman project update --goal "..." --instructions-file ./INSTRUCTIONS.md project-123` | [Project settings](#project-settings) |
| Memory (durable topics, `.foreman/memory/`) | Agents and operator | `foreman project memory write --name conventions --file notes.md project-123` | [Project memory](#12-project-memory) |
| Library (read-only files, `.foreman/library/`) | Operator | `foreman project library add --name specs project-123 ./docs/specs` | [Project library](#121-project-library) |

Memory is agent-written and is rendered as informational notes, never as
instructions. Environment variables, secrets, the setup script and the network
policy are separate records ([Environment, secrets, setup script and network policy](#environment-secrets-setup-script-and-network-policy)):
`foreman project env set|unset|list`, `foreman project secret set --from-env`,
`foreman project setup-script`, `foreman project network`. Check what an agent
would actually receive with `foreman project context project-123`.

### Work in threads, and steer them

A **thread** is one unit of agent work: a workflow run (with its task) or a
jobsite. Threads are a read model over existing projections
([Operator API surface](#2-operator-api-surface), `/api/projects/:id/threads`):

```bash
foreman thread list --project project-123
foreman thread steer --message "use the v2 API instead" run:<run-id>
foreman thread stop run:<run-id>
foreman thread resolve run:<run-id>
```

Steering a running claude or pi phase writes your message into the live agent session
(no pause); anything else is pause, commit partial work, resume with your message
injected once into the next phase prompt ([Steering](#steering-v1-and-thread-housekeeping)).
`resolve` is a disposition flag; it never stops a run. Terminal threads without a
PR resolve themselves after `idle_resolve_after_days` (default 7), and a thread
resolves when its PR merges.

### Overview and the workspace

The Overview answers "what needs me?": threads grouped as Ready for review,
Waiting on you, Working, Landing, Idle and Resolved, plus an `attention` signal
([Project Overview](#project-overview); `foreman_overview` over MCP). The
browser view is the LiveView workspace at `/dashboard/projects/:id` (settings at
`/dashboard/projects/:id/settings`), behind the same bearer-token guard as
`/dashboard/runs` ([Project workspace](#141-project-workspace-liveview)). It
subscribes to the projection; it does not poll.

### Talk to the coordinator

Every project has one durable coordinator conversation. Paste a bug or a task
list; the coordinator answers, asks, proposes or starts threads, and routes
follow-ups ([Project coordinator](#14-project-coordinator);
[Chat with the project coordinator](#chat-with-the-project-coordinator)):

```bash
foreman project chat project-123 "triage the failing nightly build"
```

It acts through a closed command set and can never merge, approve, archive or
retry. Tuning (`coordinator_propose_before_start`,
`coordinator_max_active_threads`, `coordinator_reuse_threads`) is enforced by the
server, not by the prompt. Its `schedule` and `add_repo` actions are rejected as
unsupported in this revision. Thread counts in its replies are not the model's
arithmetic: the context carries the Overview's counts per group (a `STATUS`
section) and a reply that talks about thread status gets a
`Status (computed by Foreman from the Overview): ready for review 2 · ...` line
appended.

### Approvals and questions

When an agent is denied a tool or asks a question, the thread shows as
`waiting_on_you` ([Needs you](#needs-you-approvals-and-questions)):

```bash
foreman approvals list --project project-123
foreman approvals approve --run <run-id> --call <tool_call_id>
foreman questions list --project project-123
foreman questions answer --run <run-id> --question <id> --text "yes, use postgres"
```

Unanswered requests expire (default 30 minutes). Approving one tool relaxes the
approval mode for the next phase as a whole ([Approval scope](#needs-you-approvals-and-questions)).
There is no MCP tool to approve, deny or answer.

### Review, then merge

Every finished run and jobsite leaves a session archive and an automated review
([Session archive and automated review](#session-archive-and-automated-review)).
When a PR is ready the merge gate holds it for you. You approve the exact commit you
reviewed (`--head-sha`: the PR head as `foreman run prs <run-id>` or GitHub shows it),
then merge:

```bash
foreman run approve-merge --id <run-id> --approver <name> --identity github:<login> --head-sha <sha>
foreman run merge --id <run-id>
```

A push to the PR after you approved voids the approval and holds the gate again: review the
new commit and approve it (the `run approve-merge` notes under "Runs" have the details).

### PR watching and auto-fix

Foreman watches each run's PR (checks, reviews, comments, conflicts) and can open
bounded fix threads: `foreman run prs|fix-ci|address-comments|resolve-conflicts|create-pr|watch-start|watch-stop <run-id>`.
Auto-fix is opt-in per project (`--pr-auto-fix`), with at most one fix in flight
per PR and a hard cap of 5 attempts per kind
([PR watching and auto-fix](#pr-watching-and-auto-fix)).

### Notifications

`ForemanServer.Notifier` maps run, review, approval and PR events to outbound
Telegram/Slack messages through `ForemanServer.Messaging`. A project chooses how
much it hears with `foreman project update --notification-preference
every_turn|blocked_only|off project-123` ([Outbound messaging delivery](#outbound-messaging-delivery)).

### Schedules

A project can own cron or interval schedules that create (and by default
approve) a task each time a slot falls due:

```bash
foreman project schedule create --project-id project-123 --name "Daily triage" \
  --cron "0 9 * * 1-5" --prompt "Triage new issues and summarise" --workflow fix
foreman project schedule list --project-id project-123
```

Rules (UTC only, no catch-up storm, overlap policy, exactly-once fire) are in
[Scheduled tasks](#122-scheduled-tasks).

### Usage, limits, pause and resume

```bash
foreman usage --project project-123 --by day
foreman project settings project-123
foreman project update --max-concurrent-runs 2 --daily-thread-cap 20 project-123
foreman project pause project-123 --reason "release freeze"
foreman project resume project-123
```

Usage groups tokens and provider-reported cost by day, model, provider, role or
thread; cost is "unknown", never estimated ([Usage and cost](#usage-and-cost)).
Limits are enforced server-side at admission, and a paused project refuses new
work while in-flight runs keep going ([Pause, resume and reactivate](#pause-resume-and-reactivate)).

### Not verified against the live service

These paths were built and tested with fakes only and are **UNVERIFIED** live:

- E9 PR watching against real GitHub: webhook deliveries, force-pushes, check
  re-runs, merge-conflict resolution and unresolved review threads (spike S4).
- Resuming a **Claude** provider session (Claude auth was unavailable); `pi`
  sessions are verified and bound to their working directory.
- The phase-wide effect of approving a tool on a **Claude** run (spike S2).

Multi-repo projects are not part of this chapter.

## Core Concepts

### Projects

A project is a repository registered with Foreman. Commands operate on
one project at a time via `--project-id`/`--project`.

**Project environment.** A project's `config.env` (a map of variable name to
value) is delivered to every workflow-phase agent of that project's runs. It is
the base layer. The `FOREMAN_*` namespace is reserved for Foreman
(`FOREMAN_RUN_ID`, `FOREMAN_ARTIFACT_PATH`, ...): a `config.env` key with that
prefix fails the phase before any agent launches
(`reserved_project_env_keys`) instead of being silently overridden or passed
through. Values of secret-named keys
(names containing `API_KEY`, `TOKEN`, `PASSWORD`, `SECRET`, `CREDENTIAL`, ... as
underscore-delimited words) are redacted from
worker logs, but `config.env` itself is still stored in project event payloads;
a real secret store is a separate, later feature. Jobsite `agent.env` is a
different mechanism (an operator-allowlisted per-request map) and is unchanged.

**Base branch.** A run's base branch is the registered checkout's `HEAD` at the
moment the run's first phase starts, latched for the run. There is no
per-project `default_branch` setting: `project update`/`register` payloads that
carry one are rejected with `setting_removed: default_branch`.

### Create a project

```
foreman project create \
  --id project-123 \
  --path /srv/foreman/project-123 \
  --task-provider beads \
  --task-provider-database-path /srv/foreman/project-123/.beads
```

### Get one project

```
foreman project get project-123
```

### Update a project

```
foreman project update --task-provider beads --task-provider-database-path /srv/foreman/project-123/.beads project-123
```

### Delete a project

```
foreman project delete project-123
```

### List projects

```
foreman project list
```

Use `foreman project list --include-archived --format json` when you need archived projects or raw JSON.

`project delete` **archives** a project; it never purges anything. It is
**rejected** while the project has active runs; pass `--force` to print the
blocking run IDs. Archived projects are hidden from the default list, refuse new
work, stay readable by id and with `--include-archived`, and come back with
`foreman project reactivate <id>`. The event history, runs, tasks and any
`.foreman/` artifacts are kept (see `docs/decisions/project-delete.md`); there is
no operator command that hard-deletes a project.

### Moving a session into a project

`foreman project adopt` brings an existing run, jobsite or task into a project.
*Move* re-homes it (a run moves with its task and that task's other runs) and
updates its archive manifest; the original events keep their project, and
`ReviewRecorded` keeps pointing at the original project. A session that is still
running (or paused) cannot be moved; use *Continue* instead, which starts a new
task in the target project seeded from the session's archive and leaves the
original running. *Mint* (`--new-project`) creates a project from the session's
repo and goal and moves the session into it. Tasks imported from beads stay in
their source project, and a session's repo must be the target project's path.
See `docs/cli-reference.md` (`foreman project adopt`).

### Setup recommendations

`foreman project recommend <id>` (also `GET /api/projects/<id>/recommendations`
and the read-only MCP tool `foreman_project_recommendations`) lists what is
missing or misconfigured: the beads task provider not wired, no AGENTS.md or
CLAUDE.md, no CI, `gh` not logged in, workflows not installed, empty goal or
instructions, a configured provider that is not installed, a paused project.
Each item has a stable id, a severity (`action`, `warn`, `info`) and a fix: a
Foreman command computed from what was observed, or manual advice. Checks are
read-only and bounded (5 s per external command); a check that cannot run
produces no recommendation rather than a false alarm. `foreman doctor` reports
server, provider and workflow readiness (`--project` adds this summary).
### Chat with the project coordinator

```
foreman project chat project-123 "fix the login bug"
```

Posts the message, then prints the coordinator's reply and action notes as they arrive. Use `--no-wait` to return immediately, `--history 20` or `--since <seq>` to read the conversation, `--format ndjson` for scripting and `--restart` to restart a wedged coordinator (exit code 3 means it is unhealthy). See `docs/cli-reference.md`.

### Project settings

A project carries a goal, standing instructions and per-project defaults and
limits. Set them with `project update`; read them with `project settings`:

```
foreman project update --goal "Ship the v2 importer" --instructions-file ./INSTRUCTIONS.md project-123
foreman project update --thread-model opus --thread-effort high project-123
foreman project update --max-concurrent-runs 2 --daily-thread-cap 20 project-123
foreman project update --clear instructions project-123
foreman project settings project-123
```

| Setting | Limit | Meaning |
|---------|-------|---------|
| `goal` | 2000 characters | What the project is for |
| `instructions` | 16000 characters (`String.length`, like Claude Projects) | Standing instructions for every thread |
| `thread_model`, `thread_effort` (`low`/`medium`/`high`) | | Default model/effort for the project's threads |
| `coordinator_provider` (`pi`/`claude`), `coordinator_model`, `coordinator_effort` | | Provider, model and effort of the project's coordinator agent (see [Project coordinator](#14-project-coordinator)) |
| `max_concurrent_runs` | 1..1000 | Runs the project may have active at once |
| `daily_thread_cap` | 1..10000 | Threads (workflow runs plus jobsites) the project may start per UTC day |
| `library_collect_produced` | `true`/`false` | Register each run's artifacts and session-archive files in the project library (default off; see [Project library](#121-project-library)) |
| `coordinator_propose_before_start` (bool), `coordinator_max_active_threads` (1..50), `coordinator_reuse_threads` (bool) | | Coordinator tuning enforced by the server; clearable with `--clear` |
| `notification_preference` | `--notification-preference` | `every_turn`, `blocked_only` (default when unset) or `off`: which of this project's events reach the outbound messaging provider; clearable with `--clear` |
| `pr_auto_fix` | JSON object (`--pr-auto-fix`) | Opt-in PR auto-fix policy: `kinds` (`ci`, `comments`, `conflicts`), `max_attempts` 1..5, `cooldown_seconds` 0..86400 (see [PR watching and auto-fix](#pr-watching-and-auto-fix)) |

Text values are trimmed and `CRLF` is normalised to `LF`; a blank value clears the
setting. Validation is done once, by the server, and its error is shown verbatim
(for example `{:instructions_too_long, 16001, 16000}`). `status` is not settable
through `project update`: use `pause` / `resume` / `reactivate`. Unknown config keys
are rejected (`{:unknown_setting, key}`).

**Model and effort precedence.** An explicit phase `models.default` or jobsite
`agent.model` / `agent.effort` wins over the project's `thread_model` /
`thread_effort`, which win over the provider default. The project value is read
once when a run's executor starts (a resumed run reads the project's current
value). `thread_effort` is delivered as `reasoning_effort` only to providers whose
adapter declares it (logged and ignored otherwise, never an error); a jobsite
spec with only `agent.provider` records the project's model/effort in
`JobsiteStarted`.

**Limits.** `max_concurrent_runs` is enforced inside the project aggregate at run
reservation, and is further capped by the global run-slot capacity (a project value
above the global one cannot raise it). The daily thread cap counts a workflow run at
reservation and a jobsite at start; the (N+1)th thread of the UTC day is refused
(`{:daily_thread_cap_exceeded, N, day}`; HTTP `429 thread_cap_reached` for a
jobsite). Refused admissions are not terminal: the task stays approved and is
retried when the project resumes or its settings change. `project settings` (and
`GET /api/projects/<id>/settings`) shows the effective limits, usage today,
`resets_at` and the count of deferred tasks.

### Repositories

A project's `path` is its primary repository (id `main`). Extra checkouts that
already exist on the server host can be attached with
`foreman project repo add --id <repo-id> --path <abs-path> <project-id>` and
detached with `repo remove`; `repo list` (or `GET /api/projects/<id>/repositories`,
also `repositories` in the project JSON) shows them, primary first. Adding is
operator-only (there is no MCP write tool; `foreman_project_repo_list` is
read-only). The server canonicalises the path (symlinks resolved), requires a git
work-tree root, and refuses a duplicate path or a second checkout of the same
`origin`. Changing the primary with `project update --path` is validated the same
way. Policy settings `repo_allowlist` (absolute path prefixes; `..`, relative
entries and `/` are rejected) and `max_repos_per_run` (default 4) are stored via
`project.update`. A run may span several repositories (the multi-repo run gate is
open by default). Each repository the run changed gets its own branch and
PR (untouched repositories get none); sibling PRs are cross-linked in their
bodies. A repository whose push or `gh` fails does not stop the others: the run
completes (read as `completed_with_errors` on the dashboard) and
`foreman run retry-pr --id <run> --repo-id <repo>` opens the missing PR once the
cause is fixed. Each PR has its own merge gate (`approve-merge`/`merge` take
`--repo-id`; each approval names that repository's own PR head). A run with `stack_pr: true` phases cannot span several repositories
and is refused at start. An operator can close the gate again with
`config :foreman_server, :multi_repo, runs: false` (new multi-repo runs are then
refused at start with `multi_repo_runs_disabled`; single-repo runs are unaffected).

**Rollback caveat (release note).** Single-repository runs write no new event keys, so
rolling back to a build without multi-repo support is safe as long as no multi-repo run
has happened. The first multi-repo run writes events carrying `repo_id`/`repo_ids`,
which an older binary cannot replay: after that run rolling back is NOT safe.
`runs: false` stops new multi-repo runs but cannot remove events already written.

**Live proof.** `devbox run -- sh scripts/e2e/multi_repo.sh` (POSIX sh; `E2E_PROVIDER`
defaults to `pi` with `minimax/MiniMax-M2.7-highspeed`; `E2E_STAGES`, `E2E_KEEP=1`,
`E2E_TRANSCRIPT=<file>` and the other knobs are listed in the script header) runs
one real task over two scratch git repositories with local bare origins, a recording
fake `gh`, a private port and a private database, and asserts the whole flow:
two worktrees, an edit made through the sibling path, commits and pushed branches in
both repositories, two PRs, the archive (`diffs/b.patch`, manifest `repositories[]`),
the per-repository merge gate, a read-only-origin failure recovered by `run retry-pr`,
and an unchanged single-repository run on the same server. It exits non-zero naming
the failing assertion. It never creates GitHub repositories (`E2E_GITHUB=1` is refused).
The recorded run is `docs/lessons/multi-repo-e2e-2026-10-21.md`.

#### Targeting repositories, letting a thread add one, fan-out

The `task.create` command (HTTP `/api/commands`) and the MCP `foreman_task_create` accept `repo_id` (the
repository the run is rooted in; default the project primary) and `repo_ids`
(additional repositories). Unknown ids, duplicates, an extra equal to the primary
and a total above `max_repos_per_run` (primary included) are refused at creation.
Runs rooted in or spanning other repositories are admitted while the multi-repo gate
is open (the default).

A thread can ask for another repository with the write tool
`foreman_run_request_repo` (`run_id`, and `repo_id` or an absolute `repo_path`).
It is **off** until an operator sets `repo_allowlist` (`project update`): every
request, for registered and unregistered repositories alike, must resolve (symlinks
followed) inside an allowlisted prefix, and the run may hold at most
`max_repos_per_run` repositories. An unregistered git checkout inside the
allowlist is registered first. The repository's worktree is created at once but
is effective in the **next phase**. Every request, allowed or denied, is recorded
(`RunRepoRequested` on `run_repo_audit:<run_id>`). A thread cannot merge or approve.

`foreman_task_fanout` (write tool; `project_id`, `title`, `prompt`, `workflow`,
`repo_ids` or `"all"`, optional `fanout_id`) creates one independent task per
repository (`<fanout_id>-<repo_id>`, each its own run and PR). Retry with the same
`fanout_id` to stay idempotent; rejections (paused/archived project, unknown repo)
are reported per repository and keep the tasks already created.

### Usage and cost

`foreman usage` shows what a project's threads (workflow runs and jobsites) consumed, grouped by model
(default), `day`, `provider`, `role` (`thread`, `coordinator`, `review`) or `thread`:

```
foreman usage --project project-123 --from 2026-10-01 --by day
```

```
DAY         INPUT  OUTPUT  CACHE-READ  CACHE-WRITE  TOTAL   COST
2026-10-01  1200   340     8000        900          1540    0.0210*
2026-10-02  400    90      -           -            490     -
TOTAL       1600   430     8000        900          2030    0.0210*

2 events with unknown cost ("-" = no cost reported, "*" = partial sum)
daily thread cap: threads today: 3/10, resets 00:00 UTC, 4 deferred today
```

Cost is provider-reported or unknown. `-` (JSON `cost_usd: null`) means the provider reported no cost, which is
not the same as free; `*` marks a sum over only the events that reported one, and `cost_unknown_events` counts
the rest. Foreman never computes a price. `--from` / `--to` are inclusive UTC dates spanning at most 366 days;
`--limit` caps the thread rows (default 50, max 500); `--format json` prints the server response unchanged.
The same data is `GET /api/projects/<id>/usage?from=&to=&group_by=&limit=` (422 `invalid_range`,
`range_too_large`, `invalid_group_by`, `invalid_limit`; 404 for an unknown project) and the MCP read tool
`foreman_usage_get`. The response also carries the `limits` block (including `deferred_today` /
`deferred_by_reason`, the durable count of tasks refused today by the daily cap, run limit or pause) and
`cache_hints`, one per thread: `cache_read_ratio`, `idle_seconds` and `likely_cold` (`null` when the provider has
no configured cache TTL; the TTLs are `config :foreman_server, :usage, cache_ttl_seconds:`, claude 300 by
default, an assumption to tune per provider). Usage covers the last 366 days per project. Jobsite iteration
usage and reviewer-agent usage (role `review`, attributed to the reviewed run or jobsite) are included; a
jobsite that reports through worker events is not counted twice.

### Environment, secrets, setup script and network policy

Each project has one **environment record** (`config.environment`): plain
variables, an optional **setup script** and a **network policy**. It is written
only by the operator-allowlisted command `project.environment.set` (HTTP
`PUT /api/projects/<id>/environment`, or the CLI below): `project.update` and
`project.register` reject an `environment` key, because the setup script is
arbitrary code that runs on the server host.

```
foreman project env set project-123 NPM_REGISTRY=https://registry.example
foreman project env unset project-123 NPM_REGISTRY
foreman project env list project-123
printf '%s' "$TOKEN" | foreman project secret set project-123 DEPLOY_TOKEN
foreman project secret set --from-env MY_TOKEN_VAR project-123 DEPLOY_TOKEN
foreman project secret list project-123
foreman project setup-script set --file ./setup.sh project-123
foreman project network set --mode allowlist --allow pypi.org project-123
```

| Piece | Rule |
|---|---|
| Variables | names `^[A-Za-z][A-Za-z0-9_]*$`, values <= 8 KiB, <= 100 vars. `FOREMAN_*` is reserved: `project.environment.set` rejects it (`reserved_env_name`), and a project whose stored legacy `config.env`/`config.environment` already holds one fails every workflow phase and jobsite launch LOUDLY (`reserved_project_env_keys`, naming the keys) until the operator removes it. Secret-looking names (`*_TOKEN`, `*_PASSWORD`, `*_API_KEY`, ...) are rejected with `secret_in_vars`: use a secret. |
| Secrets | Names `^[A-Z][A-Z0-9_]{0,63}$`, values <= 16 KiB. The value goes straight into the server's secret store (default: 0600 files under `~/.foreman/secrets`, dir 0700, outside any repo; `config :foreman_server, :secret_store, dir:`). **Events, projections, logs, API responses and MCP results carry only the name and a version, never the value.** The CLI reads the value from stdin or `--from-env`, never from a flag. Secrets are delivered to agents as environment variables and redacted from run logs, jobsite output and session archives (transcript, `diff.patch`, `changed-files.txt`, `request.md`, analysis files): only values present in the server environment are recognised, so a value an agent reads from a committed `.env` file or fetches at runtime is not caught (see [Session archive](#session-archive-and-automated-review)). A secret wins over a variable of the same name. If the store is unavailable at launch the run proceeds without stored secrets (warning logged). OS keychain backends were evaluated and rejected (docs/spikes/E4-SP1.md). |
| Delivery | Both doors: workflow runs get the project env plus secrets (Foreman's own `FOREMAN_*` values cannot be overridden: no project key may use that namespace); jobsites get the same as a base that the spec's own allowlisted `agent.env` overrides. |
| Setup script | Runs once, right after a fresh run worktree (or jobsite worktree) is created and before any agent starts, as `sh -c` in the worktree with the project env and secrets plus `FOREMAN_WORKTREE_PATH`, `FOREMAN_RUN_ID`, `FOREMAN_PROJECT_ID`. Non-zero exit or exceeding `config :foreman_server, :project_setup, timeout_ms:` (default 300000; the process group is killed) fails the phase / jobsite (`setup_script_failed`, `setup_script_timeout`; jobsites: `hook_failed`). Output is bounded (64 KiB tail), redacted and written to `<artifact dir>/<run_id>/setup.log` (workflow door). It is not re-run for later phases that reuse the worktree. Remote jobsite specs still cannot supply `hooks.host.*`; the script only comes from this record. |
| Network policy | `default` (unchanged), `none` (`docker run --network none`; the agent cannot reach its provider API, so this fits offline tasks) or `allowlist` (an internal docker network plus an egress proxy sidecar permitting your `--allow` hosts and the always-allowed provider/VCS hosts; spike docs/spikes/E4-SP2.md). **Enforced on docker jobsites only**: the host sandbox with a non-default policy fails with `network_policy_unsupported`, a spec `sandbox.config.network` wider than the policy fails with `network_policy_violation`, and workflow runs (agents on the server host) do not enforce it. Networks and sidecars are removed when the jobsite ends and swept at boot. |

`GET /api/projects/<id>/environment` returns the record (variable values only for
the record form; a project still on legacy flat `config.env` shows `[redacted]`
values and `legacy_env: true`), `network_enforced_on` and secret names/versions.
`PUT /api/projects/<id>/secrets/<NAME>` takes `{"value": "..."}`;
`DELETE` removes it. `project env set` on a legacy project requires `--replace`
with every variable (the old values are hidden), after which the record is used
and legacy `config.env` is ignored. The MCP tool `foreman_project_environment_get`
is read-only and returns variable and secret *names* only; there is deliberately no
MCP write tool for the environment or secrets.

### Pause, resume and reactivate

```
foreman project pause project-123 --reason "release freeze"
foreman project resume project-123
foreman project reactivate project-123
```

`pause` is reversible and **enforced**: while paused, `task.create`, run
reservation, jobsite start (`spec_project_unavailable`) and BeadsWatcher imports
are refused with `{:project_paused, project_id}`. In-flight runs and jobsites keep
running (cancel them with `run.cancel`). Held beads are not skipped: the watcher
holds their line and imports it after `resume`, and tasks refused at admission are
re-admitted on resume. `reactivate` is for archived projects (and clears any
earlier pause); `resume` is for paused ones.

A run id returned by `foreman run submit` exists before admission has produced a
run. A task refused at admission (`run_limit_exceeded`, daily thread cap, pause)
keeps its run id and `foreman run get <id>` / `GET /api/runs/<id>` answers `200`
with `run.status` `deferred` and `run.reason` (or `queued` while admission is
pending), never a 404. It is re-admitted when the project is resumed, when a
`project update` changes its settings (a raised limit), and when a finished run
frees its reservation; the global run slot is only taken once the project's own
limits admit the run, so a deferred run never starves other projects.

### Tasks

A task is the unit of dispatchable work. It carries a title, optional
description, a `task_type` (legacy classification field) and/or
`workflow_type` (the workflow manifest selector), and — for ad-hoc
work — a free-text `prompt`.

`foreman task create`/`approve`/`get`/`retry` are REMOVED (TRD-018,
2026-09-13) — invoking any of them now produces the CLI's standard
"unknown command" error. Task creation is driven by Beads instead of
an operator-invoked CLI verb:

```bash
br create --title "Fix flaky retry" --type fix
```

BeadsWatcher observes the bead (or its later transition to `status:
open`) and dispatches the internal `task.create` + `task.approve`
commands automatically — no separate approval step is needed. Use
`foreman run get <run-id>` / `foreman run list` (see "Runs" below) to
monitor the resulting run, and re-open the bead (`br update <id>
--status=open`) to retry once its bound run is terminal.

Select the workflow via the bead's type (mapped through a manifest's
`task_types:` declaration — see `foreman doctor`), not a CLI flag. Workflows
requiring `ImplementationContext` (`implement-trd`, `implement-trd-beads`)
read the TRD path from the bead's own `agent_context.trd_path` field, set on
the bead directly (`br update <id> --agent-context '{"trd_path":"docs/TRD/..."}'`)
— there is no `--trd-path` CLI flag any more, and no separate approval step:
BeadsWatcher creates and auto-approves the task in one action when the bead
transitions to `open`.

### Runs

A run is one dispatched execution of a task's workflow, in its own
worktree.

```bash
foreman run list --project-id foreman --status failed --limit 5
foreman run get <run-id>
foreman run cancel --id <run-id> --reason stuck_in_recovery
foreman run pause --id <run-id> --reason operator_pause
foreman run resume --id <run-id>
foreman run remove --id <run-id>
foreman run reset --id <run-id>
foreman run approve-merge --id <run-id> --approver <name> --identity <github:login> --head-sha <sha>
foreman run merge --id <run-id>
```

- `run cancel` marks the run terminal (`cancelled`) and kills the
  dispatched agent, including its OS-level process, via `RunControl`.
- `run pause` interrupts the current phase the same way, but first commits
  the phase's partial work to the run branch and leaves the run resumable
  (`paused`) rather than terminal — it releases the run's slot and Beads
  lease without reopening the underlying task.
- `run resume` continues a `paused` run: it re-acquires a slot/lease,
  rehydrates the persisted worktree, and re-runs the interrupted phase from
  its last committed state onward. A resumed phase that produces no *new*
  output fails its discovery gate exactly as a first attempt would.
- `run remove` terminates the run, releases its slot and any per-DB
  Beads lease, and best-effort cleans the worktree and local branch.
  Use it when a run is wedged and you want a clean slate.
- `run reset` clears a **failed or stuck** run's projection state so it
  can be resubmitted fresh; cancelled or completed runs are rejected
  with `{:run_not_resettable, "<status>"}`.
- `run approve-merge` opens the run's merge gate once its PR is ready, for the exact
  commit you name with `--head-sha` (required: there is no "approve whatever the head
  is"). The server reads the PR head back from GitHub (`gh pr view`) and refuses the
  approval unless it is that commit, naming both SHAs
  (`{:head_sha_mismatch, "<yours>", "<GitHub's>"}`); an approval without one is
  `{:missing_or_invalid, :head_sha}`; GitHub unreadable is a refusal, never an assumption.
  An abbreviated SHA is a mismatch, not a prefix match: copy the full one. The recorded
  head is not the authority here: the PR watch lags a push by up to a poll interval, and
  polling is opt-in. The approval pins that commit. The server accepts it only for an
  allowlisted approver identity (`ApproverAuthorizer`); anyone else gets
  `unauthorized_approver`, before anything is read from GitHub. The identity is a claim
  made by whoever holds the API token — the token is the trust boundary — which is why
  there is deliberately no MCP tool for it.
- `run merge` squash-merges the approved PR on GitHub (`gh pr merge --squash
  --match-head-commit <approved sha>`). It refuses before approval (`pr_not_acceptable`)
  and if the PR head is no longer the approved commit
  (`head_moved_since_approval`), so nothing pushed after approval is merged
  unreviewed. The merge is pinned to exactly the commit you named when you approved
  (so a PR that got a Fix CI or conflict-resolution push before approval merges at that
  head). A PR that is already merged at the approved head is recorded without
  calling `gh` again, so a retry is safe. The server host needs an authenticated `gh`.
- **A push after approval voids the approval** (foreman-ehxy6). An approval covers one
  commit. When the PR head differs from it, the gate goes back to `pending`: the old
  approval and its pin are gone, `run merge` is refused (`pr_not_acceptable`) and
  `foreman run prs <run-id>` shows `merge_gate: pending` with the new `head_sha`. The head
  is seen either by the PR watch (a webhook, a poll or a Fix CI push records it; the gate
  is held again at once, as a `MergeGatePending` event with `reason:
  head_moved_since_approval` and both SHAs) or by `run merge` itself, which reads GitHub:
  it answers `head_moved_since_approval` and holds the gate again, so a PR watch that is
  off cannot leave a PR approved but unmergeable. To merge the new commit, review it and
  `run approve-merge ... --head-sha <new sha>` again; the old SHA is refused as a
  mismatch. The moved head is never adopted as the pin, and a head that later returns to
  the approved SHA does not revive the old approval: each approval is an explicit
  operator decision. An approval recorded before heads were pinned (no `head_sha` on its
  event) is pinned to the head the PR watch had recorded at that time and is voided the
  same way.
- **Multi-repository runs (E12)**: every repository opens its own PR with its own
  merge gate. `run approve-merge` / `run merge` take `--repo-id <repo>` (omit it for
  the primary repository); one call approves or merges exactly one PR, each merge
  pinned to that PR's own approved head. There is no approve-all, and merge stays
  operator-only (no MCP tool). If one repository's PR cannot be created the run
  still completes; that repository shows `pr_state: create_failed` (and the
  dashboard reads the run as `completed_with_errors`, a derived flag, not a run
  status), its worktree is kept, and `run retry-pr <id> --repo-id <repo>`
  (`run.pr.retry`, idempotent, allowed on a finished run) opens the missing PR and
  then reclaims the worktree. Single-repository runs are unchanged.

Phases have no default execution timeout: a workflow's `timeout_minutes:`
(alias `timeoutMinutes:`) is optional, and `0` or an absent key both mean
"run until it finishes" rather than falling back to a fixed ceiling.
Declare a positive `timeout_minutes:` on a phase to opt it back into a
deadline.

A phase can set `approval_mode:` (`default`, `prompt`, `auto_edit`,
`auto_approve`) to control the agent's permission mode. Without it, Claude
cannot write files headlessly; the phase then fails with
`{:permission_denied, [tools]}` rather than completing with no changes. A Claude
phase with `approval_mode: prompt` instead asks the operator per tool call while
it is running (in-flight approvals, below); pi has no per-call approvals and keeps
the pause-and-re-run path. Report
paths using `{task.projectReportsDir}` resolve under the run's worktree (or the
task/project directory), not the server's working directory.

### Agent command assets

`foreman commands` generates agent-native Foreman shortcuts for Claude Code plus copyable generate-only assets for Pi/OMP, Codex, and OpenCode. The assets were thin shell wrappers over `foreman task create`, `foreman run submit`, `foreman run list`, `foreman run get`, and `foreman task get`; the `task create`/`task get` wrappers are REMOVED (TRD-018, 2026-09-13) along with the CLI verbs they wrapped, so those two generated shortcuts now fail with an "unknown command" error until the generator is updated. The `run submit`/`run list`/`run get` wrappers are unaffected. Generated files inherit `FOREMAN_API_URL` and `FOREMAN_API_TOKEN` instead of embedding secrets.

Common commands:

```bash
foreman commands inventory
foreman commands generate --agent all --output ./foreman-agent-commands
foreman commands install --agent claude --scope project
foreman commands validate
```

The `task create`/`task get` agent-command shortcuts above are removed
along with the CLI verbs they wrapped (TRD-018) — there is no longer a
generated task-creation shortcut, "later approval" step, or `--trd-path`
flag. Use `foreman run submit` or the generated `foreman-run-submit` asset
for one-step ad-hoc execution; drive `implement-trd`/`implement-trd-beads`
work through Beads as described above instead.

Support states:

| Agent | Native install | Behavior |
|---|---|---|
| Claude Code | Project-local verified | Writes Markdown slash-command files under `.claude/commands/foreman` by default; existing files require `--force`. |
| Pi/OMP | Generate-only by default | Prints/writes copyable Markdown and an unsupported-native-install reason because the native command path/format is not verified here. |
| Codex | Generate-only | Prints/writes copyable Markdown and marks native install unsupported until a stable native contract is verified. |
| OpenCode | Generate-only | Prints/writes copyable Markdown and marks native install unsupported until a stable native contract is verified. |

## 2. Operator API surface

(Jobsite has its own, separate surface under `/api/jobsites`; see
[Remote Jobsite API](#remote-jobsite-api).)

All external domain mutations go through `POST /api/commands`. The
operator allowlist (`ForemanServer.CommandGateway.@allowed_operator_types`)
is exactly:

- Projects: `project.register`, `project.update`, `project.environment.set`,
  `project.archive`, `project.reactivate`, `project.pause`, `project.resume`,
  `project.adopt`, `project.repo.add`, `project.repo.remove`
- Tasks: `task.create`, `task.approve`, `task.retry`, `task.update`
- Runs: `run.cancel`, `run.pause`, `run.resume`, `run.remove`, `run.reset`,
  `run.steer`, `inbox.send`
- Merge gate (operator-only): `merge_approve`, `run.pr.merge`, `run.pr.retry`. (Voiding a
  stale approval, `run.pr.rehold`, is a system command sent by the server itself: it is on
  no allowlist, and it can only ever make the gate stricter.)
- PR watching: `run.pr.fix_ci`, `run.pr.address_comments`,
  `run.pr.resolve_conflicts`, `run.pr.watch_stop`, `run.pr.watch_start`,
  `run.pr.create` (merge is deliberately not among them)
- Threads: `thread.resolve`, `thread.reopen`
- Coordinator: `coordinator.message`, `coordinator.restart`
- Schedules: `schedule.create`, `schedule.update`, `schedule.pause`,
  `schedule.resume`, `schedule.delete`
- Approvals and questions (accepted alongside the list above):
  `tool.approve`, `tool.deny`, `question.answer`

System-only commands are never on the allowlist: `run.steer.consume`, `run.steer.deliver`,
`run.steer.undeliver`,
`schedule.mark_fired` / `schedule.skip_fire`, the `coordinator.append|turn.*|action.record`
family, `review.record` and the PR observation commands.

`CommandController` derives or verifies `aggregate_id` before calling
`CommandGateway`. The expected form is `<prefix>:<id>` (`task:<task_id>`,
`run:<run_id>`, `project:<project_id>`). A mismatched supplied
`aggregate_id` is rejected before the aggregate handles the command.

Response shapes:

- Success: `201` with `{"status": "accepted", "result": {...}}`.
- Refused command type: `403` with `{"error": "command_not_allowed", "type": "..."}`.
- Malformed envelope: `400` with `{"error": "invalid_envelope", "reason": "..."}`.
- Optimistic-concurrency conflict: `409` with `{"code": "version_conflict", "current_version": N}`.
- Project archive blocked by active runs: `409` with `{"code": "project_has_active_runs", "run_ids": [...]}`.
- Domain rejection: `422` with `{"error": "...", "detail": ...}` or `{"error": "..."}`.

Other ingress paths are separate:

- Workflow install/remove: `POST /api/admin/workflows/install` and
  `POST /api/admin/workflows/remove`.
- Webhooks: `/webhooks/github` (HMAC-signed; see
  [PR creation and merge reconciliation](#pr-creation-and-merge-reconciliation)),
  `/webhooks/external_trigger` and `/webhooks/operator/ingest` (both currently
  unauthenticated — do not expose them beyond a trusted network).
- MCP: `/mcp` (also stdio; see [MCP tool integration](#9-mcp-tool-integration)).
- Dev-only dashboards: `/debug/*` (dev env only).
- Bearer-token guarded dashboards (every env): `/dashboard` for the Jido live dashboard and `/dashboard/runs` for operator run management.

Read endpoints are projection-only:

- `GET /api/runs/{id}` returns `{run: ...}` with stringified keys, or
  `{error: "run_not_found", run_id: "..."}` with `404`. Every projected
  run carries `pr_url` — the URL of the PR the run opened, or `null`
  when Foreman recorded none. `GET /api/runs` carries the same field on
  each listed run.
- `GET /api/tasks/{id}`, `GET /api/projects`, `GET /api/projects/{id}`,
  and `GET /api/queue` expose corresponding projections.
- Threads: `GET /api/projects/{project_id}/threads` (filters `status`,
  `door=workflow|jobsite`, `limit` 1..500, default 100) and
  `GET /api/threads/{id}` (`run:<run_id>` or `jobsite:<jobsite_id>`) unify
  tasks, runs and jobsites. Fields: `id, door, project_id, task_id, title,
  status, branch, repo_path, pr_url, last_report {verdict, summary, at},
  provider_session_id, resolved, steering, run_ids, created_at, updated_at`.
  `steering` is always `"pause_resume"`, the guaranteed fallback (a live claude/pi
  phase takes a steer in-session first; see Steering below); `resolved` is `true` after `thread.resolve`
  until `thread.reopen`.
- Thread actions: `POST /api/threads/{id}/stop` (`run.cancel` / jobsite
  cancel), `POST /api/threads/{id}/steer` (`text`, optional `message_id`,
  `resume`; 202, 409 `not_steerable` for a terminal thread). Operator commands
  `thread.resolve` / `thread.reopen` (events `ThreadResolved` /
  `ThreadReopened`) are sent through `POST /api/commands` or
  `foreman thread resolve|reopen`; resolving is a disposition flag and never
  stops a run.
- Thread transcript: `GET /api/threads/{id}/transcript?after=&limit=` pages
  structured turns; `GET /api/threads/{id}/stream?after=` is the SSE tail.
  Caveat: the workflow transcript comes from the bounded `run_logs` tail, so
  `omitted_entries` > 0 / `truncated: true` means older output was dropped;
  jobsite turns have no timestamps and jobsite threads have no operator turns
  (jobsite resume prompts are not persisted as events).
- Thread lookup: `GET /api/projects/{project_id}/threads/find?q=&external_id=&branch=&pr=`
  (MCP `foreman_thread_find`) ranks exact `external_id`, branch and PR matches
  above conservative text matches (suggestions only; resolved/deleted threads
  are never text matches). It is read-only and never starts a run.

#### Steering v1 and thread housekeeping

**Live steering (claude, pi).** A phase run by `claude` or `pi` is started with streaming
input. `run.steer` writes your message into that running session: the provider queues it
and takes it after the tool call in flight (no interrupt, no pause, same provider session,
no phase boundary). The run records `RunSteerDelivered` (written), then `RunSteerConsumed`
with `delivery: "live"` when the agent took it. If the session already closed its input,
no agent is running, or the provider has no streaming input, the steer falls back to the
pause/resume flow below. A steer the run ends without taking (it completed or failed
first) is recorded `RunSteerUndelivered` with the reason, listed under the run's
`undelivered_steering`, and shown in the thread transcript; it is never dropped silently.
Disable with `config :foreman_server, :live_steering, enabled: false`.

Pause/resume flow. `run.steer` queues a
`RunSteerQueued` event (durable, idempotent per `message_id`); the run is
paused (the executor commits partial work while it unwinds) and resumed with
the message appended to the next phase prompt. When that prompt is built the
system-only command `run.steer.consume` appends `RunSteerConsumed`, so the
message is injected once and survives a server restart.
`run.steer.consume` is deliberately not operator-allowlisted. A jobsite thread
steers through `Jobsite.steer/3`, i.e. the jobsite `resume` with the message
as its `prompt` (`POST /api/jobsites/{id}/resume`).

Terminal threads with no PR are resolved automatically after a period of
inactivity by `ForemanServer.Threads.IdleResolver`:

```elixir
config :foreman_server, :threads,
  idle_resolver: true,           # start the resolver (default true)
  idle_resolve_after_days: 7,    # idle period (default 7)
  sweep_interval_ms: 3_600_000   # sweep period (default one hour)
```

### Project Overview

`GET /api/projects/{project_id}/overview` (query `include_resolved=true|false`,
default false; `resolved_limit` 0..200, default 20) answers "what needs me?".
The body has `project_id`, `groups`, `counts`, `attention`, `tabs` and
`generated_at`. `groups` has six string keys, each a list of thread cards
(newest first): `ready_for_review` (PR open and merge gate pending, or a
completed thread with a `met`/`partially_met` review and an open PR),
`waiting_on_you` (pending approval or question, blocked/stuck, failed, PR
conflict, plain pause, review `not_met` on an open PR, or failing CI on an open PR: reason `ci_failing`, from the E9 PR watch's `checks_state`, even while the merge gate is pending; or an outstanding CHANGES_REQUESTED review (reason `changes_requested`) or an unresolved review thread (reason `review_threads`) on an open PR, from the same watch's `review_decision` and `thread_ids`; conversation comments alone do not count because they have no resolved state; when CI is failing too the reason stays `ci_failing` and the review reason shows once CI clears; all of them clear on the next PR observation after the review is resolved), `working`, `landing`
(merge approved, PR still open), `idle` and `resolved` (flag, PR merged or
closed, cancelled). `attention` is `{needed, count, reasons}`: needed when
`waiting_on_you` or `ready_for_review` is non-empty. An unknown project is
`404 project_not_found`.

`tabs` carries `pull_requests` (live), and `library` / `scheduled`, which read
`{"available": false, "rows": []}` until those features register a tab provider.
`GET /api/projects` and `GET /api/projects/{id}` gain `attention` and
`attention_count`; the MCP read tool `foreman_overview` returns the same
overview for one project, or one attention line per active project without
`project_id`. Pending approvals and open questions feed `waiting_on_you` (see
[Needs you: approvals and questions](#needs-you-approvals-and-questions)). When a PR merges, `Overview.MergeResolver` resolves its thread
automatically (reason `pr_merged`; a thread you reopened after the merge stays
open). **Merging remains an operator action** (`merge_approve`, then
`run.pr.merge`): no overview or MCP surface can merge or approve; cards only
carry the text hint `operator: foreman run approve-merge/merge`.

### Operator run dashboard

Open `/dashboard/runs` with the same bearer token accepted by the browser dashboard guard: `Authorization: Bearer <token>` or `?token=<token>`. The route fails closed with `401 unauthorized` when the token is missing, wrong, or `:api_bearer_token` is unset. `/dashboard` remains the separate Jido live dashboard.

The run dashboard lists projection-backed runs, task/ad-hoc context, phase status, PR markers, durable worker logs, and read-only change evidence. Logs are read from `ProjectionStore.run_logs/1`; server `Logger` output is not copied into run logs. Missing worktrees, branches, bases, or PR evidence show explicit unavailable states rather than shelling into private paths.

Run controls use the public command boundary:

- **Stop** pauses the run with `run.pause` and default reason `operator_pause`.
- **Resume** continues a paused run with `run.resume`.
- **Restart / Reset** uses `run.reset` only for eligible failed/stuck/recovery states.
- **Abandon** removes the run with `run.remove` and may trigger Foreman's existing cleanup path.
- Terminal **Cancel**, when exposed separately, is labelled Cancel and is not Stop.

Rejected commands display their typed/domain reason and keep the last known projection state visible. The page refreshes on a bounded timer and marks stale data if refresh fails.

## 3. Ad-hoc task dispatch (unified with the task path)

There is a single dispatch ingress: `task.create` (+ `task.approve`). A
task may carry a `prompt` and skip tracker/Beads issue creation entirely
by setting `provider_tracked: false`; setting `auto_approve: true` on
the same `task.create` call immediately approves and dispatches it, so a
caller gets one-call ad-hoc dispatch without a separate `task.approve`
round trip.

Example command envelope:

```json
{
  "type": "task.create",
  "command_id": "op-task-1",
  "aggregate_id": "task:adhoc-abc123",
  "payload": {
    "task_id": "adhoc-abc123",
    "project_id": "foreman",
    "task_type": "task",
    "workflow_type": "fix",
    "title": "Update docs/user-guide.md for issue #410",
    "prompt": "Update docs/user-guide.md for issue #410",
    "provider_tracked": false,
    "auto_approve": true
  }
}
```

Current behavior:

- `task_id` and `project_id` must be non-empty; `project_id` must refer
  to an existing, non-archived project.
- `prompt` is optional; when present it is written into
  `workflow_snapshot["input"]["prompt"]` at approval time and rendered
  into any `{{input.prompt}}` / `{{input.prompt_argument}}` command
  placeholders.
- `provider_tracked` defaults to `true` (matches every pre-existing
  tracker-backed task). Set it to `false` for ad-hoc dispatch: the task
  aggregate skips the synchronous Beads/tracker `create` call at
  `task.create` time, and `RunExecutor` skips claim/complete/fail
  callbacks during the run.
- `auto_approve` is consumed by the gateway only — it is never
  persisted on `TaskCreated`. On success, `CommandGateway` immediately
  dispatches the matching `task.approve` (deterministic `command_id`,
  so a retried `task.create` cannot mint a second approval) and returns
  *that* result to the caller, so the HTTP response carries
  `approval_id` and `run_id` alongside `task_id`.
- HTTP response is `201` with `{status: "accepted", result: ...}`. Treat
  this as acknowledgement; read `GET /api/tasks/{task_id}` and
  `GET /api/runs/{run_id}` for the stable projections.

## 4. CLI work and run commands

### `foreman run submit`

```text
foreman run submit --workflow <name> --prompt <text> --project-id <id> [--work-id <id>] [--backend <backend>] [--base-branch <branch>]
```

`foreman run submit` posts a `task.create` envelope with
`provider_tracked: false` and `auto_approve: true` — this is the CLI's
ad-hoc dispatch verb, unified onto the task path described above.

- `--workflow` is required. Workflow names are validated server-side by
  `Catalog.load/1`; there is no client-side allowlist.
- `--prompt` is required.
- `--project-id` is required and must name an existing non-archived
  project.
- `--work-id` is optional and is an alias for the minted task ID; the
  CLI generates `adhoc-<hex>` when omitted (minted client-side so the
  server's no-id `task.create` flow, which resolves the ID through the
  task provider, is never triggered for an untracked task).
- `--backend` is optional. The CLI accepts `pi`, `claude`, `codex`, and
  `opencode`; it omits the field when the value is the default `pi`.
  This is a client-side readiness label only — see the caveat below.
- `--base-branch <branch>` is optional and captured at the protocol
  level only per
  [TRD-2026-80ba0665](TRD/completed/TRD-2026-80ba0665-branch-parent-resolution.md).
  The default parent branch is the operator's checkout, not `"main"`:
  `RunExecutor` records `git symbolic-ref --short HEAD` of the project
  checkout when the run's first phase starts, and AutoPR opens the PR
  against that branch. A detached checkout resolves to no branch at
  all, which is a logged error and no PR rather than a fallback. Use
  `gh pr edit <n> --base <branch>` to retarget a PR that needs a
  different base.

Backend caveat: `--backend` is a client-side value only — the payload
key is dropped by `task.create` (the aggregate builds its `TaskCreated`
payload explicitly field-by-field and ignores unrecognized keys), so it
never reaches admission. Current Jido Harness execution supports `pi`
and `claude` providers only; `codex` and `opencode` remain stale
CLI-accepted values until (if ever) a provider adapter is added for
them.

For arbitrary server workflow manifests (e.g. `implement-trd`,
`implement-trd-beads`), `run submit` cannot help — those need a
`--trd-path`, which it does not accept. `foreman task create
--workflow-type ...` followed by `foreman task approve` used to be
the way to run them, but both verbs are REMOVED (TRD-018,
2026-09-13). Create a bead instead, with `--agent-context
'{"trd_path":"<project-relative-path>"}'` and a `--type` that maps to
the target workflow, then transition it to `status: open`;
BeadsWatcher reads `agent_context.trd_path` and dispatches the
internal `task.create` + `task.approve` pair automatically (a bead
missing a required `trd_path` is instead moved to `blocked` with an
explanatory comment).

### Task dependencies at approval

`foreman task approve` is REMOVED (TRD-018, 2026-09-13). The guard
behavior below still describes the internal `task.approve` command,
exercised automatically by BeadsWatcher's auto-approval — not a CLI
verb an operator can invoke directly.

A task may carry a `dependencies` list of other task ids. The internal `task.approve` command
refuses while any of them is not `closed`, reporting
`{:task_dependencies_unsatisfied, [{id, reason}]}` with **every** unsatisfied
dependency in declaration order — a status string, `:not_found` for an id with no
task, or `:malformed` for a non-string id or an empty string. `failed` does not
satisfy: the dependency is finished but did not produce the work the dependent
task needs.

An idempotent approval retry — re-sending the same `command_id` for an approval
that already committed — bypasses the check entirely, so a dependency that has
since been reopened cannot turn a succeeded approval into a reported failure.

The value must be a list. Since it is settable only through a raw JSON payload
(see below), `task.create` refuses a present non-list up front as
`{:invalid_envelope, :invalid_dependencies}` — omitting the field is still fine.
A malformed value stored before that validation existed refuses the approval as
`{:task_dependencies_malformed, value}` rather than being silently read as "no
dependencies".

This is a guard, not a scheduler. Nothing dispatches the task
automatically when its last dependency closes. `foreman task approve`
is REMOVED (TRD-018, 2026-09-13); BeadsWatcher dispatches
`task.approve` only once, at bead import (TRD-007), so there is
currently no operator-invocable path to retry approval after a
dependency later closes — the same category of gap as `task.retry`
below. There is also no ordering or cycle detection.

The Go CLI has no `--dependencies` flag, so the field is settable only through a
raw `POST /api/commands` `task.create` payload, the same as `priority`. And
dependencies can only be set at creation: no `task.*` command adds one to an
existing task.

Before this guard existed the list was accepted, stored, and written onto
`TaskCreated` while nothing read it, so a task with unmet dependencies
dispatched immediately.

### `foreman task retry` — REMOVED (TRD-018)

`foreman task retry --id <task-id> [--reason <text>]` no longer
exists: TRD-018 (2026-09-13) deleted it along with `task create`/
`approve`/`get`. Invoking it now produces the CLI's standard "unknown
command" error, and no CLI replacement exists for retrying the
internal `task.retry` command — it remains internal-only. The guard
behavior it exposed is unchanged:

Use `task.retry` only for a task whose bound run is already terminal.
`CommandGateway` reads the task projection, verifies the bound run
exists, checks `terminal? == true`, requires matching `task_id`, then
attaches trusted terminal attestation fields (`acknowledged_run_id`,
`acknowledged_at`, `run_terminal_reason`). The Task aggregate then
clears run-bound fields and returns the task to `open`.

The retry is rejected when the task is missing, has no bound run,
references a missing run projection, references a run bound to another
task, or the run is not terminal.

## 5. Task lifecycle

Task lifecycle is event-driven:

```text
open -> ready -> in_progress -> closed | failed
blocked -> ready -> in_progress -> closed | failed
```

Lifecycle details:

- `task.create` defaults status to `open`; the aggregate also
  recognizes `blocked` as a valid non-terminal task status.
- `task.approve` enriches the operator payload with trusted workflow
  data and moves an `open` or `blocked` task to `ready`.
- Dispatch requires `ready` plus bound `run_id`/`approval_id`; it emits
  `TaskDispatched`, moving the task to `in_progress`.
- Terminal execution emits `TaskExecutionCompleted` or
  `TaskExecutionFailed`. The task projection stores success as `closed`
  and failure as `failed`.
- `task.retry` is only for a task still bound to a terminal run, or
  already `failed` by the terminal invariant. Success clears run-bound
  fields and returns the task to `open`.

Run projections use a separate, wider status vocabulary: `completed`,
`failed`, `blocked`, `deleted`, `stuck`, or `cancelled`, depending on
the terminal event.

## 6. Worker runtime and Overwatch

`ForemanServer.Overwatch` is enabled by default outside tests. Command
phases run through this path:

```text
RunExecutor -> Overwatch.start_phase/2 -> LaunchWorker -> JidoHarnessWorker
```

Current behavior:

- `RunExecutor` materializes the phase prompt, chooses the Jido Harness
  provider from the request context, builds the execution cwd/env, and
  calls `Overwatch.start_phase/2`.
- `LaunchWorker` starts the adapter, registers the worker pid with
  `Overwatch.Tracker`, emits `WorkerStarted` with sequence `0`, then
  sends the activation handshake.
- A newly reserved run can be admitted as `awaiting_worker`;
  `WorkerStarted` is the signal that moves the run to `in_progress`.
- `JidoHarnessWorker` runs `Jido.Harness` in a supervised task after
  activation, emits periodic `WorkerHeartbeat`, emits `WorkerExited` on
  normal completion, forwards normalized `{:ok, text} | {:error,
  reason}` to `RunExecutor`, then exits normally so the supervisor can
  clean up.
- If the harness task crashes before returning a result, the worker
  emits best-effort `WorkerExited` and forwards `{:error,
  {:task_crashed, reason}}`.
- Worker relaunch is crash-only: a worker that finished the phase
  (`:normal`) or was torn down (`:shutdown`) ends the child, while a
  crashed worker is relaunched and counted by
  `Overwatch.CrashLoopDetector`.

## 7. Agent runtime and Jido Harness

The only bundled runtime adapter is the in-process
`ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter`. There is no
shell-out CLI adapter and no separate worker process — agent execution
happens inside the Elixir server.

Default runtime config:

```elixir
config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: [ForemanServer.AgentRuntime.Adapters.JidoHarnessAdapter],
  agent_strategy: :react,
  agent_model: "auto"
```

The adapter routes through `ForemanServer.AgentRuntime.JidoHarness` and
the vendored `Jido.Harness` package. Supported upstream providers are
`:pi` and `:claude` (`JidoHarness.@supported_providers`).

Provider semantics:

- Requests default to `:pi` unless runtime context sets
  `provider: :claude`.
- A LiteLLM proxy is NOT a provider here: it is a model dispatcher
  reached *through* the `:pi` provider by declaring a model name the proxy
  serves. `:litellm` is not a valid `provider:` value — it returns
  `:unsupported_provider`. To route through a proxy, configure the provider
  entry with its `baseUrl` and an explicit `models` array in
  `~/.pi/agent/models.json` (the pi coding agent reads that file for custom
  provider definitions; pi 1.2.0 does not discover models from `baseUrl`
  alone) and reference one of its models, qualified, in `models.default`.
  Routing a proxy through `:claude` instead requires that endpoint to be
  configured on the claude side (`ANTHROPIC_BASE_URL` via the adapter's env),
  which `~/.pi/agent/models.json` does not affect.
- Unknown providers return `:unsupported_provider`.
- A selected but unavailable provider returns `:backend_unavailable`
  without falling back to another provider.
- `JidoHarnessAdapter.available?/0` checks whether either bundled
  provider is installed.

## 7.2 Model and provider selection

Each workflow YAML phase can declare a model at `phases[].models.default`,
which flows through `RunExecutor → base_context → JidoHarness → pi CLI
--model` flag. The phase model overrides the provider's built-in default
model. Example:

```yaml
phases:
  - name: assess
    prompt: assess.md
    models:
      default: minimax/MiniMax-M2.7
```
A phase may also declare `provider:` in its `context:` block to select
`:claude` instead of the default `:pi`. A model served by a LiteLLM proxy is
reached through the `:pi` provider with the proxy's model name, qualified
(`litellm-stack/smart_router` means pi provider `litellm-stack`, model
`smart_router`) — never `provider: :litellm`, which is not a provider (§7).

Foreman does NOT route model selection based on the model name itself —
it passes the declared model string verbatim to the selected provider's
command line. The operator decides which provider ships which model
via `models.json` configuration.

### Qualified model strings

When a phase declares `provider:` and `models.default` together, `models.default`
MUST be the qualified `"<upstream-provider>/<model-id>"` form the provider's own
catalog prints (e.g. `minimax/MiniMax-M2.7`) — not a bare vendor or model name.
A manifest that pairs a `provider:` with an unqualified `models.default` is
refused at load time, naming the phase index, the offending value, and the
expected shape; the two declarations would otherwise describe different things
and could never resolve to a catalog row. Declaring `models.default` alone, with
no `provider:`, stays legal and matches on the model column only.

**`provider: claude` is the exception.** The claude CLI takes a bare alias or model
id (`haiku`, `sonnet`, `claude-sonnet-4-5`) and rejects `<x>/<y>`, so a phase with
`provider: claude` must pin `models.default` as a bare value, the same form as the
project's `thread_model` for claude threads. A slashed value (`claude/haiku`,
`litellm-stack/smart_router`) is refused at load time with a message naming the
phase and the value; a proxy model is reached through `provider: pi`. Foreman still
never infers the provider from the model name, and passes the string verbatim.

```yaml
  - name: review
    provider: claude
    models:
      default: haiku
```

### Provider/model preflight

Before a run's first phase dispatches, every phase that declares a `provider:`
or a `models.default` is checked. Two of those checks are universal and one is
not: provider support (`:provider_unsupported`) and CLI presence
(`:provider_not_installed`) are evaluated for every declared provider, but the
live model-existence query is implemented for `pi` only — a `claude` phase
whose model the harness cannot load passes this preflight and fails later at
dispatch. A run that fails stops with zero dispatched phases and its terminal
reason is
`{:provider_model_preflight_failed, [%ForemanServer.Workflow.PreflightFailure{}]}`
— one struct per offending phase, carrying `phase`, `provider`, `model` and a
`class` that distinguishes four causes:

| `class` | Meaning |
| --- | --- |
| `:provider_unsupported` | not a provider Foreman supports |
| `:provider_not_installed` | supported, but its CLI is absent from this host |
| `:model_not_found` | the catalog was asked and answered: not present |
| `:catalog_unavailable` | the catalog could not be asked (timeout, non-zero exit, or `pi` missing from `PATH`) |

An unanswered query is never reported as an absent model — `:catalog_unavailable`
says "we don't know", `:model_not_found` says "it isn't there". The class lands
in the run record, so a failure is diagnosable from `foreman run get <run-id>`
without re-running the dispatch.

## 7.3 pi provider configuration

Models served by a LiteLLM proxy are reachable through the `:pi` provider only
when pi itself knows the proxy — a provider entry in
`~/.pi/agent/models.json` (or `$PI_CODING_AGENT_DIR/models.json`):

```jsonc
{
  "providers": {
    "litellm-stack": {
      "baseUrl": "http://127.0.0.1:4000/v1",
      "api": "openai-completions",
      "apiKey": "<the proxy master key>",
      // pi 1.2.0 does not discover models from `baseUrl` alone: an omitted
      // `models` array is an EMPTY list, so name every model you intend to
      // reference or `pi --list-models` returns no rows for this provider.
      "models": [
        { "id": "smart_router" }
      ]
    }
  }
}
```

Without that entry, `pi --list-models <provider>/<model>` finds nothing, a
phase declaring e.g. `models.default: litellm-stack/smart_router` fails the
model preflight with `:model_not_found` (§7.2). The provider key is pi-side
configuration — it is NOT a Foreman `provider:` value; Foreman still runs the
`:pi` provider. See the pi coding agent docs for the full models.json schema.

The bundled `assess`, `fix`, `prd` and `review` workflows run their pi review
phases with `provider: pi` and **no `models:` pin**, so the model is the
project's `thread_model` setting, else pi's own default. A bundled workflow must
not pin an operator-specific model such as `litellm-stack/smart_router`: a host
whose pi catalog lacks it fails the pre-phase-1 preflight with `model_not_found`
(or `400 Invalid model name` at the proxy). To use a proxy router model, set the
project's `thread_model` (e.g. `litellm-stack/smart_router`, with that provider
in `models.json` as above) or pin `models.default` in your own installed copy.
After editing bundled workflows run `foreman init --force` to refresh the
installed copies.

### 7.4 Bundled skills

Skills bundled at
`packages/foreman_server/priv/defaults/skills/<name>/SKILL.md` are installed to
`~/.foreman/skills/<name>/` by `ForemanServer.Skills.Installer`, which the
`ForemanServer.Workflow.Catalog` GenServer invokes from `init/1` at server boot. Every boot
it copies only the bundled skills not already present there, so a skill added to the bundle in
a later release reaches an operator who already has one installed, while an existing
`SKILL.md` is never overwritten — an operator edit survives restarts. To refresh an installed
skill after editing a bundled one, delete that installed directory (or the whole
`~/.foreman/skills` directory) and restart the server.

The bundle source is resolved at runtime through `Application.app_dir/2`, not through a
compile-time `__DIR__`, so a Mix release that ships `priv/` without the source tree still finds
its skills. When the install finds nothing to copy, the reason is reported rather than left as a
silent success: an absent bundle directory is `{:error, {:bundled_skills_missing, path}}`, a
`:source_dir` passed explicitly to `install/1` is `{:error, {:source_dir_missing, path}}`, and a
directory that exists but holds no skills is a plain `{:ok, :noop}`. Either error is logged at
`error` with the path that was looked in. The second code has no production caller today — the
boot hook resolves the bundle itself and no CLI flag or MCP tool sets a skills `:source_dir` —
so it exists for direct `Installer.install/1` callers and tests, and to keep the two causes from
collapsing into one if such a caller is added.

Two boundaries worth stating plainly: `~/.foreman/skills` is computed by
`ForemanServer.Skills.Installer.target_dir/1` and is NOT a directory the `pi`/`omp` CLIs scan
for skills (`packages/foreman_cli/cmd/foreman/agent_commands.go` renders skill files under
`.pi/agent/skills` instead), and `foreman init --force` refreshes workflows and prompts only,
never skills. A skill placed anywhere other than `~/.foreman/skills` is invisible to
`maybe_install/1`'s missing-skill check.

`foreman-jobsite-template` is the bundled skill for authoring Remote Jobsite
scripts: it turns a natural-language description into a `Jobsite.Spec.from_json/2`
whitelist-compliant spec plus its `.exs` runner, and its `scripts/validate_spec.py`
checks the spec offline against the same key rules the server enforces.

## 8. Telemetry, OTel, LiteLLM, and Langfuse

Local stack topology:

```text
Foreman OTLP exporter -> ops/otel-collector -> Langfuse v3
```

Defaults and env vars:

- Foreman OTel defaults to `http://localhost:4318` in `config/config.exs`.
- `devbox run up` starts `ops/otel-collector`, which listens on local
  `4318`/`4317` and joins the `litellm-langfuse-stack_default` Docker
  network.
- The collector forwards traces with `otlphttp/langfuse` to
  `http://langfuse-web:3000/api/public/otel`; the exporter appends
  `/v1/traces`.
- Langfuse v3 OTLP ingest requires HTTP Basic auth using
  `LANGFUSE_PUBLIC_KEY:LANGFUSE_SECRET_KEY`. Bearer auth with only the
  public key returns `403`.
- In production, set `OTEL_EXPORTER_OTLP_ENDPOINT` when
  `http://localhost:4318` is not the target collector/ingest URL.
- LiteLLM defaults to `LITELLM_ENDPOINT=http://localhost:4000`;
  `agent_model: "auto"` maps through `:jido_ai` model aliases to
  LiteLLM.

SigNoz operational logs are separate from the Langfuse LLM-trace path.
Foreman keeps Langfuse traces on `OTEL_EXPORTER_OTLP_ENDPOINT` and adds an
opt-in Phoenix Logger bridge for operational logs only:

- `FOREMAN_SIGNOZ_LOGS_ENABLED=true` enables the bridge.
- `FOREMAN_SIGNOZ_OTLP_ENDPOINT` points at the collector/SigNoz OTLP logs
  endpoint; default is `http://localhost:4318/v1/logs`.
- `FOREMAN_SIGNOZ_OTLP_HEADERS` accepts comma-separated `key=value` headers.
  Diagnostics report only endpoint host/port and never header values. Setting
  any header requires `FOREMAN_SIGNOZ_OTLP_ENDPOINT` to use `https://`; boot
  raises otherwise to avoid sending credentials over plaintext.
- `FOREMAN_SIGNOZ_LOG_LEVEL` defaults to `info` in production.
- Test config remains no-network: log export is disabled unless a test installs
  the capture exporter explicitly.
- `ops/otel-collector/signoz-logs.example.yaml` is a reference collector logs
  pipeline: OTLP receiver -> batch processor -> `otlphttp/signoz_logs`.

These four env vars are parsed once into `config :foreman_server, :signoz_logs`
in `packages/foreman_server/config/config.exs`.

Retention is enforced by SigNoz/storage, not Foreman. Use a 30-day default
retention policy for Foreman operational logs unless the deployment has a
stricter compliance requirement.

## 9. MCP tool integration

The server exposes an MCP endpoint at `/mcp` (HTTP, recommended) and via
`mix foreman.mcp.stdio` (stdio, for clients that spawn a child process).
Both transports share `ForemanServer.MCP.Dispatch`, so their tool sets
and behavior cannot diverge.

**Read tools** are always advertised: `foreman_doctor`,
`foreman_queue_status`, `foreman_project_list`, `foreman_project_get`,
`foreman_workflow_list`, `foreman_workflow_get`,
`foreman_workflow_validate`, `foreman_prompt_get`,
`foreman_run_get`, `foreman_run_status`, `foreman_run_get_logs`,
`foreman_run_get_events`, `foreman_run_get_activity`, `foreman_inbox_get`,
`foreman_task_list`, `foreman_task_get`, `foreman_project_settings_get`, `foreman_project_repo_list`, `foreman_usage_get`, `foreman_project_environment_get`,
`foreman_project_recommendations`, `foreman_thread_list`, `foreman_thread_get`, `foreman_thread_transcript`,
`foreman_thread_find`, `foreman_overview`.
The write-gated thread tools are `foreman_thread_stop` and
`foreman_thread_steer`.

- `foreman_run_status` returns a bounded status DTO from run and phase
  projections (`run_id`, `status`, `terminal`, `project_id`, `task_id`,
  `workflow_name`, `current_phase`, timestamps, `failure_reason`, and the
  provider's own `provider_session_id` / `provider_sessions` once a phase's
  agent has reported one, and cumulative `usage` tokens and provider-reported
  `cost_usd`, `null` where unknown).
- `foreman_run_get_logs` reads durable worker stdout/stderr events from
  `worker:<run_id>:<worker_id>` streams. Known runs with no output return
  an empty result; unknown runs return `NOT_FOUND`.
- `foreman_inbox_get` reads operator-facing run progress messages from the
  per-run inbox projection. Use it alongside logs/events/activity: inbox
  messages are agent-authored progress notes, logs are raw stdout/stderr,
  events are durable system facts, and activity is heartbeat/liveness data.

**Write tools** (`foreman_task_create`, `foreman_task_update`,
`foreman_task_add_comment`, `foreman_run_cancel`, `foreman_run_pause`,
`foreman_run_resume`, `foreman_inbox_send`, `foreman_workflow_put`,
`foreman_workflow_delete`, `foreman_prompt_put`, `foreman_project_settings_update`,
`foreman_project_pause`, `foreman_project_resume`, `foreman_project_memory_write`,
`foreman_project_memory_forget`, `foreman_schedule_create`,
`foreman_schedule_pause`, `foreman_schedule_resume`, `foreman_schedule_delete`) are unadvertised and refused unless
`allow_workflow_writes: true` is set in `:foreman_server, :mcp` config.

**Coordinator conversation tools.** `foreman_project_conversation` (read-only:
`project_id`, `after?`, `limit?` 1..200) returns the same page as
`GET /api/projects/<id>/coordinator/messages` (`messages`, `next_cursor`,
`has_more`, `truncated_before_seq`, `status`). `foreman_project_message`
(`project_id`, `text`, `message_id?`) sends an operator message to the
coordinator; it is write-gated like the tools above, its source is always
`mcp` (the caller cannot choose it), and it is rate limited per project by
`config :foreman_server, :coordinator, mcp_messages_per_minute` (default 6;
beyond it the tool returns `RATE_LIMITED`). No coordinator tool can merge,
approve, archive, register, retry, cancel, reset or remove anything.

Coordinator HTTP routes (bearer token): `POST /api/projects/:id/coordinator/messages`
(`{text, message_id?, source?}` with `source` one of `cli|http|dashboard`, -> 202
`{message_id, seq}`; a repeated `message_id` is a no-op), `GET
/api/projects/:id/coordinator/messages?after=&limit=&wait_ms=` (long-poll, `wait_ms`
0..25000), `GET /api/projects/:id/coordinator` (status) and `POST
/api/projects/:id/coordinator/restart`. Errors: 404 `project_not_found`, 409
`project_archived`, 413 `message_too_large`, 422 `invalid_*`.

`foreman_project_settings_get` returns the same typed payload as
`GET /api/projects/<id>/settings` (`project_id`, `status`, `settings`, `limits`;
no env values). Project reads over HTTP and MCP replace `config.env` /
`config.environment` values with `"[redacted]"` (keys, `name`, `task_provider` and
`database_path` stay visible). The write tools `foreman_project_settings_update`
(arguments: `project_id`, `goal`, `instructions`, `thread_model`, `thread_effort`,
`coordinator_provider`, `coordinator_model`, `coordinator_effort`,
`max_concurrent_runs`, `daily_thread_cap`, `coordinator_propose_before_start`,
`coordinator_max_active_threads`, `coordinator_reuse_threads`, `library_collect_produced`, `pr_auto_fix`, `notification_preference`, `clear`, `idempotency_key`; nothing
else), `foreman_project_pause` and `foreman_project_resume` dispatch the same
operator commands as the CLI, are refused unless `allow_workflow_writes: true`, and
report the server's error code (`instructions_too_long`, `project_paused`, ...).
Retries of `foreman_project_settings_update` with the same arguments and
`idempotency_key` are one command. No MCP tool can merge or approve.

`foreman_schedule_list` (read, always available) returns the same DTOs as
`GET /api/projects/<id>/schedules`; the four schedule write tools are described in
[Scheduled tasks](#122-scheduled-tasks).

**Project-workspace tools by area.** Overview: `foreman_overview`. Threads:
`foreman_thread_list|get|transcript|find` (read), `foreman_thread_stop|steer`
(write-gated). Memory: `foreman_project_memory_list|read` (read),
`foreman_project_memory_write|forget` (write-gated). Library:
`foreman_project_library_list|read` (read only; there is no agent write tool).
Approvals and questions: `foreman_approvals_list`, `foreman_questions_list`
(read only). PR watching: `foreman_pr_status` (read), `foreman_pr_fix` and
`foreman_pr_watch_stop` (write-gated; neither can merge). Usage:
`foreman_usage_get`. Setup: `foreman_project_recommendations`. The exact
advertised set, the write-gated subset and the rule that no tool merges or
approves are pinned by `test/foreman_server/mcp/tool_inventory_test.exs` and
`test/foreman_server/mcp/no_merge_tool_test.exs`.

`foreman_inbox_send` appends concise progress to the run inbox via the public
`inbox.send` operator command. It requires `run_id` plus a 1-2,000 character
`body`, accepts optional caller-stable `message_id`/`command_id`, and only
allows JSON-safe metadata keys `phase_id`, `worker_id`, `session_id`, and
`severity`. Prompts tell agents to send phase start, material milestone,
blocker, and phase completion notes when the tool is available, never secrets,
prompts, large logs, or command output; denial/unavailability must not block
work. Built-in `prd`/`fix` command phases receive the same guidance through a
worker `system_prompt` sidecar, so their slash-command prompt text stays
unchanged.

`foreman_task_add_comment` appends a structured Work Log comment to the task
provider issue bound to a run. It requires `run_id`, `workflow_name`,
`phase_name`, and a 1-2,000 character `description`; Foreman resolves the task
and provider issue server-side, composes the comment body, and does not accept a
Beads id, provider issue id, or raw body from the caller. Bundled prompts tell
agents to use it at phase start, material milestones, blockers, and completion;
denial/unavailability must not block work.

After editing bundled prompts or workflows, run `npm run build` if assets
need regeneration and `foreman init --force` to install fresh runtime
copies.

Tool call failures are MCP tool errors carrying the gateway's
structured reason, never transport-level JSON-RPC errors.

- `foreman_task_list` lists all tasks, optionally filtered by
  `project_id` and canonical `status` (`open`, `ready`, `in_progress`,
  `blocked`, `closed`, `failed`). It supports `limit` (default 100, max
  500) and `offset` (default 0), and returns `{tasks, total, limit,
  offset, next_offset}`.
- `foreman_task_get` returns the full projection for one task.
- `foreman_task_update` updates mutable task fields (`title`,
  `description`, `priority`, `status`). Requires `task_id` and at
  least one field to update.
- `foreman_run_cancel` dispatches `run.cancel` with `run_id` and
  `reason`; the dispatched agent, including its OS-level process, is
  killed via `RunControl`.
- `foreman_run_pause` dispatches `run.pause` with `run_id` and `reason`,
  interrupting the current phase after committing its partial work and
  leaving the run resumable.
- `foreman_run_resume` dispatches `run.resume` with `run_id`, re-entering
  the run at its first non-completed phase.


## 10. Task-provider (Beads) enablement

A project links to a task tracker by setting a `task_provider` block in
its project config (`provider:` + `config:`, including `database_path` for
the Beads JSONL/db). `bv`/`br` remain the only writers of that store from
outside Foreman; see the "Per-DB Beads lease" section of `docs/lessons/architecture-and-events.md` for the
write-serialization guarantee Foreman itself provides once a run is admitted.

- **Atomic `task.create`.** For a project with a configured `:create`
  provider, `task.create` mints the Bead and emits `TaskCreated`
  together (`ForemanServer.Aggregate.Actor`'s four-stage pipeline); the
  Bead id comes back as `external_id`. `foreman task create` is
  REMOVED (TRD-018, 2026-09-13); recover the Bead id via `GET
  /api/tasks/:id` instead of CLI stdout output. A project without a
  `:create` provider takes the no-op path: no Bead, no `external_id`.
- **Inbound sync.** Set `config :foreman_server, :start_beads_watcher?,
  true` to run one `BeadsWatcher` per registered project, rescanning its
  JSONL from scratch on every fs event/poll (relying on the projection
  store for dedupe, not a byte-offset cursor) and dispatching
  `task.create` for Beads Foreman doesn't yet own.
  **Dispatch partitioning via label gate (opt-IN).** By default, only Beads
  tagged with the `"foreman-exec"` label dispatch to Foreman; all others skip
  and route to external processors. Operator workflow: `br update <bead-id>
  --add-label foreman-exec` to include in Foreman dispatch (never `--labels`,
  which is an alias of `--set-labels` and replaces all existing labels); omit the label to
  route externally (default). Labels are Beads-native; use `br show <id>
  --json` to verify a bead's labels before claiming. A bead whose `labels`
  field is absent, or is a list without `"foreman-exec"`, routes externally
  without blocking; a `labels` field that is present but not a list —
  including an explicit `null` — is malformed (absent and malformed are
  distinct causes) and must be fixed manually before it is scanned again.
  The skip branches emit
  `[:foreman_server, :task_provider, :beads, :watcher, :label_gate, :skipped]`
  telemetry (reasons `:no_labels` / `:not_foreman_exec`). A malformed `labels`
  field is counted under the pipeline's existing `...:watcher, :malformed`
  event rather than a bespoke one, tagged with its cause in that event's
  `reason` metadata (e.g. `{:labels_not_a_list, "foreman-exec"}`). Every
  malformed path in the watcher — bad JSON, blank prompt, missing `issue_type`,
  missing bead id, malformed labels — funnels through that one event, so the
  event name is the malformed total and each cause stays queryable. All carry
  the watcher's configured `project_id`, and the outcome is logged once per
  line at `info`.
- **Orphan janitor.** Set `config :foreman_server,
  :start_beads_orphan_janitor?, true` to run `BeadsOrphanJanitor`,
  which closes Beads whose matching Foreman task never landed or
  already terminated, after a grace window.
- **Health check.** `ForemanServer.CLI.DoctorTaskProvider.run/1`
  (dispatched via `ForemanServer.CLI.run(["doctor", "task_provider"])`)
  reports per-project provider health and the janitor's cached
  `orphan_backlog` counters. It is **not currently wired to the Go
  CLI** — there is no `doctor` case in
  `packages/foreman_cli/cmd/foreman/main.go`'s dispatch table, so
  `foreman doctor task_provider` does not run today despite being
  referenced elsewhere; invoke the Elixir module directly (e.g. from
  an `iex -S mix` session) until that wiring exists.
- **Remediation.** `foreman task retry` is REMOVED (TRD-018,
  2026-09-13); see §4 for what's unchanged internally and what isn't.
  Never mutate the provider issue by hand while Foreman still owns
  it.

## 11. Jobsite: scripted agent runs

`ForemanServer.Jobsite` is the event-sourced engine behind scripted agent runs:
a run gets its own git worktree, an optional container sandbox, and loops an
agent for up to `max_iterations` turns until it emits a completion signal or
the budget is exhausted. It has two front doors onto one engine
(`ForemanServer.Jobsite.Engine`): scripts (this section) are driven by
`ForemanServer.Jobsite.Executor`, a `GenServer` under
`ForemanServer.Jobsite.Supervisor`, and keep their state in their own
`jobsite:<id>` aggregate stream (`ForemanServer.Aggregates.Jobsite`);
workflow phases (see the end of this section) run on the same engine but keep
their state in the `run:<id>`/`phase:<id>` streams, so `/api/jobsites` does not
list workflow runs and `foreman run list` does not list jobsites.

Use `foreman init --template <name>` (see
[CLI Reference](./cli-reference.md#foreman-init---template-name-real-current))
to scaffold a runnable `.foreman/<name>.exs` script against this API —
`basic` (one agent, one iteration), `iterate` (loops to a completion
signal), `parallel` (fans out across worktrees, merges sequentially),
`review` (implement, then host-verified test-and-fix loop), and `triage`
(pulls a ready Beads issue and works it). Resume after a crash or an
explicit pause with `ForemanServer.Jobsite.resume/1`, which rehydrates
authoritative state from the event stream (never from the projection or
process memory) and continues the same agent session. Recovery after a server
restart is never automatic: at boot, `ForemanServer.Jobsite.BootRecovery`
records every non-terminal jobsite that has no live executor as **paused with
reason `server_restart`** (a jobsite that never got a worktree is failed with
`executor_lost` instead), so it shows up as `paused` with a `paused_reason` in
`GET /api/jobsites` and is resumed through the same explicit path. The scan
finds candidates from the event store's `jobsite:` streams, not the projection,
so a failed projection replay cannot make it report an empty success; if the
streams cannot be listed it logs an error (`could not list jobsites`) instead.
It never starts an agent: `agent.env` values are not persisted, so an unattended
resume would run without them. Disable the scan with
`config :foreman_server, start_jobsite_boot_recovery?: false`.

**Unattended Claude runs need `approval_mode`.** The agent constructors take
`approval_mode:` (`:default | :prompt | :auto_edit | :auto_approve`, default
unset). Left unset, Claude runs in its interactive permission mode and cannot
write files or run commands headlessly — it replies that it is waiting for
approval and the run ends with no changes. Use `:auto_edit` to allow edits or
`:auto_approve` to bypass prompts, the latter ideally only inside a container
sandbox: `Agents.claude("claude-sonnet-4-6", approval_mode: :auto_approve)`.
An agent that fails outright (rejected credentials, bad model, non-zero exit)
fails the jobsite with `:agent_failed`; it does not report a completed run.
If `ANTHROPIC_API_KEY` is set in the environment it takes precedence over a
`claude` login, so an exhausted API key fails the run even when the login works.

Workflow phases run on this same engine. `ForemanServer.Workflow.RunExecutor`
no longer has a phase loop of its own: `ForemanServer.Workflow.Lowering`
compiles a manifest's phase list into a `Program` (a `:worktree` step for the
first phase, then per phase an `:agent`, an optional `:gate` for
`requiredFile:`, and a `:commit`), and `ForemanServer.Jobsite.Engine` runs it
with `ForemanServer.Workflow.JobsiteObserver` emitting the `phase.*` lifecycle
commands. Operator-visible behavior is unchanged — pause and cancel, resume,
durable run logs, stall detection, phase PRs and the worktree contract behave
as before — with one difference: a `bash:` phase (parsed and validated at load
but never executable) is now refused when the run starts, before any worktree
is provisioned, rather than failing the run at that phase.

### Remote Jobsite API

A running server can start and manage jobsites over HTTP, so a script can run on
your machine while the agent runs on the server. The server never runs code from
the script: the body is validated data, the repo is a **registered
`project_id`** (never a path on your machine), and the prompt is sent as text.

| Route | Purpose |
|---|---|
| `POST /api/jobsites` | Start a jobsite; `202` with `{"id": ...}`. Refusals the executor finds after the `202` (a project network policy the sandbox cannot enforce - `network_policy_unsupported`, an invalid project environment, a failed setup plan) are recorded: `GET /api/jobsites/:id` answers `status: "failed"` with the typed `last_error.code`, never `404` |
| `GET /api/jobsites`, `GET /api/jobsites/:id` | List / read the projected state (`status`, `branch`, `commits`, `iterations`, and `paused_reason` while paused) |
| `POST /api/jobsites/:id/pause`, `/cancel` | Body `{"reason": "..."}`; `409` if there is no running executor |
| `POST /api/jobsites/:id/resume` | Resume a paused or crashed jobsite (including one paused with `paused_reason: "server_restart"`) in the background (same flag and cap as start). Optional JSON `prompt` (non-blank, at most 8000 chars; `422 spec_option_invalid` otherwise) replaces the default `Continue.` prompt of the resumed iteration - this is jobsite steering v1 (pause, then resume with the message; `Jobsite.steer/3` does both); `404` unknown id, `409 not_resumable` if it already finished or never provisioned a worktree (status `starting`, nothing to continue), `409 already_running` if its executor is alive, `502` if the executor could not start |
| `POST /api/jobsites/:id/merge` | Body `{"into": "<branch>"}`; merges a completed jobsite's branch, only into the branch checked out in the server's repo (`409` otherwise) |

Spec keys: `project_id`, `prompt`, `agent` (`provider`, `model`, `effort`,
`approval_mode`), `strategy` (`"head"` or `{"branch": name}`), `sandbox`,
`name`, `max_iterations`, `completion_signal`, `idle_timeout_seconds`,
`completion_timeout_seconds`, `hooks.sandbox`, `exclude_paths`,
`copy_to_worktree`, `resume_session`, `push`, `bead_id`. Unknown keys are rejected.
`bead_id` names the bead the jobsite's review is reported on (comment and gap
beads, see Session archive and review). It must exist in the `project_id`'s
registered task provider and must not itself be a gap bead (filed by an earlier
review, or carrying the `foreman-gap` label). An unknown bead is refused with
`404 spec_bead_not_found`, a gap bead with `422 spec_bead_ineligible`, and a
provider that cannot be read to check it with `503 spec_bead_unavailable`; all
are audited as rejected and start nothing. A spec without `bead_id` never
consults the provider.
`push: true` publishes the branch to `origin` after the commit and needs a
branch strategy; if the push fails the jobsite fails with `push_failed` and the
commits stay on the server's local branch.

Status codes: `400` missing/malformed input, `401` bad or missing token, `403`
forbidden by policy, `404` unknown id, project or `bead_id`, `409` wrong state,
`422` invalid spec or an ineligible (gap) `bead_id`, `429` too many running jobsites, `502` the executor could not
start, `503` the task provider could not verify `bead_id`.

**Operator configuration** (`config :foreman_server, :jobsites, ...`):

| Key | Default | Meaning |
|---|---|---|
| `allow_remote_start` | off | Must be exactly `true` for `POST /api/jobsites` and `POST /api/jobsites/:id/resume` to start anything (otherwise `403`) |
| `max_concurrent_jobsites` | `3` | Running jobsites above this return `429` |
| `allow_host_sandbox` | off | The `host` sandbox runs agents as the server user with no isolation; the default is `docker` |
| `agent_env_allowlist` | `[]` | Environment variable names a request may set on the agent. Values are not persisted, so a resumed jobsite runs without them |

The token, the two on/off keys and the agent env allowlist can be set from the environment when the
server boots (`config/runtime.exs`; it applies to `mix phx.server`, `mix run`
and releases, not to `mix test`):

| Variable | Sets |
|---|---|
| `FOREMAN_API_TOKEN` | `:api_bearer_token` |
| `FOREMAN_JOBSITES_ALLOW_REMOTE_START` | `allow_remote_start` (only the exact value `true` enables it) |
| `FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX` | `allow_host_sandbox` (only the exact value `true` enables it) |
| `FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST` | `agent_env_allowlist` (comma-separated names, e.g. `ANTHROPIC_BASE_URL,ANTHROPIC_API_KEY`; blank entries are dropped) |
| `FOREMAN_HTTP_PORT` | `ForemanServerWeb.Endpoint` http port (a valid port number; `127.0.0.1` only; lets a second server run beside the dev one) |
| `FOREMAN_NOTIFY_WEBHOOK_URL` | `:messaging` (provider `webhook`, delivery enabled for every event class, no run-update rate limit, `webhook.url` from the variable) |
| `FOREMAN_REVIEW_PROVIDER` / `FOREMAN_REVIEW_MODEL` | `:review, agent:` (the fixed reviewer; `claude` or `pi`, optional model; unset keeps `claude`) |
| `FOREMAN_PR_FIX_SANDBOX` | `:pr_fix, sandbox:` (`docker` or `host`; unset keeps the jobsite default, docker, which needs a built `foreman-jobsite:<project>` image; `host` also needs `FOREMAN_JOBSITES_ALLOW_HOST_SANDBOX=true`) |
| `FOREMAN_START_BEADS_WATCHER` | `start_beads_watcher?` (`true` starts it, any other value stops it; `dev.exs` defaults to on) |

A variable that is unset changes nothing, so the API stays off by default (and `FOREMAN_START_BEADS_WATCHER` leaves the `config` value in force).

These routes fail closed: with no `:api_bearer_token` configured every request is
`401`, exactly like the rest of `/api` (which fails closed too, with a local-development opt-in that these routes do not have). Put TLS in
front of the server before exposing it beyond localhost. Every start, pause,
cancel, resume and merge request, accepted or rejected, is recorded in an
audit stream with the caller's TCP address (the proxy's, behind one; requests
refused with `401` are not recorded).

Scripts: `foreman init --template basic|iterate|parallel` scaffold scripts that
load the `foreman_client` package (`packages/foreman_client`, via `Mix.install`;
needs only Erlang/OTP 27+, no Foreman checkout, no database). Set `FOREMAN_API_TOKEN` and
`FOREMAN_PROJECT_ID` (and `FOREMAN_API_URL` if the server is not local), then
`elixir .foreman/<name>.exs`. `iterate` also reads optional `FOREMAN_AGENT_MODEL`, `FOREMAN_MAX_ITERATIONS` and `FOREMAN_AGENT_ENV` (names of shell variables to pass to the agent as `agent.env`, e.g. `ANTHROPIC_API_KEY`; the server must list them in `FOREMAN_JOBSITES_AGENT_ENV_ALLOWLIST`). `review` and `triage` still run inside a booted
server app with `mix run`.

## 12. Project memory

Each project has durable memory that every agent thread can read and write, like a project notebook.

- **Location.** `<project path>/.foreman/memory/`: `MEMORY.md` (a generated index, one `- [name](name.md) - description` line per topic, sorted) plus one `<name>.md` file per topic. A topic file may start with a `<!-- description: ... -->` line; that is the hook shown in the index. Names match `^[a-z0-9][a-z0-9_-]{0,63}$` (`memory` is reserved). `.foreman/.gitignore` gets a `memory/` line automatically; other `.foreman` files stay tracked.
- **Caps.** 64 KiB per topic (after redaction), 200 topics, index at most 200 lines / 25 KiB. Violations are rejected with `content_too_large`, `too_many_topics` or `index_full` and leave disk untouched. Configurable under `config :foreman_server, :project_memory`.
- **Redaction.** Bearer tokens, `api_key=`/`token=`/`password=`/`secret=` values, private-key blocks and the project's configured secret env values are replaced by `[REDACTED]` before anything is written. Content is never stored in events; the event log (`ProjectMemoryWritten` / `ProjectMemoryForgotten` on `project_memory:<id>`) keeps only name, description, sha256, size, redaction count and author.
- **Durable facts only.** Log dumps (more than half identical lines) and secret-heavy pastes (more than half the bytes redacted, for content of 200 bytes or more) are rejected with `content_not_durable`.
- **Agents** use the MCP tools `foreman_project_memory_list`, `foreman_project_memory_read`, `foreman_project_memory_write` and `foreman_project_memory_forget` (the last two need `allow_workflow_writes`). Their descriptions carry the guidance: save decisions, conventions, gotchas and project-wide preferences; never task progress, logs or secrets; list before writing and update instead of duplicating; forget facts that became false.
- **Operators** can view, edit and delete through `GET|PUT|DELETE /api/projects/:id/memory[/:name]` and the CLI:

```
foreman project memory list <project-id> [--format json]
foreman project memory read --name conventions <project-id>
foreman project memory write --name conventions --description "How we work" --file notes.md <project-id>
foreman project memory forget --name conventions <project-id>
foreman project memory sync <project-id>
```

- **Hand edits and drift.** Editing `.foreman/memory/*.md` in an editor is fine. `POST /api/projects/:id/memory/sync` (or `foreman project memory sync`) compares file hashes with the audit index, re-redacts the edited content and records each difference as an operator-authored write or forget. A second sync reports nothing.

## 12.1 Project library

Each project can hold a **library**: files and folders that every agent thread can read, like Claude's project knowledge. Agents never write to it directly.

- **Location.** `<project path>/.foreman/library/<entry_id>/files/...` plus an `entry.json` per entry. Only `.foreman/library/` is gitignored (added to `.foreman/.gitignore` on first use); `.foreman/Dockerfile`, `.foreman/bead.exs` and `.foreman/pi-models.json` stay tracked. The bytes never enter the event log: `ProjectLibraryAdded` / `ProjectLibraryReplaced` / `ProjectLibraryRemoved` carry metadata only.
- **Limits (mirroring Claude).** At most 100 files per add and 480 MB per file. A folder add takes the first 100 eligible files (sorted path order) up to 200 MB total, skipping hidden files and directories, `node_modules`, symlinks and files over 30 MB; at most 10 folders per project. Every skipped file is reported back with a reason (`hidden`, `node_modules`, `symlink`, `not_regular`, `over_30mb`, `folder_file_cap`, `folder_byte_budget`), never silently dropped. All limits are under `config :foreman_server, :library`.
- **Read-only delivery.** Agents on both doors get `FOREMAN_LIBRARY_PATH` when the library is non-empty: the absolute host directory for workflow runs and host-sandbox jobsites, and a read-only bind mount at `/library` for docker jobsites. Nothing is copied or linked into the worktree (Foreman commits the whole worktree). On the host, files are `chmod` read-only, which is advisory because agents run as the same user; the docker mount is the real guarantee.
- **Standing context.** The library index (entry names, kinds and file lists) is a "Project library" section of the standing context (see [Standing context](#13-standing-context)); file contents are never inlined.
- **Thread-produced files (opt-in).** With `foreman project update --library-collect-produced <project-id>`, each completed phase's artifact and the run's session-archive `analysis.md` / `diff.patch` are registered into one `produced-<run_id>` entry, idempotently per path and content, within `produced_max_files_per_run` (100) and `produced_max_bytes_per_run` (50 MB), and only from the run's own directories. Off by default because registering every run's output clutters the library. Copied files are not redacted: they are agent output with the same exposure as the run's git branch.
- **Operators** use the CLI (`foreman project library list|add|replace|remove`, see the CLI reference) or the HTTP endpoints `/api/projects/:id/library`. **Agents** use the read-only MCP tools `foreman_project_library_list` and `foreman_project_library_read` (files up to 1 MiB per read).

## 12.2 Scheduled tasks

A project can own **schedules**: a prompt, a workflow and a timetable. Each time a
slot falls due the server creates one task in the project (id
`sched-<schedule_id>-<slot>`, `slot` = unix seconds) and, unless the schedule says
otherwise, approves it so the normal dispatcher runs it. Scheduled tasks are ad hoc
(`provider_tracked: false`): no Beads issue is created per fire.

```bash
foreman project schedule create --project-id myproj --name "Daily triage" \
  --cron "0 9 * * 1-5" --prompt "Triage new issues and summarise" --workflow fix
foreman project schedule create --project-id myproj --name "Dep bump" \
  --every 24h --prompt-file prompts/deps.md --workflow implement --auto-approve=false
foreman project schedule list --project-id myproj
foreman project schedule pause|resume|delete --project-id myproj --id <schedule-id>
```

Over HTTP the same commands are `POST /api/commands` (`schedule.create`,
`schedule.update`, `schedule.pause`, `schedule.resume`, `schedule.delete`) and the
read is `GET /api/projects/<id>/schedules` (`{ticker, schedules: [...]}`; this is
the data behind the Scheduled tab). MCP: `foreman_schedule_list` plus the four write
tools (`foreman_schedule_create` takes an optional `request_id`: repeating it returns
the same schedule instead of creating a second one; without it every call creates a
new schedule). Typed rejections such as `{:invalid_schedule_spec, :every,
:below_minimum}`, `{:schedule_limit_reached, 50}` or `{:unknown_workflow, name}` are
returned verbatim.

**Syntax.** `every` is `<n>s|m|h|d` with a minimum of `min_interval_seconds`
(default 300), aligned to an anchor (creation time unless given), so `every: 30m`
fires at creation+30m, +60m, ... `cron` is the standard five fields (minute hour
day-of-month month day-of-week) with `*`, lists, ranges and `*/n` / `a-b/n` steps,
`JAN-DEC` and `SUN-SAT` names; when both day-of-month and day-of-week are restricted
a day matches if **either** matches (Vixie cron). `@daily`, `?`, `L`, `W`, `#` and a
seconds field are rejected (`unsupported_syntax`), as are expressions that can never
fire (`0 0 30 2 *`).

**Time zones.** UTC only: cron times are UTC wall-clock times, and `timezone` accepts
only `UTC` / `Etc/UTC`. There is no tz database in the dependency set, so DST rules
do not exist to define. The decision is recorded in `Schedule.Spec`.

**Misfire grace and no catch-up.** A due slot may fire up to
`misfire_grace_seconds` late (default 600). Only the single *latest* due slot is
ever considered: after downtime the latest slot fires if it is within grace (the
older ones are counted in `last_outcome.missed_count` and never fire), otherwise it
is recorded as skipped with reason `missed` and the count of slots that were due.
A skipped slot is consumed and never retried. Slots that fell due while a schedule
was paused do not fire on resume, and editing a schedule's spec restarts its
baseline.

**Overlap, pause and caps.** `overlap: skip` (default) skips a fire while the previous
fire's task is still `open`, `ready` or `in_progress`; `allow` fires regardless. A
fire is skipped with `project_paused` while the project is paused or archived, and
with `daily_cap` once the project's daily thread cap is reached. Every skip is
recorded with its reason: `last_outcome` in `schedule list` (`skipped: overlap`) is
how you see why a fire did not happen. `auto_approve: false` leaves each created task
`open` as a proposal for an operator to approve.

**Exactly once.** Each fire is `scheduler_intent.record` -> `task.create` ->
(`task.approve`) -> `schedule.mark_fired` -> `scheduler_intent.confirm`, every step
with a deterministic command id. After a crash, `Schedule.Ticker` redoes intents that
were recorded but not confirmed within `recovery_grace_ms` (on boot and every 20
ticks) without creating duplicate tasks.

**Operations.** The ticker (`Schedule.Ticker`) is supervised and enabled by default
(`config :foreman_server, :schedule, ticker_enabled:`; env
`FOREMAN_SCHEDULE_TICKER_ENABLED=true|false`; tick every `tick_interval_ms`, default
30 s). Other keys: `min_interval_seconds` (300), `max_per_project` (50 non-deleted
schedules), `default_misfire_grace_seconds` (600). `schedule list` and the HTTP
response report `ticker: running|disabled`; while it is `disabled`, schedules exist
but do not fire. Schedule prompts are operator-authored data stored in the event log
(`ScheduleCreated`, `ScheduleUpdated`): do not put secrets in them.


## 13. Standing context

Every agent launch, on both doors, starts with the project's **standing context**, built by one function (`ForemanServer.ProjectContext.build/2`) and re-read at every launch (no cache):

1. **Project instructions** (`project update --instructions`, operator text),
2. **Repositories** (the project path; only shown alongside other context),
3. **Project memory** (the generated `MEMORY.md` index with the standing memory guidance, inside a `<project_notes>` block labelled as agent-written, informational notes, not instructions),
4. anything a registered section provider adds (config `:foreman_server, :project_context, section_providers`).

Empty parts are omitted entirely: a project with no instructions and no memory gets no injected text and no behaviour change. Secret values (the project's `config.env` secrets, bearer tokens, log-policy patterns) are redacted from the text before it is delivered.

**Delivery.** The workflow door sets the harness `system_prompt` for every agent phase; for covered `command:` phases the inbox-progress prompt is appended after the context, separated by a blank line (merged, never overwritten). The jobsite door builds the context once per jobsite start and sends the same `system_prompt` on every iteration. A provider that does not declare `system_prompt` support (amp, kimi, opencode) gets the text prefixed to the prompt instead. Workflow prompt templates can place the text themselves with `{{project_context}}`, `{{project_instructions}}` and `{{project_memory}}` (each is the empty string when there is nothing; shipped templates do not use them).

**Budget and truncation.** Defaults: 24 000 bytes total, instructions 16 000, repositories 1 000, memory 6 000, library 3 000 (`config :foreman_server, :project_context, max_bytes:, section_caps:`). Over-cap content is cut at a line boundary (never inside a UTF-8 character) and the injected text says so: `[truncated: N lines omitted from <section>; <how to fetch the rest>]`. If the total is still over budget, Library shrinks first, then Memory, then Repositories; instructions last.

**Inspecting what an agent received.** `foreman project context <project-id>` (or `GET /api/projects/:id/context`) shows what a launch would receive now. With session capture on, the text each run/jobsite actually launched with is archived as `project-context.md` beside `request.md` (workflow runs: first agent launch; jobsite: its single build) and the manifest carries a `project_context` block (`sha256`, `bytes`, `truncated`, `redactions`). There is no CLI write surface: edit instructions with `project update`, memory with `project memory`.

## 14. Project coordinator

Every project has one durable **coordinator conversation**: paste a bug, a stack trace or a task list, ask a quick question, or say "go ahead". A coordinator agent triages it, answers in place, and asks Foreman to start, propose or steer **threads** (workers, each with its own session, branch and PR). It hears back when threads report (review verdicts, failures).

**How it works.** The conversation is event-sourced on the `coordinator:<project>` stream (`CoordinatorMessageAppended`, `CoordinatorTurnStarted/Completed/Failed`, `CoordinatorActionRecorded`, `CoordinatorRestarted`). `ForemanServer.Coordinator.Runner` wakes one `ProjectWorker` per project; turns run strictly one at a time per project (a worker crash also ends its in-flight turn; a replacement worker never starts a second concurrent turn) (messages that arrive mid-turn are coalesced into the next turn) and different projects run in parallel. Each turn renders a bounded prompt (about 12k tokens: instructions, memory index, thread cards, recent messages, limits, workflow list, never the full history; cuts are announced in the text), runs a provider agent through the harness (default `pi` + `minimax/MiniMax-M2.7-highspeed`; per project `coordinator_provider`, `coordinator_model`, `coordinator_effort`), and parses ONE fenced JSON block `{"reply": ..., "actions": [...]}`. The agent has no Foreman tools and no MCP: its only effect is that block, which Foreman validates and executes (spike S1, docs/spikes/S1.md).

**Actions** (closed set): `answer`, `ask`, `start_thread`, `propose_threads`, `approve_proposed`, `route_followup`, `remember`, `forget`, `set_tuning`, `add_repo`, `schedule`. `start_thread`/`propose_threads` create tasks with `task.create` (`propose_threads`, or `propose_before_start`, leaves them `open`: that is the proposal gate; say "go ahead" and `approve_proposed` runs `task.approve`). The workflow is chosen by Foreman, never by free text: an explicit `workflow` must be installed (else the rejection lists the valid ones), otherwise `task_type` maps through the workflow catalog, otherwise the coordinator is told to ask. `add_repo` (E12) and `schedule` (E11) are recorded as rejected with a clear reason until those features exist. Every action's outcome (`executed`, `proposed`, `rejected`, `failed`) is recorded and shown to the next turn; a rejection never aborts a turn, and the operator sees a notice for anything that did not run.

**Tuning is enforced, not advisory** (settings `coordinator_propose_before_start`, `coordinator_max_active_threads` 1..50, `coordinator_reuse_threads`; also set by `set_tuning`, which stores a memory note too): `propose_before_start` forces every thread the coordinator creates to stay a proposal; `max_active_threads` rejects a start beyond the cap (`cap_exceeded: active_threads N`) and "max N at a time" also tightens `max_concurrent_runs` (it never raises a project cap); `reuse_threads` turns a start into a follow-up when a live thread has the same `bead_id` or the model names one (otherwise advisory, because "same area" is semantic). Loosening a limit needs the operator's exact words (`quote`) to appear in their message.

**Security model.** Capability, not prompt: the coordinator is a system actor that can dispatch only `task.create`, `task.approve` (for tasks it created or proposed), `project.update` (tuning keys only) and its own `coordinator.*` commands (`Coordinator.Dispatch.command_types/0`); it cannot call `merge_approve`, `run.pr.merge`, `project.archive`, `task.retry` or any other operator gate, and no handler builds such a command. Turns triggered by reports, agent-authored text or MCP messages have `:machine` authority and may only answer, ask, propose, route a follow-up or remember; they cannot start or approve work, forget, change tuning, add repositories or schedule. Every thread/task/memory id is checked against the turn's project (`out_of_project`). Pasted text is rendered inside `<untrusted_input>` blocks whose delimiters are neutralised, and conversation text is redacted of project secrets before it is stored. Notes that read as merge/approve automation are refused. Prompt framing is best-effort; the boundary is the closed allowlist plus Policy, and the adversarial tests keep it honest even when the model obeys an injection.

**Health and restart.** A failed turn (provider error, malformed output, timeout, interrupted by a server stop) is recorded and retried; three consecutive failures mark the coordinator `unhealthy`, post one visible system notice ("the coordinator has not responded - last error ...") and stop automatic turns until `foreman project chat <id> --restart` (`POST /api/projects/:id/coordinator/restart`, command `coordinator.restart`). A turn found open at startup is closed as `interrupted` and re-run; the reply id and every command id derive from the triggering message, so a restart never duplicates a reply or a thread and a message appended while the server was down is processed after startup.

**Reports.** `ReviewRecorded` and failed/cancelled run and jobsite events append a report message per thread (`report_key` makes duplicates and the 24 h startup backfill harmless) and wake a machine-authority turn; at most `report_turns_per_hour` (default 6) report turns per project (the rest are listed `suppressed`, announced once), and reports about review-gap-bead threads never start a turn.

**Surfaces.** CLI `foreman project chat`; HTTP `POST /api/projects/:id/coordinator/messages`, `GET .../messages?after=&limit=&wait_ms=` (long-poll), `GET .../coordinator`, `POST .../coordinator/restart`; MCP `foreman_project_conversation` (read) and `foreman_project_message` (a write tool: hidden unless `allow_workflow_writes`, always stored with source `mcp`, rate limited by `mcp_messages_per_minute`). The LiveView workspace is `/dashboard/projects/:id` (section 14.1).

**Config** (`config :foreman_server, :coordinator`): `enabled`, `agent`, `default_provider/model/effort`, `agent_timeout_ms`, `turn_timeout_ms`, `retry_backoff_ms`, `unhealthy_after`, `max_message_bytes`, `max_actions_per_turn`, `max_threads_per_turn`, `untrusted_sources` (default `["mcp"]`: MCP messages never carry operator authority), `report_turns_per_hour`, `report_backfill_hours`, `mcp_messages_per_minute`, `report_events`, `context: [max_total_tokens: ...]`.

## 14.1 Project workspace (LiveView)

`GET /dashboard/projects/:id` is the browser view of one project; `/dashboard/projects/:id/settings` is its settings page. Both sit behind the same browser token guard as `/dashboard/runs`: open them with `?token=<FOREMAN_API_TOKEN>` (or an `Authorization: Bearer` header); without it the answer is `401`, and an unknown project is `404`. Moving between the two pages inside the app reuses the authenticated socket.

**Workspace.** Left: the coordinator conversation (`CoordinatorAPI`, the same entry as `POST /api/projects/:id/coordinator/messages`; `Load earlier messages` pages backwards by cursor), coordinator health with a `Restart coordinator` button when it is `unhealthy`, proposals with a `Start` button (`task.approve`, only for open tasks the coordinator proposed for this project) and the message box. Right: the Overview (`ForemanServer.Overview`) grouped as Ready for review / Waiting on you / Working / Landing / Idle / Resolved with an attention dot, and one card per thread. Card actions are exactly the existing operator ones: `Pause`/`Resume` (`run.pause`/`run.resume`), `Stop` (two clicks: `Stop`, then `Confirm stop`; `Threads.Actions.stop`), `Resolve`/`Reopen` (`thread.resolve`/`thread.reopen`) and a steer box (`Threads.Actions.steer`). Workflow cards also carry four PR buttons in a labelled group: `Fix CI`, `Address comments`, `Resolve conflicts` (the E9 fix threads: `run.pr.fix_ci` / `run.pr.address_comments` / `run.pr.resolve_conflicts`) and `Create PR` (`run.pr.create`), the same commands as `foreman run fix-ci|address-comments|resolve-conflicts|create-pr` and MCP `foreman_pr_fix`. A button that does not apply is disabled with its reason shown beside it (CI is not failing, no unresolved review comments, no merge conflicts, a fix is already running, no PR watched, a PR already exists, the run has not completed); the Run aggregate stays the authority and refuses what the watch state cannot support. There is **no merge or PR-approval control**: merging stays operator-only (`foreman run approve-merge`). Tabs below the Overview: *Library* and *Pull requests* come from the Overview tab providers (a tab without a registered provider says "Not available yet."), *Scheduled* lists the project's schedules with `Pause`/`Resume` (`schedule.pause`/`schedule.resume`).

**Settings.** One form for goal, instructions (live counter against the 16000-character limit), thread and coordinator model/effort/provider, `max_concurrent_runs`, `daily_thread_cap` and the coordinator tuning keys, written through `project.update`; a blank field clears the setting and the aggregate's own error is shown next to the field. Pause/Resume/Archive/Reactivate (each with a confirm step), the project memory (list, edit, forget; the same `ProjectMemory` functions as the HTTP API, author `dashboard`), limits and the usage rollup. Save writes only the fields you changed since the page loaded (a setting changed elsewhere in the meantime is left alone), and a failed usage or limits read shows an error instead of an empty pane. Environment variables are shown by NAME only; values and secrets are never rendered, and they are still edited with `project.environment.set`.

**Updates, not polling.** A connected page subscribes once to `ProjectionStore` and coalesces bursts: the first relevant event arms one timer (`config :foreman_server, :workspace, coalesce_ms:`, default 250) and everything that arrives inside the window is folded into a single refresh; an idle project does no work and worker-output events never refresh the page. All thread titles, reports, conversation text and memory content are escaped; only `http(s)` PR URLs become links.

**Accessibility baseline.** Both pages have a `main` landmark with a skip link, labelled form controls, a visible keyboard focus ring, `aria-live` regions for save results and the instructions counter, and `role="alert"` field errors; secrets are shown as reference names only. A browser check (axe-core, tab order, idle WebSocket traffic) lives in `scripts/e2e/ui-a11y/`: seed a project with at least one thread, then `cd scripts/e2e/ui-a11y && npm install && npx playwright install chromium && node ui_a11y.mjs --base http://localhost:<port> --token <FOREMAN_API_TOKEN> --project <id> --report ../../../docs/lessons/ui-a11y-report-<date>.md`. Use `localhost`, not `127.0.0.1`: the dev endpoint's origin check rejects the LiveView WebSocket for the latter. The check exits non-zero on any serious/critical axe violation, wrong focus order, or more than `--max-idle-frames` (default 2) non-heartbeat frames in `--idle-seconds` (default 10). Details and the latest result: `docs/spikes/E16-SP1.md`, `docs/lessons/ui-a11y-report-2026-10-22.md`.

## Day-to-day workflow

### 1. Start or check the server

```bash
devbox run server
```

If commands fail with a connection error, confirm `FOREMAN_API_URL`
points at the running server (`http://127.0.0.1:4766` in dev) and that
`devbox run ps` shows it up.

### 2. Register the project (once)

```bash
foreman project create --id my-project --path /path/to/repo --task-provider beads --task-provider-database-path /path/to/repo/.beads
```

### 3. Create and approve a task

`foreman task create` and `foreman task approve` are REMOVED
(TRD-018, 2026-09-13). Create a bead instead — BeadsWatcher dispatches
the internal `task.create` + `task.approve` pair automatically the
moment it transitions to `status: open`:

```bash
br create --title "Add cooldown retry for transient CLI failures" \
  --description "When a provider reports a transient rate limit, retry after cooldown instead of terminal failure." \
  --type fix
```

— or dispatch ad-hoc work in one call:

```bash
foreman run submit --project-id my-project --workflow fix \
  --prompt "Add cooldown retry for transient CLI failures"
```

### 4. Monitor

```bash
foreman run list --project-id my-project --status in_progress
foreman run get <run-id>
```

`foreman task get <task-id>` is REMOVED (TRD-018, 2026-09-13); read
the task projection directly via `GET /api/tasks/:id` (`curl` or an
MCP tool) instead.

Foreman has no TUI/cockpit today — monitoring is projection reads via
the CLI or `GET /api/*`. For live event/heartbeat detail during a run,
use the MCP tools `foreman_run_get_events` / `foreman_run_get_activity`,
or the `/debug/*` LiveView dashboards in a dev environment.

### 5. Recover a wedged or failed run

`foreman task retry` is REMOVED (TRD-018, 2026-09-13); re-opening the
bead (`br update <id> --status=open`) is the closest replacement once
the run below is terminal, though it goes through the same bead-import
path as creating a new task rather than a dedicated retry command.

```bash
foreman run get <run-id>                 # inspect status first
foreman run reset --id <run-id>          # failed/stuck only; clears projection for resubmission
foreman run remove --id <run-id>         # terminate + release slot/lease + best-effort cleanup
```

There is no interactive "kill-switch" or phase-resume primitive; a
stuck run is removed or reset, and the task is retried or recreated.

### PR creation and merge reconciliation

PR creation is **not** a workflow phase — bundled workflows declare no
`create-pr`/`pr-wait`/`merge` phases and there is no `checkpointPr`
option. `ForemanServer.Workflow.AutoPR.maybe_create_pr/1`, called from
`RunExecutor.finalize_run/1`, derives the PR from run state instead: it
checks `git rev-list --count base..head > 0` against the branch
recorded when the run's first phase started, publishes with `git push
-u origin <head>`, and calls `gh pr create`. When that final PR is created the
run signals `run.pr.ready`, which puts the PR into the merge gate: Foreman will
not merge it until an operator runs `foreman run approve-merge ... --head-sha <sha>`
(the commit they reviewed) and then `foreman run merge` (see the run commands above). The server can also follow
the PR's state on GitHub in two opt-in ways, each appending a `PrUpdated`
event to the run (neither changes task status or the PR fields `foreman run
get` shows; the richer PR record is `foreman run prs`, see "PR watching and auto-fix"): `POST /webhooks/github`, which needs
`FOREMAN_GITHUB_WEBHOOK_SECRET` — every delivery must carry a valid
`X-Hub-Signature-256`, a missing or wrong signature gets `401`, and with no
secret configured the endpoint answers `503` to everything — and a polling
fallback (`FOREMAN_PR_MONITOR_ENABLED=true`) that reads each PR with `gh pr
view`. Deliveries are attributed to runs by PR URL; a PR no run owns is
accepted and ignored.

By default one run yields at most one final PR. `auto_pr/1` is called from
`finalize_run/1`, after every phase has completed, and opens from the run's
single branch — `foreman/<task-id>/<run-id>` unless the workflow's `worktree.branch` says
otherwise. For task-backed runs, when both the task title and task description
are set, the final PR title is exactly the task title and the final PR body is
exactly the task description; if either is present but blank or malformed,
AutoPR returns a typed metadata error before publishing the branch. A task field
that was never set (for example, a title-only task) does not fail: AutoPR falls
back to the generated title/body. Ad-hoc no-task runs keep the legacy generated
run/artifact title and body either way.
Workflows may opt into phase boundary PR records with `stack_pr:
true` on an individual phase. Top-level `pr:`, `merge:`, `stacked:`, and
`checkpointPr` settings remain unsupported.
A `stack_pr: true` phase runs after that phase's normal commit decision and
before `PhaseCompleted`. It targets the recorded run base branch and uses the
same Foreman run branch as the head. Because every tagged phase shares that
head/base pair, GitHub usually exposes one open PR; later tagged phases push the
run branch again before reusing that PR URL, so the remote diff stays cumulative
from the run base instead of silently showing an older phase's head. If the head
has no commits beyond the run base, Foreman records a phase PR no-op and
continues. Push/create failures and closed matching PRs fail the responsible
phase with typed details. A created or reused phase PR record suppresses the
final AutoPR; no-op records do not.

**PR bodies carry unresolved review findings only when Foreman generates the body.**
Phase PRs, and final AutoPRs for ad-hoc no-task runs, append a `## Unresolved
review findings` section to the generated body when the PR-creating phase's
artifact contains a `<!-- FOREMAN_REVIEW_FINDINGS_START -->` /
`<!-- FOREMAN_REVIEW_FINDINGS_END -->` block — the format the bundled `review`
workflow's phases write. Task-backed final AutoPR bodies are exact task
descriptions and do not append artifact or review-finding sections. Absent or
empty blocks add nothing to generated bodies. An unterminated block (a start
marker with no matching end marker) is distinct: the phase found something and
failed to close its markers, so a warning is logged and the generated body
instead names the artifact for a human to check directly, rather than silently
dropping the findings.

**Commits are Foreman's, not the agent's.** At each phase boundary Foreman
stages and commits whatever the phase produced into the run's worktree, so an
agent that writes files without committing still leaves a proposable branch. The
message (`Foreman run <run-id> phase <n>`) and author are fixed, the commit skips
repository pre-commit hooks, and a phase that produced nothing creates no commit
— so AutoPR still proposes only real work.

A phase controls **whether** it commits, with a phase-level `commit:` boolean.
A phase can also request a phase PR record with `stack_pr: true`; that does not
force a commit. A phase can declare `timeout_minutes:` (camelCase `timeoutMinutes:` also accepted) as a
non-negative-integer number of minutes for its execution timeout; `0`, or an
omitted key, both mean no timeout. When `timeout_minutes` is absent, the resolved
deadline follows `FailurePolicy.resolve/2` precedence: per-call opts, then
`:foreman_server, :agent_runtime, :failure_policies[task_type]`, then
`:foreman_server, :agent_runtime, :default_timeout_ms`, then the built-in default
of `:infinity`. No dev or prod config file sets either key (`config/test.exs` sets
`:agent_runtime`, and run-executor tests `Application.put_env` failure policies and
defaults into it), so absent-timeout phases have no wall-clock deadline in normal
operation. There is no confirmed source for a live 30-minute ceiling on a phase
that declares none (foreman-4uj5): a BEAM started before #510 could still hold the
`default_timeout_ms: 1_800_000` that dev/prod config carried then, but the one run
that showed the symptom dispatched ~12 h after #510 from a workflow with no phase
timeout, so treat that as an unproven hypothesis — verify a server's effective
config live before concluding it.
Unlike `worktree:`, which is workflow-level because a run has only one worktree,
each phase produces its own output, so these are genuinely per-phase questions:

```yaml
phases:
  - name: create-prd
    command: "/skill:ensemble-full-create-prd --foreman"
    timeout_minutes: 10   # execution timeout in minutes (optional)
    commit: true          # commit this phase's work when it completes (default)
    stack_pr: true        # create/reuse a phase PR after the commit
  - name: refine-prd
    command: "/skill:ensemble-full-refine-prd --foreman"
    commit: false         # defer: a later phase's commit absorbs it
    stack_pr: true        # records no-op unless prior committed diff is ahead
  - name: create-trd
    command: "/skill:ensemble-full-create-trd --foreman"
    commit: true          # commits refine-prd's work together with its own
```

Omitting `commit:` means `true`, so the seven bundled workflows that declare
nothing keep committing every phase. Use `commit: false` to batch consecutive
phases into one reviewable commit.

One combination is **rejected when the workflow loads**, not at run time,
because nothing at run time can rescue it:

- A phase declaring `commit: false` that no later phase commits, in a workflow
  whose `worktree.cleanup` is `always` or `on_success`. The deferred changes
  live only in the run's worktree, and both of those modes delete it — so the
  work is destroyed with no branch and nothing for PR creation to propose. The
  error names the deferring phase and the cleanup mode, and states both fixes:
  commit the work in a later phase, or declare `cleanup: never`.

The same never-committed deferral is **accepted** under `cleanup: never` (the
default when you declare no `worktree:` block). There the work survives in the
worktree on disk, so a workflow that stages changes for you to inspect or commit
by hand is a legitimate thing to author. Because PR creation counts commits
only, such a run succeeds and produces no PR — so Foreman logs a warning when
the run reaches terminal, naming the deferring phase, and that warning also
fires when a run fails before reaching the phase that would have absorbed the
work.

Two earlier rules described here no longer exist. A `commit: false` phase
immediately before a `requiredFile:` phase was refused, on the theory that
document discovery would attribute the earlier phase's uncommitted document to
the gated phase; that refusal made deferral and discovery mutually exclusive and
so forbade exactly the batching the tag exists to provide, which is the shape the
`plan` and `prd` workflows want. Never-committed deferral was also refused
unconditionally, which is the rule now narrowed to the cleanup case above.

## Documentation Discipline

See `AGENTS.md`'s "Documentation Gate" section for the mandatory
pre-completion gate: enumerate externally-visible identifiers a change
adds/removes/renames, grep them across `CLAUDE.md`,
`README.md`, this file, and `docs/cli-reference.md`, and fix or
explicitly annotate any stale hit. `docs/PRD/*` and `docs/TRD/*` are
point-in-time design specs, not living docs — leave their historical
claims as written; add a forward-pointer note instead of rewriting them.

## Safety Rules

- Keep the controller workspace clean before rerunning important tasks.
- Prefer targeted `run reset`/`task retry` over bulk retries.
- Inspect run/task projections and events before changing state.
- Do not manually mutate an active run's worktree unless you intend to
  take ownership of that run.

## Session archive and automated review

Every terminal run (workflow runs and jobsites — completed, failed, or
cancelled) leaves a session archive under
`<repo>/.foreman/sessions/<run|jobsite>/<id>/`:
`manifest.json`, `request.md` (the original request), `transcript.jsonl`,
`diff.patch`, `changed-files.txt`, and — once reviewed — `analysis.json` and
`analysis.md`. Capture never fails a run; a failed or truncated capture is
recorded in the manifest (`capture_errors`, `transcript_truncated`,
`diff_status`), never silently empty. A workflow run's transcript is rebuilt
from its redacted, bounded run logs (`transcript_source: "run_logs"`); a
jobsite's comes from the harness events.

A multi-repository run (more than one repository attached) keeps the primary
repository's `diff.patch` and `changed-files.txt` exactly as above and adds one
pair per additional repository: `diffs/<repo_id>.patch` and
`diffs/<repo_id>.files.txt` (same size bound and truncation record in
`capture_errors`, stages `diff:<repo_id>` / `changed_files:<repo_id>`; the repo
id is validated, so it cannot escape `diffs/`). The manifest (still
`foreman.review.manifest.v1`) gains `repositories`:
`[{id, primary, branch, base_ref, worktree_path, diff_status, pr_url}]`, primary
first, with `pr_url` taken from the repository's PR association (`null` when it
opened none). Single-repository archives have no `repositories` key and no
`diffs/` directory. The automated reviewer is told to read every
`diffs/*.patch` only when the manifest lists more than one repository. Jobsites
stay single-repository: a `repositories` key in a jobsite spec is rejected with
`spec_forbidden_key` (multi-repo jobsites unsupported).

A cancelled run or jobsite is archived and reviewed like any other, with
manifest `status: "cancelled"`. Cancelled work is never committed, so its
`diff.patch` is the working-tree diff against the base: uncommitted changes to
tracked files and new untracked files are included (gitignored files are not;
the checkout's index is marked intent-to-add). If that marking fails, for example
on a held `index.lock`, the diff still holds every tracked change but omits the
new files, and the manifest's `capture_errors` says so (stage `intent_to_add`).
A jobsite cancel or failure (for example an agent that dies) captures that diff just before its worktree is discarded. For a
workflow run, `run.cancel`
is recorded before the run's executor has actually stopped, so the review step
waits up to 30 seconds for the executor to exit before it archives the run from
its retained worktree (after the timeout it captures anyway and logs a warning).

A failed workflow run has the same ordering problem: the phase failure records
`run.fail` before the executor has written the run's archive, so the review step
waits up to 30 seconds for the executor to exit and then reviews the archive the
executor wrote. After the timeout it reviews anyway and logs a warning; if the
archive still does not exist the review is recorded `undetermined` with
`error_code: archive_missing`. A completed run is not waited for: its archive is
written before `run.complete`.

After the archive is written, a fixed reviewer agent grades the diff and
transcript against the original request on correctness, tests, documentation
and robustness, and records a `ReviewRecorded` event (command `review.record`,
system-only: not on the operator allowlist). The reviewer grades the content of
the diff against the request, not the branch outcome: whether the work was
pushed, merged or opened as a PR is never counted as a gap. Verdicts are `met`,
`partially_met`, `not_met`, or `undetermined` (the review itself failed; the
`error_code` says why). When the work came from a bead (workflow runs whose
task id is `beads:<project>:<bead>`, or a jobsite started with `bead_id`) the
verdict is posted as a bead comment and each gap becomes a new bead labelled
`foreman-exec` + `foreman-gap`, which Foreman then dispatches. A bead that
an earlier recorded review filed as a gap bead gets the comment but spawns no
further gap beads (depth cap of 1); the guards are the review event log and the
bead's own `foreman-gap` label. The same rule applies at the remote jobsite
door: `POST /api/jobsites` refuses a `bead_id` that is a gap bead
(`422 spec_bead_ineligible`) or absent from the project. The bead step needs both `bead_id` and `project_id`: a
jobsite without a `project_id` is still reviewed and the review is recorded,
only the bead step (comment and gap beads) is skipped. A cancelled run or
jobsite gets the verdict comment but no gap beads: unfinished work the operator
stopped on purpose is not filed as work items (the recorded summary says so).

Transcript lines are `{type, timestamp, text, stream}`; `stream` is non-null
only for process-stream provider events such as stderr. Text is secret-redacted
before it is written (values of sensitive environment variables and bearer
tokens become `[REDACTED]`). The same redaction is applied to `diff.patch`,
`changed-files.txt` (and the per-repository `diffs/*`), `request.md`,
`analysis.json`/`analysis.md` and the manifest's `request` title and prompt, and
it runs on the whole diff before the size bound, so a truncated diff never
keeps a prefix of a secret. **Limit: only secrets present in the Foreman
server's environment are recognised** (values of environment variables whose
names contain `secret`, `token`, `password`, `credential`, `api_key` and the like,
at least 4 bytes). A value an agent reads from a committed `.env` file, a value
that exists only in the project secret store (injected into the agent's
environment but not in the server's), or one fetched at runtime, is not caught
and stays in `diff.patch` verbatim; treat the archive like the repository itself.

Known limits: a review is write-once per subject — a recorded `undetermined`
is never retried, and re-reviewing needs a new mechanism. The Analyzer does not
replay history on boot, so runs that finish while it is down are not reviewed.
A second terminal event for a subject whose review is still running is ignored.
With `:pi` the harness surfaced zero text events in a smoke test, and with
`:claude` the authentication must be valid; verify the reviewer provider by
running a jobsite end to end before relying on verdicts.

Add `.foreman/sessions/` to the `.gitignore` of every repo Foreman reviews:
untracked files there can be swept into an agent's `git add -A`.

Configuration (`config :foreman_server, :review`): `capture`, `analysis`
(set `analysis: false` to keep archiving but stop spending an agent run per
terminal run), `archive_root`, `agent` (`%{provider:, model:, effort:}` — the
reviewer is deliberately independent of the run's own provider), `evaluator`,
`evaluator_timeout_ms`, `max_transcript_bytes`, `max_diff_bytes`,
`max_comment_bytes`, `max_gap_beads`.

## Further Reading

- Command syntax: [CLI Reference](./cli-reference.md)
- Adding a Jido Harness provider: [docs/guides/adding-a-jido-harness-provider.md](./guides/adding-a-jido-harness-provider.md)

## Phase stall detection

Workflow authors can opt a phase into stall detection with `stall_detection`. `agent` detects no qualifying agent output; `messaging` detects no appended inbox/message progress. Example:

```yaml
phases:
  - name: wait-for-reply
    command: "/skill:verify"
    stall_detection:
      kind: messaging
      threshold_ms: 1800000
      policy: attention
```

Defaults: agent no-output = 900000 ms; messaging no-progress = 1800000 ms. Disable detector scheduling with `config :foreman_server, :stall_detection_enabled, false`. Do not use `0` or negative thresholds; validation treats those as malformed. A detected stall writes `RunStallReported`, updates `latest_stall` on run/phase/task projections, and appears in `foreman run get --format json`, MCP `foreman_run_status`, and API projection reads. Heartbeats alone are not progress.

## Outbound messaging delivery

`ForemanServer.Notifier` (supervised, started by default; `config :foreman_server, :start_notifier?, false` stops it) is the production producer of `Messaging.notify/2`. It subscribes to projection events (no replay) and maps them through the table in `ForemanServer.Notifier.Mapping`: run/jobsite failure and CI failing -> `failure`; run stall -> `stall`; a not-met review verdict, an agent question, an approval request/expiry, PR changes requested and exhausted PR fix attempts -> `action_needed`; run completed, PR created and any other review verdict -> `run_update`. Rows match by event name only (`RunFailed`, `JobsiteFailed`, `RunStallReported`, `RunCompleted`, `ReviewRecorded`, `QuestionOpened`, `QuestionExpired`, `ToolCallRequested`, `ToolCallExpired`, `PrCreated`, `PrChecksChanged`, `PrReviewChanged`, `PrFixExhausted`); an event Foreman does not produce simply never matches. Extend or override rows with `config :foreman_server, :notifier, rules: [%{event_type:, class:, severity:, level: :blocked | :progress, subject:, key_fields: [...], body_fields: [...], match: %{field => [values]}, url_field:}]` (configured rules win; a malformed rule raises at startup). Per project, the `notification_preference` setting (`every_turn`, `blocked_only` (default) or `off`) filters by level: `blocked_only` delivers only failures, stalls, needs-input, approvals, CI failing and review not met; `every_turn` also delivers progress rows and enables the `run_update` class for that notification; `off` delivers nothing. `run_update_rate_limit_ms` is enforced by the Notifier: at most one `run_update` per run per window. Replays collapse through the `dedupe_window_ms` check because the correlation id is a digest of the event type and the rule's `key_fields`. Notification events never carry a secret: the recipient is the label `default` and Slack/webhook destinations are resolved from config by the dispatcher (a Slack or webhook recipient is never used as the URL). A third provider, `webhook: [url:, secret:]` (`url` literal http(s) or `{:system, "ENV"}`; optional `secret` signs the body with HMAC-SHA256 in `x-foreman-signature`), POSTs a `foreman.notification.v1` JSON document. There is no desktop-push provider.

Enable outbound Telegram/Slack delivery with `config :foreman_server, :messaging`. Runtime config keys: `enabled`, `provider`, `event_classes`, `dedupe_window_ms`, `run_update_rate_limit_ms`, `telegram: [token:, chat_id:]`, and `slack: [webhook_url:]`. `ForemanServer.Messaging.notify/2` never calls provider HTTP directly; it persists notification lifecycle state. The supervised dispatcher starts after `CommandRouter`, performs restart catch-up from the event log, subscribes to projection events, redelivers notifications with no durable terminal outcome (an in-flight attempt or a retryable failure is retried; only a recorded success or a non-retryable failure is skipped), guarantees at most one delivery per notification within one dispatcher process lifetime even if both catch-up and a live projection event observe it, and records redacted success/failure state. A catch-up or subscribe failure crashes the dispatcher under supervision rather than silently dropping live/replay delivery. Delivery failure is notification state only; it must not turn a healthy run into failed.

## PR watching and auto-fix

Foreman watches the pull requests its runs open and can start small, bounded
"fix threads" on them. Nothing here ever merges: the merge gate
(`foreman run approve-merge`, `foreman run merge`) stays operator-only, and no
MCP tool, auto-fix policy or background reactor can approve or merge a PR. What the
watcher can do is take an approval back: a head it records that differs from the
approved one voids that approval and holds the gate again (see `run approve-merge`
under "Runs"); a fix push to an approved PR therefore needs a
fresh operator approval of the new head.

**Observation.** `ForemanServer.PrWatcher` is on by default
(`config :foreman_server, :pr_watcher, enabled:`; `FOREMAN_PR_WATCHER_ENABLED=false`
stops it). It reads each PR (checks, review decision, comments, unresolved
threads, merge conflicts) and folds changes into the run's PR projection as
`PrChecksChanged` / `PrReviewChanged` events. Two things trigger a read:

- a polling monitor, `ForemanServer.PrMonitor`, **opt-in** with
  `FOREMAN_PR_MONITOR_ENABLED=true`. It needs the `gh` CLI installed and
  authenticated on the server host. Polling is adaptive per PR: 30 s while checks
  are pending, 60 s within ten minutes of a change, 5 minutes when stable
  (`:pr_monitor_interval_ms`), 15 minutes after a day idle, with jitter, a
  per-tick cap (`:pr_monitor_max_per_tick`, 25) and back-off on failures or rate
  limits;
- `POST /webhooks/github` (needs `FOREMAN_GITHUB_WEBHOOK_SECRET`). Subscribe the
  webhook to `check_run`, `check_suite`, `pull_request`, `pull_request_review`,
  `pull_request_review_comment`, `pull_request_review_thread` and `issue_comment`.
  A delivery only refreshes the PR sooner; the signature is still mandatory and
  unknown PRs are ignored.

**Multi-repository runs.** A run that touched several repositories has one PR per
repository, and every PR is watched, polled and fixed on its own, addressed as
`{run_id, repo_id}` (`repo_id` is carried on the PR's events only for a
non-primary repository). A webhook or poll for repository b's PR updates b's PR
record only: it never changes a's PR state, watch record or merge gate. A fix
thread for a PR attaches that repository's checkout and that repository's
worktree, never another repository's.

**Reading.** `foreman run prs <run-id>` (HTTP `GET /api/runs/:id/prs`, MCP
`foreman_pr_status`) returns one record per PR: URL, status, head SHA (as the watch last
recorded it: the commit you review and name in `approve-merge --head-sha`; the server
checks it against GitHub, which is the authority), checks state, failing
checks, review decision, comment count, whether it is still watched, fix counters
(`ci`, `comments`, `conflicts` attempts and what is in flight) and the merge gate.

**Fix threads.** `foreman run fix-ci|address-comments|resolve-conflicts <run-id>
[--pr <url>] [--note <text>]` starts a jobsite that checks out the PR head
branch, fast-forwards it to the remote (never force), lets the agent fix the
problem and pushes to that same branch. PR comments, review text and CI logs are
untrusted and are passed to the agent inside a fence it cannot close. The agent is
the one the run used (its provider session is resumed only when the original
worktree path still exists), else `config :foreman_server, :pr_fix, agent:`.
`foreman run create-pr <run-id>` opens the PR when the run has none;
`foreman run watch-stop|watch-start <run-id> [--pr <url>]` pauses or resumes
watching one PR (a merged or closed PR is dropped automatically).

**Loop guard.** Per PR there is at most one fix in flight (of any kind), and a hard cap of
5 attempts per kind (operators included), and a fix that left the PR head unchanged is
recorded as `PrFixExhausted` (`no_progress`) instead of being retried. Exhaustion
is an event (`run.pr.fix_exhausted`), visible in `foreman run prs`.

**Auto-fix is opt-in per project.** Set the `pr_auto_fix` project setting, e.g.
`foreman project update <project> --pr-auto-fix '{"kinds":["ci"],"max_attempts":2,"cooldown_seconds":300}'`
(kinds from `ci`, `comments`, `conflicts`; attempts 1..5; cooldown 0..86400 s).
Without it PRs are observed but never changed unless an operator asks.

**Not verified against real GitHub (spike S4).** Live webhook deliveries, force
pushes to the PR branch, check re-run, merge-conflict resolution and unresolved
review-thread reads were designed from the GitHub API documentation and tested
with fakes only. Resuming a Claude provider session from a new directory is also
unverified; pi sessions are bound to their working directory.

## Needs you: approvals and questions

Agents can need an operator decision. Both show up as `waiting_on_you` in the project Overview.

- **In-flight tool approvals (Claude, `approval_mode: prompt`).** The claude CLI is started with `--permission-prompt-tool`, pointing at Foreman's per-run permission endpoint (`POST /agent-permission/:run_id`, authenticated by a per-run token, not the operator token). Each tool call that would prompt is recorded as a request (`approval_delivery: inflight`) and the call BLOCKS inside the live session until the operator decides: approve lets that one call run (no phase re-run, same provider session), deny tells the agent it was refused, and after `approval_timeout_ms` (default 30 minutes) nobody answering denies it (`decided_by: system`, reason `timeout`). Decide with `foreman approvals approve|deny`, `tool.approve` / `tool.deny` on `POST /api/commands`, or the Approve / Deny buttons on the thread card in the project workspace. A run that ends while a call is blocked expires the request and denies the call; a server restart kills the agent and its requests expire through the sweeper. A tool refused in flight is not re-requested by the post-hoc pause; the phase then fails as `permission_denied`. Set `config :foreman_server, :approvals, inflight: false` to keep Claude on the pause-and-re-run path; `inflight_base_url` overrides the URL claude uses to reach the endpoint (default `http://127.0.0.1:<port>`). The agent can only create requests: deciding is the operator-only `tool.approve` / `tool.deny` (never an MCP tool).
- **Tool approvals.** When a phase's agent is denied tools (`permission_denied`), the run pauses with reason `awaiting_approval` and one request per tool is recorded (`pause_on_permission_denied`, default on; set `config :foreman_server, :approvals, pause_on_permission_denied: false` to fail the phase as before). List them with `GET /api/projects/:id/approvals` (`?status=all` for history), `GET /api/runs/:run_id/approvals` or the read-only MCP tool `foreman_approvals_list`. Decide with `POST /api/commands` `tool.approve` / `tool.deny` (payload `run_id`, `tool_call_id`). Each request reports `approval_delivery`: `resume_with_override` (pi, claude: the run is resumed with a one-phase `approval_mode` override per spike S2) or `live` (ACP providers; no production caller opens such sessions yet). `tool.approve` is unrelated to the merge gate (`merge_approve`, `run.pr.merge`), which stays operator-only.
- **Questions.** `GET /api/projects/:id/questions`, MCP `foreman_questions_list`, answer with `question.answer` (payload `run_id`, `question_id`, `text`). The answer reaches a run's agent as an E6 steering message, or is published on `com.foreman.reply.operator` for unscoped questions.
- **Timeouts.** Unanswered requests expire durably (`ToolCallExpired`, `QuestionExpired`) via `Approvals.Sweeper` (`:approvals` config: `tool_call_timeout_ms` default 30 min, `sweep_interval_ms`, `on_timeout: :surface | :deny`). Expired items show as `approval_expired` / `question_expired`. There is no MCP tool to approve, deny or answer.

**Approval scope.** An approval resumes the run with an `approval_mode_override` on the `run.steer` message (`auto_edit` for edit tools such as Write/Edit, `auto_approve` otherwise). The override applies to the next phase only (including command phases), but within that phase it is phase-wide: pi and claude have no per-tool grant, so approving one tool relaxes the approval mode for that whole phase. The post-hoc claude path was exercised live only for `approval_mode: prompt` (see the in-flight bullet above for the per-call path); the harness does declare `allowed_tools` for claude, which Foreman does not pass yet. Only the names `Jobsite.Agent` knows (`default`, `prompt`, `auto_edit`, `auto_approve`) are accepted as an override.

**Recovery.** On startup the deliverers re-deliver approvals that were committed while the server was down (approved and never settled calls, denied calls whose run is still paused, answers to paused runs); the commands are idempotent, so an already-delivered decision is a no-op. An approved call whose decision never settled shows in the Overview as `approval_delivery_failed` while its run is paused.

**MCP read tools.** `foreman_approvals_list` (`project_id` or `run_id`, optional `status`) and `foreman_questions_list` (`project_id`, optional `status`) return the same fields as the HTTP endpoints. They are read-only; there is deliberately no MCP tool to approve, deny or answer.
