defmodule ForemanServer.TestSupport.EffectWorld do
  @moduledoc false
  # The outside world of the keyed push and PR-create effects (TRD-013), for the
  # tests that drive `AutoPR`, `PhasePR` and `PrCreate` through their injectable
  # command runners and then recover from a simulated crash.
  #
  #   * `fixture!/1` is a real git repository with a bare `origin`, `main` pushed
  #     and a head branch one commit ahead of it that origin does not have;
  #   * `start/0` is a scripted GitHub plus a call log, and `runner/1` the 3-arity
  #     command runner over both: `git` is the real binary, `gh pr list` and
  #     `gh pr create` are answered from the scripted PRs. The effect commands
  #     (`git push`, `gh pr create`) are counted when they reach the world, and a
  #     one-shot crash point (`crash_at/3`) parks the calling process just before or
  #     just after one of them;
  #   * `crash!/4` runs a function in a process, waits for it to park at the crash
  #     point and kills it: the key the effect wrote stays `started`, exactly as
  #     after a node crash;
  #   * `sweep/1` runs the boot sweep with the two real reconcilers, whose `git` and
  #     `gh` go through the same runner (the sweep runs in the caller, so the runner
  #     travels in the process dictionary);
  #   * `start_run!/2`, `status/1`, `block_reason/1` and `recovery_outcomes/1` read
  #     the run a block lands on.

  import ExUnit.Assertions

  alias ForemanServer.{Aggregate, CommandRouter, EventStore, RunControl}
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.Idempotency.Reconcilers.{BranchPush, PrCreate}
  alias ForemanServer.TestSupport.UniqueIds
  alias ForemanServer.Workflow.BootReconciliation

  @runner_key :effect_world_runner

  defmodule Push do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler
    @impl true
    def reconcile(metadata),
      do: BranchPush.reconcile(metadata, command_runner: Process.get(:effect_world_runner))
  end

  defmodule Create do
    @moduledoc false
    @behaviour ForemanServer.Idempotency.Reconciler
    @impl true
    def reconcile(metadata),
      do: PrCreate.reconcile(metadata, command_runner: Process.get(:effect_world_runner))
  end

  @type world :: pid()

  # --- git -------------------------------------------------------------------------

  @spec git!(String.t(), [String.t()]) :: String.t()
  def git!(dir, args) do
    case System.cmd("git", args, cd: dir, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      {output, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}): #{output}")
    end
  end

  @doc """
  A repository with a bare `origin`, `main` pushed, and `head` one commit ahead of
  `main` that origin does not have. `repo` is left on `main`.
  """
  @spec fixture!(String.t()) :: %{
          origin: String.t(),
          repo: String.t(),
          head: String.t(),
          base: String.t()
        }
  def fixture!(head) do
    repo = scratch("repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-b", "main"])
    configure!(repo)
    commit!(repo, "base.txt", "base")
    adopt!(repo, head)
  end

  @doc """
  Give `repo` (a repository on `main` with a commit) a bare `origin` with `main`
  pushed, and a `head` branch one commit ahead of `main` that origin does not have.
  """
  @spec adopt!(String.t(), String.t()) :: map()
  def adopt!(repo, head) do
    origin = scratch("origin") <> ".git"
    git!(repo, ["init", "--bare", "-b", "main", origin])
    git!(repo, ["remote", "add", "origin", origin])
    git!(repo, ["push", "-u", "origin", "main"])
    git!(repo, ["checkout", "-b", head])
    commit!(repo, "work.txt", "work")
    git!(repo, ["checkout", "main"])

    %{origin: origin, repo: repo, head: head, base: "main"}
  end

  defp scratch(label) do
    path =
      Path.join(System.tmp_dir!(), "effect-world-#{label}-#{System.unique_integer([:positive])}")

    ExUnit.Callbacks.on_exit(fn -> File.rm_rf(path) end)
    path
  end

  @doc "Another local commit on the head branch (`repo` stays on `main`); returns the new tip."
  @spec commit_on_head!(map(), String.t()) :: String.t()
  def commit_on_head!(%{repo: repo, head: head} = fx, name) do
    git!(repo, ["checkout", head])
    commit!(repo, name, name)
    git!(repo, ["checkout", "main"])
    local_tip(fx)
  end

  @doc "The local tip of the fixture's head branch."
  @spec local_tip(map()) :: String.t()
  def local_tip(%{repo: repo, head: head}), do: git!(repo, ["rev-parse", "refs/heads/" <> head])

  @doc "The head branch as origin has it, or `nil`."
  @spec remote_tip(map()) :: String.t() | nil
  def remote_tip(%{origin: origin, head: head}) do
    case System.cmd("git", ["--git-dir", origin, "rev-parse", "--verify", "refs/heads/" <> head],
           stderr_to_stdout: true
         ) do
      {output, 0} -> String.trim(output)
      {_output, _code} -> nil
    end
  end

  @doc "Push the head branch so origin already holds the local tip."
  @spec publish!(map()) :: :ok
  def publish!(%{repo: repo, head: head}) do
    git!(repo, ["push", "origin", head])
    :ok
  end

  @doc """
  Another commit lands on origin's head branch from a second clone. Returns its
  SHA, which is neither the fixture's local tip nor what origin held before.
  """
  @spec land_other_commit!(map()) :: String.t()
  def land_other_commit!(%{origin: origin, head: head}) do
    other = scratch("other")
    git!(System.tmp_dir!(), ["clone", origin, other])
    configure!(other)

    case remote_tip(%{origin: origin, head: head}) do
      nil -> git!(other, ["checkout", "-b", head])
      _tip -> git!(other, ["checkout", head])
    end

    commit!(other, "someone-else-#{System.unique_integer([:positive])}.txt", "other")
    git!(other, ["push", "origin", head])
    git!(other, ["rev-parse", "HEAD"])
  end

  @doc "Point `origin` somewhere that does not exist: its refs cannot be read."
  @spec break_origin!(map()) :: :ok
  def break_origin!(%{repo: repo}) do
    git!(repo, ["remote", "set-url", "origin", scratch("gone") <> ".git"])
    :ok
  end

  defp configure!(repo) do
    git!(repo, ["config", "user.email", "test@example.com"])
    git!(repo, ["config", "user.name", "Test"])
    git!(repo, ["config", "commit.gpgsign", "false"])
  end

  defp commit!(repo, file, content) do
    File.write!(Path.join(repo, file), content <> "\n")
    git!(repo, ["add", "."])
    git!(repo, ["commit", "-m", content])
  end

  # --- the scripted world ----------------------------------------------------------

  @doc "A scripted GitHub and call log. `owner` (the test) is told when a crash point is reached."
  @spec start() :: world()
  def start do
    owner = self()

    {:ok, world} =
      Agent.start_link(fn ->
        %{
          owner: owner,
          prs: [],
          calls: [],
          crash: nil,
          list_error?: false,
          executed: %{push: 0, create: 0}
        }
      end)

    world
  end

  @doc "A PR already on GitHub (`state`: `\"OPEN\"`, `\"CLOSED\"` or `\"MERGED\"`)."
  @spec add_pr!(world(), String.t(), String.t(), String.t()) :: String.t()
  def add_pr!(world, head, base, state \\ "OPEN") do
    Agent.get_and_update(world, fn state_map ->
      number = length(state_map.prs) + 1
      url = "https://github.com/acme/widgets/pull/#{number}"
      pr = %{"number" => number, "state" => state, "url" => url, "head" => head, "base" => base}
      {url, %{state_map | prs: state_map.prs ++ [pr]}}
    end)
  end

  @doc "From now on `gh pr list` fails: GitHub cannot be queried."
  @spec fail_gh_list!(world()) :: :ok
  def fail_gh_list!(world), do: Agent.update(world, &%{&1 | list_error?: true})

  @doc "Every PR on GitHub is merged now (merged before recovery ran)."
  @spec merge_prs!(world()) :: :ok
  def merge_prs!(world) do
    Agent.update(world, fn state ->
      %{state | prs: Enum.map(state.prs, &Map.put(&1, "state", "MERGED"))}
    end)
  end

  @doc "How many times `effect` (`:push` or `:create`) reached the world."
  @spec executed(world(), :push | :create) :: non_neg_integer()
  def executed(world, effect), do: Agent.get(world, & &1.executed[effect])

  @doc "Every command the runner received, oldest first, as `{executable, args, opts}`."
  @spec calls(world()) :: [{String.t(), [String.t()], keyword()}]
  def calls(world), do: Agent.get(world, &Enum.reverse(&1.calls))

  @doc "The PRs on GitHub."
  @spec prs(world()) :: [map()]
  def prs(world), do: Agent.get(world, & &1.prs)

  @doc "Park the next `effect` (`:push` or `:create`) `:before` or `:after` it reaches the world."
  @spec crash_at(world(), :push | :create, :before | :after) :: :ok
  def crash_at(world, effect, side) when effect in [:push, :create] and side in [:before, :after],
    do: Agent.update(world, &%{&1 | crash: {effect, side}})

  @doc "The 3-arity command runner over `world`."
  @spec runner(world()) :: (String.t(), [String.t()], keyword() -> {String.t(), integer()})
  def runner(world), do: fn exe, args, opts -> handle(world, exe, args, opts) end

  defp handle(world, exe, args, opts) do
    Agent.update(world, &%{&1 | calls: [{exe, args, opts} | &1.calls]})
    run(world, exe, args, opts)
  end

  defp run(world, "git", ["push" | _] = args, opts) do
    park(world, :push, :before)
    result = System.cmd("git", args, opts)
    Agent.update(world, &update_in(&1.executed.push, fn n -> n + 1 end))
    park(world, :push, :after)
    result
  end

  defp run(_world, "git", args, opts), do: System.cmd("git", args, opts)

  defp run(world, "gh", ["pr", "create" | _] = args, _opts) do
    park(world, :create, :before)
    url = add_pr!(world, flag(args, "--head"), flag(args, "--base"))
    Agent.update(world, &update_in(&1.executed.create, fn n -> n + 1 end))
    park(world, :create, :after)
    {url <> "\n", 0}
  end

  defp run(world, "gh", ["pr", "list" | _] = args, _opts) do
    Agent.get(world, fn
      %{list_error?: true} -> {"error connecting to api.github.com\n", 1}
      state -> {list(state.prs, args), 0}
    end)
  end

  defp list(prs, args) do
    states =
      case flag(args, "--state") do
        "all" -> ["OPEN", "CLOSED", "MERGED"]
        "closed" -> ["CLOSED"]
        "merged" -> ["MERGED"]
        # `gh pr list` lists only open PRs unless told otherwise.
        _ -> ["OPEN"]
      end

    fields = (flag(args, "--json") || "url,number,state") |> String.split(",")

    prs
    |> Enum.filter(&(&1["state"] in states))
    |> Enum.filter(&(&1["head"] == flag(args, "--head") and &1["base"] == flag(args, "--base")))
    |> Enum.take(limit(flag(args, "--limit")))
    |> Enum.map(&Map.take(&1, fields))
    |> Jason.encode!()
  end

  defp limit(nil), do: 30
  defp limit(n), do: String.to_integer(n)

  defp flag(args, name) do
    case Enum.drop_while(args, &(&1 != name)) do
      [^name, value | _] -> value
      _ -> nil
    end
  end

  # The crash point: tell the test, then never come back. The test kills the process.
  defp park(world, effect, side) do
    crash =
      Agent.get_and_update(world, fn
        %{crash: {^effect, ^side}} = state -> {state.owner, %{state | crash: nil}}
        state -> {nil, state}
      end)

    if crash do
      send(crash, {:effect_world_parked, effect, side, self()})
      Process.sleep(:infinity)
    end
  end

  @doc """
  Run `fun` in a process that parks at `effect`/`side` (`crash_at/3`), then kill it.
  The effect's key is left `started`.
  """
  @spec crash!(world(), :push | :create, :before | :after, (-> any())) :: :ok
  def crash!(world, effect, side, fun) do
    crash_at(world, effect, side)
    {pid, ref} = spawn_monitor(fun)

    receive do
      {:effect_world_parked, ^effect, ^side, ^pid} ->
        Process.exit(pid, :kill)
        assert_receive {:DOWN, ^ref, :process, ^pid, :killed}, 5_000
        :ok

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("the process ended (#{inspect(reason)}) without reaching #{effect} #{side}")
    after
      15_000 -> flunk("the process never reached #{effect} #{side}")
    end
  end

  # --- recovery ---------------------------------------------------------------------

  @doc "The boot sweep, with the real reconcilers over `world`'s runner."
  @spec sweep(world()) :: :ok
  def sweep(world) do
    Process.put(@runner_key, runner(world))

    BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end,
      classes: %{"branch_push" => Push, "pr_create" => Create}
    )
  end

  # --- the run a block lands on -----------------------------------------------------

  @doc "Register `project_id` at `path` (call once, from `setup_all`)."
  @spec register_project!(String.t(), String.t()) :: :ok
  def register_project!(project_id, path) do
    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        payload: %{project_id: project_id, path: path},
        aggregate_id: "project:#{project_id}"
      })

    :ok
  end

  @doc "A started, non-terminal run on `project_id` with a unique id."
  @spec start_run!(String.t(), String.t()) :: String.t()
  def start_run!(project_id, label) do
    run_id = UniqueIds.unique_run_id(label)

    {:ok, _} =
      CommandRouter.dispatch_run_start(project_id, %{
        run_id: run_id,
        task_id: "task-#{run_id}",
        workflow_snapshot: %{phases: [], attempt: 1}
      })

    ExUnit.Callbacks.on_exit(fn -> RunControl.clear(run_id) end)
    run_id
  end

  @spec status(String.t()) :: String.t()
  def status(run_id), do: Run |> Aggregate.load("run:#{run_id}") |> elem(0) |> Map.fetch!(:status)

  @doc "The reason of the run's `RunBlocked`, or `nil` when it was not blocked."
  @spec block_reason(String.t()) :: String.t() | nil
  def block_reason(run_id) do
    case Enum.find(events(run_id), &(&1.event_type == "RunBlocked")) do
      nil -> nil
      event -> Aggregate.get(event.payload, :reason)
    end
  end

  @doc "The `outcome` of every `RunRecoveryAttempted` on the run, oldest first."
  @spec recovery_outcomes(String.t()) :: [String.t()]
  def recovery_outcomes(run_id) do
    for %{event_type: "RunRecoveryAttempted", payload: payload} <- events(run_id),
        do: Aggregate.get(payload, :outcome)
  end

  defp events(run_id) do
    {:ok, recorded} = EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)

    for event <- recorded do
      %{event_type: Aggregate.event_type(event), payload: Aggregate.event_payload(event)}
    end
  end
end
