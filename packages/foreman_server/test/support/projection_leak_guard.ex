defmodule ForemanServer.TestSupport.ProjectionLeakGuard do
  @moduledoc """
  Fails the suite when a test module ends with a non-terminal run, whose id is a hand-written
  literal, still in the process-wide `ForemanServer.ProjectionStore` (foreman-fhe9o, the class
  behind foreman-b8qjy).

  A run left in the store is read back by id from every later test. Ids from
  `ForemanServer.TestSupport.UniqueIds.unique_run_id/1` cannot be shared, but a typed literal
  (`"run-1"`) is shared with every other test that types it, so the victim passes or fails with
  the seed's module order. The report names the module after which the run was still there and
  the files that type its id.

  ## What counts

    * *fixed id*: the run id appears verbatim, between double quotes, somewhere under `test/`.
      Generated ids (`"run-\#{n}"`, UUIDs, random tokens) never do, so nothing guesses at id shapes.
    * *left behind*: the run is not terminal when the module has finished, i.e. after its tests
      and every `on_exit`. Runs a module resets away (`ForemanServer.TestSupport.ProjectionStoreReset`)
      do not count.
    * only `async: false` modules are judged: concurrent modules legitimately have runs in flight
      at each other's boundaries.

  ## Why a clean module is never accused

  ExUnit tells a formatter about `{:module_finished, _}` asynchronously, so this process may read
  the store after the runner has started the next module. The runner casts `{:module_started, _}`
  *before* any code of that module runs, and a message to a local process is queued before
  `cast/2` returns. So when this process's mailbox is still empty after it has read the store,
  nothing of a later module can have run before the read, and the read is exactly what the finished
  module left. When it is not empty the module is not judged: a formatter that lags misses a
  boundary, it never blames the next module's runs on the previous one. That is also why a polluter
  can slip through a run that a later run of the same seed catches, and why `verdict!/1` fails a
  suite that judged none of its modules.

  ## Wiring

  The `test` alias in `mix.exs` passes this module as a `--formatter`: ExUnit then tells it
  `{:module_finished, _}` after every module. (Configuring it from `test_helper.exs` would not do:
  Mix re-applies a `--formatter` given on the command line after the helper has run and drops
  the helper's.) `install!/0`, called from `test_helper.exs`, loads the fixed ids and registers an
  `ExUnit.after_suite/1` callback that raises when a run was left behind, when the formatter never
  saw the end of the suite (it was not registered, or it crashed, so nothing was judged), or when
  it judged none of a suite's modules (it is inert). A formatter runs beside the runner, not
  inside a test, so the guilty test itself cannot be failed.

  Fix a reported id by minting it with `UniqueIds.unique_run_id/1`, or by resetting the store in
  the module's `on_exit`.
  """

  use GenServer

  @sources "test/**/*.{ex,exs}"
  @fixed_ids_key {__MODULE__, :fixed_ids}
  @result_key {__MODULE__, :result}
  # A suite with at least this many judgeable modules that judged none is not a busy formatter,
  # it is a broken one.
  @inert_after 10

  @type leak :: %{run_id: String.t(), module: String.t()}
  @type result :: %{leaks: [leak()], judged: non_neg_integer(), sync: non_neg_integer()}

  @doc "Loads the fixed ids and arms the verdict; call once from `test_helper.exs`."
  @spec install!() :: :ok
  def install!() do
    sources = Path.wildcard(@sources)

    if sources == [] do
      raise "ProjectionLeakGuard found no test sources under test/ (cwd #{File.cwd!()}), " <>
              "so it could never flag anything"
    end

    :persistent_term.put(@fixed_ids_key, sources |> Enum.map(&File.read!/1) |> fixed_ids())
    :persistent_term.erase(@result_key)

    ExUnit.after_suite(fn _stats -> verdict!() end)
  end

  @doc """
  Raises when the suite left a fixed-id run behind (run from `ExUnit.after_suite/1`); otherwise
  prints one line saying how many modules were judged, so a guard that is off cannot pass for
  one that is clean.
  """
  @spec verdict!(result() | nil) :: :ok
  def verdict!(result \\ :persistent_term.get(@result_key, nil)) do
    case result do
      nil ->
        Mix.raise("ProjectionLeakGuard never saw the end of the suite; nothing was judged")

      %{leaks: [], judged: 0, sync: sync} when sync >= @inert_after ->
        Mix.raise(
          "ProjectionLeakGuard judged none of #{sync} modules: the mailbox was never empty"
        )

      %{leaks: [], judged: judged, sync: sync} ->
        IO.puts("ProjectionLeakGuard: judged #{judged} of #{sync} modules, no run left behind")

      %{leaks: leaks} ->
        sources = Path.wildcard(@sources)
        Mix.raise(message(leaks, fn run_id -> typed_in(run_id, sources) end))
    end
  end

  @doc false
  @spec message([leak()], (String.t() -> [String.t()])) :: String.t()
  def message(leaks, typed_in_fun) do
    lines =
      leaks
      |> Enum.group_by(& &1.run_id, & &1.module)
      |> Enum.sort()
      |> Enum.map(fn {run_id, modules} ->
        [first | later] = Enum.uniq(modules)

        "  #{inspect(run_id)}: still in the store after #{first}#{and_after(later)}; " <>
          "typed in #{files(typed_in_fun.(run_id))}"
      end)

    """
    Test modules left non-terminal runs with hand-written ids in the shared ProjectionStore:
    #{Enum.join(lines, "\n")}
    A later test that reads the same id sees them (foreman-fhe9o). Mint the id with
    ForemanServer.TestSupport.UniqueIds.unique_run_id/1, or reset the store in on_exit with
    ForemanServer.TestSupport.ProjectionStoreReset.reset!/0.
    """
  end

  defp and_after([]), do: ""
  defp and_after(later), do: " (and after #{length(later)} later module(s))"

  defp files([]), do: "no test file (a support module?)"
  defp files(paths), do: paths |> Enum.take(5) |> Enum.join(", ")

  @doc "The files among `paths` that type `run_id` between double quotes."
  @spec typed_in(String.t(), [Path.t()]) :: [Path.t()]
  def typed_in(run_id, paths) do
    quoted = ~s("#{run_id}")
    Enum.filter(paths, &(&1 |> File.read!() |> String.contains?(quoted)))
  end

  @doc """
  Every string between double quotes in `sources` that could be an id.

  Over-collecting is harmless: a generated id never equals a literal.
  """
  @spec fixed_ids([String.t()]) :: MapSet.t(String.t())
  def fixed_ids(sources) do
    for source <- sources,
        [_, literal] <- Regex.scan(~r/"([A-Za-z0-9][A-Za-z0-9_.:\-]*)"/, source),
        into: MapSet.new(),
        do: literal
  end

  @doc "The ids of the non-terminal runs in `runs` that are fixed ids."
  @spec fixed_live_run_ids([map()], MapSet.t(String.t())) :: [String.t()]
  def fixed_live_run_ids(runs, fixed_ids) do
    for %{run_id: run_id, terminal?: false} <- runs, MapSet.member?(fixed_ids, run_id), do: run_id
  end

  @impl true
  def init(opts) do
    # The runner is waiting for the next module's `:DOWN`; every microsecond this process needs to
    # wake up is a chance for it to announce the next module first (and for this one to be skipped).
    Process.flag(:priority, :high)
    fixed_ids = Keyword.get_lazy(opts, :fixed_ids, fn -> :persistent_term.get(@fixed_ids_key) end)
    {:ok, %{fixed_ids: fixed_ids, leaks: [], judged: 0, sync: 0}}
  end

  @impl true
  def handle_cast({:module_finished, %ExUnit.TestModule{} = test_module}, state) do
    {:noreply, judge(state, test_module, &ForemanServer.ProjectionStore.list_runs/0, &backlog/0)}
  end

  def handle_cast({:suite_finished, _times}, state) do
    :persistent_term.put(@result_key, Map.take(state, [:leaks, :judged, :sync]))
    {:noreply, state}
  end

  def handle_cast(_event, state), do: {:noreply, state}

  @doc """
  Judges one finished module: `runs_fun` reads the store, `backlog_fun` the formatter's mailbox
  length, read after the store (see the moduledoc for why that makes the read exact).

  The store is read before anything else, even for modules that will not be judged: the runner
  is already on its way to the next module, and the shorter this takes, the likelier the read
  still counts.
  """
  @spec judge(map(), ExUnit.TestModule.t(), (-> [map()]), (-> non_neg_integer())) :: map()
  def judge(state, %ExUnit.TestModule{name: name, tests: tests}, runs_fun, backlog_fun) do
    runs = runs_fun.()
    exact? = backlog_fun.() == 0

    cond do
      Enum.any?(tests, &(&1.tags[:async] == true)) ->
        state

      not Enum.any?(tests, &ran?/1) ->
        state

      not exact? ->
        %{state | sync: state.sync + 1}

      true ->
        leaks =
          for id <- fixed_live_run_ids(runs, state.fixed_ids),
              do: %{run_id: id, module: inspect(name)}

        %{state | judged: state.judged + 1, sync: state.sync + 1, leaks: state.leaks ++ leaks}
    end
  end

  defp backlog do
    {:message_queue_len, backlog} = Process.info(self(), :message_queue_len)
    backlog
  end

  defp ran?(%ExUnit.Test{state: nil}), do: true
  defp ran?(%ExUnit.Test{state: {:failed, _}}), do: true
  defp ran?(%ExUnit.Test{}), do: false
end
