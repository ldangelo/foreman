defmodule ForemanServer.TestSupport.PrDeliveryWorld do
  @moduledoc """
  The one world the four files of the Phase 1 adversarial suite (TRD-025, 037, 032, 040) share.

  One world is one pull request on a scripted GitHub plus a call log. Everything a scenario
  asks is answered by the REAL production code reading that GitHub: `CommandGateway`,
  `Aggregates.Run`, `PrEvidence`, `PrObservation`, `PrWatcher.Observer`, `PrStatus` and the
  projection. Only the `gh` binary is scripted, through the seam production already has
  (`RunPrMerge.set_command_runner/1`, a `:persistent_term` that `RunPrMerge.runner_opts/0` hands
  to `PrStatus.fetch/2` for the gateway's head read and the forced observation). A test using this
  world is `async: false`.

  ## Real and scripted

    * REAL: the event store, every aggregate, the gateway (`dispatch_operator/1`: the path the
      HTTP controller and the CLI take), the evaluator, the observer, the projection, the
      `required_checks` setting (written through the operator `project.update` command) and the
      merge gate.
    * SCRIPTED: `gh pr view <url> --json ...` (one PR record that a test mutates: `push!/2`,
      `complete_check!/4`, ...). Nothing else: a `gh` or other call the world was not scripted for
      is answered with exit code 1 and the text `unscripted call: ...`, recorded, and makes the
      test fail at its end naming the call (`take_unscripted!/1` hands the list to a test that
      provokes one on purpose, the harness self-check).

  ## Helpers

  The world:

    * `start!/1` - the world, the `gh` runner installed, cleanup registered with `on_exit`
    * `pr_url/1`, `head/1`, `calls/1`, `view_calls/1`, `take_unscripted!/1`
    * `runner/1` - the 3-arity `(cmd, args, opts)` runner over the world (what `start!/1` installs)
    * `script!/3` - register a handler for further calls (`(world, args -> {:reply, {out, code}} |
      :pass)`); the first handler that answers wins, the core handler for `pr view` is first. This
      is how TRD-037, 032 and 040 add the calls they need (publisher, `gh pr merge`, `gh pr list`)
      without changing what the core handler answers.

  The PR record (what `gh pr view` shows):

    * `check_run/2`, `status_context/2` - rollup items in GitHub's JSON shape (`CheckRun` with
      `workflowName`, `status`, `conclusion`, `startedAt`, `completedAt`; `StatusContext` with
      `context`, `state`)
    * `set_rollup!/2`, `add_check!/2` - replace or extend the rollup
    * `push!/3` - a new head: the PR gets `head` and an empty rollup (checks of the old commit do
      not belong to the new one)
    * `complete_check!/4`, `rerun_check!/3` - move one check run to completed, or back to running
    * `truncate_rollup!/2` - prepend passing filler checks until GitHub's list is cut

  Projects, runs and the gate:

    * `project!/2` - a registered project (operator `project.register`); `set_required!/3` sets or
      clears its `required_checks` through the operator `project.update` command
    * `ready_run!/3` - a run whose PR is ready at the PR's current head (the gate pending), with a
      clean review-findings record for that head unless told otherwise; the run is completed by the
      world's cleanup (the projection must not keep a non-terminal run)
    * `record_findings!/4` - the review-findings record of the finalising executor for a head
    * `observe!/3` - one observation of the PR through the real observer; with `observed_at:` the
      checks event carries that time (evidence of any age, without a clock seam)
    * `approve/3` - `merge_approve` through `CommandGateway.dispatch_operator/1`
    * `merge/1` - `run.pr.merge` through the same operator path

  Reads for assertions: `events/2`, `gate_pending?/1`, `gate_approved?/1`.
  """

  import ExUnit.Assertions

  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore, RunPrMerge}
  alias ForemanServer.PrWatcher.Observer
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.TestSupport.{GateEvidence, PrWatchSupport, UniqueIds}
  alias ForemanServer.Workflow.MergeGate

  @type world :: pid()
  @type run :: %{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t()
        }

  @zero_time "0001-01-01T00:00:00Z"
  @approver "github:ldangelo"

  # -- the world ----------------------------------------------------------------------------

  @doc """
  Start a world with one open PR (`head: "head-one"`, base `main`, an empty rollup, one changed
  file) and install its `gh` runner. Options: `:head`. The runner is removed, the runs the world
  readied are completed and an unscripted call fails the test when the test ends.
  """
  @spec start!(keyword()) :: world()
  def start!(opts \\ []) do
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)

    pr = %{
      head: Keyword.get(opts, :head, "head-one"),
      base: "main",
      branch: "foreman/task-world/run",
      state: "OPEN",
      mergeable: "MERGEABLE",
      rollup: [],
      files: [%{"path" => "lib/a.ex", "additions" => 3, "deletions" => 1}],
      changed_files: 1,
      additions: 3,
      deletions: 1,
      comments: []
    }

    state = %{
      pr_url: "https://github.com/acme/world-#{token}/pull/1",
      pr: pr,
      calls: [],
      unscripted: [],
      handlers: [{:pr_view, &view_handler/2}],
      runs: []
    }

    {:ok, world} = Agent.start(fn -> state end)
    MergeGate.clear()
    :ok = RunPrMerge.set_command_runner(runner(world))

    ExUnit.Callbacks.on_exit(fn ->
      RunPrMerge.clear_command_runner()
      final = Agent.get(world, & &1)
      Agent.stop(world)
      for run <- final.runs, do: end_run(run)

      assert final.unscripted == [],
             "the world was not scripted for: " <> Enum.join(final.unscripted, "; ")
    end)

    world
  end

  defp end_run(%{run_id: run_id, project_id: project_id}),
    do: PrWatchSupport.complete_run!(run_id, project_id)

  @doc "The PR's URL."
  @spec pr_url(world()) :: String.t()
  def pr_url(world), do: Agent.get(world, & &1.pr_url)

  @doc "The PR's head SHA as GitHub shows it now."
  @spec head(world()) :: String.t()
  def head(world), do: Agent.get(world, & &1.pr.head)

  @doc "Every call that reached the world, oldest first, as `{cmd, args}`."
  @spec calls(world()) :: [{String.t(), [String.t()]}]
  def calls(world), do: world |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "The `gh pr view` calls of the PR, oldest first."
  @spec view_calls(world()) :: [[String.t()]]
  def view_calls(world), do: for({"gh", ["pr", "view" | _] = args} <- calls(world), do: args)

  @doc """
  The unscripted calls so far, as text; the list is emptied, so a test that provokes one on
  purpose (the harness self-check) is not failed for it at the end.
  """
  @spec take_unscripted!(world()) :: [String.t()]
  def take_unscripted!(world),
    do:
      Agent.get_and_update(world, fn state ->
        {Enum.reverse(state.unscripted), %{state | unscripted: []}}
      end)

  @doc "Register `fun` (`(world, args -> {:reply, {output, exit_code}} | :pass)`) for more `gh` calls."
  @spec script!(world(), atom(), (world(), [String.t()] ->
                                    {:reply, {String.t(), integer()}} | :pass)) ::
          :ok
  def script!(world, name, fun) when is_atom(name) and is_function(fun, 2),
    do: Agent.update(world, &%{&1 | handlers: &1.handlers ++ [{name, fun}]})

  @doc "The 3-arity `(cmd, args, opts)` runner over the world."
  @spec runner(world()) :: (String.t(), [String.t()], keyword() -> {String.t(), integer()})
  def runner(world), do: fn cmd, args, opts -> handle(world, cmd, args, opts) end

  defp handle(world, cmd, args, _opts) do
    handlers =
      Agent.get_and_update(world, fn state ->
        {state.handlers, %{state | calls: [{cmd, args} | state.calls]}}
      end)

    reply =
      if cmd == "gh" do
        Enum.find_value(handlers, fn {_name, fun} ->
          case fun.(world, args) do
            {:reply, reply} -> reply
            :pass -> nil
          end
        end)
      end

    reply || unscripted(world, cmd, args)
  end

  defp unscripted(world, cmd, args) do
    text = Enum.join([cmd | args], " ")
    Agent.update(world, &%{&1 | unscripted: [text | &1.unscripted]})
    {"unscripted call: " <> text, 1}
  end

  defp view_handler(world, ["pr", "view", url, "--json", _fields]) do
    case Agent.get(world, &{&1.pr_url, &1.pr}) do
      {^url, pr} -> {:reply, {Jason.encode!(view_payload(pr)), 0}}
      _other_pr -> :pass
    end
  end

  defp view_handler(_world, _args), do: :pass

  defp view_payload(pr) do
    %{
      "state" => pr.state,
      "mergeable" => pr.mergeable,
      "headRefOid" => pr.head,
      "headRefName" => pr.branch,
      "baseRefName" => pr.base,
      "statusCheckRollup" => pr.rollup,
      "files" => pr.files,
      "changedFiles" => pr.changed_files,
      "additions" => pr.additions,
      "deletions" => pr.deletions,
      "comments" => pr.comments
    }
  end

  # -- the PR record ------------------------------------------------------------------------

  @doc """
  A check run in GitHub's rollup shape. Options: `:workflow` ("ci"), `:status` ("COMPLETED"),
  `:conclusion` ("SUCCESS"; blank unless the run is completed), `:started_at`, `:completed_at`.
  """
  @spec check_run(String.t(), keyword()) :: map()
  def check_run(name, opts \\ []) do
    status = Keyword.get(opts, :status, "COMPLETED")
    completed? = status == "COMPLETED"

    %{
      "__typename" => "CheckRun",
      "name" => name,
      "workflowName" => Keyword.get(opts, :workflow, "ci"),
      "status" => status,
      "conclusion" => if(completed?, do: Keyword.get(opts, :conclusion, "SUCCESS"), else: ""),
      "startedAt" => Keyword.get(opts, :started_at, "2026-11-12T13:58:43Z"),
      "completedAt" =>
        if(completed?,
          do: Keyword.get(opts, :completed_at, "2026-11-12T13:58:49Z"),
          else: @zero_time
        )
    }
  end

  @doc "A commit status in GitHub's rollup shape (`state`: SUCCESS, PENDING, FAILURE, ERROR, EXPECTED)."
  @spec status_context(String.t(), String.t()) :: map()
  def status_context(name, state \\ "SUCCESS") do
    %{
      "__typename" => "StatusContext",
      "context" => name,
      "state" => state,
      "targetUrl" => "https://ci.example/#{name}",
      "startedAt" => "2026-11-12T13:58:43Z"
    }
  end

  @doc "Replace the rollup."
  @spec set_rollup!(world(), [map()]) :: :ok
  def set_rollup!(world, items) when is_list(items), do: update_pr!(world, &%{&1 | rollup: items})

  @doc "Append one item to the rollup."
  @spec add_check!(world(), map()) :: :ok
  def add_check!(world, item), do: update_pr!(world, &%{&1 | rollup: &1.rollup ++ [item]})

  @doc """
  Somebody pushes: the PR has head `head` and an empty rollup (no check ran on the new commit
  yet). The head defaults to a fresh one.
  """
  @spec push!(world(), String.t()) :: :ok
  def push!(world, head), do: update_pr!(world, &%{&1 | head: head, rollup: []})

  @doc "Complete the running check run `name` with `conclusion` (`:completed_at` optional)."
  @spec complete_check!(world(), String.t(), String.t(), keyword()) :: :ok
  def complete_check!(world, name, conclusion, opts \\ []) do
    update_check!(world, name, fn item ->
      %{
        item
        | "status" => "COMPLETED",
          "conclusion" => conclusion,
          "completedAt" => Keyword.get(opts, :completed_at, "2026-11-12T14:00:00Z")
      }
    end)
  end

  @doc "Re-run the check run `name`: it is running again (`:started_at` optional), nothing completed."
  @spec rerun_check!(world(), String.t(), keyword()) :: :ok
  def rerun_check!(world, name, opts \\ []) do
    update_check!(world, name, fn item ->
      %{
        item
        | "status" => "IN_PROGRESS",
          "conclusion" => "",
          "completedAt" => @zero_time,
          "startedAt" => Keyword.get(opts, :started_at, "2026-11-12T15:00:00Z")
      }
    end)
  end

  @doc """
  GitHub cuts the rollup: `extra` passing filler check runs are listed after the PR's own, so
  that the list is longer than `PrStatus.max_list/0` and the oldest entries (the PR's own, which
  GitHub lists first) fall off. Pass enough fillers to exceed the limit.
  """
  @spec truncate_rollup!(world(), pos_integer()) :: :ok
  def truncate_rollup!(world, extra) when is_integer(extra) and extra > 0 do
    fillers = for n <- 1..extra, do: check_run("filler-#{n}")
    update_pr!(world, &%{&1 | rollup: &1.rollup ++ fillers})
  end

  defp update_pr!(world, fun), do: Agent.update(world, &%{&1 | pr: fun.(&1.pr)})

  defp update_check!(world, name, fun) do
    found? =
      Agent.get_and_update(world, fn state ->
        case Enum.split_with(
               state.pr.rollup,
               &(&1["__typename"] == "CheckRun" and &1["name"] == name)
             ) do
          {[], _rest} ->
            {false, state}

          {[_ | _], _rest} ->
            rollup =
              Enum.map(state.pr.rollup, fn
                %{"__typename" => "CheckRun", "name" => ^name} = item -> fun.(item)
                other -> other
              end)

            {true, put_in(state.pr.rollup, rollup)}
        end
      end)

    assert found?, "the world's PR has no check run named #{inspect(name)}"
    :ok
  end

  # -- projects, runs, the gate -------------------------------------------------------------

  @doc """
  Register a project through the operator `project.register` command and, when `required` is a
  list, set its `required_checks` (`set_required!/3`). Returns the project id.
  """
  @spec project!(world(), [map()] | nil) :: String.t()
  def project!(world, required \\ nil) do
    id = "project-world-#{token()}"

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "register-#{id}",
               type: "project.register",
               aggregate_id: "project:#{id}",
               payload: %{project_id: id, path: System.tmp_dir!(), config: %{}}
             })

    if required, do: set_required!(world, id, required)
    id
  end

  @doc """
  Set the project's `required_checks` (a list of `%{"name" => , "kind" => , "workflow" => }`
  entries; `[]` is "no checks configured") or clear it (`nil`: the gate is off), through the
  operator `project.update` command.
  """
  @spec set_required!(world(), String.t(), [map()] | nil) :: :ok
  def set_required!(_world, project_id, required) do
    payload =
      case required do
        nil -> %{project_id: project_id, cleared_settings: ["required_checks"]}
        list -> %{project_id: project_id, required_checks: list}
      end

    assert {:ok, _} =
             CommandGateway.dispatch_operator(%{
               command_id: "update-#{project_id}-#{token()}",
               type: "project.update",
               aggregate_id: "project:#{project_id}",
               payload: payload
             })

    :ok
  end

  @doc """
  A run of `project_id` whose PR is ready at the PR's current head: the real `run.pr.ready`
  command, the gate pending. Unless `findings: :none`, the review-findings record of that head is
  a clean block (so a refusal is about the checks, not `findings_absent`).
  """
  @spec ready_run!(world(), String.t(), keyword()) :: run()
  def ready_run!(world, project_id, opts \\ []) do
    run_id = UniqueIds.unique_run_id("world")
    pr = Agent.get(world, &{&1.pr_url, &1.pr})
    {pr_url, %{head: head, branch: branch, base: base}} = pr
    started = %{run_id: run_id, project_id: project_id, task_id: "task-world"}

    :ok =
      EventStore.append_to_stream("run:#{run_id}", 0, [
        %Elixir.EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])
    run = Map.put(started, :pr_url, pr_url)
    Agent.update(world, &%{&1 | runs: [run | &1.runs]})
    assert {:ok, _} = ForemanServer.PrAssociate.store(run_id, pr_url)

    PrWatchSupport.dispatch!(%{
      type: "run.pr.ready",
      command_id: "ready-#{run_id}",
      aggregate_id: "run:#{run_id}",
      payload: %{
        run_id: run_id,
        project_id: project_id,
        task_id: "task-world",
        pr_url: pr_url,
        branch_name: branch,
        head_sha: head,
        base_branch: base
      }
    })

    if Keyword.get(opts, :findings, :clean) == :clean, do: record_findings!(world, run, head)
    run
  end

  @doc """
  The review-findings record the finalising executor writes (`run.pr.findings`) for `head`:
  a clean block by default; `opts` override payload fields (`:status`, `:findings`,
  `:artifact_path`, ...), see `GateEvidence.record_findings!/3`.
  """
  @spec record_findings!(world(), run(), String.t(), keyword()) :: :ok
  def record_findings!(_world, run, head, opts \\ []),
    do: GateEvidence.record_findings!(run, head, opts)

  @doc """
  Observe the run's PR once through the real observer (`PrWatcher.Observer.observe/2`), as the
  PR monitor does on every poll. With `observed_at:` the checks event the observer builds is
  dispatched with that time as its `observed_at` (everything else is the observer's own batch),
  so a scenario can record evidence of any age.
  """
  @spec observe!(world(), run(), keyword()) :: :ok
  def observe!(world, %{run_id: run_id, pr_url: pr_url}, opts \\ []) do
    fetch = fn url -> PrStatus.fetch(url, command_runner: runner(world)) end

    case Keyword.fetch(opts, :observed_at) do
      :error ->
        assert {:ok, _} = Observer.observe(pr_url, fetch_fun: fetch, auto_fix: false)
        :ok

      {:ok, observed_at} when is_integer(observed_at) ->
        assert {:ok, status} = fetch.(pr_url)
        previous = run_id |> ProjectionStore.pr_watch() |> Enum.find(&(&1.pr_url == pr_url))

        assert {:ok, batch} =
                 ForemanServer.PrObservation.commands(run_id, pr_url, status, previous, nil,
                   policy: Observer.observation_policy(run_id)
                 )

        for command <- batch do
          command = aged(command, observed_at)
          assert {:ok, _} = CommandGateway.dispatch_system(command)
        end

        :ok
    end
  end

  defp aged(%{type: "run.pr.checks", payload: payload} = command, observed_at),
    do: %{command | payload: %{payload | observed_at: observed_at}}

  defp aged(command, _observed_at), do: command

  @doc """
  `merge_approve` through the operator path (`CommandGateway.dispatch_operator/1`: what the HTTP
  controller and the CLI call). The head named defaults to the PR's current head. Returns the
  gateway's answer unchanged.
  """
  @spec approve(world(), run(), keyword()) :: term()
  def approve(world, %{run_id: run_id}, opts \\ []) do
    CommandGateway.dispatch_operator(%{
      command_id: "approve-#{token()}",
      type: "merge_approve",
      aggregate_id: "run:#{run_id}",
      payload: %{
        run_id: run_id,
        approver: "leo",
        approver_identity: @approver,
        head_sha: Keyword.get_lazy(opts, :head_sha, fn -> head(world) end)
      }
    })
  end

  @doc """
  `run.pr.merge` through the operator path (`CommandGateway.dispatch_operator/1`), which merges
  on GitHub only for a gate approved for the PR's head. Returns the gateway's answer unchanged.
  """
  @spec merge(run()) :: term()
  def merge(%{run_id: run_id}) do
    CommandGateway.dispatch_operator(%{
      command_id: "merge-#{token()}",
      type: "run.pr.merge",
      aggregate_id: "run:#{run_id}",
      payload: %{run_id: run_id}
    })
  end

  # -- reads --------------------------------------------------------------------------------

  @doc "The `data` of every event of `type` on the run's stream, oldest first."
  @spec events(run() | String.t(), String.t()) :: [map()]
  def events(%{run_id: run_id}, type), do: events(run_id, type)

  def events(run_id, type) when is_binary(run_id) do
    for %{event_type: ^type, data: data} <- PrWatchSupport.run_events(run_id), do: data
  end

  @doc "True while the run's merge gate waits for an approval."
  @spec gate_pending?(run()) :: boolean()
  def gate_pending?(%{run_id: run_id}),
    do: MergeGate.pending_for_key?(ForemanServer.PrGate.gate_key(run_id, nil))

  @doc "True once the run's merge gate has been approved."
  @spec gate_approved?(run()) :: boolean()
  def gate_approved?(%{run_id: run_id}),
    do: MergeGate.approved?(ForemanServer.PrGate.gate_key(run_id, nil))

  defp token, do: Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
end
