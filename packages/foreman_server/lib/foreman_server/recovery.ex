defmodule ForemanServer.Recovery do
  @moduledoc """
  TRD-019: Recovery scanner.

  Top-level helpers that detect interrupted runs and stale scheduler intents,
  emitting recovery events through `CommandRouter.dispatch/2`.

  ## Responsibilities
  * `do_detect/1` — scans the projection store for active runs whose last
    event is older than `:foreman_server, :run_stale_after_ms` (default 5
    minutes). For each, emits a `RunRecoveryEvent` so downstream recovery
    aggregates can mark `recovery.require` and re-drive the run.
  * `detect_unconfirmed_intents/1` — walks the projection of recorded
    `ScheduledFireRecorded` events that lack a confirmation and emits a
    `SchedulerIntentStale` for each, so the scheduler can re-dispatch.
  * `confirm_execution/1` — emits `ScheduledFireConfirmed` for an intent.
  * `skip_fire/2` — emits `ScheduledFireSkipped` for an intent.
  * `record_intent/3` — emits `ScheduledFireRecorded` for an intent.

  Idempotency is provided by the Actor command dedup keyed on `command_id`.
  Callers should pass a stable `command_id` (e.g. UUID) to ensure that
  crash-restart redispatches collapse to a single underlying event.
  """

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.Events

  @typedoc "Recovery scan options."
  @type scan_opts :: [
          {:now, DateTime.t()},
          {:stale_after_ms, non_neg_integer()},
          {:command_id_prefix, String.t()}
        ]

  @default_stale_after_ms 5 * 60 * 1000

  @doc """
  Detect interrupted runs and emit a `RunRecoveryEvent` for each.

  Returns `{:ok, dispatched_count}` where `dispatched_count` is the number of
  `RunRecoveryEvent` events successfully accepted by the `CommandRouter`.
  Runs already terminal (`completed`, `failed`, `cancelled`) are skipped.
  """
  @spec do_detect(scan_opts()) :: {:ok, non_neg_integer()}
  def do_detect(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    stale_after_ms = Keyword.get(opts, :stale_after_ms, default_stale_after_ms())
    prefix = Keyword.get(opts, :command_id_prefix, "recovery-detect")

    runs = ProjectionStore.list_runs()
    interrupted = Enum.filter(runs, &(terminal_run?(&1) == false))

    recoverable =
      Enum.filter(interrupted, fn run ->
        last_event_at = get_last_event_at(run)
        diff_ms = DateTime.diff(now, last_event_at, :millisecond)
        diff_ms >= stale_after_ms
      end)

    Enum.reduce_while(recoverable, {:ok, 0}, fn run, {:ok, count} ->
      command_id = "#{prefix}:#{run.run_id}:#{unique_token()}"

      command = %{
        aggregate_id: "run:#{run.run_id}",
        command_id: command_id,
        type: "run.recovery_event",
        payload: %{
          run_id: run.run_id,
          reason: "stale_event",
          last_event_at: DateTime.to_iso8601(get_last_event_at(run)),
          recovered_at: DateTime.to_iso8601(now)
        }
      }

      case CommandGateway.dispatch_system(command) do
        {:ok, _spec} -> {:cont, {:ok, count + 1}}
        {:error, _} -> {:halt, {:ok, count}}
      end
    end)
  end

  @doc """
  Detect unconfirmed scheduler intents and re-dispatch them.

  Walks the projection of `ScheduledFireRecorded` events looking for any whose
  stream hasn't seen a `ScheduledFireConfirmed` or `ScheduledFireSkipped`.
  Emits one `SchedulerIntentStale` per stale intent so the scheduler runtime
  can re-fire. Returns the number of staleness events dispatched.
  """
  @spec detect_unconfirmed_intents(scan_opts()) :: {:ok, non_neg_integer()}
  def detect_unconfirmed_intents(opts \\ []) do
    prefix = Keyword.get(opts, :command_id_prefix, "recovery-scheduler-stale")

    intents = ProjectionStore.list_scheduler_intents()

    stale =
      Enum.flat_map(intents, fn intent ->
        case intent.status do
          "recorded" -> [intent]
          _ -> []
        end
      end)

    Enum.reduce_while(stale, {:ok, 0}, fn intent, {:ok, count} ->
      command_id = "#{prefix}:#{intent.intent_id}:#{unique_token()}"

      command = %{
        aggregate_id: "scheduler_intent:#{intent.intent_id}",
        command_id: command_id,
        type: "scheduler_intent.mark_stale",
        payload: %{
          intent_id: intent.intent_id,
          task_id: intent.task_id,
          run_id: intent.run_id,
          marked_stale_at: DateTime.to_iso8601(DateTime.utc_now())
        }
      }

      case CommandGateway.dispatch_system(command) do
        {:ok, _spec} -> {:cont, {:ok, count + 1}}
        {:error, _} -> {:halt, {:ok, count}}
      end
    end)
  end

  @doc """
  Record a scheduler intent via `scheduler_intent.record`.
  """
  @spec record_intent(String.t(), map()) :: {:ok, map()} | {:error, term()}

  def record_intent(intent_id, payload) when is_binary(intent_id) and is_map(payload) do
    command = %{
      aggregate_id: "scheduler_intent:#{intent_id}",
      command_id: "scheduler_intent.record:#{intent_id}",
      type: "scheduler_intent.record",
      payload: Map.put(payload, :intent_id, intent_id)
    }

    CommandGateway.dispatch_system(command)
  end

  @doc """
  Confirm execution of a scheduler intent via `scheduler_intent.confirm`.
  """
  @spec confirm_execution(String.t()) :: {:ok, map()} | {:error, term()}
  def confirm_execution(intent_id) when is_binary(intent_id) do
    command = %{
      aggregate_id: "scheduler_intent:#{intent_id}",
      command_id: "scheduler_intent.confirm:#{intent_id}:#{unique_token()}",
      type: "scheduler_intent.confirm",
      payload: %{intent_id: intent_id, confirmed_at: DateTime.to_iso8601(DateTime.utc_now())}
    }

    CommandGateway.dispatch_system(command)
  end

  @doc """
  Skip a stale scheduler intent via `scheduler_intent.skip`.
  """
  @spec skip_fire(String.t(), term()) :: {:ok, map()} | {:error, term()}
  def skip_fire(intent_id, reason) when is_binary(intent_id) do
    command = %{
      aggregate_id: "scheduler_intent:#{intent_id}",
      command_id: "scheduler_intent.skip:#{intent_id}:#{unique_token()}",
      type: "scheduler_intent.skip",
      payload: %{intent_id: intent_id, reason: reason}
    }

    CommandGateway.dispatch_system(command)
  end

  # ---------------------------------------------------------------------------
  # Internal
  # ---------------------------------------------------------------------------

  defp terminal_run?(%{status: status}) when is_binary(status),
    do: status in ~w(completed failed cancelled merged run_complete_terminal)

  defp terminal_run?(_), do: false

  defp get_last_event_at(%{last_event_at: %DateTime{} = ts}), do: ts
  defp get_last_event_at(%{last_event_at: ts}) when is_binary(ts), do: parse_iso8601(ts)
  defp get_last_event_at(%{updated_at: %DateTime{} = ts}), do: ts
  defp get_last_event_at(%{last_event_at_ms: ms}) when is_integer(ms), do: DateTime.from_unix!(ms, :millisecond)
  defp get_last_event_at(_), do: DateTime.utc_now()

  defp parse_iso8601(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, dt, _} -> dt
      _ -> DateTime.utc_now()
    end
  end

  defp default_stale_after_ms do
    case Application.get_env(:foreman_server, :run_stale_after_ms, :unset) do
      :unset -> @default_stale_after_ms
      nil -> @default_stale_after_ms
      value when is_integer(value) -> value
      _ -> @default_stale_after_ms
    end
  end

  defp unique_token do
    case Code.ensure_loaded(Events) do
      {:module, _} ->
        try do
          EventStore.UUID.uuid4()
        rescue
          _ -> Integer.to_string(System.unique_integer([:positive]))
        end

      _ ->
        Integer.to_string(System.unique_integer([:positive]))
    end
  end
end
