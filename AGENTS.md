# Foreman — Agent Context

This file is loaded into every agent prompt, so it holds **rules only**. Mechanics, history and post-mortems live in `docs/lessons/` (index at the bottom) — read the matching file before touching that area. Keep this file under ~10 KB: add new detail to a `docs/lessons/*.md` file, not here.

## Working Rules

1. **Think before coding.** State assumptions; if several interpretations exist, present them; if something is unclear, stop and ask. Push back when a simpler approach exists.
2. **Be concise.** Facts and findings only; skip the discovery narration.
3. **Simplicity first.** Minimum code that solves the problem. No speculative features, single-use abstractions, configurability nobody asked for, or error handling for impossible cases.
4. **Surgical changes.** Every changed line traces to the request. Don't refactor or restyle adjacent code; mention unrelated dead code, don't delete it. Remove only the orphans your change created.
5. **Goal-driven.** Turn the task into a verifiable check (failing test → passing test; tests green before and after a refactor). State a short plan for multi-step work.

## Documentation Gate

A gate, not a suggestion: it blocks calling a task done, like running the tests.

1. List every externally visible identifier your diff added, removed or renamed: command/event types (`"foo.bar"`), MCP tools (`foreman_*`), HTTP routes, CLI flags/verbs, env vars, config keys, workflow/prompt names.
2. `grep` each removed/renamed identifier in `CLAUDE.md`, `README.md`, `docs/user-guide.md`, `docs/cli-reference.md`. A hit is a stale reference: fix it or annotate it as historical.
3. `grep` the *replaced* counterpart of each added identifier so the replacement is documented where the old name was.
4. State which of those four files needed edits and which didn't, and why ("no operator-visible change" is valid; silence is not).

`AGENTS.md` is **not** a doc-update target: do not add change notes or post-mortems here. Put them in `docs/lessons/` and, only if the rule is short and always needed, add one line here. `docs/PRD/*` and `docs/TRD/*` are point-in-time specs; leave their claims as written and add a forward-pointer note instead.

- After editing bundled workflows or prompts, run `foreman init --force` to refresh the installed copies.
- Verify a CLI command against Go source (`packages/foreman_cli/cmd/foreman/main.go` and the `runProject`/`runRun`/`runThread`/`runWorkflow`/`runApprovals`/`runQuestions`/`runCommands` case lists) or a fresh `go build ./cmd/foreman` — never a stale `./foreman` binary or `docs/cli-reference.md` (which still carries annotated, non-routing verbs). A new CLI verb MUST be added to the `usage` const in `main.go` and to `docs/cli-reference.md`; `usage_drift_test.go` parses the dispatch switches and fails the build when usage, dispatch, docs or `agent_commands` disagree.

## Typed Boundaries, Loud Failures (§5)

Make the compiler catch it; if it can't, fail loudly. Never degrade to a plausible-looking success. Full rules and post-mortems: `docs/lessons/typed-boundaries-full.md`.

- **5.1 Typed returns.** Error/result payloads are structs with `@enforce_keys` and `@type t`, never bare maps. Maps are for genuinely open data only.
- **5.2 Total result handling.** Match exactly the documented return shapes. No catch-all that wraps an unknown value as success; no `rescue`/`catch`/`_ -> :ok` around code you don't understand. A crash beats a lie.
- **5.3 Absent ≠ malformed.** Unknown id → `NOT_FOUND`; missing required arg → `INVALID_PARAMS` naming it; wrong key type past the boundary → raise.
- **5.4 One key convention per boundary**, normalized once at the entry point (atoms internally, only schema-declared keys, never mint atoms). Never `Map.get(a, :k) || Map.get(a, "k")`.
- **5.4b Whitelist-normalize map params**; drop unknown keys; never insert `nil` for an absent key. A key is live only when something reads it — check the reader on rename.
- **5.5 Compile-time enforcement.** Generate dispatch from the registry so a missing implementation fails to compile. An undefined module/function/unused-alias warning is a defect report — read it.
- **5.6 Verify third-party contracts** in `deps/<lib>/lib/**` and pin them with a test.
- **5.7 Never duplicate a boundary** across transports/adapters; share one module and test both variants.

## Invariants (do not relax)

