# CLI Reference

Complete reference for all `foreman` commands, options, and usage examples.

Project-aware operator commands (`run`, `status`, `reset`, and `retry`) accept `--project <name-or-path>`. Registered names resolve through `~/.foreman/projects.json`; absolute paths are accepted directly for one-off targeting.

> **INCORRECT.** Of the four verbs named, only `run` is dispatched, and it takes
> `--project-id`, not `--project`. `status`, `reset` and `retry` are not
> top-level commands (see the block below). `--project` is real on `task`.


> ## Read this first: most of this file documents commands that do not exist
>
> The Go CLI dispatches exactly six top-level verbs (`packages/foreman_cli/cmd/foreman/main.go`); every other verb
> returns `foreman: unknown command`. The complete real surface, taken from the
> subcommand switches and flag sets in that package, is:
>
> foreman init              --force   # --force is REQUIRED without --template (installs runtime workflows/prompts)
> foreman init              --template <basic|iterate|parallel|review|triage> --dir --force   # scaffolds <dir>/.foreman/; --force optional, additionally refreshes the installed runtime
>
> foreman project create    --format --id --idempotency-key --path --task-provider --task-provider-database-path
> foreman project get       --format
> foreman project update    --format --idempotency-key --task-provider --task-provider-database-path --goal --instructions --instructions-file --thread-model --thread-effort --coordinator-provider --coordinator-model --coordinator-effort --max-concurrent-runs --daily-thread-cap --coordinator-propose-before-start --coordinator-max-active-threads --coordinator-reuse-threads --library-collect-produced --clear
> foreman project settings  --format
> foreman project context   --format
> foreman usage             --project --from --to --by --limit --format
> foreman approvals         list --project --run --all --format | approve --run --call --by --reason | deny --run --call --by --reason
> foreman questions         list --project --all --format | answer --run --question --text --by
> foreman project env       list --format | set --replace | unset
> foreman project secret    list --format | set --from-env | unset
> foreman project setup-script show | set --file | clear
> foreman project network   show | set --mode --allow
> foreman project library   list --format | add --name --format | replace --name --format | remove
> foreman project pause     --reason --idempotency-key
> foreman project resume    --idempotency-key
> foreman project reactivate --idempotency-key
> foreman project delete    --force --idempotency-key   # archives; see docs/decisions/project-delete.md
> foreman project list      --format --include-archived
> foreman project chat      --m --no-wait --since --history --format --restart --timeout   # exit 2 usage, 3 unhealthy coordinator
>
> foreman task create       --description --id --project --status --task-type --title --trd-path --workflow-type  # REMOVED (TRD-018)
> foreman task approve      --approved-by --command-id --id  # REMOVED (TRD-018)
> foreman task retry        --id --reason  # REMOVED (TRD-018)
> foreman task get          (no flags)  # REMOVED (TRD-018)
> foreman task list        --project --status  # REMOVED (TRD-018)
> foreman task update      --description --id --priority --status --title  # REMOVED (TRD-018)
>
> foreman run list          --limit --project-id --status
> foreman run get           (no flags)
> foreman run cancel        --id --reason
> foreman run pause         --id --reason
> foreman run resume        --id
> foreman run remove        --id
> foreman run reset         --id
> foreman run approve-merge --approver --id --identity
> foreman run merge         --id
> foreman run submit        --backend --base-branch --project-id --prompt --work-id --workflow
>
> foreman thread list       --door --limit --project --status
> foreman thread get        (no flags)
> foreman thread stop       --reason
> foreman thread resolve    --reason
> foreman thread reopen     (no flags)
> foreman thread steer      --message --message-id --no-resume
>
> foreman workflow install  --remote --retries --retry-delay-ms --source --target
> foreman workflow remove   --all
>
> `foreman task create`, `foreman task approve`, `foreman task
> retry`, `foreman task get`, `foreman task list`, and `foreman task
> update` are REMOVED (TRD-018, 2026-09-13) — the `task` dispatch
> case and its handler functions were deleted from
> `packages/foreman_cli/cmd/foreman/task.go` (51 lines remain: shared
> HTTP envelope/JSON helpers used by other command files, not
> task-verb handlers); invoking any of them now produces the CLI's
> standard "unknown command" error.
>
> Every verb except `init` REQUIRES a subcommand: bare `foreman run`,
> `foreman task`, `foreman project` or `foreman workflow` returns
> `missing subcommand`. Any section below showing flags directly on a bare verb
> (notably `foreman run --prompt …`) is not a real invocation.
>
> Twenty-five documented top-level verbs are not dispatched at all: `abandon`,
> `attach`, `board`, `clean-state`, `debug`, `import`, `inbox`,
> `issue`, `logs`, `merge`, `metrics`, `monitor`, `plan`, `pr`, `purge`,
> `recover`, `reset`, `retry`, `sentinel`, `server`, `sling`, `status`, `stop`,
> `watch`, `worktree`. Each section below that describes one now carries a
> **NOT IMPLEMENTED** note naming the nearest real command where one exists.
>
> The sections have been annotated rather than deleted: they read as a record of
> intended design, and deleting them would discard that. But they are not a
> reference, and this file is the one an operator or agent reaches for first —
> which is not hypothetical. REQ-007 of
> `docs/PRD/PRD-2026-d306444f-phase-commit-control.md` was specified against the
> `foreman inbox` surface documented below as though it worked, and had to be
> dropped once the aggregate behind it turned out to be unreachable. `docs/lessons/documentation-discipline-history.md`
> warns against trusting a stale build artifact over
> source; this is the same failure with the roles reversed, where the *document*
> is the stale artifact.
>
> Note also that this file is *incomplete* about what is real: it has no section
> for `run get`, `run cancel`, `run pause`, `run resume`, `run reset`, `workflow install` or `workflow
> remove`, all of which exist. `run pause` and `run resume` are new
> (unattended-run-control: no default phase timeout, real pause/resume/kill —
> `run cancel` now also kills the dispatched agent's OS-level process via
> `RunControl.cancel_agent/1`, not just the run projection). `foreman task
> approve`, `task get`, `task retry`, `task list`, and `task update` used to
> round out that list; TRD-018 (2026-09-13) deleted them — along with `task
> create`, which did have a section below — from the Go CLI (see the
> corrected inventory above). The block above is authoritative; `docs/lessons/operator-reference.md`
> (Task Lifecycle / Go CLI Commands) reflects the same
> TRD-018 removal and remains accurate against the Go source.
>
> Web dashboard note: the operator run-management surface is not a CLI verb.
> Open `/dashboard/runs` on the Phoenix server with the bearer token guard;
> `/dashboard` remains the separate Jido live dashboard. Dashboard run controls
> dispatch the same command types listed above (`run.pause`, `run.resume`,
> `run.remove`, `run.reset`, and separately-labelled `run.cancel` if exposed).
> None of these are Go CLI verbs. Two more operator command types have no
> section here either: `task.update` did have a Go CLI verb (`foreman task
> update`, removed by TRD-018, see this file's top-of-file note);
> `project.reactivate` never had one. `docs/user-guide.md`'s HTTP API
> section is the complete operator command allowlist.

## Global Usage

```bash
foreman [command] [options]
foreman --help              # Show all commands
foreman <command> --help    # Show command-specific help
```

### Local Development Services

> **INCORRECT.** Neither `devbox run dev:up` nor `devbox run db:up` exists.
> `devbox.json` defines 22 scripts; the stack is brought up with `devbox run up`
> (see `docs/lessons/devbox-and-toolchain.md`). Database scripts are `db:migrate`, `db:reset`,
> `db:rollback`, `db:console`.

This repository's Devbox/direnv setup starts Docker Compose services before you run Foreman locally. `devbox run dev:up` starts shared Postgres plus Hindsight; `devbox run db:up` starts only the shared pgvector Postgres container. `.envrc` sources `.env`, and Foreman CLI/server commands use `DATABASE_URL` from `.env` or the process environment. If `DATABASE_URL` is unset, the compose-managed Foreman database is exposed on `127.0.0.1:55432` by default; Hindsight uses a separate `hindsight` database in the same container.

### Domain Groups and Deprecated Aliases

> **NOT IMPLEMENTED — this entire section.** `foreman --help` prints a flat
> command list (the `usage` const in `main.go`), not domain groups. There is no
> alias machinery at all: `main.go` contains no alias, deprecation or shorthand
> handling, and its `default:` branch returns `unknown command`, so every
> spelling in the table below — including the `Use instead` column — is
> unroutable. Of the 23 distinct verbs listed in the groups, three exist —
> `init`, `run`, `task`; `retry` and `reset` exist only as the subcommands
> `task retry` and `run reset`.
>
> `foreman server start` in the closing line does not exist either; use
> `mix phx.server`.

`foreman --help` groups commands by domain:

- Setup/health: `init`, `doctor`, `daemon`, `server`
- Planning: `plan`, `sling`
- Execution: `run`, `retry`, `reset`, `stop`, `recover`
- Tasks/views: `task`, `status`, `board`, `watch` (`monitor` alias), `logs`
- Collaboration: `inbox`, `attach`, `debug`
- Delivery/VCS: `worktree`, `merge`, `pr`

Deprecated aliases stay hidden from help and print the replacement spelling when used:

| Deprecated | Use instead |
|------------|-------------|
| `foreman dashboard` | `foreman watch` |
| `foreman purge-logs` | `foreman purge logs` |
| `foreman purge-zombie-runs` | `foreman purge runs` |
| `foreman run --skip-explore` / `--skip-review` | `foreman run --workflow <custom-workflow>` |
| removed `foreman mail send` | `foreman inbox send` |

Legacy TS delegation and Node daemon start/restart were removed after the Elixir cutover; use `foreman server start` for the scheduler.

---

## Project Setup

### `foreman init`

> **PARTLY INCORRECT — including what the command does.** `foreman init`
> (no `--template`) does not initialize a project: it POSTs an empty body to
> `/api/admin/workflows/install` and prints the response (`init.go`). It
> does not create `.foreman/`, install Pi skills, or register the project. It
> declares `--force`, which is **required** for this path — bare
> `foreman init` returns `--force is required to refresh the installed
> runtime copy`. `-n`/`--name` and `--wizard` do not exist, and `init` takes
> no positional name. What it DOES take is `--template` and `--dir`
> (`init.go:44-45`), neither of which reaches the HTTP path.

Initializes Foreman in a project. Which half runs depends on `--template`: with
it, the verb writes a repo-local `.foreman/` scaffold entirely client-side,
with no HTTP request at all; without it, it POSTs the asset refresh the note
above describes. Either way it does **not** install or refresh skills --
bundled skills are installed by `ForemanServer.Skills.Installer` to
`~/.foreman/skills/` when the server boots (see `docs/user-guide.md` §7.4), so
after editing a bundled skill you delete the installed copy and restart the
server; re-running `init` changes nothing there. The CLI does not run Postgres
migrations or open a database connection.

```bash
foreman init                      # REFUSED: --force is required to refresh the runtime copy
foreman init --force              # POSTs /api/admin/workflows/install (asset refresh only)
foreman init --template NAME      # Client-side repo-local .foreman/ scaffold, no HTTP -- see below
foreman init --template NAME --dir PATH   # Same, scaffolded into PATH instead of the cwd
```

Two of the verbs this section previously listed never existed. `foreman init -n my-project` and
`foreman init --wizard` have no route: `init.go:43-45` declares exactly three flags — `--force`,
`--template` and `--dir` — with no project-name flag and no positional name, and there is no
wizard code path anywhere in `packages/foreman_cli`. `--wizard` additionally carried a table row
describing interactive behaviour it does not have. `docs/lessons/documentation-discipline-history.md` names both of these as known-bad
claims, so they are annotated rather than left to read as intended design.

| Option | Description |
|--------|-------------|
| `-n, --name <name>` | **Does not exist.** `init.go:43-45` declares `--force`, `--template` and `--dir` only; there is no project-name flag and no positional name. |
| `--force` | Overwrite existing prompt and workflow files. Run this after editing bundled source prompts/workflows so installed runtime copies do not drift. It has no effect on skills: `foreman init` never reads or writes `~/.foreman/skills`, which the server installs at boot via `ForemanServer.Skills.Installer`. |
| `--wizard` | **Does not exist** — never has; no wizard code path is present anywhere in the Go CLI. |

#### `foreman init --template <name>` (real, current)

This flag **is** implemented and does what its name says — it is the one
piece of the inaccurate prose above that is now literally true, for the
scaffold it produces. `--template <name>` (`basic`, `iterate`, `parallel`,
`review`, or `triage`) scaffolds a repo-local `<dir>/.foreman/` (default
`<dir>` is `.`): shared `README.md`/`Dockerfile`/`.gitignore`
plus the named template's runnable `.exs` script and its `prompts/*.md` file(s). It is a
pure local file write — no HTTP request, no running server required — and
never overwrites an existing file (a second invocation reports every file
`skipped`). Combine with `--force` to also run the asset-refresh POST in the
same invocation; `--force` still never overwrites a scaffold file either.

```bash
foreman init --template basic                       # scaffold .foreman/ in the current directory
foreman init --template iterate --dir /path/to/repo  # scaffold into a different repo
foreman init --template review --force               # scaffold AND refresh installed runtime prompts/workflows
```

| Option | Description |
|--------|-------------|
| `--template <name>` | Scaffold `.foreman/` from a bundled template: `basic`, `iterate`, `parallel`, `review`, `triage`. Unknown name is a usage error. |
| `--dir <path>` | Directory to scaffold `.foreman/` into (default `.`) |

The scaffolded scripts come in two kinds. `basic`, `iterate` and `parallel`
drive a **running** `foreman_server` over HTTP through the `foreman_client`
package (`packages/foreman_client`, loaded by the script with `Mix.install`;
nothing is copied into the project); they run with plain `elixir` (Erlang/OTP 27+, no Foreman
checkout or database) after `FOREMAN_API_TOKEN` and `FOREMAN_PROJECT_ID` are set
(see the user guide's Remote Jobsite API section for the server-side config).
`iterate` also reads optional `FOREMAN_AGENT_MODEL`, `FOREMAN_MAX_ITERATIONS` (positive integer, default 20) and `FOREMAN_AGENT_ENV` (comma-separated names of shell variables passed to the agent; the server must allowlist them, see the user guide).
`parallel` additionally reads `FOREMAN_MERGE_INTO` — the branch the merge step
targets, which must be the branch currently checked out in the *server's* copy of
the repo, since `Jobsite.merge_into/2` refuses any other target (409). Unlike
`FOREMAN_PROJECT_ID` it has no default, so an unset value fails the script only
after the fan-out completes, not at start.

`review` and `triage` call `ForemanServer.Jobsite` directly and must run inside
a booted `foreman_server` app (`mix run`, not `mix run --no-start`), e.g. from a
Foreman checkout: `cd packages/foreman_server && mix run ../../.foreman/review.exs`.

### `foreman project`

Manage Elixir-registered projects.

**Subcommands:**
| Command | Description |
|---------|-------------|
| `create` | Register a new project |
| `get <id>` | Fetch a project projection |
| `update <id>` | Update a project's task provider |
| `delete <id>` | Soft-delete (archive) a project |
| `list` | List project projections |
| `memory` | List, read, write, forget or sync the project's memory |
| `chat <id> [message...]` | Chat with the project's coordinator |

### `foreman project create`

Register a new project. `--id`, `--path`, and `--task-provider` are required. `--task-provider=beads` also requires `--task-provider-database-path` with an absolute Beads database path.

```
foreman project create \
  --id project-123 \
  --path /srv/foreman/project-123 \
  --task-provider beads \
  --task-provider-database-path /srv/foreman/project-123/.beads
```

| Option | Description |
|--------|-------------|
| `--id <id>` | Project ID (required) |
| `--path <path>` | Project path (required) |
| `--task-provider <provider>` | Task provider (required) |
| `--task-provider-database-path <path>` | Absolute task-provider database path; required when `--task-provider=beads` |
| `--idempotency-key <key>` | Idempotency key |
| `--format json` | Print the raw command response as JSON |

### `foreman project get <id>`

Fetch a project projection.

```
foreman project get project-123
```

| Option | Description |
|--------|-------------|
| `--format json` | Print the raw projection as JSON |

### `foreman project update <id>`

Update a project's task provider and/or settings. At least one change flag is required; `--task-provider` is only required when changing the provider. `--task-provider=beads` also requires `--task-provider-database-path` with an absolute Beads database path. The server is the single validator: its error (for example `{:instructions_too_long, 16001, 16000}`) is printed verbatim. `status` cannot be set here (use `pause`/`resume`/`reactivate`).

```
foreman project update --task-provider beads --task-provider-database-path /srv/foreman/project-123/.beads project-123
```

| Option | Description |
|--------|-------------|
| `--task-provider <provider>` | Task provider (required only when changing the provider) |
| `--task-provider-database-path <path>` | Absolute task-provider database path; required when `--task-provider=beads` |
| `--goal <text>` | Project goal (max 2000 characters) |
| `--instructions <text>` | Standing instructions (max 16000 characters); exclusive with `--instructions-file` |
| `--instructions-file <path>` | Read the instructions from a file |
| `--thread-model <model>`, `--thread-effort <low\|medium\|high>` | Default model/effort for threads |
| `--coordinator-provider <pi\|claude>`, `--coordinator-model <model>`, `--coordinator-effort <low\|medium\|high>` | Coordinator settings |
| `--max-concurrent-runs <n>` | Concurrent runs limit (1..1000) |
| `--daily-thread-cap <n>` | Threads started per UTC day (1..10000) |
| `--library-collect-produced[=false]` | Register each run's artifacts and session-archive files in the project library (opt-in, default off) |
| `--coordinator-propose-before-start=<true\|false>`, `--coordinator-max-active-threads <n>` (1..50), `--coordinator-reuse-threads=<true\|false>` | Coordinator tuning, enforced by the server |
| `--clear <setting>` | Clear a setting (repeatable) |
| `--idempotency-key <key>` | Idempotency key (without it the command id hashes the whole update) |
| `--format json` | Print the raw command response as JSON |

### `foreman project recommend <id>`

Read-only `GET /api/projects/:id/recommendations`: setup recommendations for a project, each with a stable id, a severity (`action` > `warn` > `info`) and an optional fix (a Foreman command, or manual advice). Detector ids: `task_provider.wire_beads`, `task_provider.br_missing`, `repo.agents_md_missing`, `ci.none_detected`, `gh.unauthenticated`, `gh.check_timeout`, `git.no_remote`, `workflows.not_installed`, `workflows.unmapped_types`, `provider.coordinator_unavailable`, `provider.none_installed`, `settings.instructions_empty`, `settings.goal_empty`, `settings.env_plain_secrets`, `memory.empty` (only when project memory exists), `project.paused`, `stack.test_hint`. A fact that cannot be observed produces no recommendation. Probes check only fixed file names and run external commands (`gh auth status`) by absolute path from the server's `PATH` with a 5 s bound each (15 s total, then HTTP 504); nothing from the repository is executed.

```bash
foreman project recommend my-project
foreman project recommend --format json my-project
foreman project recommend --fail-on warn my-project   # exit 1 when a warn/action exists
```

The MCP read tool `foreman_project_recommendations` returns the same body.

### `foreman project adopt`

Brings a session into a project via `POST /api/project-adoptions` (not an MCP tool; the move is also reachable as the `project.adopt` command on `POST /api/commands`).

```bash
foreman project adopt --kind run --id RUN --into other-project            # move
foreman project adopt --kind run --id RUN --into other-project --continue --prompt "also add /readyz"
foreman project adopt --kind run --id RUN --new-project --project-id my-app --path /repo --goal "..."
```

- **Move** re-homes the task, all runs of that task (or the jobsite) and the archive manifest (`.foreman/sessions/<kind>/<id>/manifest.json` gains `project_id`, `adopted_from`, `adopted_at`). Event history is immutable: events keep their original `project_id`, the read model and the manifest change, and `ReviewRecorded` keeps the original project. Refusals: `subject_active` (any non-terminal run/jobsite, including paused ones: they hold a run reservation), `subject_not_found`, `project_not_found`, `project_archived`, `project_paused`, `subject_bound_to_task_provider` (a `beads:<project>:<bead>` task belongs to its source project's beads DB), `repo_not_in_project` (the session's repo must be the target project's path). Re-issuing is a no-op that still repairs a stale manifest.
- **Continue** (`--continue --prompt`) creates a NEW task in the target project whose prompt is built from the archive (`request.md`, branch, `changed-files.txt`, a bounded tail of `transcript.jsonl`, wrapped as untrusted data) plus your text; the source is untouched and may still be running. The provider session is not forked (no run-start path carries a session id): the new thread always starts context-seeded.
- **Mint** (`--new-project`) registers a project from the session's manifest (id = repo directory slug, goal = request title) and moves the session into it. Refused with `path_in_use` when a live project already owns that repo path, and with `repo_not_in_project` when `--path` is not the session's repo.

### `foreman project settings <id>`

Print a project's status, settings and live limits (`GET /api/projects/<id>/settings`): effective `max_concurrent_runs`, `active_runs`, `daily_thread_cap`, `threads_started_today`, `remaining_today`, `cap_reached?`, `resets_at`, `deferred_tasks`, `deferred_today` (tasks refused today by the cap, run limit or pause; `deferred_by_reason` in `--format json`). `--format json` prints the raw response. `config.env` values are never shown.

### `foreman usage --project <id>`

Print token and cost usage of a project (`GET /api/projects/<id>/usage`). `--project` is required (it is never guessed). Flags: `--from YYYY-MM-DD`, `--to YYYY-MM-DD` (inclusive UTC days, at most 366 days apart; shape checked locally, range rules by the server), `--by day|model|provider|role|thread` (default `model`; sent as `group_by`), `--limit N` (thread rows, server default 50, max 500), `--format table|json` (`json` prints the response unchanged). The table columns are group, `INPUT`, `OUTPUT`, `CACHE-READ`, `CACHE-WRITE`, `TOTAL`, `COST`, plus a `TOTAL` row. A cost of `-` is unknown (`cost_usd: null`: the provider reported none, which is not free); `*` marks a partial sum; a footnote lists the number of events with unknown cost. When the project has a daily thread cap a line follows, for example `daily thread cap: threads today: 3/10, resets 00:00 UTC, 4 deferred today`. Server errors (`invalid_range`, `range_too_large`, `invalid_group_by`, `invalid_limit`, unknown project) are printed with their code.

### `foreman project env list|set|unset <id>`
Manage the project's plain environment variables (`PUT /api/projects/<id>/environment`,
operator command `project.environment.set`). `set <id> NAME=value ...` merges into the
current variables; `--replace` starts from an empty set (required once to migrate a legacy
`config.env` project whose values are hidden). `list --format json` prints the raw
`GET /api/projects/<id>/environment` response. Secret-looking names are rejected: use `secret`.

### `foreman project secret list|set|unset <id> [NAME]`
Secrets live only in the server's secret store; events, logs and responses carry names and
versions. `set <id> NAME` reads the value from **stdin** (trailing newline trimmed) or from
`--from-env VAR`; the value is never a flag or argument and is never printed.
`list` prints `NAME`, version and update time. `unset` deletes.

### `foreman project setup-script show|set|clear <id>`
`set --file <path>` installs the script the server runs once after each fresh run/jobsite
worktree is created (fatal on non-zero exit or timeout); `clear` removes it; `show` prints it.

### `foreman project network show|set <id>`
`set --mode default|none|allowlist [--allow <host> ...]`. Enforced on docker jobsites only;
workflow runs and the host sandbox do not enforce it (host sandbox + policy is a typed error).

### `foreman project context <id>`

Print the standing context an agent launched now would receive (`GET /api/projects/<id>/context`, read-only): project instructions, repositories and the memory index, exactly as injected. `--format json` returns `system_text`, `bytes`, `sha256`, `sections`, `truncated` (sections cut to fit the budget) and `redactions`. A project with no instructions or memory prints `no standing context`; an unknown project exits non-zero.

```
foreman project context project-123
foreman project context --format json project-123
```

### `foreman project repo add|remove|list <id>`

Manage the repositories of a multi-repository project (E12). The project's own `path` is the synthesised **primary** repository (id `main`, cannot be removed); `repo add` attaches further checkouts that already exist on the server host (no clone). `add --id <repo-id> --path <abs-path> [--default-branch B] [--by NAME]` and `remove --id <repo-id> [--by NAME]` post the operator commands `project.repo.add` / `project.repo.remove` (`--idempotency-key` makes retries collapse). Ids match `^[a-z0-9][a-z0-9-]{0,31}$`. Before dispatch the server resolves the path with realpath (symlinks cannot alias a repository), requires the root of a git work tree, and rejects a path equal to the primary or another attached repository (`repo_path_duplicate`) or a checkout with the same normalised `origin` URL as another repository (`repo_remote_duplicate`). A `project update --path` that moves the primary goes through the same checks. `list [--format=json]` reads `GET /api/projects/<id>/repositories` (primary first); the project JSON carries the same list under `repositories`. Run-start still refuses more than one repository (`multi_repo_runs_disabled`) until the multi-repo gate is lifted. Project settings `repo_allowlist` (absolute path prefixes) and `max_repos_per_run` (default 4) are set with the `project.update` command; they are validated (`invalid_repo_allowlist`, `max_repos_per_run_invalid`) but not yet consumed.

```
foreman project repo add --id api --path /srv/api project-123
foreman project repo list project-123
foreman project repo remove --id api project-123
```

### `foreman project pause <id>` / `resume <id>` / `reactivate <id>`

`pause [--reason <text>]` refuses new work (`task.create`, run reservation, jobsite start, BeadsWatcher imports) with `{:project_paused, id}` while in-flight runs continue; it is reversible. `resume` restores admission and re-admits held work. `reactivate` un-archives an archived project. Each takes `--idempotency-key <key>`.

### `foreman project schedule list|create|pause|resume|delete`

Manage a project's scheduled tasks. `list --project-id <id> [--json]` prints ID, NAME, SPEC, STATUS, NEXT FIRE and LAST OUTCOME plus a `ticker: running|disabled` line (schedules do not fire while the ticker is disabled). `create --project-id <id> --name <n> (--every <30m> | --cron "<expr>") [--timezone <tz>] (--prompt <text> | --prompt-file <path>) --workflow <w> [--auto-approve=false] [--overlap skip|allow] [--id <schedule-id>]` posts `schedule.create` (exactly one of `--every`/`--cron`; `--overlap` defaults to `skip`, `--auto-approve` to true). `pause|resume|delete --project-id <id> --id <schedule-id>` post `schedule.pause|resume|delete`. Server rejections (e.g. `{:invalid_schedule_spec, :every, :below_minimum}`) are printed verbatim with a non-zero exit.

### `foreman project delete <id>`

Archive a project (**not** a purge: runs, tasks and event history are kept; reactivate with `foreman project reactivate <id>`). The server rejects the archive while active runs remain.

```
foreman project delete --force project-123
```

| Option | Description |
|--------|-------------|
| `--force` | Print active run ids if archive is blocked |
| `--idempotency-key <key>` | Idempotency key |

### `foreman project list`

List project projections. Default table columns: ID, PATH, ARCHIVED, REGISTERED, VERSION.

```
foreman project list --include-archived
```

| Option | Description |
|--------|-------------|
| `--include-archived` | Include archived projects |
| `--format json\|ndjson` | Output format |

### `foreman project chat`

Talk to a project's coordinator. A message (arguments, `-m`, or piped stdin) is POSTed to `/api/projects/:id/coordinator/messages`; the CLI then long-polls `GET .../messages?after=<seq>&wait_ms=20000` and prints coordinator/system/agent messages until the coordinator is idle again. With no message on a TTY it runs an interactive loop (`/restart` restarts the coordinator, `/quit` or EOF exits).

```
foreman project chat project-123 "fix the login bug"
```

| Option | Description |
|--------|-------------|
| `-m <text>` | Message text (alternative to positional words or stdin) |
| `--no-wait` | Return right after the POST, printing `message_id` and `seq` |
| `--since <seq>` | Print messages after the cursor, then exit |
| `--history <n>` | Print the last `n` messages, then exit |
| `--format text\|json\|ndjson` | `json`/`ndjson` emit the server's message objects |
| `--restart` | Restart the coordinator (`POST .../coordinator/restart`), then exit |
| `--timeout <duration>` | Overall wait bound (default `10m`) |

Exit codes: `0` ok, `2` usage error, `3` coordinator `unhealthy` (the notice includes `last_error`), other non-zero for HTTP errors (the server's error envelope is printed).

### `foreman project memory`

View, edit and delete a project's memory (`<project>/.foreman/memory/`). All verbs call `/api/projects/:id/memory`; content is redacted and size-capped by the server.

```
foreman project memory list [--format json|table] <project-id>
foreman project memory read --name <topic> [--format json|table] <project-id>
foreman project memory write --name <topic> [--description <text>] --file <path|-> [--format json|table] <project-id>
foreman project memory forget --name <topic> <project-id>
foreman project memory sync [--format json|table] <project-id>
```

| Verb | HTTP | Notes |
|------|------|-------|
| `list` | `GET /api/projects/:id/memory` | table by default; `--format json` prints one JSON object per topic (NDJSON) |
| `read` | `GET /api/projects/:id/memory/:name` | prints the content; `--format json` prints the whole response |
| `write` | `PUT /api/projects/:id/memory/:name` | content from `--file <path>` or stdin with `--file -`; `--name` and `--file` are required |
| `forget` | `DELETE /api/projects/:id/memory/:name` | `--name` required |
| `sync` | `POST /api/projects/:id/memory/sync` | records hand-edited files in the audit trail; exits non-zero if any topic could not be recorded |

Server errors keep their code (`content_too_large`, `index_full`, `too_many_topics`, `content_not_durable`, `name_invalid` = 422; unknown topic or project = 404; archived project = 409). `foreman commands` also generates `foreman-project-memory-list` and `foreman-project-memory-read` assets.

### `foreman project library`

Add, replace, remove and list a project's library files (`<project>/.foreman/library/`). Uploads go to `/api/projects/:id/library` as multipart `files[]` parts.

```
foreman project library list [--format json|table] <project-id>
foreman project library add [--name <name>] [--format json|table] <project-id> <path>...
foreman project library replace [--name <name>] [--format json|table] <project-id> <entry-id> <path>...
foreman project library remove <project-id> <entry-id>
```

| Verb | HTTP | Notes |
|------|------|-------|
| `list` | `GET /api/projects/:id/library` | entries, the markdown index and the effective limits |
| `add` | `POST /api/projects/:id/library` | one folder (walked locally with the server's rules) or up to 100 files (480 MB each); every skipped file is printed with its reason |
| `replace` | `PUT /api/projects/:id/library/:entry_id` | keeps the entry id, name and kind unless `--name` is given |
| `remove` | `DELETE /api/projects/:id/library/:entry_id` | deletes the files and the entry |

Folder rules (client and server): hidden files and directories, `node_modules`, symlinks and files over 30 MB are skipped; at most the first 100 files within 200 MB (sorted path order; the rest are reported as `folder_file_cap` / `folder_byte_budget`); at most 10 folders per project. Reading a file is `GET /api/projects/:id/library/:entry_id/files/*path` (raw bytes, 1 MiB cap, served as an attachment). Adding a directory that lives on the server host (`{"server_path": "/abs/dir"}` JSON body) is refused with 403 `server_path_disabled` unless `config :foreman_server, :library, allow_server_paths: true`. Server errors keep their code (`name_invalid`, `path_invalid`, `too_many_files`, `file_too_large`, `folder_empty`, `too_many_folders`, `duplicate_name`, `source_missing` = 422; `too_large` = 413; unknown entry or project = 404; archived project = 409). The opt-in setting `foreman project update --library-collect-produced` registers each run's artifacts and archive files into the library. Agents read the library through the MCP tools `foreman_project_library_list` / `foreman_project_library_read`; there is no agent write tool.

---

## Agent Command Assets

### `foreman commands`

Generate, validate, or install agent command assets for Foreman operators. The generated assets were thin wrappers over Go CLI commands: `foreman task create`, `foreman task get <task-id>`, `foreman task list`, and `foreman task update` are all REMOVED (TRD-018, 2026-09-13) — every generated shortcut wrapping the `task` verb group now fails with the CLI's "unknown command" error until the generator is updated. `foreman run submit`, `foreman run list`, and `foreman run get <run-id>` are unaffected and round out the wrapped set. They inherit `FOREMAN_API_URL` and `FOREMAN_API_TOKEN`; generated files must not embed secret values.

**Subcommands:**
| Command | Description |
|---------|-------------|
| `inventory` | Print the canonical command inventory. |
| `generate` | Render copyable assets for one target agent or all agents. |
| `install` | Install verified native assets for one target agent. |
| `validate` | Render all targets and check CLI verbs/flags, unresolved placeholders, and unsupported-target reasons. |

### `foreman commands inventory`

Print generated command IDs, CLI mappings, and descriptions. Pass `--json` for the full structured inventory.

```bash
foreman commands inventory
foreman commands inventory --json
```

### `foreman commands generate --agent <agent>`

Render command assets for `claude`, `pi`, `omp`, `codex`, `opencode`, or `all`. Without `--output`, the command prints JSON containing each rendered file. With `--output`, it writes generated files below `<output>/<agent>/`.

```bash
foreman commands generate --agent all --output ./foreman-agent-commands
```

### `foreman commands install --agent <agent>`

Install native command files only when Foreman has a verified native path/format. Claude Code project-local Markdown slash commands are verified and install to `.claude/commands/foreman` by default. Existing files are refused unless `--force` is supplied. For Pi and OMP agents, `--scope global` uses the recommended global skill directory when no `--target` is specified. For other agents (Codex, OpenCode), `--scope global` requires an explicit `--target` directory that the operator has verified.

```bash
foreman commands install --agent claude --scope project
foreman commands install --agent claude --target .claude/commands/foreman --force
```

Pi/OMP install to ~/.pi/agent/skills/<id>/SKILL.md. Codex and OpenCode remain generate-only.

### `foreman commands validate`

Validate the generated inventory and rendered assets against the Go CLI contract.

```bash
foreman commands validate
```

The workflow task shortcuts create tasks that require later approval. The `foreman-run-submit` asset is the one-step ad-hoc execution path and documents that `--backend codex|opencode` being accepted by the CLI does not prove runtime provider readiness.

---

## Dispatching Work

### `foreman run`

> **NOT IMPLEMENTED as described.** `foreman run` is not a dispatch verb; it
> requires one of `list`, `get`, `cancel`, `remove`, `reset`, `submit`, and a
> bare `foreman run` returns `missing subcommand`. None of the twenty flags this
> section documents exist anywhere in `run.go` — `--model`, `--watch`,
> `--no-watch`, `--yes`, `--dry-run`, `--resume`, `--resume-failed`,
> `--max-agents`, `--stagger`, `--skip-explore`, `--skip-review`, `--no-pipeline`,
> `--no-auto-dispatch`, `--runtime-mode`, `--telemetry`, `--project`,
> `--project-path`, `--default-branch`, `--task`, `--foreman`.
>
> **NOT IMPLEMENTED as of TRD-018.** This section used to say "To
> start work, use `foreman task create` + `foreman task approve`, or
> `foreman run submit`" — the first two verbs were deleted on
> 2026-09-13 (see the note at the top of this file). Start work today
> by creating or opening a bead (`br create`, or `br update <id>
> --status=open`) and labeling it for Foreman (`br update <id> --add-label
> foreman-exec` — `--labels` would REPLACE all existing labels) — BeadsWatcher dispatches the internal `task.create` +
> `task.approve` commands automatically for open, labeled beads; unlabeled
> beads are left for external processors (see the label gate in
> [`docs/user-guide.md`](../docs/user-guide.md)).
> `foreman run submit` for one-step ad-hoc execution.
> Telemetry specifically is not a CLI flag on any command: Langfuse LLM
> traces are controlled by `OTEL_EXPORTER_OTLP_ENDPOINT`,
> `LANGFUSE_PUBLIC_KEY`, and `LANGFUSE_SECRET_KEY`; SigNoz operational logs
> are a separate opt-in path controlled by `FOREMAN_SIGNOZ_LOGS_ENABLED`,
> `FOREMAN_SIGNOZ_OTLP_ENDPOINT`, `FOREMAN_SIGNOZ_OTLP_HEADERS`, and
> `FOREMAN_SIGNOZ_LOG_LEVEL`, parsed once into `config :foreman_server,
> :signoz_logs` (see
> [`docs/user-guide.md`](../docs/user-guide.md#8-telemetry-otel-litellm-and-langfuse)).

Dispatch ready tasks to AI agents by sending a scheduler tick to the Elixir orchestration server, which owns ready-task claiming, capacity, and worker launches.

> **NOT A REAL INVOCATION.** The bare `foreman run [flags]` example block and
> flag table immediately below predate `foreman run`'s dispatch-verb
> requirement (see the `NOT IMPLEMENTED as described` note above) and are
> kept only as a record of the intended design, per this file's annotation
> convention. `foreman run --watch` in the paragraph after it is likewise
> not a real invocation. Today: `foreman run submit` for one-step ad-hoc
> execution, or let BeadsWatcher auto-dispatch via `br create`/`br update
> --status=open` with the `foreman-exec` label (the label gate skips an
> open bead that lacks it).

Default workflows include a `documentation` phase before finalization. The bundled bug workflow starts with a lightweight Explorer phase that uses `Grep`, `Glob`, and targeted `Read` discovery before implementation; Elixir Overwatch rejects Graphify tools so worker discovery does not create slow generated worktree artifacts. The documentation phase updates required operator/developer docs (`CLAUDE.md`, `README.md`, `docs/user-guide.md`, and this CLI Reference) when task behavior changes, or writes `DOCUMENTATION_REPORT.md` explaining why no doc update was needed.

Workflow PR/merge behavior is not driven by `create-pr`, `pr-wait`, or `merge` phases — no such phase is implemented or dispatched, and a phase declaring none of `command`/`prompt`/`bash` fails to load with `{:missing_phase_action, index}`. A run still has one Foreman branch, defaulting to `foreman/<task-id>/<run-id>` for unique branches per retry, but a phase can now declare `stack_pr: true` to create or reuse a phase PR from that run branch to the recorded run base branch after that phase's commit decision. Task-backed final AutoPRs use exact task metadata (`Task.title` as PR title, `Task.description` as PR body); ad-hoc no-task runs keep the legacy generated run/artifact PR text. Top-level `merge:` and `pr:` YAML tags remain invalid, and there is no `stacked:` or `checkpointPr` setting. A phase-level `commit:` boolean controls only whether that phase commits its work; `stack_pr:` does not force a commit. A phase may also declare `timeout_minutes: <positive integer>` (camelCase `timeoutMinutes:` also accepted) to set its execution timeout in minutes; omitting it routes the deadline through app-config `failure_policies` /
`default_timeout_ms` and then the built-in `:infinity` default (no wall-clock deadline
unless one is configured; a BEAM that still applies a fixed ceiling after #510 is a
stale runtime or unshipped override, not this code path — see `docs/lessons/phase-execution-and-pr-mechanics.md`). Created/reused phase PR records suppress final AutoPR; no-op phase PR records do not. When reusing an open phase PR, Foreman pushes the run branch before recording reuse so the provider diff cannot remain stuck on an older head. `foreman run get <id>` JSON includes `run.phase_prs` when phase records exist. See "PR creation and merge reconciliation" in the User Guide.

Run `foreman init --force` after editing bundled workflow YAML or prompts. `foreman run`, `foreman run --watch`, and direct worker startup fail fast if installed runtime prompts/workflows are stale, so scheduler-launched agents cannot run with outdated instructions.

Foreman latches the run's PR base **branch** from the registered checkout's `HEAD` when the run's first phase starts; this is not where every worktree starts (implementation runs start from the frozen `source_revision`, other runs from a declared `worktree.base`). There is no project `defaultBranch`/`--default-branch` setting (removed; a payload carrying `default_branch` is rejected with `setting_removed`). A project's `config.env` reaches workflow-phase agents; a `config.env` key starting with `FOREMAN_` is reserved and fails the phase with `reserved_project_env_keys`.

```bash
foreman run                       # Dispatch all ready tasks through the Elixir scheduler
foreman run --project my-project   # Dispatch against a registered project without cd
foreman run --dry-run              # Check Elixir server availability without ticking
foreman run --no-watch             # Tick once and exit; monitor with watch/status
```

| Option | Default | Description |
|--------|---------|-------------|
| `--max-agents <n>` | `5` | Maximum concurrent agents |
| `--model <model>` | — | Force a specific model (overrides `FOREMAN_DEFAULT_MODEL`) |
| `--dry-run` | — | Show what would be dispatched without doing it |
| `--no-watch` | — | Exit immediately after dispatching (don't monitor agents) |
| `--resume` | — | Resume stuck/rate-limited runs from a previous dispatch |
| `--resume-failed` | — | Also resume failed runs (not just stuck/rate-limited) |
| `--no-pipeline` | — | Skip the explorer/qa/reviewer pipeline — run as single worker agent |
| `--workflow <name>` | — | Run all dispatched tasks with this workflow (overrides `workflow:<name>` labels and task-type mapping) |
| `--task <id>` | — | Dispatch only this specific task by ID (must be ready) |
| `--no-auto-dispatch` | — | Disable automatic dispatch when an agent completes and capacity is available |
| `--stagger <duration>` | — | Stagger delay between dispatches to prevent thundering herd (e.g. `30s`, `1m`) |
| `--project <name>` | — | Registered project name (default: current directory) |
| `--project-path <absolute-path>` | — | Absolute project path (advanced/script usage) |
| `--runtime-mode <mode>` | — | Runtime mode: `normal`\|`test` (test uses deterministic phase-runner seams) |
| `--yes` | — | Answer yes to run confirmation prompts (for non-interactive dispatch) |

> **Deprecated:** `--skip-explore` and `--skip-review` are still parsed for backwards compatibility but have **no effect** on the pipeline (phase shape is defined entirely by the workflow YAML). They are hidden from `--help` and print a deprecation warning. Use `--workflow <custom-workflow>` with a project-local or global workflow that has the phase shape you want.

Pipeline budgets are optional environment guards. `0` disables a budget: `FOREMAN_MAX_PIPELINE_WALL_CLOCK_MS`, `FOREMAN_MAX_PIPELINE_COST_USD`, `FOREMAN_MAX_PIPELINE_TOOL_CALLS`, and `FOREMAN_MAX_PIPELINE_REVIEW_LOOPS`. When exceeded, Foreman stops the run, writes a native task failure note, and marks the run stuck for operator action.

### `foreman run task`

Operator use of `foreman run task` was removed after the Elixir cutover. The hidden `--run-id` bridge is reserved for Elixir scheduler-launched Node/Pi workers; when that bridge sees an Elixir-only task, Foreman mirrors task metadata into the worker store before execution so prompts receive title/type/priority/description metadata.

| Option | Default | Description |
|--------|---------|-------------|
This command remains registered only so operator invocations receive an explicit removal message. The internal `--run-id` bridge is hidden and reserved for Elixir scheduler launches.

### `foreman run list [--status <status>] [--project-id <id>] [--limit <n>]`

List run projections as JSON. Issues `GET /api/runs` with optional query filters forwarded to the server-side projection store. Use it before run maintenance to find failed or stuck runs.

```bash
foreman run list                                # all runs, no filter
foreman run list --limit 20                     # cap result count
foreman run list --status failed --limit 10     # filter by status
foreman run list --project-id foreman           # filter by project
```

| Option | Description |
|--------|-------------|
| `--status <status>` | Filter by run status (`in_progress`, `completed`, `failed`, `cancelled`, etc.). |
| `--project-id <id>` | Filter by registered project id. |
| `--limit <n>` | Maximum number of runs to return. Must be non-negative. |

### `foreman run remove --id <run-id>`

Remove a run and clean up its worktree/branch. Issues `POST /api/commands` with a `run.remove` envelope. The server terminates the run, releases its run slot and per-DB Beads lease, and best-effort cleans the projected worktree plus the local branch.

```bash
foreman run remove --id run-f971378012da4da2fec3ec74dbac325d
```

| Option | Description |
|--------|-------------|
| `--id <run-id>` | Run ID (required). |

### `foreman run submit --workflow <name> --prompt <text> --project-id <id> [--work-id <id>] [--backend <backend>] [--base-branch <branch>]`

> **PARTLY INCORRECT.** The flag is `--base-branch`, not `--base`, and there is
> no `--short`. Real set: `--workflow --prompt --project-id --work-id --backend
> --base-branch`. Note that `--base-branch` is accepted by the CLI but, per
> `docs/lessons/phase-execution-and-pr-mechanics.md`, is still not consumed server-side — the PR base is the branch the
> run's work was cut from.

Posts a `task.create` envelope (`provider_tracked: false`, `auto_approve:
true`) rather than a separate `work.submit` ingress — the `work.*` command
types have been retired; ad-hoc dispatch is unified onto the task path.

- `--workflow` (required) — the workflow name to execute. Validated
  server-side by `Catalog.load/1`; there is no client-side allowlist.
- `--prompt` (required) — the input prompt/text for the workflow.
- `--project-id` (required) — the project ID.
- `--work-id` (optional) — alias for the task ID. Minted client-side as
  `adhoc-<hex>` when omitted, so the server's no-id `task.create` flow
  (which resolves the ID through the task provider) is never triggered for
  an untracked task.
- `--backend` (optional) — accepted by `foreman run submit`, validated
  client-side against `pi`, `claude`, `codex`, `opencode` (default `pi`;
  `run.go` rejects anything else before the request is sent). When it is not
  the `pi` default it travels in the `task.create` payload, and **nothing
  server-side reads that key**: neither `Task`'s `handle_command/2` nor
  `CommandGateway` consumes a `backend` field, so the flag selects no adapter
  and no harness provider. What actually decides the backend is the runtime's
  configured `:jido_harness, :providers` adapter list plus each phase's
  `provider:` (`:pi` or `:claude` only, `JidoHarness.@supported_providers`) —
  `:litellm` is a model dispatcher reached through one of those providers, not
  one itself. Accepting a value here is therefore NOT evidence that a backend
  is installed, ready, or reachable: `foreman_doctor` (MCP) reports
  `jido_harness` provider readiness, and `foreman doctor` reports the same rows.
  AgentRuntime's own `:backend` opt is a separate, internal manual-strategy
  parameter with no CLI surface.
- `--base-branch <branch>` (optional, half-consumed per
  [TRD-2026-80ba0665](TRD/TRD-2026-80ba0665-branch-parent-resolution.md))
  — parent branch for the new task's worktree and PR. **The default now
  resolves server-side from the operator's checkout**: `RunExecutor` records
  `git symbolic-ref --short HEAD` of the project checkout when the run's first
  phase starts, and `AutoPR` opens the PR against that branch, replacing the
  historical `"main"` fallback. A detached checkout resolves to no branch,
  which is `{:auto_pr_base_branch_unresolved, reason}` at `error` and no PR.
  **The flag itself remains protocol-level capture only**: the CLI accepts and
  forwards it inside the `task.create` envelope, but nothing server-side
  reads it, so an explicit value cannot yet override the checkout. Use
  `gh pr edit <n> --base <branch>` to retarget a PR onto a different base.

Example:

```text
foreman run submit --workflow implement-trd --prompt "Fix the CLI submit bug" --project-id foreman
```

```bash
foreman run reset --id run-f971378012da4da2fec3ec74dbac325d
```

| Option | Description |
|--------|-------------|
| `--id <run-id>` | Run ID (required). |

### `foreman run approve-merge --id <run-id> --approver <name> --identity <github:login> [--repo-id <repo-id>]`

Opens a run's merge gate once its PR is ready (the run has signalled `run.pr.ready`). Sends the `merge_approve` operator command. The server accepts it only when `--identity` is on the approver allowlist (`ForemanServer.Workflow.ApproverAuthorizer`, currently the single identity `github:ldangelo`); any other identity is rejected with `unauthorized_approver` and the gate stays shut.

The identity is a claim made by whoever holds the API token, not an authenticated login: the token is the trust boundary. For the same reason there is deliberately no MCP tool for this command; an agent must not be able to approve its own PR.

| Option | Description |
|--------|-------------|
| `--id <run-id>` | Run ID (required). |
| `--approver <name>` | Approver name, recorded on the approval (required). |
| `--identity <github:login>` | Approver identity checked against the allowlist (required). |
| `--repo-id <repo-id>` | Repository whose PR to approve (E12 multi-repo runs). Omit for the run's primary repository. |

Each PR of a multi-repository run has its own merge gate (`merge_gates`, keyed by `repo_id`; the primary's is `nil`), so one `approve-merge` call approves exactly one PR. There is no approve-all. An unknown `--repo-id` fails with `{:merge_gate_not_found, :run, "<repo-id>"}`; for the primary the legacy `{:merge_gate_not_found, :run}` is unchanged.

### `foreman run merge --id <run-id> [--repo-id <repo-id>]`

Squash-merges the run's PR on GitHub with `gh pr merge --squash --match-head-commit <sha>`. Sends the `run.pr.merge` operator command; only the run id is sent, because the server builds the rest from the run's stored `PrReady` event and ignores any other payload field.

It refuses unless the merge gate is approved (`pr_not_acceptable`), and unless the PR head is still the commit that was approved (`head_moved_since_approval`), so commits pushed after approval are never merged unreviewed. A closed or conflicted PR fails with `pr_closed` or `pr_conflicted`, and a failing `gh` with `gh_merge_failed`. A PR that is already merged at the approved head is recorded without calling `gh` again, so retrying after a partial failure is safe; one merged at any other head is refused with `head_moved_since_approval`. The `gh` CLI must be installed and authenticated on the server host.

| Option | Description |
|--------|-------------|
| `--id <run-id>` | Run ID (required). |
| `--repo-id <repo-id>` | Repository whose PR to merge (E12). Omit for the run's primary repository. Only that repository's approval and `PrReady` (and so its own `--match-head-commit` pin) are used. |

### `foreman run retry-pr <run-id> --repo-id <repo-id>`

Re-opens the PR of one repository of a multi-repository run whose PR could not be created. Sends the `run.pr.retry` operator command; the server re-runs the PR step for that repository from its preserved worktree (association and `run.pr.ready` included) and then reclaims that worktree if the workflow's `cleanup` policy would have. Idempotent: a repository that already has its PR returns it again and opens nothing. Allowed on a finished run. Like merge, it is operator-only and has no MCP tool. `--repo-id` is always the repository's real id (the primary's included). A repository with nothing to propose fails with `nothing_to_propose`; an unknown repository with `unknown_repo`.

| Option | Description |
|--------|-------------|
| `<run-id>` / `--id <run-id>` | Run ID (required). |
| `--repo-id <repo-id>` | Repository to open the PR for (required). |

### `foreman thread list|get|stop|steer|resolve|reopen`

A thread is the operator-facing unit of work: a workflow run (`run:<id>`) or a jobsite (`jobsite:<id>`). All verbs print the server's JSON.

| Verb | Request |
|------|---------|
| `foreman thread list --project <project-id> [--status <s>] [--door workflow\|jobsite] [--limit <n>]` | `GET /api/projects/:id/threads` (`--project` is required). |
| `foreman thread get <thread-id>` | `GET /api/threads/:id`. |
| `foreman thread stop [--reason <r>] <thread-id>` | `POST /api/threads/:id/stop`: `run.cancel` for a workflow thread, the jobsite cancel for a jobsite thread. A terminal thread exits 3 (HTTP 409 `not_stoppable`, naming its status). |
| `foreman thread resolve [--reason <r>] <thread-id>` | Reads the thread's project, then sends the `thread.resolve` operator command (aggregate `thread:<thread-id>`). A disposition flag only; it never stops a run. |
| `foreman thread reopen <thread-id>` | Sends `thread.reopen`; a thread that is not resolved is rejected. |
| `foreman thread steer --message <text> [--message-id <id>] [--no-resume] <thread-id>` | `POST /api/threads/:id/steer`: queues an operator message (`run.steer` for a workflow thread, `Jobsite.steer` for a jobsite thread); the work is paused then resumed with the message in its next prompt. 202 `{thread_id, message_id, mode}`; a terminal thread exits 3 (409 `not_steerable`); blank or oversize (>8000) text is 400. `--no-resume` keeps a paused run paused (workflow door). |

Not exposed as CLI verbs (HTTP/MCP only): thread transcript, the live stream and thread lookup.

| Route | Purpose |
|-------|---------|
| `GET /api/threads/:id/transcript?after=<seq>&limit=<n>` | One cursor page of structured turns (`after` >= -1, default -1; `limit` 1..1000, default 200). Body `{turns, next_cursor, truncated, omitted_entries, terminal}`. Unknown thread 404, junk params 400. |
| `GET /api/threads/:id/stream?after=<seq>` | Server-Sent Events tail: replays turns after `after`, then `event: turn` per new turn, `: heartbeat` comments, and `event: end` once the thread is terminal and drained. |
| `GET /api/projects/:project_id/threads/find?q=&external_id=&branch=&pr=` | Deterministic lookup (`ForemanServer.Threads.Finder`, no LLM): exact `external_id`, branch and PR (URL or number) matches outrank conservative text matches (Jaccard >= 0.5 over title + first 200 chars of prompt; `suggested: true`; resolved/deleted threads are never text matches). `{candidates: [{thread_id, reason, score, title, status, branch, resolved, suggested}]}`; no criterion is 400. Read-only: it never starts a run. |

**Steering v1 (`pause_resume`).** Live mid-turn steering is not built (every thread DTO carries `"steering": "pause_resume"`). Steering pauses the work (the run executor commits partial work as it winds down), then resumes with the operator message appended to the next phase prompt. Workflow door: operator command `run.steer` appends `RunSteerQueued` (idempotent per `message_id`; `--no-resume` keeps the run paused). Once a phase prompt carrying the message is built, the system-only command `run.steer.consume` appends `RunSteerConsumed`, so a message is injected exactly once; the queue is `RunSteerQueued` minus `RunSteerConsumed` in the event log and survives restarts. `run.steer.consume` is deliberately NOT in the operator allowlist. Jobsite door: `Jobsite.steer/3`, equivalent to `POST /api/jobsites/:id/resume` with a `prompt` (see Remote Jobsite API).

**Resolve / reopen.** `thread.resolve` and `thread.reopen` append `ThreadResolved` / `ThreadReopened` on `thread:<thread-id>`. Resolved threads are excluded from text lookup. Terminal threads without a PR are idle-resolved by `IdleResolver`, configured under `config :foreman_server, :threads` (`idle_resolver`, `idle_resolve_after_days`, `sweep_interval_ms`; see the user guide).

**Overview.** There is no `foreman overview` CLI verb. `GET /api/projects/:project_id/overview[?include_resolved=true|false&resolved_limit=0..200]` (and the MCP read tool `foreman_overview`) groups threads into `ready_for_review`, `waiting_on_you`, `working`, `landing`, `idle`, `resolved` with `counts`, `attention` (`needed`, `count`, `reasons`) and `tabs` (`pull_requests` live; `library`/`scheduled` `available: false` until registered). Read-only: merging is still `merge_approve` then `run.pr.merge`, operator only.

**Transcript caveats.** The workflow transcript is built from `run_logs`, which keep a bounded tail: when entries were dropped `omitted_entries` > 0 and `truncated` is true. Jobsite turns carry no timestamps (`at: null`, ordered by iteration) and jobsite threads have no operator turns, because jobsite resume prompts are not persisted as events.


---

## Monitoring

### `foreman status`

> **NOT IMPLEMENTED.** `foreman status` is not dispatched. Nearest real: `foreman run list [--status <s>] [--project-id <id>] [--limit <n>]` and `foreman run get <id>`.

Show project status: task counts, active agents, costs (total and per-turn), tokens, elapsed time (total and per-turn), and tool usage. `--live` opens the unified cockpit directly to the status/workflow view; `--watch` remains the compact refreshing status output; `--json` remains machine-readable.

```bash
foreman status                    # Snapshot of current state
foreman status --project my-project # Status for a registered project without cd
foreman status -w                 # Live refresh every 10 seconds
foreman status -w 5               # Live refresh every 5 seconds
foreman status --live             # Unified cockpit opened to status/workflow
foreman status --json             # Machine-readable output
```

| Option | Default | Description |
|--------|---------|-------------|
| `-w, --watch [seconds]` | `10` | Compact auto-refresh interval |
| `--live` | — | Open the unified cockpit in status/workflow view |
| `--json` | — | Output as JSON |
| `--project <name-or-path>` | — | Show status for a registered project name or absolute project path |
| `--all` | — | Aggregate status across all registered projects |

The cockpit status view renders ordered phase nodes, retry arrows, current failure/error text, artifacts, last activity, and active phase summary. Use `m/e/l/r/f` to inspect messages, events, logs, reports, and files for the selected task/run.

### `foreman logs`

> **NOT IMPLEMENTED.** `foreman logs` is not dispatched. Run logs are readable through the MCP tool `foreman_run_get_logs` (see MCP Server below), which is backed by the durable worker-event log described in `docs/lessons/run-logs-known-issues.md`.

Show run logs with structured rendering. When the Elixir backend is available, worker stdout/stderr is read from durable `WorkerStdout` / `WorkerStderr` event projections and rendered as timestamped, color-coded lines with stream, type, and phase labels. Known runs with no captured output render as empty; unknown runs report not found. Falls back to raw log file parsing when the backend is unavailable.

```bash
foreman logs bd-abc1              # Show structured log entries
foreman logs bd-abc1 --tail 200    # Show more log lines
foreman logs bd-abc1 --follow      # Follow logs in real-time
foreman logs bd-abc1 --raw         # Print raw JSON log only
```

| Option | Default | Description |
|--------|---------|-------------|
| `--run <runId>` | — | Run ID (overrides positional ID) |
| `--project <name>` | — | Registered project name (default: current directory) |
| `--project-path <absolute-path>` | — | Absolute project path (advanced/script usage) |
| `--tail <lines>` | `80` | Raw log lines to show |
| `--follow` | — | Follow the raw JSON log after printing the summary |
| `--raw` | — | Print only the raw JSON log tail |

### `foreman metrics`

> **NOT IMPLEMENTED.** `foreman metrics` is not dispatched, and no CLI surface replaces it.

Show detailed task metrics including cost and time statistics. This provides a focused view of accumulated metrics separate from the full status dashboard.

```bash
foreman metrics                  # Show all metrics
```

**Displayed metrics:**
- **Total Cost** — Cumulative cost in USD across all turns
- **Total Turns** — Total number of turns executed (denominator for per-turn metrics)
- **Cost per Turn** — Average cost per turn in USD
- **Total Time** — Cumulative elapsed time (formatted as hours/minutes/seconds)
- **Time per Turn** — Average time per turn

Per-turn metrics show `—` when total turns is zero.

### `foreman watch`

> **NOT IMPLEMENTED.** `foreman watch` is not dispatched. Poll `foreman run get <id>` instead.

Canonical live operator cockpit. The TTY view fills the terminal viewport and combines active/attention task selection, inbox timeline, status/workflow flow chart, board context, detail tabs, search/filter controls, and an action palette. Palette reset requires explicit `y` confirmation and then runs `foreman reset` for the selected task; non-reset actions still print copy/manual command text. `foreman dashboard` is a deprecated alias for this command (it prints a deprecation notice). For a compact refreshing status view, use `foreman status --watch`.

```bash
foreman watch                     # Unified live cockpit
foreman watch --no-watch          # One-shot snapshot, no polling
foreman watch --refresh 5000      # Refresh every 5 seconds
```

| Option | Default | Description |
|--------|---------|-------------|
| `--refresh <ms>` | `5000` | Cockpit refresh interval; also applies to `--no-watch` setup defaults |
| `--inbox-limit <n>` | `5` | One-shot snapshot inbox message limit |
| `--inbox-poll <ms>` | `2000` | Ignored by the cockpit; retained for compatibility with prior watch loops |
| `--events-limit <n>` | `5` | One-shot snapshot pipeline event limit |
| `--no-board` | — | Only meaningful with `--no-watch`: hide board summary panel |
| `--no-inbox` | — | Only meaningful with `--no-watch`: hide inbox panel |
| `--no-events` | — | Only meaningful with `--no-watch`: hide pipeline events panel |
| `--no-watch` | — | Print one deterministic snapshot and exit |
| `--project <id>` | — | Filter to a specific project |

Cockpit keys: `j/k` select, `i` inbox, `s` status/workflow, `b` board, `n` create task (TTY form with type/priority dropdowns), `m/e/l/r/f` detail tabs, `/` search, `1/2/3` active/attention/all scopes, `!` failed, `p` has PR, `d` dirty worktree, `a`/`:` action palette, `q`/`Esc` quit. Palette reset asks for `y` confirmation and executes `foreman reset` for the selected task; the Go cockpit `R` key resets the selected run or a selected task card's latest known run. All other entries print copy/manual command text only.

### `foreman monitor`

> **NOT IMPLEMENTED.** `foreman monitor` is not dispatched. Poll `foreman run get <id>` instead.

Alias for the canonical `foreman watch` command, with the same options and behavior.

```bash
foreman monitor                     # Unified live cockpit (same as foreman watch)
foreman monitor --no-watch          # One-shot snapshot, no polling
foreman monitor --refresh 5000      # Refresh every 5 seconds
```

### `foreman sentinel`

> **NOT IMPLEMENTED.** `foreman sentinel` is not dispatched, and no CLI surface replaces it.

Continuous QA testing agent that monitors a branch for test failures and auto-creates follow-up fix tasks.

```bash
# Run once
foreman sentinel run-once
foreman sentinel run-once --branch dev --test-command "npm test"
foreman sentinel run-once --dry-run

# Start background daemon
foreman sentinel start
foreman sentinel start --interval 15 --failure-threshold 3

# Check sentinel status
foreman sentinel status
foreman sentinel status --json --limit 20

# Stop background daemon
foreman sentinel stop
foreman sentinel stop --force
```

**`sentinel run-once` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--branch <branch>` | `main` | Branch to test |
| `--test-command <cmd>` | `npm test` | Test command to run |
| `--failure-threshold <n>` | `2` | Consecutive failures before filing a bug task |
| `--dry-run` | — | Simulate without running tests or creating tasks |

**`sentinel start` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--branch <branch>` | `main` | Branch to monitor |
| `--interval <minutes>` | `30` | Check interval |
| `--test-command <cmd>` | `npm test` | Test command |
| `--failure-threshold <n>` | `2` | Consecutive failures before bug |
| `--dry-run` | — | Simulate |

Sentinel persists each run in `sentinel_runs` and records `sentinel-start`, `sentinel-pass`, and `sentinel-fail` events for audit/watch surfaces.

**`sentinel status` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--limit <n>` | `10` | Recent runs to show |
| `--json` | — | Output as JSON |

**`sentinel stop` options:**

| Option | Description |
|--------|-------------|
| `--force` | Force kill with SIGKILL |

---

## Interactive Board

### `foreman board`

> **NOT IMPLEMENTED.** `foreman board` is not dispatched. `foreman run list` is the only run overview.

On a TTY, open the unified cockpit in board view. The board pane groups rows by task-status lifecycle columns, keeps workflow phase and run/PR state as separate card metadata, and lets operators jump to inbox/status details without starting a second terminal loop. Terminal events update task status first, so a merged PR appears in `done` because the task is marked `merged`. Non-TTY output, `--all`, and `--filter` keep the legacy/scriptable board path.

```bash
foreman board                     # TTY: unified cockpit opened to board view
foreman board --project my-project
foreman board --limit 10
foreman board --filter ready      # Legacy/scriptable filtered board path
```

| Option | Description |
|--------|-------------|
| `--project <name>` | Registered project name |
| `--project-path <absolute-path>` | Absolute project path for scripts/advanced usage |
| `--all` | Render legacy/scriptable boards for all registered projects |
| `--limit <n>` | Maximum tasks per column / cockpit fetch limit |
| `--filter <status>` | Use the legacy/scriptable filtered board path |

## Debugging & Recovery

### `foreman debug`

> **NOT IMPLEMENTED.** `foreman debug` is not dispatched, and no CLI surface replaces it.

AI-powered execution analysis. Gathers all artifacts (logs, mail, reports, run progress, and debug timeline payload/file-change fields) for a task and sends them to an AI model for deep-dive diagnostics.

```bash
foreman debug bd-abc1             # Full AI analysis with Opus
foreman debug bd-abc1 --raw       # Dump all artifacts without AI
foreman debug bd-abc1 --model anthropic/claude-sonnet-4-6  # Cheaper model
foreman debug bd-abc1 --run 14dd  # Analyze a specific run (not latest)
```

| Option | Default | Description |
|--------|---------|-------------|
| `--run <id>` | latest | Specific run ID to analyze |
| `--model <model>` | `anthropic/claude-opus-4-6` | Model for analysis |
| `--raw` | — | Print collected artifacts without AI analysis |

**Artifacts collected:**
- Run summary (status, cost, turns, tool breakdown)
- All Agent Mail messages (chronological)
- Pipeline reports (EXPLORER_REPORT.md, QA_REPORT.md, REVIEW.md, PR_WAIT_REPORT.md with CodeRabbit finding details, etc.)
- Agent worker logs (`~/.foreman/logs/<runId>.log`)
- Task info from `native task store show`

### `foreman recover`

> **NOT IMPLEMENTED.** `foreman recover` is not dispatched, and no CLI surface replaces it.

Autonomous recovery agent for pipeline failures.

```bash
foreman recover bd-abc1 --reason test-failed   # Recover from test failure
foreman recover bd-abc1 --raw                   # Show collected context without AI
foreman recover bd-abc1 --execute-clean-replay  # Full clean replay flow
```

| Option | Default | Description |
|--------|---------|-------------|
| `--reason <reason>` | — | Failure reason: `test-failed` \| `stuck` \| `stale-blocked` \| `finalize-conflict` |
| `--run-id <id>` | latest | Specific run ID |
| `--output <text>` | — | Pre-captured test output to include in context |
| `--model <model>` | — | Model to use for recovery |
| `--raw` | — | Print collected context without invoking AI |
| `--prepare-clean-replay` | — | Create a fresh clean-replay workspace |
| `--apply-clean-replay` | — | Copy intended changed files into clean replay workspace |
| `--validate-clean-replay` | — | Run typecheck and build in clean replay workspace |
| `--commit-clean-replay` | — | Stage and commit the clean replay workspace |
| `--push-clean-replay` | — | Push the validated clean replay branch |
| `--execute-clean-replay` | — | Run full clean replay: apply, validate, commit, and push |

### `foreman doctor`

Reports the health checks the server really performs, via `GET /api/doctor`: server reachable, read model (event store projection) reachable, one row per `jido_harness` provider (the same data as the `foreman_doctor` MCP tool), workflow catalog installed, and, with `--project`, a summary of that project's setup recommendations (see `foreman project recommend`).

```bash
foreman doctor                       # Run the checks
foreman doctor --project my-project  # Also summarise setup recommendations
foreman doctor --strict              # Exit 1 on warnings as well
foreman doctor --format json         # Machine-readable output
```

| Option | Description |
|--------|-------------|
| `--project <id>` | Add the project setup-recommendation summary check (404 for an unknown project) |
| `--strict` | Treat `warn` checks as failures |
| `--format json` | Output the server's `{checks: [{id, status, title, detail}]}` body |

Exit code: `0` when no check has status `fail` (and, with `--strict`, none `warn`); `1` otherwise or on a usage error.

**NOT IMPLEMENTED:** `--fix` and `--dry-run` (passing them is a usage error), and the Pi SDK, DB integrity, bundled-skill, prompt/workflow-staleness, duplicate `task_type`, zombie-run, stale-run and stale-worktree checks. Use `foreman init --force` to refresh installed prompts and workflows.

### `foreman server`

> **NOT IMPLEMENTED.** `foreman server` is not dispatched. The Phoenix server is started with `mix phx.server` from `packages/foreman_server/` (`docs/lessons/operator-reference.md`). See also the projection-table correction above.

Manage the experimental Elixir orchestration server used by TRD-2026-014.

```bash
foreman server start              # Start local Elixir server
foreman server status             # Show PID/URL and health
foreman server doctor             # Auto-start then run server doctor checks
foreman server doctor --no-auto-start  # Doctor check only
foreman server stop               # Stop server started by Foreman
```

| Option | Description |
|--------|-------------|
| `--port <port>` | Override local HTTP port (default `4766`; `14766` for `MIX_ENV=test`) |
| `--no-auto-start` | For `doctor`, fail instead of starting a stopped server |

`server status` shows the active `MIX_ENV`, event store, projection store, and project config store. In Postgres event-store mode, read projections persist in `foreman_project_projections`, `foreman_task_projections`, `foreman_run_projections`, and `foreman_inbox_message_projections`; in term mode projections remain in memory and rebuild from the term log. `MIX_ENV=test` refuses user port `4766` and non-temp storage unless `FOREMAN_ALLOW_TEST_PORT_COLLISION=1` / `FOREMAN_ALLOW_TEST_PERSISTENT_STORAGE=1` are set intentionally. `server doctor` validates event-store readability, projection catch-up/lag, worker projections, VCS adapters, provider adapters, and integration projections. The JSON output includes counters/timers for phase duration, retries, failures, recoveries, worker restarts, and projection lag. When server auth is enabled, set `FOREMAN_SERVER_AUTH_TOKEN` so doctor/metrics calls send the bearer token. Binding the Elixir HTTP server beyond loopback also requires this token. Worker starts strip forbidden host variables (`FOREMAN_SERVER_AUTH_TOKEN`, `AWS_*`, `GITHUB_*`, `NPM_*`, `SSH_*`, `DATABASE_*`) and scope explicit project/run secrets to the run. Destructive server commands record `AuthorizationChecked` and `AuditRecorded` events.

> **Correction.** No `*_projections` tables exist. The repository has exactly two
> migrations — `create_jido_storage_tables` and `create_idempotency_keys_table`
> — and none of `foreman_project_projections`, `foreman_task_projections`,
> `foreman_run_projections` or `foreman_inbox_message_projections` appears in any
> source file. `foreman server` is not a command either (see the note under
> Agent Mail and `foreman-x4ca`). Left in place as intended design; the
> `foreman_inbox_message_projections` name in particular is the read side of the
> deleted `InboxThread` aggregate and was never built.

Elixir backend roles: the **Node CLI** parses commands/renders projections, the **Elixir server** owns aggregate-validated commands/events/projections/recovery/security/overwatch and all database access, automatically ticks the scheduler every 5 seconds to claim `ready` tasks within capacity and launch the Node/Pi worker bridge, and **Node/Pi workers** execute Pi SDK phases, stream worker events, emit authoritative terminal run/task events, stream Pi SDK tool calls/assistant messages as ordered worker events, expose typed Foreman tools (`mail_send`, `mail_read`, `phase_handoff`, `artifact_write`, `validation_result`, `task_block`, `progress_update`, `ask_operator`, `abort_phase`, `needs_retry`, `safe_command_run`), and ask Elixir overwatch to approve/deny tool calls before execution. Node workers and CLI clients do not connect directly to the database; they use Elixir HTTP commands/projections and do not drain DB-backed merge queues from inside the worker. Raw log files are compatibility/debug projections of the worker event stream. The launcher records process-exit facts and emits a diagnostic fallback failure only when a worker exits without an authoritative terminal event; that fallback may parse the final worker output to avoid stale phase attribution, but authoritative worker terminal events remain preferred. If an Elixir-backed view is wrong, inspect the event timeline first, then projection lag/rebuild state, then recovery events (`ExternalWorkerObserved` before `WorkerReattached`, `WorkerRestarted`, or `NeedsOperator`). After cutover, Elixir is the backend; `foreman daemon start|restart` fails fast and directs operators to `foreman server start`. See [Elixir Backend Architecture](./guides/elixir-backend-architecture.md).

The Elixir server can follow a run's PR on GitHub in two opt-in ways; each appends a `PrUpdated` event to the run's stream, and neither changes task status or adds merge metadata to `foreman run get` (`foreman run prs` shows the richer PR watch record). A PR monitor (`FOREMAN_PR_MONITOR_ENABLED=true`; off by default) reads the PR of every run with a recorded association using `gh pr view`, so the `gh` CLI must be installed and authenticated on the server host; an unchanged PR adds nothing on later polls. `POST /webhooks/github` is the real-time path for `pull_request` events: every delivery must carry a valid `X-Hub-Signature-256` HMAC-SHA256 of the raw body, keyed by `FOREMAN_GITHUB_WEBHOOK_SECRET`. It fails closed: with no secret configured every delivery gets `503`, and a missing, malformed or wrong signature gets `401`. Deliveries are attributed to runs by PR URL; a PR no run owns is accepted and ignored. There is no `foreman server doctor` check for the secret (`server` is not a routed command).


### `foreman run prs <run-id>`

Lists the pull requests a run is watching (`GET /api/runs/<id>/prs`): PR URL, status, checks state and failing checks, review decision, comment count, whether watching is on, fix attempt counters per kind (`ci`, `comments`, `conflicts`) with any fix in flight, and the merge gate. The same record is returned by the MCP read tool `foreman_pr_status`. An unknown run is `404`.

### `foreman run fix-ci|address-comments|resolve-conflicts <run-id> [--pr <url>] [--note <text>]`

Operator commands `run.pr.fix_ci`, `run.pr.address_comments`, `run.pr.resolve_conflicts`. Each starts one fix thread (a jobsite that checks out the PR head branch, fast-forwards it to the remote, never force-pushes, and pushes the fix to that branch). `--pr` selects the PR when the run has several; `--note` (at most 2000 characters) is operator guidance. Refused with a typed error when a fix of that kind is already in flight for the PR, when the per-PR/per-kind cap of 5 attempts is used up, or when the PR is closed/merged. These commands never merge. The MCP write tool `foreman_pr_fix` is the same operation with trigger `coordinator`.

### `foreman run create-pr <run-id>` / `foreman run watch-stop|watch-start <run-id> [--pr <url>]`

`create-pr` (`run.pr.create`) opens the PR for a run that has none. `watch-stop` / `watch-start` (`run.pr.watch_stop`, `run.pr.watch_start`; MCP `foreman_pr_watch_stop`) pause or resume PR watching. None of them merge or approve: use `approve-merge` and `merge`.

**Project policy.** `foreman project update <id> --pr-auto-fix '<json>'` sets `pr_auto_fix` (`kinds` from `ci|comments|conflicts`, `max_attempts` 1..5, `cooldown_seconds` 0..86400); `--clear pr_auto_fix` turns automatic fixing off. Server settings: `FOREMAN_PR_WATCHER_ENABLED`, `FOREMAN_PR_MONITOR_ENABLED` (polling, off by default), `FOREMAN_GITHUB_WEBHOOK_SECRET`. Live webhooks, force-push handling, check re-run, conflict resolution and unresolved-thread reads are UNVERIFIED against real GitHub (spike S4).

### `foreman reset`

> **NOT IMPLEMENTED.** `foreman reset` is not dispatched. The real command is `foreman run reset --id <run-id>`, which clears a failed or stuck run projection — it does not stop workers, close PRs, or delete branches as described here.

Reset Elixir-backed task work. The command stops active worker processes when present, removes stale task worktrees unless `--keep-worktree` is set, closes any open/draft PR recorded for the task before deleting its remote branch, deletes local/origin `foreman/<task>` branches, removes prior run logs/reports, clears run linkage and failure fields, sets the task back to `ready`, and requests scheduler dispatch. If GitHub reports the recorded PR was already merged, reset leaves that PR unchanged, preserves prior run artifacts for auditability, continues branch/worktree cleanup, marks any still-active run completed, marks the task closed, and skips scheduler dispatch to avoid redundant reruns. Closed/completed tasks can be reopened this way; merged tasks remain terminal.

```bash
foreman reset foreman-abc12
foreman reset foreman-abc12 --reason "stale worker"
foreman reset foreman-abc12 --dry-run
foreman reset foreman-abc12 --keep-worktree
```

| Option | Description |
|--------|-------------|
| `--reason <text>` | Reason recorded in run history |
| `--dry-run` | Preview worker/worktree/branch/log cleanup, open/draft PR closure, active-run terminalization, and reset/dispatch steps |
| `--keep-worktree` | Do not remove the task worktree |
| `--project <name-or-path>` | Target a registered project name or absolute project path |

### `foreman retry`

> **NOT IMPLEMENTED.** `foreman retry` is not dispatched, and neither is `foreman task retry` any more — TRD-018 (2026-09-13) removed it too (see the note at the top of this file). The internal `task.retry` command it used to invoke is unchanged, but there is no CLI verb left to call it; there is no `--dispatch`, `--model`, or positional-id form either way.

Reset a task and optionally re-dispatch it immediately.

> The example block and option table below are historical — a record of the
> command as originally designed, per this file's annotation convention —
> not a currently-runnable command. None of `bd-abc1` as a positional id,
> nor `--dispatch`/`--model`/`--dry-run`/`--project`, exist on any CLI verb
> today.

```bash
foreman retry bd-abc1             # Reset task to ready
foreman retry bd-abc1 --project my-project  # Retry inside a registered project without cd
foreman retry bd-abc1 --dispatch  # Reset and dispatch immediately
foreman retry bd-abc1 --model anthropic/claude-opus-4-6  # Override model
foreman retry bd-abc1 --dry-run   # Preview
```

| Option | Description |
|--------|-------------|
| `--dispatch` | Dispatch immediately after reset |
| `--model <model>` | Override the agent model |
| `--dry-run` | Show what would happen |
| `--project <name-or-path>` | Target a registered project name or absolute project path |

### `foreman abandon`

> **NOT IMPLEMENTED.** `foreman abandon` is not dispatched. Nearest real: `foreman run remove --id <run-id>`, which removes a run and cleans its worktree/branch.

Abandon obsolete Foreman work that should not land.

```bash
foreman abandon <task-or-run-id> --reason "too stale to land"
foreman abandon <task-or-run-id> --dry-run
foreman abandon <task-or-run-id> --delete-branch --force
foreman abandon --missing-branches --dry-run
foreman abandon --missing-branches --reason "branch missing"
```

Abandon removes matching merge-queue entries, archives/removes the run worktree, marks the task `blocked` unless `--keep-task` is used, and marks the run failed with an audit event. Branch deletion is opt-in via `--delete-branch`; use `--force` for unmerged branches. Use `--missing-branches` to bulk-abandon completed runs whose `foreman/<task>` branch is missing locally, which clears stale rows that otherwise make `foreman merge` warn repeatedly.

### `foreman clean-state`

> **NOT IMPLEMENTED.** `foreman clean-state` is not dispatched. This stub is also duplicated below at the fuller section of the same name.

Reset Foreman to a clean operator state by intentionally dropping stale/obsolete Foreman work.

### `foreman run kill-switch`

> **NOT IMPLEMENTED.** `foreman run kill-switch` is not a `run` subcommand. `runRun` dispatches exactly `list`, `get`, `cancel`, `pause`, `resume`, `remove`, `reset`, `submit`. Nearest real: `foreman run cancel --id <run-id> --reason <text>` (now also kills the dispatched agent's OS-level process via `RunControl.cancel_agent/1`, not just the run projection) or, to stop and later continue the same run, `foreman run pause --id <run-id>` followed by `foreman run resume --id <run-id>` (resume re-runs the interrupted phase from its last committed partial work).

Kill a stuck active run and route to a recovery phase without losing artifacts. This is the first-class operator kill-switch for stuck phases — it stops the active worker, marks the current phase as failed with `retryWith` routing, and preserves the worktree, PR, and reports by default.

```bash
foreman run kill-switch <run-id>                              # safe-by-default: preserve worktree, PR, reports
foreman run kill-switch <run-id> --route-to qa                # route to qa instead of developer
foreman run kill-switch <run-id> --reason "blocking CodeRabbit review"
foreman run kill-switch <run-id> --dry-run
foreman run kill-switch <run-id> --reset                       # also reset task to backlog
foreman run kill-switch <run-id> --force                       # confirm worktree deletion
foreman run kill-switch <run-id> --close-pr                    # close the GitHub PR
foreman run kill-switch <run-id> --discard-reports             # delete ~/.foreman/reports/<run-id>/
```

**Typical workflow (pr-wait blocking review):**

1. Observe a run stuck in `pr-wait` with a terminal-negative CodeRabbit review.
2. Kill the stuck phase: `foreman run kill-switch <run-id> --route-to cr-developer --reason "terminal CodeRabbit CHANGES_REQUESTED"`.
3. The run is marked failed with `retryWith → cr-developer`; worktree and PR are preserved.

**Safe-by-default behavior (no destructive flags needed):**

| Action | Default | Flag to change |
|--------|---------|---------------|
| Mark phase failed with `retryWith` → target | **ON** | `--route-to <phase>` |
| Stop the worker process | **ON** | — |
| Preserve worktree (`~/.foreman/worktrees/...`) | **ON** | `--force` to delete |
| Preserve PR (no close, no comment) | **ON** | `--close-pr` to close |
| Preserve reports (`~/.foreman/reports/<run-id>/`) | **ON** | `--discard-reports` to delete |
| Reset task to backlog | OFF | `--reset` |
| Delete worktree | OFF | `--force` + confirmation |
| Close the PR | OFF | `--close-pr` |
| Discard reports | OFF | `--discard-reports` |

| Option | Description |
|--------|-------------|
| `<run-id>` | Run ID to kill |
| `--route-to <phase>` | Target workflow phase for `retryWith` routing (default: `developer`); unknown phases are rejected and `retryOnly` targets are activated explicitly |
| `--reason <text>` | Reason recorded in kill-switch event and run history |
| `--reset` | Also reset the task to backlog (opt-in; default preserves task status) |
| `--force` | Confirm worktree deletion intent |
| `--close-pr` | Close the GitHub PR (handled by Elixir backend) |
| `--discard-reports` | Delete the reports directory for this run |
| `--dry-run` | Preview what would happen without making changes |
| `--project <name>` | Registered project name (default: current directory) |
| `--project-path <absolute-path>` | Absolute project path (advanced/script usage) |

### `foreman clean-state`

> **NOT IMPLEMENTED.** `foreman clean-state` is not dispatched, and no CLI surface replaces it. Duplicate of the stub above.

```bash
foreman clean-state --dry-run
foreman clean-state --force
foreman clean-state --force --delete-branches
foreman clean-state --force --delete-branches --delete-origin-branches
```

`clean-state` removes stale/conflict merge-queue entries, marks non-active related runs abandoned (`failed` with `merge_strategy: none`), removes non-active Foreman worktrees, and marks related tasks blocked unless `--keep-tasks` is used. It never mutates active pending/running runs. Mutating cleanup requires `--force`; without `--force` it previews only. Origin branch deletion is never implicit; opt in with `--delete-origin-branches`.

### `foreman stop`
Removed after Elixir cutover. Use Elixir-backed run/recovery controls instead.

### `foreman merge`

> **NOT IMPLEMENTED.** `foreman merge` is not dispatched. PR creation is automatic and server-side (`Workflow.AutoPR.maybe_create_pr/1`, called from `RunExecutor.finalize_run/1`); there is no operator merge verb.

Merge completed agent work into the target branch via the refinery. Merge-capable workflows enqueue work from an explicit `merge` phase; workflows without that phase are not merge-queued by workflow execution. For PR-gated workflows, merge rechecks PR readiness and waits if GitHub surfaces a late pending check after `pr-wait`. The Elixir server also reconciles recorded GitHub PRs after creation, so a PR merged outside `foreman merge` is observed and the associated Foreman task becomes `merged`.

```bash
foreman merge                     # Process merge queue
foreman merge --task bd-abc1      # Merge a specific task by ID
foreman merge --list              # List tasks ready to merge
foreman merge --dry-run           # Preview merge operations
foreman merge --target-branch dev # Merge into dev instead of main
foreman merge --no-tests          # Skip test validation
foreman merge --stats             # Show merge cost statistics
foreman merge --stats weekly      # Weekly cost breakdown
```

| Option | Default | Description |
|--------|---------|-------------|
| `--target-branch <branch>` | auto-detected | Branch to merge into |
| `--no-tests` | — | Skip running tests during merge |
| `--test-command <cmd>` | `npm test` | Test command to run |
| `--task <id>` | — | Merge a single task by ID |
| `--list` | — | List tasks ready to merge |
| `--dry-run` | — | Preview merge operations |
| `--resolve <runId>` | — | Resolve a merge conflict |
| `--strategy <strategy>` | — | Conflict resolution: `theirs` or `abort` |
| `--auto-retry` | — | Auto-retry with exponential backoff |
| `--stats [period]` | — | Show merge cost stats (`daily`, `weekly`, `monthly`, `all`) |
| `--json` | — | Output as JSON |

### `foreman pr`

> **NOT IMPLEMENTED.** `foreman pr` is not dispatched. See the AutoPR note under `foreman merge`.

Create GitHub pull requests for completed work.

```bash
foreman pr                        # Create PRs for all completed tasks
foreman pr --draft                # Create as draft PRs
foreman pr --base-branch dev      # PR against dev instead of main
```

| Option | Default | Description |
|--------|---------|-------------|
| `--base-branch <branch>` | `main` | Base branch for PRs |
| `--draft` | — | Create draft PRs |

---

## GitHub Issues Integration

### `foreman issue`

> **NOT IMPLEMENTED.** `foreman issue` is not dispatched, and no CLI surface replaces it.

GitHub Issues integration commands for viewing, listing, importing, and syncing issues.

```bash
foreman issue list                # List GitHub issues
foreman issue view bd-123        # View a specific issue
foreman issue import bd-123       # Import an issue as a Foreman task
foreman issue labels              # List repository labels
foreman issue milestones          # List repository milestones
foreman issue configure           # Configure GitHub sync
foreman issue status              # Show sync status
foreman issue link bd-123 --pr 456  # Link PR to issue
```

**`issue view` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `<issue>` | — | Issue number or URL |
| `--project <name>` | current directory | Registered project name |
| `--json` | — | Output as JSON |

**`issue list` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--state <state>` | open | Issue state: open, closed, all |
| `--labels <labels>` | — | Filter by labels (comma-separated) |
| `--milestone <milestone>` | — | Filter by milestone |
| `--limit <n>` | 50 | Maximum issues to show |
| `--json` | — | Output as JSON |

**`issue configure` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--auto-import` | — | Automatically import new issues |
| `--sync-labels` | — | Sync labels from GitHub |

**`issue import` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `<issue>` | — | Issue number, URL, or path to local repo |
| `--project <name>` | current directory | Registered project name |
| `--type <type>` | — | Task type: task, bug, feature |
| `--priority <priority>` | — | Task priority: critical, high, medium, low |
| `--dry-run` | — | Preview without creating task |
| `--json` | — | Output as JSON |

**`issue labels` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--json` | — | Output as JSON |

**`issue milestones` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--state <state>` | active | Milestone state: open, closed, all |
| `--json` | — | Output as JSON |

**`issue webhook` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--enable` | — | Enable webhook |
| `--disable` | — | Disable webhook |
| `--url <url>` | — | Webhook URL |
| `--events <events>` | — | Webhook events (comma-separated) |
| `--json` | — | Output as JSON |

**`issue status` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `--project <name>` | current directory | Registered project name |
| `--json` | — | Output as JSON |

**`issue link` options:**

| Option | Default | Description |
|--------|---------|-------------|
| `<issue>` | — | Issue number or URL |
| `--pr <number>` | — | PR number to link |
| `--unlink` | — | Unlink instead of linking |
| `--project <name>` | current directory | Registered project name |
| `--json` | — | Output as JSON |

---

## MCP Server

There is **no `foreman mcp` subcommand**. The Go CLI does not implement one.
The MCP server is part of the Elixir application and is reached one of two
ways.

### HTTP transport (recommended)

The MCP server runs as a supervised child of `ForemanServer.Application`
(`ForemanServer.MCP`) and is mounted by `ForemanServerWeb.MCPRouter` on the
existing Phoenix endpoint. When the server is running, MCP is already
available — nothing extra to start:

```
http://127.0.0.1:4766/mcp
```

It is gated on config, enabled by default in `dev`:

```elixir
config :foreman_server, :mcp,
  enabled: true,
  mount: "/mcp",
  allow_workflow_writes: false,
  allow_insecure_local: true
```

| Key | Default (dev) | Description |
|--------|--------|-------------|
| `enabled` | `true` | Start the MCP server child |
| `mount` | `/mcp` | Path on the Phoenix endpoint |
| `allow_workflow_writes` | `false` | Advertise and permit write tools |
| `allow_insecure_local` | `true` | Accept requests with no bearer token |

With `allow_insecure_local: false`, requests must send
`Authorization: Bearer <token>` matching `:foreman_server, :api_bearer_token`.

Client config for a Streamable HTTP MCP client (Oh My Pi shown; see
`docs/mcp-config.md` upstream for the schema):

```json
{
  "mcpServers": {
    "foreman": { "type": "http", "url": "http://127.0.0.1:4766/mcp" }
  }
}
```

### stdio transport

For MCP clients that spawn the server as a child process:

```bash
cd packages/foreman_server && mix foreman.mcp.stdio
```

stdout carries JSON-RPC frames only; diagnostics go to stderr. The token is
read from the `initialize` request's `_meta.authorization` field
(`"Bearer <token>"`).

This starts a second copy of the application, so prefer the HTTP transport
when a Foreman server is already running.

### Tools

Read tools are always advertised: `foreman_doctor`, `foreman_queue_status`,
`foreman_project_list`, `foreman_project_get`, `foreman_workflow_list`,
`foreman_workflow_get`, `foreman_workflow_validate`, `foreman_prompt_get`,
`foreman_run_get`, `foreman_run_status`,
`foreman_run_get_logs`, `foreman_run_get_events`, `foreman_run_get_activity`,
`foreman_inbox_get`, `foreman_task_list`, `foreman_task_get`, `foreman_project_settings_get`, `foreman_project_repo_list` (repositories, primary first), `foreman_project_recommendations`, `foreman_project_environment_get` (variable/secret names only),
`foreman_usage_get` (same payload as `GET /api/projects/<id>/usage`; arguments `project_id`, `from`, `to`, `group_by`, `limit`; `cost_usd: null` means unknown, `cost_unknown_events` counts unpriced events),
`foreman_thread_list` (`project_id`, optional `status`, `door`, `limit`),
`foreman_thread_get` (`thread_id`), `foreman_thread_transcript` (`thread_id`,
optional `after`, `limit`), `foreman_thread_find` (`project_id`, optional `q`,
`external_id`, `branch`, `pr`, `limit`; at least one criterion).

Write-gated thread tools (`allow_workflow_writes: true`): `foreman_thread_stop`
(`thread_id`, optional `reason`) and `foreman_thread_steer` (`thread_id`,
`text`, optional `message_id`, `resume`).

`foreman_run_get_events` reads the `run:<run_id>` stream only. Worker liveness
and stdout/stderr events are appended to `worker:<run_id>:<worker_id>` streams
instead, so use `foreman_run_get_activity` for per-worker heartbeat counts,
last sequence, and last-heartbeat timestamps. `foreman_run_get_logs` reads the
bounded worker log projection: known runs with no captured output return an
empty success and unknown runs return `NOT_FOUND`, so "this run wrote nothing"
is never confused with "no such run". The default response is the latest 500
entries; the in-memory projection retains up to 5,000 entries or 1 MiB per run,
whichever binds first, and reports any eviction as `truncated: true` with
non-zero `omitted_entries` / `omitted_bytes` — a truncated read can never look
complete. There is no store-unavailable error: the projection is server state,
so for a known run the read always succeeds.

Write-gated multi-repository tools (`allow_workflow_writes: true`; system commands,
not operator routes): `foreman_run_request_repo` (`run_id`, `repo_id` or `repo_path`;
allowlist + cap + audit; effective next phase) and `foreman_task_fanout`
(`project_id`, `title`, `prompt`, `workflow`, `repo_ids` or `"all"`, optional
`fanout_id`). `foreman_task_create` also takes optional `repo_id` and `repo_ids`.

`foreman_inbox_get` reads the per-run operator inbox projection. Inbox progress,
logs, events, and activity are complementary: inbox messages are concise
agent-authored progress notes, logs are raw stdout/stderr, events are durable
system facts, and activity is heartbeat/liveness data.

`foreman_run_status` returns a bounded projection DTO with `run_id`, `status`,
`terminal`, `project_id`, `task_id`, `workflow_name`, `current_phase`,
`started_at_ms`, `last_event_at_ms`, `failure_reason`, `provider_session_id`
(latest provider-reported session id, or `null`), and `provider_sessions` (ordered
list of `{worker_id, provider, model, provider_session_id}`, empty when none); it
does not scrape logs or raw events. It also carries `usage`
(`input_tokens`, `output_tokens`, `cache_read_tokens`, `cache_write_tokens`,
`total_tokens`, `cost_usd`; every value `null` when the provider did not report it, and
`usage` itself `null` for runs that predate usage capture); `cost_usd` is provider-reported
only. `foreman_run_get` returns the same fields in its full projection.

`foreman_task_list` accepts optional `project_id`, canonical `status` (`open`,
`ready`, `in_progress`, `blocked`, `closed`, `failed`), `limit` (default 100,
max 500), and `offset` (default 0), and returns `{tasks, total, limit, offset,
next_offset}` in task-id ascending order. `foreman_task_get` returns one full task
projection or `NOT_FOUND`.

Write tools (`foreman_task_create`, `foreman_task_update`,
`foreman_task_add_comment`, `foreman_run_cancel`, `foreman_run_pause`,
`foreman_run_resume`, `foreman_inbox_send`, `foreman_workflow_put`,
`foreman_workflow_delete`, `foreman_prompt_put`, `foreman_project_settings_update`,
`foreman_project_pause`, `foreman_project_resume`) are unadvertised and refused
unless `allow_workflow_writes: true`.

`foreman_project_settings_get` returns the same typed payload as
`GET /api/projects/<id>/settings` (`project_id`, `status`, `settings`, `limits`;
no env values). Project reads over HTTP and MCP replace `config.env` /
`config.environment` values with `"[redacted]"` (keys, `name`, `task_provider` and
`database_path` stay visible). The write tools `foreman_project_settings_update`
(arguments: `project_id`, `goal`, `instructions`, `thread_model`, `thread_effort`,
`coordinator_provider`, `coordinator_model`, `coordinator_effort`,
`max_concurrent_runs`, `daily_thread_cap`, `coordinator_propose_before_start`,
`coordinator_max_active_threads`, `coordinator_reuse_threads`, `library_collect_produced`, `notification_preference`, `clear`, `idempotency_key`; nothing
else), `foreman_project_pause` and `foreman_project_resume` dispatch the same
operator commands as the CLI, are refused unless `allow_workflow_writes: true`, and
report the server's error code (`instructions_too_long`, `project_paused`, ...).
Retries of `foreman_project_settings_update` with the same arguments and
`idempotency_key` are one command. No MCP tool can merge or approve.
`foreman_task_create` requires `description` for `FOREMAN_TASK_DESCRIPTION`, passes
`prompt` separately for `:prompt`-action phases, and defaults `auto_approve: true`.
`foreman_task_update` requires `task_id` and at least one of `title`,
`description`, `priority`, or `status`; unsupported fields are dropped at the
handler boundary and no-op updates return `INVALID_PARAMS` before dispatch.
`foreman_inbox_send` dispatches the public `inbox.send` command to append a run
progress note: required `run_id` and 1-2,000 character `body`, optional
`message_id`/`command_id`, and JSON-safe metadata keys `phase_id`, `worker_id`,
`session_id`, `severity`. It returns `{run_id, message_id, status: "sent"}`;
unknown runs return `NOT_FOUND`, duplicate message IDs return `ALREADY_EXISTS`,
and policy denial returns `POLICY_REFUSED`. Bundled prompts tell agents to post
phase start, material milestone, blocker, and phase completion notes when the
tool is available, but never secrets, prompts, large logs, or command output,
and never block work if the tool is denied/unavailable/fails.
`foreman_task_add_comment` appends a structured provider Work Log comment for a
run-bound task: required `run_id`, `workflow_name`, `phase_name`, and
`description` (1-2,000 chars). Foreman resolves the task/provider target and
rejects caller-supplied provider ids or raw bodies. Agents use it on the same
phase start/milestone/blocker/completion cadence, and failure is non-blocking.
Built-in `prd` and `fix` command phases receive this as a worker `system_prompt`
sidecar, leaving slash-command prompt text unchanged. After editing bundled
prompts/workflows, run `npm run build` where applicable and
`foreman init --force` to reinstall runtime copies.

Both transports share `ForemanServer.MCP.Dispatch`, so their tool sets and
behavior cannot diverge.

---

## Agent Mail

> **GO CLI NOT IMPLEMENTED.** Neither `foreman inbox` nor `foreman inbox send` exists in the Go CLI.
> MCP does expose `foreman_inbox_get` and the write-gated `foreman_inbox_send`.
> The **Go CLI**'s command switch
> (`packages/foreman_cli/cmd/foreman/main.go:85-98`) dispatches exactly
> `project`, `task`, `run`, `workflow` and `init`; anything else returns
> `foreman: unknown command`. That is the only `foreman` entry point in the
> repository — `packages/` holds `foreman_cli`, `foreman_server` and
> `jido_harness`, and the string `inbox` appears in no Go, TypeScript or
> JavaScript source in any of them. Passages elsewhere in this file describing a
> Node CLI or `foreman daemon` refer to a retired architecture.
>
> The Elixir side this section describes is gone too. It named an "event-backed
> inbox projection (`InboxMessageAppended` / `InboxDeliveryUpdated`)", but the
> only code that ever produced those events was
> `ForemanServer.Aggregates.InboxThread`, which was unreachable from every
> direction at once — `inbox.send` absent from the command allowlist, no
> `"inbox:"` clause in `CommandRouter.aggregate_module_for/1`, no event structs,
> no `ProjectionStore` handler, no HTTP route, no MCP tool, and no caller. It has
> been deleted (see `docs/lessons/typed-boundaries-full.md` §5.3). There is no
> `foreman_inbox_message_projections` table in the codebase either, despite the
> mention under `server status`.
>
> Retained as a record of the intended design, not as a description of behavior.
> Do not implement against it without re-deriving the design: an entire
> requirement (REQ-007 of `PRD-2026-d306444f-phase-commit-control.md`) was
> specified against this inbox as though it worked, and had to be dropped.

### `foreman inbox`

View the Agent Mail inbox — messages sent between agents and the foreman orchestrator. In Elixir/default backend mode, inbox reads the Elixir event-backed inbox projection (`InboxMessageAppended` / `InboxDeliveryUpdated`) and does not require the Node daemon socket. When run on a TTY with no explicit selector, `foreman inbox` opens the unified cockpit focused on the inbox view: task list, selected-run timeline, status/board jump keys, details, and `m/e/l/r/f` tabs for messages, events, logs, reports, and files. The cockpit phase rail follows the selected run's workflow phase order and shows per-phase retry counts. Message rows render oldest-first (chronological) with local `mm/dd hh:mm`, sender, receiver, and message columns. The cockpit refreshes live while keeping the selected run pinned; `/`, `1/2/3`, `!`, `p`, and `d` search/filter rows; `a` or `:` opens the action palette. Palette reset requires explicit `y` confirmation and then runs `foreman reset` for the selected task; non-reset actions still print copy/manual command text. Use `--non-interactive` for scriptable output. Task/run drilldowns stay scriptable by default and enter the cockpit only with `--interactive`.

```bash
foreman inbox                     # TTY: unified cockpit opened to inbox view; non-TTY summary
foreman inbox --non-interactive   # Scriptable active/attention summary
foreman inbox task bd-abc1        # Scriptable task drilldown; add --logs --reports --files
foreman inbox task bd-abc1 --interactive # Cockpit with this task selected
foreman inbox run <run-id> --interactive # Cockpit with this run selected
foreman inbox --task bd-abc1      # Legacy task selector; still supported
foreman inbox --all               # Task-first all-run summary
foreman inbox --all --watch       # Live stream ALL messages across all runs
foreman inbox --watch             # Live stream latest run's messages
foreman inbox --unread            # Show only unread messages
foreman inbox --limit 100         # Show more messages
foreman inbox --compact           # Summarize task/run, phases, tools, denials, notable events
foreman inbox task bd-abc1 --logs --reports --files
foreman inbox task bd-abc1 --select-report   # Interactive report file picker → opens in $EDITOR
foreman inbox run <run-id> --select-report      # Interactive run report file picker → opens in $EDITOR
foreman inbox --ack               # Mark shown messages as read
```

| Option | Default | Description |
|--------|---------|-------------|
| `--agent <name>` | all | Filter to specific agent/role |
| `--run <id>` | latest | Filter to a specific run ID |
| `--task <id>` | — | Legacy selector: resolve run by task ID |
| `--all` | — | Show/watch task-first output across all runs |
| `--watch` | — | Poll every 2 seconds for new messages |
| `--unread` | — | Show only unread messages |
| `--limit <n>` | `50` | Maximum messages/summary rows |
| `--events-limit <n>` | `50` | Maximum lifecycle events |
| `--interactive` | — | For task/run subcommands, open the cockpit with the selected id |
| `--non-interactive` | — | Force scriptable output even when stdout is a TTY |
| `--scope <scope>` | attention | Task summary scope: active, attention, all, terminal |
| `--messages` / `--events` | — | Task/run drilldown sections |
| `--logs` | — | Task/run subcommand: show last 24 structured log entries (timestamp, stream, type, phase, message) with color coding; falls back to raw log files if Elixir backend unavailable |
| `--reports` | — | Task/run subcommand: show phase report files |
| `--files` | — | Task/run subcommand: show file changes |
| `--select-report` | — | Task/run subcommands only: interactively select a report file to open in `$EDITOR` |

### `foreman inbox send`

Send an Agent Mail message within a pipeline run (replaces the removed `foreman mail send`).

```bash
foreman inbox send \
  --run-id "abc123" \
  --from "developer" \
  --to "foreman" \
  --subject "phase-complete" \
  --body '{"phase":"developer","status":"complete"}'
```

| Option | Default | Description |
|--------|---------|-------------|
| `--run-id <id>` | `$FOREMAN_RUN_ID` | Run ID (falls back to env var) |
| `--from <agent>` | *required* | Sender agent role (e.g. `explorer`, `developer`) |
| `--to <agent>` | *required* | Recipient agent role (e.g. `foreman`, `developer`) |
| `--subject <subject>` | *required* | Message subject (e.g. `phase-started`, `phase-complete`, `agent-error`) |
| `--body <json>` | `'{}'` | Message body (must be a valid JSON string) |

Use `agent-error` only for unrecoverable infrastructure/runtime failures. QA/product failures should write a FAIL report so workflow retry routing can send feedback to the configured remediation phase.

---

## Task Planning

### `foreman plan`

> **NOT IMPLEMENTED.** `foreman plan` is not dispatched. Planning runs used to be started as ordinary tasks via `foreman task create --workflow-type plan …`, but that verb is REMOVED (TRD-018, 2026-09-13) too — see the note at the top of this file. Start one today via Beads instead: create a bead whose `--type` resolves to the `plan` workflow (e.g. `br create --type plan ...`), or transition an existing bead to `status: open`; BeadsWatcher dispatches the internal `task.create` command with that workflow automatically.

Run the Ensemble PRD → TRD pipeline. Converts a product description into a Technical Requirements Document with decomposed tasks.

```bash
foreman plan "Add user authentication with OAuth"
foreman plan docs/PRD.md          # From a file
foreman plan "..." --prd-only     # Stop after PRD generation
foreman plan --from-prd docs/PRD.md  # Start from existing PRD
foreman plan "..." --output-dir docs/auth  # Custom output directory
foreman plan "..." --dry-run      # Preview steps
foreman plan prd "Add user authentication"   # Server-backed PRD planning
foreman plan trd docs/PRD.md                  # Server-backed TRD planning
```

`foreman plan prd` and `foreman plan trd` submit `plan.prd` / `plan.trd` commands to the local Elixir orchestration server. They auto-start the server by default; use `--no-auto-start` to require an already-running server.

| Option | Default | Description |
|--------|---------|-------------|
| `--prd-only` | — | Stop after PRD generation |
| `--from-prd <path>` | — | Start from an existing PRD file |
| `--output-dir <dir>` | `./docs` | Output directory for PRD/TRD |
| `--runtime <runtime>` | `claude-code` | AI runtime (`claude-code` or `codex`) |
| `--dry-run` | — | Show steps without executing |

Server-backed `plan prd` / `plan trd` options: `--project <path>`, `--output-dir <dir>`, `--provider <provider>`, `--run-id <id>`, `--command-id <id>`, `--no-auto-start`.

### `foreman sling trd`

> **NOT IMPLEMENTED.** `foreman sling trd` is not dispatched. The suggested replacement, `foreman task create --workflow-type implement-trd --trd-path <path>`, is also REMOVED (TRD-018, 2026-09-13) — see the note at the top of this file. Start one today via Beads instead: create a bead with `--agent-context '{"trd_path":"<path>"}'` and a `--type` that resolves to the `implement-trd` (or `implement-trd-beads`) workflow, or set that `agent_context` on an existing bead and transition it to `status: open`; BeadsWatcher reads `agent_context.trd_path` and dispatches `task.create` + `task.approve` automatically (a bead missing a required `trd_path` is moved to `blocked` with a comment instead).

Convert a Technical Requirements Document into a native task hierarchy with dependencies.

```bash
foreman sling trd docs/TRD.md    # Create native tasks from TRD
foreman sling trd docs/TRD.md --dry-run  # Preview
foreman sling trd docs/TRD.md --json     # Output parsed structure
foreman sling trd docs/TRD.md --auto     # Skip confirmation prompts
foreman sling trd docs/TRD.md --skip-completed   # Skip [x] items
foreman sling trd docs/TRD.md --close-completed  # Create and close [x] items
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview without creating tasks |
| `--auto` | Skip confirmation prompts |
| `--json` | Output parsed structure as JSON |
| `--skip-completed` | Skip `[x]` completed tasks |
| `--close-completed` | Create and immediately close `[x]` tasks |
| `--no-parallel` | Disable parallel sprint detection |
| `--force` | Recreate tasks even if they exist |
| `--no-risks` | Skip risk register items |
| `--no-quality` | Skip quality requirements |

### `foreman task create`

> **REMOVED (TRD-018).** `foreman task create` is gone as of
> 2026-09-13: TRD-018 deleted the `task` dispatch case and its
> handlers from
> `packages/foreman_cli/cmd/foreman/task.go` (which still exists for
> shared HTTP helpers used by other command files; see the
> authoritative verb list at the top of this file). Invoking it now
> produces the CLI's standard "unknown command" error. Task creation
> today is driven by Beads — `br create`, or transitioning an
> existing bead to `status: open` with the `foreman-exec` label — which
> BeadsWatcher observes to dispatch the internal `task.create` command
> automatically (an open bead without the label is skipped by the label gate); that
> internal command's guard/payload semantics are unchanged, only the
> CLI verb is gone.
>
> The section below is kept as a historical record of the CLI verb's
> shape immediately before removal, including a still-relevant
> correction: eight flags shown in the examples/table below never
> existed even then — `--type` (the real flag was `--task-type`),
> `--priority` (settable only via a raw `task.create` envelope; see
> `docs/lessons/operator-reference.md`), `--parent`, `--model`, `--dry-run`, `--from-text`,
> `--no-llm`, `--project-path`. The real set was `--id --project
> --title --description --task-type --workflow-type --trd-path
> --status`. Two corrections of note: `--command-id` was a `task
> approve` flag, not a `task create` one, and `--status` — which the
> options table below omits entirely — was real and defaulted to
> **`open`**, not the `backlog` status the sentence below claims.

Create a new structured task in backlog status. Natural-language task generation (`--from-text`) was removed after the Elixir backend cutover.

```bash
foreman task create --title "Fix login timeout" --type bug --priority 1
foreman task create --title "Fix login timeout" --description "Session expires too early"
```

| Option | Default | Description |
|--------|---------|-------------|
| `--title <text>` | — | Task title (required) |
| `--description <text>` | — | Optional task description |
| `--type <type>` | `task` | Task type. Bundled auto-routed types: `task`, `bug`, `feature`, `epic`, `smoke`; project/global workflows can declare additional `task_type` values. |
| `--priority <level>` | `medium` | Priority: `0`–`4` or `critical`/`high`/`medium`/`low`/`backlog` |
| `--from-text <description>` | — | Removed after Elixir cutover; use `--title` and `--description` |
| `--parent <id>` / `--dry-run` / `--no-llm` / `--model` | — | Removed natural-language generator options |
| `--trd-path <path>` | — | Project-relative TRD path; required for `--workflow-type implement-trd*` |
| `--workflow-type <name>` | — | Workflow manifest name (e.g. `fix`, `implement-trd`) |

Manifests resolve against the server's workflow catalog root —
`~/.foreman/workflows` by default, overridable via
`config :foreman_server, :workflow_root` — not a client-side allowlist.

### `foreman task list`

> **REMOVED (TRD-018).** TRD-018 deleted the entire `task` case from the
> CLI's dispatch switch, not just `create`/`approve`/`retry`/`get` — `task
> list` and `task update` are gone too, even though they were not named in
> that bead's own commit message. Invoking either now produces the CLI's
> standard "unknown command" error. There is no CLI replacement; list tasks
> via `br list`/`br show <id>` or the HTTP API (`GET /api/tasks/:id`).

List tasks, optionally filtered by project and status.

```bash
foreman task list --project foreman --status open
```

| Option | Description |
|--------|-------------|
| `--project <id>` | Filter by project ID |
| `--status <status>` | Filter by status: `open`, `ready`, `in_progress`, `blocked`, `closed`, `failed` |

### `foreman task update`

> **REMOVED (TRD-018).** Same removal as `foreman task list` above — the
> entire `task` case is gone from the CLI. Update fields via `br update
> <id> --status=... --priority=...` instead.

Update task fields (title, description, priority, status). At least one field must be provided.

```bash
foreman task update --id foreman-iv00 --priority 1 --status closed
```

| Option | Description |
|--------|-------------|
| `--id <id>` | Task ID (required) |
| `--title <text>` | New task title |
| `--description <text>` | New task description |
| `--priority <0-4>` | Priority: `0`=critical, `1`=high, `2`=medium, `3`=low, `4`=backlog |
| `--status <status>` | New status: `open`, `ready`, `in_progress`, `closed`, `failed` |


## Migration and Coexistence

### `foreman import --to-elixir`

> **NOT IMPLEMENTED.** `foreman import` is not dispatched, and no CLI surface replaces it.

Import a TypeScript-era migration payload into the Elixir event store. The payload is JSON and may include `projects`, `tasks`, `runs`, `workflows`, `inbox_messages`, and `config`.

```bash
foreman import --to-elixir --file migration.json
foreman import --to-elixir --from-node --project foreman
foreman import --to-elixir --file migration.json --command-id migration-2026-014
foreman import --to-elixir --file migration.json --no-auto-start
```

| Option | Description |
|--------|-------------|
| `--file <path>` | Migration JSON payload to import |
| `--from-node` | Deprecated. The CLI no longer reads Node/Postgres state directly; export a migration JSON separately and use `--to-elixir --file <path>`. |
| `--command-id <id>` | Explicit server command id for idempotent retries |
| `--no-auto-start` | Require an already-running Elixir server |

Elixir is the backend after cutover. Legacy TS delegation has been removed, and `foreman daemon start|restart` now fails with guidance to use `foreman server start`. Operator commands either route through Elixir-backed APIs/events/projections or report removal.

---

## Agent Sessions

### `foreman attach`

> **NOT IMPLEMENTED.** `foreman attach` is not dispatched, and no CLI surface replaces it.

Attach to a running or completed agent session to inspect its state.

```bash
foreman attach                    # Attach to latest session
foreman attach bd-abc1            # Attach to a specific task by ID
foreman attach --list             # List attachable sessions
foreman attach --follow           # Tail the agent log file
foreman attach --stream           # Stream Agent Mail messages
foreman attach --worktree         # Open a shell in the agent's worktree
foreman attach --kill             # Kill the agent process
```

| Option | Description |
|--------|-------------|
| `--list` | List attachable sessions |
| `--follow` | Follow log file (like `tail -f`) |
| `--stream` | Stream Agent Mail messages in real time |
| `--worktree` | Open an interactive shell in the worktree |
| `--kill` | Kill the agent process |

---

## Worktree Management

### `foreman worktree`

> **NOT IMPLEMENTED.** `foreman worktree` is not dispatched. Worktrees are provisioned and reclaimed server-side, one per run (see `docs/lessons/phase-execution-and-pr-mechanics.md`); there is no operator worktree verb.

Manage git worktrees used by Foreman agents.

```bash
foreman worktree list             # Show all active worktrees
foreman worktree list --json      # Machine-readable output
foreman worktree clean            # Remove orphaned worktrees
foreman worktree clean --all      # Remove ALL worktrees including active
foreman worktree clean --force    # Force-delete branches
foreman worktree clean --dry-run  # Preview removal
```

**`worktree list` options:**

| Option | Description |
|--------|-------------|
| `--json` | Output as JSON |

**`worktree clean` options:**

| Option | Description |
|--------|-------------|
| `--all` | Remove ALL worktrees including active ones |
| `--force` | Force-delete branches (including remote) |
| `--dry-run` | Preview removal without deleting |

---

## Maintenance

### `foreman purge`

> **NOT IMPLEMENTED.** `foreman purge` is not dispatched. Nearest real: `foreman run remove --id <run-id>`.

Purge old agent logs and stale run records. The old `foreman purge-logs` and `foreman purge-zombie-runs` spellings remain as hidden deprecated aliases.

#### `foreman purge logs`

Remove old agent log files from `~/.foreman/logs/` based on a retention policy.

```bash
foreman purge logs                # Delete logs older than 7 days
foreman purge logs --days 30      # Custom retention window
foreman purge logs --dry-run      # Preview
foreman purge logs --all          # Delete all terminal-status logs regardless of age
```

| Option | Default | Description |
|--------|---------|-------------|
| `--days <n>` | `7` | Delete logs from runs older than N days |
| `--dry-run` | — | Preview without making changes |
| `--all` | — | Delete all terminal-status logs regardless of age (use with caution) |

#### `foreman purge runs`

Remove failed run records for tasks that are already closed or no longer exist. Reduces database clutter.

```bash
foreman purge runs                # Clean up stale records
foreman purge runs --dry-run      # Preview
```

| Option | Description |
|--------|-------------|
| `--dry-run` | Preview without making changes |

---

## GitHub Issues Integration

### `foreman issue`

> **NOT IMPLEMENTED.** `foreman issue` is not dispatched. Near-duplicate of the section above, which this one predates or follows — it is not a strict copy: only this copy mentions `foreman issue webhook`.

GitHub Issues integration commands.

```bash
foreman issue view owner/repo#123      # View a specific issue
foreman issue list owner/repo          # List open issues
foreman issue configure owner/repo    # Configure a repository for sync
foreman issue import owner/repo#123   # Import issue as Foreman task
foreman issue labels owner/repo       # List repository labels
foreman issue milestones owner/repo   # List repository milestones
foreman issue webhook owner/repo      # Manage GitHub webhooks
foreman issue status owner/repo       # Show sync status
foreman issue link owner/repo#123 --pr owner/repo#456  # Link PR to issue
```

| Option | Description |
|--------|-------------|
| `-h, --help` | Display help for command |

**Subcommands:**
| Command | Description |
|---------|-------------|
| `view` | View a GitHub issue |
| `list` | List GitHub issues for a repository |
| `configure` | Configure a GitHub repository for sync |
| `import` | Import GitHub issue(s) as Foreman tasks |
| `labels` | List labels for a GitHub repository |
| `milestones` | List milestones for a GitHub repository |
| `webhook` | Manage GitHub webhooks for a repository |
| `status` | Show sync status for a GitHub repository |
| `link` | Link a GitHub pull request to an issue (or unlink) |

> **Removed commands:** `foreman mail send` has been removed — use `foreman inbox send`.










## Stall fields in run/task JSON

`foreman run get <run-id> --format json`, `foreman run list --format json`, task JSON reads, and MCP `foreman_run_status` may include `latest_stall` when the server has persisted a `RunStallReported` event. The object is projection-derived and contains `stall_kind`, `policy`, `status_effect`, `threshold_ms`, `idle_ms`, `activity_at_ms`, `detected_at_ms`, `phase_id`, optional task/phase labels, `idempotency_key`, and `reason`. Non-stalled runs return `null`/absence, not synthetic defaults.

## Messaging CLI status

No standalone `foreman messaging` or notification test-delivery CLI command exists in this revision. `foreman project update --notification-preference every_turn|blocked_only|off <id>` sets a project's notification preference (see the user guide's Outbound messaging delivery section). Outbound Telegram/Slack/webhook delivery is configured on the server via `config :foreman_server, :messaging`; run/detail surfaces may show projected notification lifecycle state when notification events exist.

### `foreman approvals`

```
foreman approvals list (--project <id> | --run <id>) [--all] [--format table|json]
foreman approvals approve --run <id> --call <tool_call_id> [--by <name>] [--reason <text>]
foreman approvals deny    --run <id> --call <tool_call_id> [--by <name>] [--reason <text>]
```

Agent tool-permission requests (`GET /api/projects/:id/approvals`, `GET /api/runs/:run_id/approvals`). `approve`/`deny` post `tool.approve` / `tool.deny` to `/api/commands` for ONE tool call; they never touch the run's merge gate (`foreman run approve-merge` / `merge` stay the only way to merge). `--all` includes decided, expired and finished requests. An approval relaxes the approval mode for the NEXT PHASE ONLY, but phase-wide: pi/claude have no per-tool grant (the claude path is unverified live). The `approval_delivery` column is `resume_with_override` (the run is resumed with a one-phase approval-mode override) or `live`.

### `foreman questions`

```
foreman questions list --project <id> [--all] [--format table|json]
foreman questions answer --run <id|global> --question <id> --text <answer> [--by <name>]
```

Questions agents asked the operator (`GET /api/projects/:id/questions`); `answer` posts `question.answer`. Unanswered requests expire after the configured timeout and then show as `approval_expired` / `question_expired` in the Overview.
