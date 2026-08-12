# Foreman

Foreman orchestrates AI-agent workflows backed by the Elixir/Phoenix
service in `packages/foreman_server`. This repository currently
contains:

| Path | Role |
|---|---|
| `packages/foreman_server/` | The Elixir/Phoenix runtime. Hosts the `ForemanServer.AgentRuntime` subsystem (TRD-2026-6af02293). |
| `docs/PRD/` | Product requirements documents, one per design slice. |
| `docs/TRD/` | Technical requirements documents, one per design slice. |
| `docs/architecture/`, `docs/standards/` | Architectural context and conventions. |
| `dist/` | Generated artifacts (CLI/daemon/MCP/templates). |
| `AGENTS.md` | Agent-context contract for coding subagents (read-only here). |
| `CLAUDE.md` | Durable developer architecture conventions (start here when modifying the runtime). |

## Subsystem documentation

| Slice | Doc |
|---|---|
| `foreman_server` agent runtime (TRD-2026-6af02293) | [`CLAUDE.md`](./CLAUDE.md) (developer conventions), [`docs/user-guide.md`](./docs/user-guide.md) (operator config & adapter extension). This slice did not add a CLI; see the Go CLI slice when it lands. |
| Go/Elixir CQRS parity (TRD-2026-96872fc5) | per-PR notes in `docs/TRD/`; the `Workflow.Catalog` GenServer (CLAUDE.md §11) owns every manifest and prompt at runtime, hot-reloads on a 2 s poll, and auto-installs bundled templates when `~/.foreman/workflows` has no `*.yaml`. |

## Beads sync (atomic task.create + bidirectional sync)

The Go/Elixir CQRS slice wires Beads (the `br` CLI) into Foreman so
that projects with a configured `:create` task provider get
atomic `task.create` (mint Bead + emit `TaskCreated` together) and,
with the watcher enabled, inbound Beads appear as Foreman tasks.

- **Atomic `task.create` (provider-backed projects).** For projects
  with a configured `:create` provider, `POST /api/commands` with
  `task.create` runs the four-stage actor pipeline: the aggregate
  emits a stage-1 `TaskCreated` event spec, the actor calls
  `provider.create/2` to mint a Bead, the actor re-decides with the
  Bead ID as `payload.external_id`, and `CommandRouter` appends the
  committed event. The Bead ID is surfaced in the HTTP response, so
  `foreman task create` prints the linked Bead ID on stdout. Projects
  without a `:create` provider take the no-op path: no Bead is
  minted, no `external_id` is surfaced, and the `task.create`
  response carries only the Foreman `task_id`.
- **Beads → Foreman (inbound).** Opt in with
  `config :foreman_server, :start_beads_watcher?, true`. The
  `BeadsWatcherSupervisor` spawns one `BeadsWatcher` per registered
  project; each watcher tails the project's JSONL and dispatches
  `task.create` for new Beads that Foreman doesn't yet own.
- **Orphan janitor.** Opt in with
  `config :foreman_server, :start_beads_orphan_janitor?, true`. After a
  grace window, `BeadsOrphanJanitor` closes Beads whose matching
  Foreman task never landed (stranded issuance) or whose Foreman task
  already terminated. The janitor caches its last scan counters as
  `orphan_backlog` (8 fields: `lines_processed`, `lines_tagged`,
  `lines_untagged`, `lines_malformed`, `lines_retained`,
  `lines_closed`, `lines_age_young`, `lines_no_linked_at`).
  `foreman doctor task_provider` reads this snapshot via the
  supervisor's CQRS read boundary — the doctor never triggers a
  scan itself, and `orphan_backlog` is `nil` until the first scan
  completes for a registered project.
- **Operator remediation.** `foreman task retry` is the remediation
  path for tasks whose bound run is already terminal (see
  `docs/user-guide.md` §16).

Enablement, the per-project `task_provider` block, the doctor health
check (`foreman doctor task_provider`), and the orphan janitor's
opt-in semantics are documented in
[`docs/user-guide.md`](./docs/user-guide.md) (§11–§12, §16). See
[`docs/cli-reference.md`](./docs/cli-reference.md) for the CLI surface
and [`CLAUDE.md`](./CLAUDE.md) §11–§13 for the architectural
invariants.

## Task-provider boundary overview

The Go/Elixir CQRS task-provider slice keeps task-tracker ownership on
the Beads side and splits Foreman's responsibilities by lifecycle:

- `RunExecutor` drives claim, complete, and fail transitions during an
  active run.
- `Workflow.BootReconciliation` drives orphan-reopen on boot.
- `foreman doctor task_provider` is the operator-facing health check.

Enablement, the per-project `task_provider` block, and doctor output are
documented in the [task-provider enablement guide](./docs/user-guide.md#11-task-provider-enablement).

The agent runtime is an OTP-supervised, backend-agnostic façade over
pluggable adapters. Callers register a module that implements
`ForemanServer.AgentRuntime.BackendAdapter`, then call
`ForemanServer.AgentRuntime.execute/3` to run prompts.

```elixir
defmodule MyApp.ClaudeAdapter do
  use ForemanServer.AgentRuntime.BackendAdapter

  def name, do: :claude
  def capabilities do
    %{
      type: :remote,
      strengths: [:long_context, :code_review],
      weaknesses: [:image_input],
      supported_contexts: [:code_review, :brainstorm],
      cost_per_call: 0.012,
      typical_latency_ms: 4_500
    }
  end

  def available?, do: true

  def execute(%{prompt: prompt, context: ctx}, _opts) do
    MyApp.ClaudeAPI.complete(prompt, ctx)
  end
end

# Register via config (preferred)
config :foreman_server, :agent_runtime,
  enabled: true,
  adapters: [MyApp.ClaudeAdapter]

# Call it:
ForemanServer.AgentRuntime.execute("Summarize this PR", %{pr: 123},
  strategy: :automatic, task_type: :code_review)
```

See [`CLAUDE.md`](./CLAUDE.md) for the full convention catalogue and
[`docs/user-guide.md`](./docs/user-guide.md) for operator
configuration and the adapter extension workflow.

## Build & test

The Elixir runtime (verified tests in this slice):
```
cd packages/foreman_server && mix test
```

For full-repo build/test (CLI/daemon/MCP), see the per-package
`package.json`/`mix.exs`.
