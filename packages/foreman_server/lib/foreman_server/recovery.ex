defmodule ForemanServer.Recovery do
  @moduledoc "Startup recovery scanner for interrupted runs and stale scheduler fire intents."

  use GenServer

  alias ForemanServer.{CommandRouter, ProjectionStore}
  alias ForemanServer.Scheduler.Runtime

  @recoverable_run_statuses MapSet.new(["in_progress", "stuck"])
  @terminal_run_statuses MapSet.new(["completed", "failed", "blocked", "merged", "paused"])
  @terminal_task_statuses MapSet.new(["closed", "merged", "failed", "blocked", "stuck"])

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec detect() :: {:ok, map()}
  def detect do
    GenServer.call(__MODULE__, :detect)
  end

  @spec detect_unconfirmed_intents(keyword()) :: {:ok, map()}
  def detect_unconfirmed_intents(opts \\ []) do
    case Keyword.get(opts, :older_than) do
      %DateTime{} = older_than ->
        GenServer.call(__MODULE__, {:detect_unconfirmed_intents, older_than})

      _ ->
        GenServer.call(__MODULE__, :detect_unconfirmed_intents)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      boot_id: Keyword.get(opts, :boot_id, boot_id()),
      boot_started_at: Keyword.get(opts, :boot_started_at, DateTime.utc_now()),
      worker_launcher: scheduler_env(:worker_launcher, ForemanServer.WorkerLauncher)
    }

    send(self(), :detect)
    {:ok, state}
  end

  @impl true
  def handle_call(:detect, _from, state) do
    {:reply, {:ok, do_detect(state)}, state}
  end

  def handle_call(:detect_unconfirmed_intents, _from, state) do
    {:reply, {:ok, do_detect_unconfirmed_intents(state)}, state}
  end

  def handle_call({:detect_unconfirmed_intents, older_than}, _from, state) do
    {:reply, {:ok, do_detect_unconfirmed_intents(state, ProjectionStore.snapshot(), older_than)}, state}
  end

  @impl true
  def handle_info(:detect, state) do
    _ = do_detect(state)
    {:noreply, state}
  end

  defp do_detect(state) do
    snapshot = ProjectionStore.snapshot()

    interrupted_runs =
      snapshot.runs
      |> Map.values()
      |> Enum.filter(&interrupted_run?/1)
      |> Enum.map(&recover_interrupted_run(&1, state))

    intent_results = do_detect_unconfirmed_intents(state, snapshot)

    %{
      interrupted_runs: interrupted_runs,
      intents: intent_results
    }
  end

  defp do_detect_unconfirmed_intents(
         state,
         snapshot \\ ProjectionStore.snapshot(),
         older_than \\ nil
       ) do
    cutoff = older_than || state.boot_started_at

    snapshot.scheduler_intents
    |> Map.values()
    |> Enum.filter(&recoverable_pending_intent?(&1, cutoff))
    |> Enum.map(&recover_unconfirmed_intent(&1, snapshot, state))
    |> summarize_intent_results()
  end

  defp recover_interrupted_run(run, state) do
    run_id = Map.fetch!(run, :run_id)

    outcome = "interrupted_run_detected"

    %{
      run_id: run_id,
      outcome: outcome,
      result:
        emit_run_recovery(run_id, outcome, %{
          run_status: Map.get(run, :status),
          task_id: Map.get(run, :task_id),
          boot_id: state.boot_id
        }, state)
    }
  end

  defp recover_unconfirmed_intent(intent, snapshot, state) do
    fire_id = Map.fetch!(intent, :fire_id)
    run_id = Map.get(intent, :run_id)
    task_id = Map.get(intent, :task_id)
    run = run_id && Map.get(snapshot.runs, run_id)
    task = task_id && Map.get(snapshot.tasks, task_id)

    with {:ok, run_id} <- required_binary(run_id, :run_id),
         {:ok, task_id} <- required_binary(task_id, :task_id),
         {:ok, _stale} <- mark_intent_stale(intent, state) do
      if abandoned_intent?(run, task) do
        skip_abandoned_intent(intent, run, task, state)
      else
        redispatch_intent(intent, run_id, task_id, task, state)
      end
    else
      {:error, _reason} ->
        %{
          fire_id: fire_id,
          run_id: run_id,
          task_id: task_id,
          action: :invalid,
          result: :ignored
        }
    end
  end

  defp redispatch_intent(intent, run_id, task_id, task, state) do
    fire_id = Map.fetch!(intent, :fire_id)
    phase_order = intent_phase_order(intent)
    next_attempt = (Map.get(intent, :attempt) || 1) + 1

    with {:ok, _recovery} <-
           emit_run_recovery(run_id, "scheduled_fire_redispatched", %{
             fire_id: fire_id,
             task_id: task_id,
             attempt: next_attempt,
             boot_id: state.boot_id
           }, state),
         {:ok, _recorded} <-
           Runtime.record_intent(task, %{
             fire_id: fire_id,
             run_id: run_id,
             phase_id: List.first(phase_order),
             phase_order: phase_order,
             attempt: next_attempt
           }),
         {:ok, launch_result} <- state.worker_launcher.launch(task, run_id, phase_order) do
      %{
        fire_id: fire_id,
        run_id: run_id,
        task_id: task_id,
        action: :redispatched,
        attempt: next_attempt,
        result: launch_result
      }
    else
      {:error, reason} ->
        %{
          fire_id: fire_id,
          run_id: run_id,
          task_id: task_id,
          action: :redispatched,
          attempt: next_attempt,
          result: {:error, reason}
        }
    end
  end

  defp skip_abandoned_intent(intent, run, task, state) do
    fire_id = Map.fetch!(intent, :fire_id)
    run_id = Map.get(intent, :run_id)
    task_id = Map.get(intent, :task_id)

    reason = abandoned_reason(run, task)

    with {:ok, _skipped} <-
           emit_command(%{
             command_id: "recovery:#{state.boot_id}:fire-skip:#{fire_id}",
             command_type: "scheduler.fire.skip",
             payload: %{
               fire_id: fire_id,
               run_id: run_id,
               task_id: task_id,
               reason: reason
             }
           }),
         {:ok, _recovery} <-
           emit_run_recovery(run_id, "scheduled_fire_skipped", %{
             fire_id: fire_id,
             task_id: task_id,
             reason: reason,
             boot_id: state.boot_id
           }, state) do
      %{
        fire_id: fire_id,
        run_id: run_id,
        task_id: task_id,
        action: :skipped,
        result: reason
      }
    else
      {:error, reason_error} ->
        %{
          fire_id: fire_id,
          run_id: run_id,
          task_id: task_id,
          action: :skipped,
          result: {:error, reason_error}
        }
    end
  end

  defp mark_intent_stale(intent, state) do
    fire_id = Map.fetch!(intent, :fire_id)
    run_id = Map.get(intent, :run_id)

    emit_command(%{
      command_id: "recovery:#{state.boot_id}:intent-stale:#{fire_id}",
      command_type: "scheduler.intent.stale",
      payload: %{
        fire_id: fire_id,
        run_id: run_id,
        task_id: Map.get(intent, :task_id),
        attempt: Map.get(intent, :attempt),
        reason: "pickup_unconfirmed_after_restart"
      }
    })
  end

  defp emit_run_recovery(nil, _outcome, _extra_payload, _state), do: {:ok, :missing_run_id}

  defp emit_run_recovery(run_id, outcome, extra_payload, state) do
    emit_command(%{
      command_id: "recovery:#{state.boot_id}:run:#{run_id}:#{outcome}",
      command_type: "run.recover",
      payload:
        extra_payload
        |> Map.put(:run_id, run_id)
        |> Map.put(:outcome, outcome)
    })
  end

  defp emit_command(command) do
    case CommandRouter.handle(command) do
      {:ok, result} -> {:ok, result}
      {:error, {:duplicate_idempotency_key, _key}} -> {:ok, :duplicate}
      other -> other
    end
  end

  defp summarize_intent_results(results) do
    Enum.reduce(results, %{results: [], redispatched: 0, skipped: 0, invalid: 0}, fn result, acc ->
      action = Map.get(result, :action)

      acc
      |> update_in([:results], &(&1 ++ [result]))
      |> Map.update!(summary_key(action), &(&1 + 1))
    end)
  end

  defp summary_key(:redispatched), do: :redispatched
  defp summary_key(:skipped), do: :skipped
  defp summary_key(_), do: :invalid

  defp interrupted_run?(run) when is_map(run) do
    MapSet.member?(@recoverable_run_statuses, Map.get(run, :status, ""))
  end

  defp recoverable_pending_intent?(intent, boot_started_at) when is_map(intent) do
    Map.get(intent, :status) in ["recorded", "stale"] and
      older_than_boot?(Map.get(intent, :updated_at), boot_started_at)
  end

  defp abandoned_intent?(run, task) do
    missing_or_terminal_run?(run) or missing_or_terminal_task?(task)
  end

  defp missing_or_terminal_run?(nil), do: true

  defp missing_or_terminal_run?(run) do
    status = Map.get(run, :status, "")
    MapSet.member?(@terminal_run_statuses, status) or not MapSet.member?(@recoverable_run_statuses, status)
  end

  defp missing_or_terminal_task?(nil), do: true

  defp missing_or_terminal_task?(task) do
    status = Map.get(task, :status, "")
    MapSet.member?(@terminal_task_statuses, status) or status not in ["in_progress", "in-progress"]
  end

  defp abandoned_reason(run, task) do
    cond do
      is_nil(run) ->
        "run_missing"

      Map.get(run, :status) in ["completed", "failed", "blocked", "merged", "paused"] ->
        "run_#{Map.get(run, :status)}"

      is_nil(task) ->
        "task_missing"

      Map.get(task, :status) not in ["in_progress", "in-progress"] ->
        "task_#{Map.get(task, :status)}"

      true ->
        "abandoned"
    end
  end

  defp older_than_boot?(nil, _boot_started_at), do: true
  defp older_than_boot?(%DateTime{} = updated_at, boot_started_at), do: DateTime.compare(updated_at, boot_started_at) == :lt

  defp older_than_boot?(updated_at, boot_started_at) when is_binary(updated_at) do
    case DateTime.from_iso8601(updated_at) do
      {:ok, parsed, _offset} -> DateTime.compare(parsed, boot_started_at) == :lt
      _ -> true
    end
  end

  defp older_than_boot?(_updated_at, _boot_started_at), do: true

  defp intent_phase_order(intent) do
    case Map.get(intent, :phase_order) do
      phases when is_list(phases) -> phases
      _ -> []
    end
  end

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp boot_id do
    System.unique_integer([:positive, :monotonic])
    |> Integer.to_string()
  end

  defp scheduler_env(key, default) do
    :foreman_server
    |> Application.get_env(:scheduler, [])
    |> Keyword.get(key, default)
  end
end
