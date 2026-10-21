defmodule ForemanServer.PrWatcher do
  @moduledoc """
  Watches the pull requests of runs (E9): turns what GitHub reports into typed
  events on the owning run's stream and runs fix threads.

  Shape: a `ProjectionStore` subscriber like `Messaging.Dispatcher` and
  `Review.Analyzer`. `init/1` subscribes with `replay_existing: false` - a
  restart must not re-observe history - and a failed subscribe crashes the
  process (it is not swallowed). It reacts to:

    * `PrAssociated`, `PrReady`, `PrWatchStarted` - observe the PR immediately
      instead of waiting for the next poll;
    * `PrFixRequested` - the fix reactor (below);
    * `JobsiteCompleted` / `JobsiteFailed` of a jobsite this watcher started for a fix -
      finish that fix;
    * every other event - ignored, state unchanged (so the observations the
      watcher itself causes can never feed back into it).

  Observation is `ForemanServer.PrWatcher.Observer` (one fetch, deterministic
  commands, so a poll, a webhook and this subscriber converge on one event).
  Work runs in a task under a private `Task.Supervisor`, never in the
  subscription callback, so a slow `gh` cannot back up the projection broadcast.
  Refreshes of one PR are single-flight: concurrent `refresh_now/2` callers
  share one fetch. Delivery from the projection is at-least-once, which is safe
  because observation is idempotent by digest.

  ## Fix reactor (E9-S3)

  `PrFixRequested` (appended by `run.pr.fix_ci | address_comments | resolve_conflicts`,
  from an operator or the auto-fix policy) is the only trigger. The aggregate has
  already decided the request is allowed and bounded; the reactor starts exactly one
  push-enabled follow-up jobsite on the PR head branch (`ForemanServer.PrFix.plan/4`,
  `Jobsite.run_async/1`) and records `run.pr.fix_started` with its id. The side effect
  lives here, never in the aggregate (the actor re-runs `handle_command/2` on a version
  conflict). A re-delivered `PrFixRequested` starts nothing: the request is skipped when
  its fix is already starting, has a jobsite, or is no longer the PR's in-flight request.
  When the jobsite ends the reactor re-reads the PR and records `run.pr.fix_finished`
  with the outcome (`pushed` when the PR head moved, `no_change` when it did not,
  `failed` when the jobsite failed or could not start), then hands the fresh observation
  to the auto-fix policy. After a restart (`handle_continue(:recover)`) fixes whose jobsite
  already ended are finished, a request that never got a jobsite is finished as
  `failed` (`lost_on_restart`), and fixes still running are waited for.

  Nothing in this module can merge a PR: the merge gate (`run.pr.merge` /
  `merge_approve`) is operator-only and is never dispatched here.

  Public API: `refresh/2` (async, used by webhooks), `refresh_now/2` (sync, used
  by tests and the poller), `stats/1`, `running?/1`.

  Configuration (`config :foreman_server, :pr_watcher, enabled: boolean`;
  env `FOREMAN_PR_WATCHER_ENABLED=false` turns it off). `gh` missing is
  reported in `stats/1` as `last_error: :gh_not_installed`; the process stays up.
  Polling is owned by `ForemanServer.PrMonitor` (`FOREMAN_PR_MONITOR_ENABLED`).
  """

  use GenServer

  alias ForemanServer.{CommandGateway, Jobsite, PrFix, PrObservation, ProjectionStore}
  alias ForemanServer.PrWatcher.Observer

  require Logger

  @refresh_timeout 120_000
  @observe_events ~w(PrAssociated PrReady PrWatchStarted)
  @jobsite_terminal ~w(JobsiteCompleted JobsiteFailed)

  @type server :: GenServer.server()
  @type refresh_result :: {:ok, Observer.result()} | {:error, Observer.error()}

  # -- public API ------------------------------------------------------------

  @doc "Whether the watcher is enabled in configuration (default true)."
  @spec enabled?() :: boolean()
  def enabled? do
    Application.get_env(:foreman_server, :pr_watcher, [])[:enabled] != false
  end

  @doc """
  Start the watcher. Options: `:name` (default `#{inspect(__MODULE__)}`),
  `:fetch_fun` (`pr_url -> {:ok, PrStatus.t()} | {:error, term()}`, defaults to
  `Observer.default_fetch/1`), `:jobsite_starter` (`opts -> {:ok, jobsite_id} |
  {:error, term()}`, defaults to `Jobsite.run_async/1`) and `:plan_opts` (keyword passed to
  `PrFix.plan/4`, for tests).
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Whether a watcher process is registered under `server`."
  @spec running?(server()) :: boolean()
  def running?(server \\ __MODULE__), do: GenServer.whereis(server) != nil

  @doc "Observe `pr_url` in the background. Returns `:ok` immediately."
  @spec refresh(String.t(), server()) :: :ok
  def refresh(pr_url, server \\ __MODULE__) when is_binary(pr_url),
    do: GenServer.cast(server, {:refresh, pr_url})

  @doc """
  Observe `pr_url` and wait for the result. Concurrent callers for one PR share
  a single fetch.
  """
  @spec refresh_now(String.t(), server()) :: refresh_result()
  def refresh_now(pr_url, server \\ __MODULE__) when is_binary(pr_url),
    do: GenServer.call(server, {:refresh_now, pr_url}, @refresh_timeout)

  @doc "Counters and the last error."
  @spec stats(server()) :: map()
  def stats(server \\ __MODULE__), do: GenServer.call(server, :stats)

  # -- GenServer -------------------------------------------------------------

  @impl true
  def init(opts) do
    {:ok, supervisor} = Task.Supervisor.start_link()

    case ProjectionStore.subscribe(replay_existing: false) do
      :ok ->
        {:ok,
         %{
           supervisor: supervisor,
           fetch_fun: Keyword.get(opts, :fetch_fun, &Observer.default_fetch/1),
           jobsite_starter: Keyword.get(opts, :jobsite_starter, &Jobsite.run_async/1),
           plan_opts: Keyword.get(opts, :plan_opts, []),
           inflight: %{},
           starting: MapSet.new(),
           fix_tasks: %{},
           jobsites: %{},
           observations: 0,
           errors: 0,
           last_error: nil
         }, {:continue, :recover}}

      {:error, reason} ->
        {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:recover, state), do: {:noreply, recover_fixes(state)}

  @impl true
  def handle_info({:projection_event, %{event_type: type} = event}, state)
      when type in @observe_events do
    case event |> event_payload() |> pr_url() do
      nil -> {:noreply, state}
      url -> {:noreply, start_refresh(state, url, nil)}
    end
  end

  def handle_info({:projection_event, %{event_type: "PrFixRequested"} = event}, state),
    do: {:noreply, start_fix(state, event_payload(event))}

  def handle_info({:projection_event, %{event_type: type} = event}, state)
      when type in @jobsite_terminal do
    payload = event_payload(event)
    {:noreply, jobsite_ended(state, get(payload, :jobsite_id), terminal_of(type, payload))}
  end

  def handle_info({:projection_event, _other}, state), do: {:noreply, state}

  def handle_info({ref, result}, state) when is_reference(ref) do
    Process.demonitor(ref, [:flush])

    case Map.pop(state.fix_tasks, ref) do
      {nil, _} -> {:noreply, finish_refresh(state, ref, result)}
      {key, tasks} -> {:noreply, fix_task_done(%{state | fix_tasks: tasks}, key, result)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    case Map.pop(state.fix_tasks, ref) do
      {nil, _} ->
        {:noreply, finish_refresh(state, ref, {:error, {:refresh_crashed, reason}})}

      {{:start, _key, payload} = task, tasks} ->
        Logger.error("PrWatcher fix task #{inspect(task)} crashed: #{inspect(reason)}")
        {:noreply, fail_crashed_start(%{state | fix_tasks: tasks}, task, payload)}

      {task, tasks} ->
        Logger.error("PrWatcher fix task #{inspect(task)} crashed: #{inspect(reason)}")
        {:noreply, %{state | fix_tasks: tasks, starting: release_start(state.starting, task)}}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_cast({:refresh, pr_url}, state), do: {:noreply, start_refresh(state, pr_url, nil)}

  @impl true
  def handle_call({:refresh_now, pr_url}, from, state),
    do: {:noreply, start_refresh(state, pr_url, from)}

  def handle_call(:stats, _from, state) do
    {:reply,
     state
     |> Map.take([:observations, :errors, :last_error])
     |> Map.put(:fixes_in_flight, map_size(state.jobsites) + MapSet.size(state.starting)), state}
  end

  # -- observation -------------------------------------------------------------

  # Single-flight per PR: a refresh already running for `pr_url` absorbs this
  # request, and a waiting caller is answered with that run's result.
  defp start_refresh(state, pr_url, waiter) do
    case Enum.find(state.inflight, fn {_ref, {url, _waiters}} -> url == pr_url end) do
      {ref, {url, waiters}} ->
        put_in(state.inflight[ref], {url, add_waiter(waiters, waiter)})

      nil ->
        fetch = state.fetch_fun

        task =
          Task.Supervisor.async_nolink(state.supervisor, fn ->
            Observer.observe(pr_url, fetch_fun: fetch)
          end)

        put_in(state.inflight[task.ref], {pr_url, add_waiter([], waiter)})
    end
  end

  defp add_waiter(waiters, nil), do: waiters
  defp add_waiter(waiters, from), do: [from | waiters]

  defp finish_refresh(state, ref, result) do
    {{_url, waiters}, inflight} = Map.pop(state.inflight, ref, {nil, []})
    Enum.each(waiters, &GenServer.reply(&1, result))
    state = %{state | inflight: inflight}

    case result do
      {:ok, _} ->
        %{state | observations: state.observations + 1}

      {:error, :not_watched} ->
        state

      {:error, reason} ->
        Logger.warning("PrWatcher refresh failed: #{inspect(reason)}")
        %{state | errors: state.errors + 1, last_error: reason}
    end
  end

  # -- fix reactor ---------------------------------------------------------------

  defp start_fix(state, payload) do
    key = {get(payload, :run_id), get(payload, :pr_url)}

    if MapSet.member?(state.starting, key) or not requested?(key, payload) do
      state
    else
      starter = state.jobsite_starter
      plan_opts = state.plan_opts

      task =
        Task.Supervisor.async_nolink(state.supervisor, fn ->
          {:started, run_fix(payload, starter, plan_opts)}
        end)

      %{
        state
        | starting: MapSet.put(state.starting, key),
          fix_tasks: Map.put(state.fix_tasks, task.ref, {:start, key, payload})
      }
    end
  end

  # Only the PR's CURRENT request may start a jobsite: a re-delivered event whose fix
  # already has a jobsite (or already finished) finds the in-flight marker moved on.
  defp requested?({run_id, pr_url}, payload) do
    with record when not is_nil(record) <-
           run_id |> ProjectionStore.pr_watch() |> Enum.find(&(&1.pr_url == pr_url)) do
      record.fix.in_flight == :requested and
        record.fix.in_flight_attempt == get(payload, :attempt)
    else
      _ -> false
    end
  end

  defp run_fix(payload, starter, plan_opts) do
    kind = get(payload, :kind)
    run_id = get(payload, :run_id)
    pr_url = get(payload, :pr_url)
    plan_opts = Keyword.put_new(plan_opts, :note, get(payload, :note))

    with {:ok, plan} <- PrFix.plan(kind, run_id, pr_url, plan_opts),
         {:ok, jobsite_id} <- start_jobsite(starter, plan) do
      started = %{
        run_id: run_id,
        pr_url: pr_url,
        jobsite_id: jobsite_id,
        resumed_session: plan.resumed_session
      }

      case dispatch_fix(:started, payload, started) do
        {:ok, _} ->
          :ok

        {:error, reason} ->
          Logger.error("PrWatcher could not record fix start #{jobsite_id}: #{inspect(reason)}")
      end

      {:ok, jobsite_id}
    else
      {:error, reason} ->
        Logger.warning("PrWatcher fix #{kind} for #{pr_url} not started: #{inspect(reason)}")

        dispatch_fix(:finished, payload, %{
          run_id: run_id,
          pr_url: pr_url,
          outcome: "failed",
          error_code: error_code(reason)
        })

        {:error, reason}
    end
  end

  defp start_jobsite(starter, plan) do
    case starter.(plan.jobsite_opts) do
      {:ok, jobsite_id} when is_binary(jobsite_id) -> {:ok, jobsite_id}
      {:error, reason} -> {:error, reason}
    end
  end

  defp release_start(starting, {:start, key, _payload}), do: MapSet.delete(starting, key)
  defp release_start(starting, _finish_task), do: starting

  # A start task that crashed never reported an outcome; without one the aggregate
  # keeps the fix in flight and refuses every later request for the PR. Record the
  # failure (off the GenServer, like every other dispatch) and free the start slot.
  defp fail_crashed_start(state, {:start, key, _payload} = task, payload) do
    finished = %{
      run_id: get(payload, :run_id),
      pr_url: get(payload, :pr_url),
      outcome: "failed",
      error_code: "start_crashed"
    }

    dispatcher =
      Task.Supervisor.async_nolink(state.supervisor, fn ->
        dispatch_fix(:finished, payload, finished)
      end)

    %{
      state
      | starting: release_start(state.starting, task),
        fix_tasks: Map.put(state.fix_tasks, dispatcher.ref, {:finish, {:crashed_start, key}})
    }
  end

  defp fix_task_done(state, {:start, key, payload}, {:started, result}) do
    state = %{state | starting: MapSet.delete(state.starting, key)}

    case result do
      {:ok, jobsite_id} ->
        meta = %{
          run_id: get(payload, :run_id),
          pr_url: get(payload, :pr_url),
          kind: get(payload, :kind),
          attempt: get(payload, :attempt),
          head_sha: get(payload, :head_sha),
          jobsite_id: jobsite_id
        }

        state = %{state | jobsites: Map.put(state.jobsites, jobsite_id, meta)}
        # The jobsite may have ended before it was registered here; the projection knows.
        jobsite_ended(state, jobsite_id, projected_terminal(jobsite_id))

      {:error, _reason} ->
        state
    end
  end

  defp fix_task_done(state, {:finish, jobsite_id}, _result),
    do: %{state | jobsites: Map.delete(state.jobsites, jobsite_id)}

  defp terminal_of("JobsiteCompleted", _payload), do: :completed

  defp terminal_of("JobsiteFailed", payload),
    do: {:failed, get(payload, :code) || "jobsite_failed"}

  defp projected_terminal(jobsite_id) do
    case ProjectionStore.jobsite(jobsite_id) do
      %{status: "completed"} -> :completed
      %{status: status} when status in ["failed", "cancelled"] -> {:failed, "jobsite_#{status}"}
      _running_or_unknown -> nil
    end
  end

  defp jobsite_ended(state, _jobsite_id, nil), do: state

  defp jobsite_ended(state, jobsite_id, terminal) do
    case Map.pop(state.jobsites, jobsite_id) do
      {nil, _} ->
        state

      {meta, jobsites} ->
        fetch = state.fetch_fun

        task =
          Task.Supervisor.async_nolink(state.supervisor, fn ->
            finish_fix(meta, terminal, fetch)
          end)

        %{
          state
          | jobsites: jobsites,
            fix_tasks: Map.put(state.fix_tasks, task.ref, {:finish, jobsite_id})
        }
    end
  end

  # The jobsite ended: decide the outcome from the PR itself, record it, then give the
  # (now fix-free) PR back to the auto-fix policy.
  defp finish_fix(meta, terminal, fetch) do
    base = %{run_id: meta.run_id, pr_url: meta.pr_url}
    payload = Map.take(meta, [:run_id, :pr_url, :kind, :attempt, :head_sha])

    {finished, observed} =
      case terminal do
        :completed -> completed_outcome(meta, fetch)
        {:failed, code} -> {%{outcome: "failed", error_code: to_string(code)}, nil}
        :lost -> {%{outcome: "failed", error_code: "lost_on_restart"}, nil}
      end

    result = dispatch_fix(:finished, payload, Map.merge(base, finished))

    with %{status: status, runs: runs} <- observed do
      Observer.auto_fix(runs, meta.pr_url, status)
    end

    result
  end

  defp completed_outcome(meta, fetch) do
    case Observer.observe(meta.pr_url, fetch_fun: fetch, auto_fix: false) do
      {:ok, %{status: status} = observed} ->
        outcome = if status.head_sha == meta.head_sha, do: "no_change", else: "pushed"
        {%{outcome: outcome, new_head_sha: status.head_sha}, observed}

      {:error, reason} ->
        {%{outcome: "failed", error_code: "refresh_failed_" <> error_code(reason)}, nil}
    end
  end

  defp dispatch_fix(:started, payload, extra) do
    fix_command(
      "run.pr.fix_started",
      "pr_fix_started",
      payload,
      Map.put(extra, :started_at, now())
    )
  end

  defp dispatch_fix(:finished, payload, extra) do
    fix_command(
      "run.pr.fix_finished",
      "pr_fix_finished",
      payload,
      Map.put(extra, :finished_at, now())
    )
  end

  defp fix_command(type, prefix, payload, extra) do
    run_id = get(payload, :run_id)
    pr_url = get(payload, :pr_url)

    CommandGateway.dispatch_system(%{
      type: type,
      command_id:
        "#{prefix}:#{run_id}:#{PrObservation.url_hash(pr_url)}:#{get(payload, :kind)}:#{get(payload, :attempt)}",
      aggregate_id: "run:#{run_id}",
      payload: Map.merge(%{run_id: run_id, pr_url: pr_url}, extra)
    })
  end

  # -- restart recovery -------------------------------------------------------------

  # A fix whose jobsite already ended while the server was down must not leave its PR
  # permanently "fixing"; one that is still running is waited for like any other.
  defp recover_fixes(state) do
    for record <- ProjectionStore.watched_prs(),
        record.fix.in_flight != nil,
        reduce: state do
      acc ->
        meta = %{
          run_id: record.run_id,
          pr_url: record.pr_url,
          kind: record.fix.in_flight_kind,
          attempt: record.fix.in_flight_attempt,
          head_sha: record.fix.in_flight_head_sha
        }

        case record.fix.in_flight do
          :requested ->
            end_recovered(acc, meta, :lost)

          jobsite_id when is_binary(jobsite_id) ->
            meta = Map.put(meta, :jobsite_id, jobsite_id)
            acc = %{acc | jobsites: Map.put(acc.jobsites, jobsite_id, meta)}
            jobsite_ended(acc, jobsite_id, projected_terminal(jobsite_id))
        end
    end
  end

  defp end_recovered(state, meta, terminal) do
    fetch = state.fetch_fun
    jobsite_id = "recovered:#{meta.run_id}:#{meta.kind}:#{meta.attempt}"

    task =
      Task.Supervisor.async_nolink(state.supervisor, fn -> finish_fix(meta, terminal, fetch) end)

    %{state | fix_tasks: Map.put(state.fix_tasks, task.ref, {:finish, jobsite_id})}
  end

  # -- helpers -------------------------------------------------------------------------

  defp error_code(%{code: code}) when is_atom(code) and not is_nil(code), do: Atom.to_string(code)
  defp error_code(code) when is_atom(code) and not is_nil(code), do: Atom.to_string(code)

  defp error_code(tuple) when is_tuple(tuple) and is_atom(elem(tuple, 0)),
    do: Atom.to_string(elem(tuple, 0))

  defp error_code(_other), do: "unknown"

  defp now, do: System.system_time(:millisecond)

  # Projection events carry their payload as `data` (appended events) or `payload` (applied).
  defp event_payload(%{data: data}) when is_map(data), do: data
  defp event_payload(%{payload: payload}) when is_map(payload), do: payload
  defp event_payload(_event), do: %{}

  defp pr_url(payload) do
    case get(payload, :pr_url) do
      url when is_binary(url) and url != "" -> url
      _ -> nil
    end
  end

  defp get(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
