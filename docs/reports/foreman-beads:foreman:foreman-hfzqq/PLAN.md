# Plan — launch Foreman pi workers with `PI_SUBAGENT_CHILD=1`

## 1. Verdict

**Real bug, unimplemented.** `grep -rn PI_SUBAGENT_CHILD .` in this repo returns
zero hits, so no Foreman-launched pi worker sets it.

Evidence that the variable matters (user-installed extension, outside this repo,
`~/.pi/agent/npm/node_modules/pi-advisor-flow/dist/index.js`):

- `:288` `var isMarkedSubagent = () => process.env.PI_SUBAGENT_CHILD === "1";`
- `:4799` `if (!isMarkedSubagent() && !await runtime.setExecutorModel(executor)) {`
  — runs on every `session_start`, so the extension silently replaces the model
  Foreman resolved in `ForemanServer.Workflow.ModelResolution` and logged in
  `run_executor.ex` `log_phase_model/5`.
- `:4845` same hijack for thinking effort (`runtime.pi.setThinkingLevel`);
  `:4887` model-select sync is skipped when marked.

Accuracy note for the comment/doc text: in the installed extension the advisor
*gates* (`advisorPlanGateRef` `:51`, `advisorCompletionGateRef` `:53`,
`advisorBlockOnBlockedRef` `:57`) are config refs and are **not** keyed on
`isMarkedSubagent()`. What the variable suppresses is the executor
model/effort override and model-select sync. `pi-subagents`
(`src/extension/index.js:217`) *does* go fully inert on the same variable. Write
that, not "it disables the gates".

## 2. Root cause

`ForemanServer.Workflow.RunExecutor.prepare_agent_launch/5`
(`packages/foreman_server/lib/foreman_server/workflow/run_executor.ex:2014`)
builds the worker env map at lines 2200-2203 from the project environment, the
Library env and `foreman_env/4`. Nothing marks the process as a Foreman-owned
child pi session, so machine-wide pi extensions treat it as an interactive
session and override its model.

