defmodule ForemanServer.Threads.Actions do
  @moduledoc """
  Door-agnostic operator actions on a thread (see `ForemanServer.Threads.Thread`).

  Each action resolves the thread through `ForemanServer.Threads.get/1` and
  routes to the command or control path the thread's door already owns; no new
  aggregate command is introduced here.

    * `stop/3` - workflow door: `run.cancel` through
      `CommandGateway.dispatch_operator/1`. Jobsite door: `Jobsite.cancel/2`
      when an executor is alive (it records the intent and the executor emits
      `JobsiteCancelled`); a paused jobsite has no executor, so the existing
      `jobsite.cancel` command is dispatched directly.
  """

  alias ForemanServer.CommandGateway
  alias ForemanServer.Jobsite
  alias ForemanServer.Threads
  alias ForemanServer.Threads.Thread

  @default_stop_reason "operator_stop"

  @stoppable_run_statuses ~w(awaiting_worker in_progress paused blocked stuck needs_recovery)
  @stoppable_jobsite_statuses ~w(starting running paused)

  @type stop_error ::
          :thread_not_found
          | {:not_stoppable, String.t() | nil}
          | {:no_executor, String.t() | nil}
          | {:cancel_failed, term()}

  @doc """
  Stop a thread. `opts`: `:idempotency_key` (becomes the `run.cancel`
  `command_id`; default a fresh unique id, so two distinct stops never
  deduplicate into one).

  Returns `{:ok, :stopping}`, `{:error, :thread_not_found}`,
  `{:error, {:not_stoppable, status}}` for a terminal thread (nothing is
  dispatched), `{:error, {:no_executor, status}}` for a starting/running
  jobsite whose executor is gone, or `{:error, {:cancel_failed, reason}}` when
  the underlying cancel is rejected.
  """
  @spec stop(String.t(), String.t() | nil, keyword()) :: {:ok, :stopping} | {:error, stop_error()}
  def stop(thread_id, reason \\ nil, opts \\ []) when is_binary(thread_id) and is_list(opts) do
    reason = normalize_reason(reason)

    with {:ok, %Thread{} = thread} <- Threads.get(thread_id) do
      do_stop(thread, reason, opts)
    end
  end

  defp do_stop(%Thread{door: :workflow, id: "run:" <> run_id, status: status}, reason, opts)
       when status in @stoppable_run_statuses do
    envelope = %{
      type: "run.cancel",
      command_id: Keyword.get_lazy(opts, :idempotency_key, &fresh_command_id/0),
      aggregate_id: "run:" <> run_id,
      payload: %{run_id: run_id, reason: reason}
    }

    case CommandGateway.dispatch_operator(envelope) do
      {:ok, _} -> {:ok, :stopping}
      {:error, cause} -> {:error, {:cancel_failed, cause}}
      {:error, cause, _detail} -> {:error, {:cancel_failed, cause}}
    end
  end

  defp do_stop(
         %Thread{door: :jobsite, id: "jobsite:" <> jobsite_id, status: status},
         reason,
         opts
       )
       when status in @stoppable_jobsite_statuses do
    cond do
      Jobsite.Executor.pid_for(jobsite_id) != nil ->
        case Jobsite.cancel(jobsite_id, reason) do
          :ok -> {:ok, :stopping}
          {:error, %Jobsite.Error{} = error} -> {:error, {:cancel_failed, error.code}}
        end

      status == "paused" ->
        # A paused jobsite's executor has exited, so nothing would honor an
        # intent; cancel the aggregate itself.
        command = %{
          type: "jobsite.cancel",
          command_id: Keyword.get_lazy(opts, :idempotency_key, &fresh_command_id/0),
          aggregate_id: "jobsite:" <> jobsite_id,
          payload: %{jobsite_id: jobsite_id, reason: reason}
        }

        case CommandGateway.dispatch_system(command) do
          {:ok, _} -> {:ok, :stopping}
          {:error, cause} -> {:error, {:cancel_failed, cause}}
          {:error, cause, _detail} -> {:error, {:cancel_failed, cause}}
        end

      true ->
        {:error, {:no_executor, status}}
    end
  end

  defp do_stop(%Thread{status: status}, _reason, _opts), do: {:error, {:not_stoppable, status}}

  defp normalize_reason(reason) when is_binary(reason) and reason != "", do: reason
  defp normalize_reason(_), do: @default_stop_reason

  defp fresh_command_id, do: "thread-stop:" <> Elixir.EventStore.UUID.uuid4()
end