- **Phase execution runs on the Jobsite engine** (`Workflow.Lowering` → `Jobsite.Engine`). Do not reintroduce a second phase loop in `RunExecutor`.
- **Workflow vocabulary is closed.** Phase fields: `PhaseSpec.@fields` + `commit`, `stack_pr`, `timeout_minutes`, `approval_mode`; plus the workflow `worktree:` block. Never author `builtin`, `checkpointPr`, `create-pr`, `pr-wait` or `merge` phases; don't dispatch stale workflows from `~/.foreman/workflows/` (supported set: `packages/foreman_server/priv/defaults/workflows/`).
- **Refuse what cannot be honoured; warn where the consequence is merely invisible.** No load-time veto on a manifest a retained worktree makes satisfiable.
- **The PR base is the branch the run was cut from; there is no default.** Undeterminable base → typed error and no PR, never a guess to `main`.
- **Env vars exported by `foreman_env/3` prove only that Foreman computed them.** If a variable "has no effect", read `JidoHarnessWorker.init/1` first. A `command:` phase has no in-prompt channel: anything it must know travels by env.
- **The merge gate is operator-only.** `merge_approve` / `run.pr.merge` are never exposed as MCP tools or agent paths.
- **Phase timeouts:** an absent `timeout_minutes:` means no deadline (`:infinity`); resolution order is in `FailurePolicy.resolve/2`.
- **Remote Jobsite API** stays fail-closed (`RequireAuthenticated`), `allow_remote_start` default off, `hooks.host.*` forbidden, client never supplies repo paths.
- **Foreman never learns provider from model name.** Harness providers are `[:pi, :claude]`; a LiteLLM proxy is reached *through* them.

## Testing and Safety

- **A failing test is a failed build, full stop.** No "expected" or "known" failures, including the seed-dependent suite non-determinism (a bug to fix, not a threshold). A red `main` is a regression to fix immediately.
- Before re-running a task to validate a fix, the fix must be committed on the branch under test. Don't benchmark from a dirty/ambiguous workspace; checkpoint (commit or patch) before any reset or cleanup.
- Toolchain is Elixir 1.20.4 / OTP 28 via devbox, mirrored in CI — change `devbox.json`, `ci.yml` and `jido-upstream-upgrade.yml` together. Verify with `devbox run -- bash -c 'cd packages/foreman_server && MIX_ENV=test mix test --warnings-as-errors'`.
- `br` never commits or pushes. Follow this repo's git rules (commit only when asked) over generic workflow advice.

## Commands

```bash
devbox run setup | up | server | iex | ps | down     # bootstrap, services, Phoenix server
devbox run test | test:unit | test:langfuse          # test suites
devbox run db:migrate | db:reset | db:console
br ready | br list | br show <id> | br create | br update <id> --status=open | br close <id>   # Beads (br never commits)
bv --robot-triage                                    # graph-aware triage sidecar
```

## Code Search (xerj)

The repo is indexed in a local xerj node under prefix `foreman` (`http://localhost:9200`, data dir `~/xerj-data`). Use it to find code you can't see; still read the file before editing it.

- `xerj def --prefix foreman <symbol>` (definition, file:line) and `xerj search --prefix foreman "<words>"` (ranked passages). Always pass `--prefix foreman`; the default prefix is `ax`.
- Node down: `xerj --data-dir "$HOME/xerj-data" --insecure --bind 127.0.0.1 --port 9200`. Re-index: `xerj autoindex . --prefix foreman`.
- Never run `xerj init` here: it writes `.mcp.json` and skill files and appends its own block to this file.

## Architecture in One Paragraph

CQRS/event-sourced Elixir umbrella: `foreman_server` (Phoenix is the sole HTTP ingress; `CommandGateway` → aggregates via `CommandRouter` → events → `ProjectionStore`), a thin Go CLI (`packages/foreman_cli`), `jido_harness` (agent providers), and `foreman_client`. Aggregates hold typed state structs and typed event structs; commands are idempotent by `command_id`. Task sources go through the `TaskProvider` behaviour (`RunExecutor` drives claim/complete/fail; `BootReconciliation` drives orphan-reopen).

## Where to Read More (`docs/lessons/`)

| File | Read before touching |
| --- | --- |
| `phase-execution-and-pr-mechanics.md` | RunExecutor, Jobsite engine, `commit:`/`stack_pr:`/`timeout_minutes:`, AutoPR, base-branch resolution, `FOREMAN_*` env/artifact contract, merge gate, `/api/jobsites` |
| `typed-boundaries-full.md` | Full §5 rules with the MCP/StepSequencer/cleanup post-mortems |
| `architecture-and-events.md` | Stack, command flow, actors, aggregate state, domain events, idempotency, Go CLI boundaries, TaskProvider, ImplementationContext |
| `operator-reference.md` | Starting/stopping the server, projects, task lifecycle, Go CLI commands, workflow install |
| `devbox-and-toolchain.md` | `devbox run` catalog, otel-collector, SigNoz logs, toolchain pin |
| `beads-runtime-and-dispatch.md` | Beads quickstart, label-gate dispatch partitioning, `bv` sidecar, session protocol |
| `beads-workflow-legacy.md` | Older Beads narrative (historical) |
| `run-logs-known-issues.md` | Durable run logs, MCP run status, known issues, stall detection, outbound messaging |
| `documentation-discipline-history.md` | Why the documentation gate exists; CLI-reference corrections |
