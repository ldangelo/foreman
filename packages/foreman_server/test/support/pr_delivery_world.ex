defmodule ForemanServer.TestSupport.PrDeliveryWorld do
  @moduledoc """
  The one world the four files of the Phase 1 adversarial suite (TRD-025, 037, 032, 040) share.

  One world is a scripted GitHub holding pull requests (a primary one and any number added) plus a
  call log. Everything a scenario asks is answered by the REAL production code reading that
  GitHub: `CommandGateway`, `Aggregates.Run`, `PrEvidence`, `PrObservation`,
  `PrWatcher.Observer`, `PrStatus`, `GitHub.PrMerge` and the projection. Only the `gh` binary is
  scripted, through the seam production already has (`RunPrMerge.set_command_runner/1`, a
  `:persistent_term` that `RunPrMerge.runner_opts/0` hands to `PrStatus.fetch/2` and
  `GitHub.PrMerge.merge/3`). A test using this world is `async: false`.

  ## Real and scripted

    * REAL: the event store, every aggregate, the gateway (`dispatch_operator/1`: the path the
      HTTP controller and the CLI take), the evaluator, the observer, the projection, the
      `required_checks` setting (written through the operator `project.update` command) and the
      merge gate.
    * SCRIPTED: `gh pr view <url> --json <fields>` (the PR record; ONLY the requested fields are
      returned and an unknown one fails the call like gh does), `gh pr merge <url> --squash
      --match-head-commit <sha>` (refused unless the sha is the live head of an open PR, so a
      push after the approval cannot be merged) and `gh pr list --head/--base/--state/--json`.
      Nothing else: a call the world was not scripted for (another `gh` command, `git`, a PR it
      does not hold) is answered with exit code 1 and the text `unscripted call: ...`, recorded,
      and makes the test fail at its end naming the call (`take_unscripted!/1` hands the list to
      a test that provokes one on purpose).

  ## A world handle

  Every function that takes a `world` takes the pid `start!/1` returns, which means the PRIMARY
  PR, or a handle `pr(world, url)` for another PR of the same world: `push!(pr(world, url),
  "sha")`. `head/1`, `pr_url/1`, the mutators and `pr_state/1` honour the handle; the call log,
  `script!/3`, `runner/1` and the unscripted list are the world's.

  ## Helpers

  The world:

    * `start!/1` - the world, the `gh` runner installed, cleanup registered with `on_exit`
    * `pr_url/1`, `head/1`, `pr_state/1`, `calls/1`, `view_calls/1`, `merge_calls/1`,
      `take_unscripted!/1`
    * `runner/1` - the 3-arity `(cmd, args, opts)` runner over the world (what `start!/1` installs)
    * `script!/3` - register a handler for further calls (`(world, args -> {:reply, {out, code}} |
      :pass)`); the first handler that answers wins and the core handlers (`pr view`, `pr merge`,
      `pr list`) are first, so a scenario adds calls without changing what they answer

  The PRs (what `gh pr view` shows):

    * `add_pr!/2`, `pr/2` - another PR (`branch:`, `head:`, `base:`, `state:`,
      `cross_repository:`), and the handle for it
    * `check_run/2`, `status_context/2` - rollup items in GitHub's JSON shape (`CheckRun` with
      `workflowName`, `status`, `conclusion`, `startedAt`, `completedAt`; `StatusContext` with
      `context`, `state`)
    * `set_rollup!/2`, `add_check!/2` - replace or extend the rollup
    * `push!/3` - a new head: the PR has `head` and an empty rollup
    * `complete_check!/4`, `rerun_check!/3` - move one check run to completed, or back to running
    * `truncate_rollup!/2` - append passing filler checks until GitHub's list is cut
    * `set_raw!/2` - fields of a `gh pr view` payload used verbatim in place of the computed ones
      (a recorded real payload)

  Projects, runs and the gate:

    * `project!/2` - a registered project (operator `project.register`); `set_required!/3` sets or
      clears its `required_checks` through the operator `project.update` command
    * `ready_run!/3` - a run whose PR is ready at the PR's current head (the gate pending), with a
      clean review-findings record for that head unless told otherwise (`findings: :none`); `pr:
      url` readies it for another PR of the world
    * `start_run!/2` - a run with NO PR (a run that has not opened one)
    * `finish_runs!/1` - complete every run of the world that is not terminal yet (what the
      cleanup does at the end of the test; a run the test completed is left alone)
    * `record_findings!/4` - the review-findings record of the finalising executor for a head
    * `observe!/3` - one observation of the PR through the real observer; with `observed_at:` the
      checks event carries that time (evidence of any age, without a clock seam)
    * `approve/3` - `merge_approve` through `CommandGateway.dispatch_operator/1` (`head_sha:`,
      `approver:`, `identity:`); `merge/1` - `run.pr.merge`; `operator/3` - any operator command
      (always `dispatch_operator/1`, never `dispatch_system/1`)

  The runs a world readied or started are completed when the test ends (unless the test
  completed them: a terminal run is left alone), before the unscripted-call check, so a failed
  assertion never leaves a non-terminal run in the projection.

  Reads for assertions: `events/2`, `gate_pending?/1`, `gate_approved?/1`.
  """

  import ExUnit.Assertions

  alias ForemanServer.{CommandGateway, EventStore, ProjectionStore, RunPrMerge}
  alias ForemanServer.PrWatcher.Observer
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.TestSupport.{GateEvidence, PrWatchSupport, UniqueIds}
  alias ForemanServer.Workflow.MergeGate

  @type world :: pid() | {pid(), String.t()}
  @type run :: %{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t() | nil
        }

  @zero_time "0001-01-01T00:00:00Z"
  @approver "github:ldangelo"

  # -- the world ----------------------------------------------------------------------------

  @doc """
  Start a world with one open PR (`head: "head-one"`, base `main`, an empty rollup, one changed
  file) and install its `gh` runner. Options: `:head`. The runner is removed, the runs the world
  readied are completed and an unscripted call fails the test when the test ends.
  """
  @spec start!(keyword()) :: pid()
  def start!(opts \\ []) do
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    pr_url = "https://github.com/acme/world-#{token}/pull/1"

    state = %{
      pr_url: pr_url,
      token: token,
      prs: %{pr_url => new_pr(1, Keyword.get(opts, :head, "head-one"), [])},
      calls: [],
      unscripted: [],
      handlers: [
        {:pr_view, &view_handler/2},
        {:pr_merge, &merge_handler/2},
        {:pr_list, &list_handler/2}
      ],
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

  defp new_pr(number, head, opts) do
    %{
      number: number,
      head: head,
      base: Keyword.get(opts, :base, "main"),
      branch: Keyword.get(opts, :branch, "foreman/task-world/run"),
      state: Keyword.get(opts, :state, "OPEN"),
      cross_repository: Keyword.get(opts, :cross_repository, false),
      mergeable: "MERGEABLE",
      merge_state: "CLEAN",
      review_decision: "",
      rollup: [],
      files: [%{"path" => "lib/a.ex", "additions" => 3, "deletions" => 1}],
      changed_files: 1,
      additions: 3,
      deletions: 1,
      comments: [],
      reviews: [],
      raw: %{}
    }
  end

  @doc """
  Complete every run the world readied or started that is not terminal yet. The cleanup of
  `start!/1` calls it; a scenario that wants the runs ended earlier may too.
  """
  @spec finish_runs!(world()) :: :ok
  def finish_runs!(world) do
    for run <- Agent.get(agent(world), & &1.runs), do: end_run(run)
    :ok
  end

  # A run the test already completed is terminal: leave it alone.
  defp end_run(%{run_id: run_id, project_id: project_id}) do
    case ProjectionStore.run(run_id) do
      %{terminal?: true} -> :ok
      _non_terminal -> PrWatchSupport.complete_run!(run_id, project_id)
    end
  end

  defp agent({world, url}) when is_pid(world) and is_binary(url), do: world
  defp agent(world) when is_pid(world), do: world

  defp url_of({_world, url}), do: url
  defp url_of(world), do: Agent.get(world, & &1.pr_url)

  @doc "The handle for another PR of the world (one `add_pr!/2` returned the URL of)."
  @spec pr(world(), String.t()) :: {pid(), String.t()}
  def pr(world, url) when is_binary(url) do
    world = agent(world)
    assert Agent.get(world, &Map.has_key?(&1.prs, url)), "the world holds no PR #{url}"
    {world, url}
  end

  @doc """
  Another open PR on the world's GitHub; returns its URL. Options: `:head` (a fresh sha),
  `:branch` (`headRefName`), `:base`, `:state` (`"OPEN"`, `"CLOSED"`, `"MERGED"`),
  `:cross_repository` (a fork's PR). The URL is the repository's next pull number.
  """
  @spec add_pr!(world(), keyword()) :: String.t()
  def add_pr!(world, opts \\ []) do
    Agent.get_and_update(agent(world), fn state ->
      number = map_size(state.prs) + 1
      url = "https://github.com/acme/world-#{state.token}/pull/#{number}"
      head = Keyword.get_lazy(opts, :head, fn -> "head-pr-#{number}" end)
      branch = Keyword.get(opts, :branch, "foreman/task-world/run-#{number}")
      pr = new_pr(number, head, Keyword.put(opts, :branch, branch))
      {url, %{state | prs: Map.put(state.prs, url, pr)}}
    end)
  end

  @doc "The PR's URL (the primary's for a world, its own for a handle)."
  @spec pr_url(world()) :: String.t()
  def pr_url(world), do: url_of(world)

  @doc "The PR's head SHA as GitHub shows it now."
  @spec head(world()) :: String.t()
  def head(world), do: read_pr(world).head

  @doc "The PR's state as GitHub shows it now (`\"OPEN\"`, `\"CLOSED\"`, `\"MERGED\"`)."
  @spec pr_state(world()) :: String.t()
  def pr_state(world), do: read_pr(world).state

  defp read_pr(world) do
    url = url_of(world)
    Agent.get(agent(world), & &1.prs[url])
  end

  @doc "Every call that reached the world, oldest first, as `{cmd, args}`."
  @spec calls(world()) :: [{String.t(), [String.t()]}]
  def calls(world), do: world |> agent() |> Agent.get(& &1.calls) |> Enum.reverse()

  @doc "The `gh pr view` calls, oldest first."
  @spec view_calls(world()) :: [[String.t()]]
  def view_calls(world), do: for({"gh", ["pr", "view" | _] = args} <- calls(world), do: args)

  @doc "The `gh pr merge` calls, oldest first (answered or refused)."
  @spec merge_calls(world()) :: [[String.t()]]
  def merge_calls(world), do: for({"gh", ["pr", "merge" | _] = args} <- calls(world), do: args)

  @doc """
  The unscripted calls so far, as text; the list is emptied, so a test that provokes one on
  purpose (the harness self-check) is not failed for it at the end.
  """
  @spec take_unscripted!(world()) :: [String.t()]
  def take_unscripted!(world) do
    Agent.get_and_update(agent(world), fn state ->
      {Enum.reverse(state.unscripted), %{state | unscripted: []}}
    end)
  end

  @doc "Register `fun` (`(world, args -> {:reply, {output, exit_code}} | :pass)`) for more `gh` calls."
  @spec script!(
          world(),
          atom(),
          (pid(), [String.t()] -> {:reply, {String.t(), integer()}} | :pass)
        ) :: :ok
  def script!(world, name, fun) when is_atom(name) and is_function(fun, 2),
    do: Agent.update(agent(world), &%{&1 | handlers: &1.handlers ++ [{name, fun}]})

  @doc "The 3-arity `(cmd, args, opts)` runner over the world."
  @spec runner(world()) :: (String.t(), [String.t()], keyword() -> {String.t(), integer()})
  def runner(world) do
    world = agent(world)
    fn cmd, args, opts -> handle(world, cmd, args, opts) end
  end

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

  # -- the scripted gh ----------------------------------------------------------------------

  defp view_handler(world, ["pr", "view", url, "--json", fields]) do
    case Agent.get(world, & &1.prs[url]) do
      nil -> :pass
      pr -> {:reply, view_reply(pr, String.split(fields, ","))}
    end
  end

  defp view_handler(_world, _args), do: :pass

  # Only the requested fields, like gh; a field the PR record cannot answer fails the call.
  defp view_reply(pr, requested) do
    payload = Map.merge(view_payload(pr), pr.raw)

    case Enum.reject(requested, &Map.has_key?(payload, &1)) do
      [] -> {Jason.encode!(Map.take(payload, requested)), 0}
      [unknown | _] -> {"Unknown JSON field: #{inspect(unknown)}", 1}
    end
  end

  defp view_payload(pr) do
    %{
      "state" => pr.state,
      "mergeable" => pr.mergeable,
      "headRefOid" => pr.head,
      "headRefName" => pr.branch,
      "baseRefName" => pr.base,
      "statusCheckRollup" => pr.rollup,
      "reviewDecision" => pr.review_decision,
      "reviews" => pr.reviews,
      "comments" => pr.comments,
      "mergeStateStatus" => pr.merge_state,
      "files" => pr.files,
      "changedFiles" => pr.changed_files,
      "additions" => pr.additions,
      "deletions" => pr.deletions
    }
  end

  # `gh pr merge <url> --squash --match-head-commit <sha>`: GitHub refuses a merge whose pinned
  # commit is not the head of the PR, and a merge of a PR that is not open. A merge without the
  # pin is not scripted: production must always pin.
  defp merge_handler(world, ["pr", "merge", url | flags]) do
    with %{} = pr <- Agent.get(world, & &1.prs[url]),
         [sha] <- flag_value(flags, "--match-head-commit") do
      cond do
        pr.state != "OPEN" ->
          {:reply, {"Pull request #{url} is not mergeable: the pull request is #{pr.state}", 1}}

        pr.head != sha ->
          {:reply, {"Head branch was modified. Review and try the merge again.", 1}}

        true ->
          Agent.update(world, &put_in(&1.prs[url].state, "MERGED"))
          {:reply, {"", 0}}
      end
    else
      _not_scripted -> :pass
    end
  end

  defp merge_handler(_world, _args), do: :pass

  # `gh pr list --head <branch> --base <branch> --state open|closed|merged|all --json <fields>
  # --limit <n>`. As the real gh, `--state closed` lists the merged ones too.
  @list_fields ~w(url number state headRefOid headRefName baseRefName isCrossRepository)
  defp list_handler(world, ["pr", "list" | flags]) do
    fields =
      String.split(List.first(flag_value(flags, "--json") || []) || "url,number,state", ",")

    case Enum.reject(fields, &(&1 in @list_fields)) do
      [unknown | _] ->
        {:reply, {"Unknown JSON field: #{inspect(unknown)}", 1}}

      [] ->
        states =
          case flag_value(flags, "--state") do
            ["all"] -> ["OPEN", "CLOSED", "MERGED"]
            ["closed"] -> ["CLOSED", "MERGED"]
            ["merged"] -> ["MERGED"]
            _open -> ["OPEN"]
          end

        head = flag_value(flags, "--head")
        base = flag_value(flags, "--base")
        limit = String.to_integer(List.first(flag_value(flags, "--limit") || []) || "30")

        listed =
          world
          |> Agent.get(& &1.prs)
          |> Enum.sort_by(fn {_url, pr} -> pr.number end)
          |> Enum.filter(fn {_url, pr} ->
            pr.state in states and (is_nil(head) or [pr.branch] == head) and
              (is_nil(base) or [pr.base] == base)
          end)
          |> Enum.take(limit)
          |> Enum.map(fn {url, pr} ->
            Map.take(
              %{
                "url" => url,
                "number" => pr.number,
                "state" => pr.state,
                "headRefOid" => pr.head,
                "headRefName" => pr.branch,
                "baseRefName" => pr.base,
                "isCrossRepository" => pr.cross_repository
              },
              fields
            )
          end)

        {:reply, {Jason.encode!(listed), 0}}
    end
  end

  defp list_handler(_world, _args), do: :pass

  defp flag_value(flags, name) do
    case Enum.drop_while(flags, &(&1 != name)) do
      [^name, value | _] -> [value]
      _absent -> nil
    end
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
  yet).
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

  @doc """
  Use `fields` (a map of `gh pr view` JSON field names to values, for example a recorded real
  payload) verbatim in place of the PR record's own answer for those fields.
  """
  @spec set_raw!(world(), map()) :: :ok
  def set_raw!(world, %{} = fields),
    do: update_pr!(world, &%{&1 | raw: Map.merge(&1.raw, fields)})

  defp update_pr!(world, fun) do
    url = url_of(world)
    Agent.update(agent(world), fn state -> %{state | prs: Map.update!(state.prs, url, fun)} end)
  end

  defp update_check!(world, name, fun) do
    url = url_of(world)

    found? =
      Agent.get_and_update(agent(world), fn state ->
        rollup = state.prs[url].rollup
        own? = &(&1["__typename"] == "CheckRun" and &1["name"] == name)

        if Enum.any?(rollup, own?) do
          updated = Enum.map(rollup, fn item -> if own?.(item), do: fun.(item), else: item end)
          {true, put_in(state.prs[url].rollup, updated)}
        else
          {false, state}
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
             operator("project:#{id}", "project.register", %{
               project_id: id,
               path: System.tmp_dir!(),
               config: %{}
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

    assert {:ok, _} = operator("project:#{project_id}", "project.update", payload)
    :ok
  end

  @doc """
  A run of `project_id` that has not opened a PR (`RunStarted` only, `pr_url: nil`). It is
  completed when the test ends unless the test did.
  """
  @spec start_run!(world(), String.t()) :: run()
  def start_run!(world, project_id) do
    run_id = UniqueIds.unique_run_id("world")
    started = %{run_id: run_id, project_id: project_id, task_id: "task-world"}

    :ok =
      EventStore.append_to_stream("run:#{run_id}", 0, [
        %Elixir.EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok = ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])
    run = Map.put(started, :pr_url, nil)
    Agent.update(agent(world), &%{&1 | runs: [run | &1.runs]})
    run
  end

  @doc """
  A run of `project_id` whose PR is ready at the PR's current head: the PR associated and the real
  `run.pr.ready` command, the gate pending. Options: `:pr` (the URL of another PR of the world,
  default the primary); unless `findings: :none`, the review-findings record of that head is a
  clean block (so a refusal is about the checks, not `findings_absent`).
  """
  @spec ready_run!(world(), String.t(), keyword()) :: run()
  def ready_run!(world, project_id, opts \\ []) do
    pr_url = Keyword.get_lazy(opts, :pr, fn -> url_of(world) end)
    %{head: head, branch: branch, base: base} = read_pr(pr(world, pr_url))
    run = %{start_run!(world, project_id) | pr_url: pr_url}
    run_id = run.run_id

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
  controller and the CLI call). Options: `:head_sha` (default: the run's PR head now),
  `:approver` ("leo") and `:identity` (the approver's identity, "github:ldangelo"). Returns the
  gateway's answer unchanged.
  """
  @spec approve(world(), run(), keyword()) :: term()
  def approve(world, %{run_id: run_id, pr_url: pr_url}, opts \\ []) do
    operator("run:#{run_id}", "merge_approve", %{
      run_id: run_id,
      approver: Keyword.get(opts, :approver, "leo"),
      approver_identity: Keyword.get(opts, :identity, @approver),
      head_sha: Keyword.get_lazy(opts, :head_sha, fn -> head(pr(world, pr_url)) end)
    })
  end

  @doc """
  `run.pr.merge` through the operator path (`CommandGateway.dispatch_operator/1`), which merges
  on GitHub only for a gate approved for the PR's head. Returns the gateway's answer unchanged.
  """
  @spec merge(run()) :: term()
  def merge(%{run_id: run_id}), do: operator("run:#{run_id}", "run.pr.merge", %{run_id: run_id})

  @doc """
  Any command through the operator path (`CommandGateway.dispatch_operator/1`, never
  `dispatch_system/1`): the envelope a client POSTs to `/api/commands`. Returns the answer
  unchanged.
  """
  @spec operator(String.t(), String.t(), map()) :: term()
  def operator(aggregate_id, type, payload) do
    CommandGateway.dispatch_operator(%{
      command_id: "#{type}-#{token()}",
      type: type,
      aggregate_id: aggregate_id,
      payload: payload
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
