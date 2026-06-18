defmodule ForemanServer.LogReconciler do
  @moduledoc "Reconciles missed terminal run events from worker log files."

  alias ForemanServer.EventStore

  @completed_markers ["PIPELINE COMPLETED", "[PIPELINE] COMPLETED"]
  @failed_markers ["PIPELINE FAILED", "[PIPELINE] FAILED", "Fatal:"]
  @log_exts [".err", ".log", ".out"]

  @spec reconcile_terminal_runs([map()], keyword()) :: [map()]
  def reconcile_terminal_runs(active_runs, opts \\ []) when is_list(active_runs) do
    log_dir = Keyword.get(opts, :log_dir) || scheduler_env(:log_dir, default_log_dir())

    active_runs
    |> Enum.flat_map(fn run ->
      run_id = Map.get(run, :run_id)

      with {:ok, run_id} <- required_run_id(run_id),
           {:ok, status} <- terminal_status_from_logs(log_dir, run_id),
           {:ok, _event} <- append_terminal_event(run_id, status) do
        [%{run_id: run_id, status: status, source: "log"}]
      else
        _ -> []
      end
    end)
  end

  defp terminal_status_from_logs(log_dir, run_id) do
    text =
      @log_exts
      |> Enum.map(&Path.join(log_dir, run_id <> &1))
      |> Enum.map(&tail_file/1)
      |> Enum.join("\n")

    cond do
      text == "" -> :error
      Enum.any?(@failed_markers, &String.contains?(text, &1)) -> {:ok, "failed"}
      Enum.any?(@completed_markers, &String.contains?(text, &1)) -> {:ok, "completed"}
      true -> :error
    end
  end

  defp append_terminal_event(run_id, "completed") do
    append(run_id, "RunCompleted", %{run_id: run_id, reconciled_from: "log"})
  end

  defp append_terminal_event(run_id, "failed") do
    append(run_id, "RunFailed", %{
      run_id: run_id,
      reason: "terminal_log_marker",
      reconciled_from: "log"
    })
  end

  defp append(run_id, event_type, payload) do
    EventStore.append(%{
      stream_id: "run:#{run_id}",
      event_type: event_type,
      payload: payload,
      metadata: %{
        correlation_id: run_id,
        idempotency_key: "log-reconcile:#{event_type}:#{run_id}"
      }
    })
  end

  defp tail_file(path) do
    case File.read(path) do
      {:ok, data} ->
        data
        |> binary_tail(64_000)

      {:error, _reason} ->
        ""
    end
  end

  defp binary_tail(data, limit) when byte_size(data) > limit do
    binary_part(data, byte_size(data) - limit, limit)
  end

  defp binary_tail(data, _limit), do: data

  defp required_run_id(run_id) when is_binary(run_id) and run_id != "", do: {:ok, run_id}
  defp required_run_id(_run_id), do: :error

  defp default_log_dir do
    Path.expand("~/.foreman/logs")
  end

  defp scheduler_env(key, default) do
    :foreman_server
    |> Application.get_env(:scheduler, [])
    |> Keyword.get(key, default)
  end
end