The env map travels: `launch_opts[:env_map]` (`run_executor.ex:2232-2241`) →
`ForemanServer.Overwatch.start_phase/2` `build_launch_env/2`
(`overwatch.ex:198`, caller's map wins verbatim) →
`JidoHarnessWorker.put_env/2`
(`overwatch/adapters/jido_harness_worker.ex:144-159`) → driver `:env`.

## 3. Failing check first

Create `packages/foreman_server/test/foreman_server/workflow/run_executor_pi_subagent_env_test.exs`:

```elixir
defmodule ForemanServer.Workflow.RunExecutorPiSubagentEnvTest do
  # Foreman-launched pi workers are marked as child sessions so machine-wide pi
  # extensions do not override the model Foreman resolved.
  use ExUnit.Case, async: false

  alias ForemanServer.ProjectSettings
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.RunExecutor

  setup do
    ProjectionStoreReset.reset!()
    on_exit(&ProjectionStoreReset.reset!/0)
    :ok
  end

  defp env(phase_spec) do
    {:ok, launch} =
      RunExecutor.__prepare_agent_launch_for_test__(
        %{
          run_id: "run-pi-subagent",
          plan_context: %{},
          task: %{task_id: "t1", project_id: "pi-subagent-proj"},
          completed: [],
          phase_specs: [],
          artifact_base: System.tmp_dir!(),
          project_settings: %ProjectSettings{}
        },
        Map.put_new(phase_spec, :name, :implement),
        0,
        1,
        nil
      )

    Keyword.fetch!(launch.launch_opts, :env_map)
  end

  test "a pi phase is launched marked as a pi child session" do
    assert env(%{})["PI_SUBAGENT_CHILD"] == "1"
    assert env(%{provider: :pi})["PI_SUBAGENT_CHILD"] == "1"
  end

  test "a non-pi phase is not marked" do
    refute Map.has_key?(env(%{provider: "claude"}), "PI_SUBAGENT_CHILD")
  end
end
```

Red before the fix (first test fails: `nil != "1"`):

```
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test test/foreman_server/workflow/run_executor_pi_subagent_env_test.exs'
```

(If deps are missing, run `mix deps.get` in `packages/foreman_server` once.)


## 4. Edits

### Edit 1 — `packages/foreman_server/lib/foreman_server/workflow/run_executor.ex`, in `prepare_agent_launch/5`

Line 2203 currently reads `      |> Map.merge(foreman_env)` and ends the `env =`
pipe (lines 2200-2203). Append one step to that pipe:

```elixir
      |> Map.merge(foreman_env)
      |> maybe_put_pi_child_marker(JidoHarness.request_provider(request))
```

Leave the `FOREMAN_* always wins` comment above the pipe untouched.

### Edit 2 — same file, new private helper

Insert immediately after `phase_launch_provider/1` (ends at line 1252):

```elixir
  # Foreman owns the model for a phase (`ModelResolution`), so every pi worker
  # it launches is marked as a child session. Machine-wide pi extensions honour
  # `PI_SUBAGENT_CHILD=1` by standing down: `pi-advisor-flow` skips its
  # `setExecutorModel`/`setThinkingLevel` override and its model-select sync,
  # and `pi-subagents` registers nothing at all. Deliberate trade-off: an
  # operator's advisor extension does not supervise Foreman phases, and in
  # exchange the phase actually runs on the resolved model. Documented in
  # `docs/user-guide.md` §7.3.
  defp maybe_put_pi_child_marker(env, :pi), do: Map.put(env, "PI_SUBAGENT_CHILD", "1")
  defp maybe_put_pi_child_marker(env, _provider), do: env
```

### Edit 3 — `packages/foreman_server/test/foreman_server/workflow/run_executor_command_test.exs:789`

This assertion breaks: the captured phase is a pi phase, so the delivered env
now carries one non-`FOREMAN_` key. Line 789 currently reads:

```elixir
    assert Enum.all?(Map.keys(delivered), &String.starts_with?(&1, "FOREMAN_"))
```

Replace with:

```elixir
    # `PI_SUBAGENT_CHILD` is Foreman's own pi-child marker, not project env.
    assert delivered["PI_SUBAGENT_CHILD"] == "1"

    assert Enum.all?(Map.keys(delivered), fn key ->
             String.starts_with?(key, "FOREMAN_") or key == "PI_SUBAGENT_CHILD"
           end)
```

### Edit 4 — `docs/user-guide.md`, end of §7.3

After line 2029 (`installed copies.`) and before the blank line preceding
`### 7.4 Bundled skills`, add:

```markdown

**Foreman marks pi workers as child sessions.** Every pi worker Foreman
launches gets `PI_SUBAGENT_CHILD=1` in its environment. Foreman resolves the
model for each phase itself (phase `models.default` > project `thread_model` >
provider default) and this marker stops machine-wide pi extensions from
overriding it — `pi-advisor-flow` skips its executor model/effort override, and
`pi-subagents` registers nothing. The trade-off is deliberate: advisor
extensions installed in your pi agent directory do not supervise Foreman phases,
so advisor plan/completion gating applies to your interactive pi sessions only.
Phases on other providers (`claude`) are unaffected.
```

## 5. Verification

```
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors test/foreman_server/workflow/run_executor_pi_subagent_env_test.exs test/foreman_server/workflow/run_executor_project_model_test.exs test/foreman_server/workflow/run_executor_command_test.exs test/foreman_server/overwatch/adapters/jido_harness_worker_env_test.exs test/foreman_server/library_delivery_test.exs'
devbox run -- bash -c 'cd packages/foreman_server && mix format --check-formatted'
```

Success = all tests pass, exit 0, no warnings; `mix format` exits 0. Then the
AGENTS.md gate:

```
devbox run -- bash -c 'cd packages/foreman_server && DATABASE_URL=postgres://postgres:postgres@localhost:55432/foreman_test MIX_ENV=test mix test --warnings-as-errors'
```

(~825 s, ~9255 tests; without `DATABASE_URL` it fails at boot with Postgrex
`28P01 invalid_password` — environment quirk, not a regression.)

Documentation gate: added identifier is the env var `PI_SUBAGENT_CHILD`; nothing
removed or renamed. `grep -n PI_SUBAGENT_CHILD CLAUDE.md README.md
docs/user-guide.md docs/cli-reference.md` must hit `docs/user-guide.md` only.
`CLAUDE.md:403-417` lists the injected **`FOREMAN_*`** vars and the project
environment rules; this marker is neither, so no edit there. `README.md` and
`docs/cli-reference.md` have no operator-visible change.

## 6. Out of scope

- `packages/jido_harness/**` — vendored fork (`UPSTREAM_PIN.md`); do **not** add
  the variable beside `PI_SKIP_VERSION_CHECK` in
  `lib/jido_harness/adapters/pi.ex:234-236` or in
  `lib/jido_harness/session/transports/pi_rpc.ex:25-26`. Its tests are a
  separate CI job and do not run in this devbox.
- `ForemanServer.Coordinator.Agent.Harness` (`coordinator/agent/harness.ex:206`)
  and `ForemanServer.Review.Evaluator.Agent`
  (`review/evaluator/agent.ex:215`) — neither builds an `env:` key, and the
  coordinator already launches pi with `no_extensions: true`
  (`harness.ex:41-47`), so advisor-flow cannot load there.
- `ForemanServer.Overwatch` `build_launch_env/2`,
  `JidoHarnessWorker.put_env/2` (forwarding hops) and
  `Exec.Runners.Overwatch.scripted_launch/4` (workflow phases skip it).
- `foreman_env/4` clauses (`run_executor.ex:5218`+) — that namespace is
  `FOREMAN_*` only and is provider-blind.
- No refactors of the env merge pipeline, no new config key, no runtime toggle.
