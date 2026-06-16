defmodule ForemanServer.PrGate do
  @moduledoc "PR readiness gate and merge orchestration state machine."

  alias ForemanServer.{EventStore, ProjectionStore, VcsAdapter}

  @spec observe(map()) :: {:ok, map()} | {:error, term()}
  def observe(input) when is_map(input) do
    input = atomize_keys(input)

    with {:ok, pr_id} <- required_binary(Map.get(input, :pr_id), :pr_id),
         {:ok, run_id} <- required_binary(Map.get(input, :run_id, pr_id), :run_id) do
      previous = get_in(ProjectionStore.snapshot(), [:pr_gates, pr_id, :state]) || "unknown"
      state = next_state(previous, input)

      append("PrGateObserved", %{
        pr_id: pr_id,
        run_id: run_id,
        state: state,
        previous_state: previous,
        checks: Map.get(input, :checks, "pending"),
        review: Map.get(input, :review, "pending"),
        stable_for_seconds: Map.get(input, :stable_for_seconds, 0),
        url: Map.get(input, :url)
      })
    end
  end

  @spec merge(map()) :: {:ok, map()} | {:error, term()}
  def merge(input) when is_map(input) do
    input = atomize_keys(input)

    with {:ok, pr_id} <- required_binary(Map.get(input, :pr_id), :pr_id),
         {:ok, run_id} <- required_binary(Map.get(input, :run_id, pr_id), :run_id),
         :ok <- revalidate(pr_id, input) do
      case VcsAdapter.merge_branch(%{
             backend: Map.get(input, :backend, "git"),
             run_id: run_id,
             branch: Map.get(input, :branch, "pr/#{pr_id}"),
             target: Map.get(input, :target, "main"),
             operation_id: "merge-pr-#{pr_id}"
           }) do
        {:ok, vcs} ->
          append("PrMerged", %{
            pr_id: pr_id,
            run_id: run_id,
            state: "merged",
            vcs_operation_id: vcs.result.operation_id,
            branch: Map.get(input, :branch, "pr/#{pr_id}"),
            target: Map.get(input, :target, "main")
          })

        {:error, reason} ->
          append("MergeFailed", %{
            pr_id: pr_id,
            run_id: run_id,
            state: "failed",
            reason: inspect(reason),
            report: %{failure_reason: inspect(reason)}
          })
      end
    else
      {:error, {:merge_gate_not_ready, details}} = error ->
        _ =
          append(
            "MergeBlocked",
            Map.merge(input, %{state: "failed", reason: "merge_gate_not_ready", details: details})
          )

        error

      error ->
        error
    end
  end

  defp revalidate(pr_id, input) do
    observed =
      Map.get(input, :observed_state) ||
        get_in(ProjectionStore.snapshot(), [:pr_gates, pr_id, :state])

    if observed == "stable_ready" do
      :ok
    else
      {:error, {:merge_gate_not_ready, %{pr_id: pr_id, observed_state: observed || "unknown"}}}
    end
  end

  defp next_state(_previous, %{checks: "failed"}), do: "failed"
  defp next_state(_previous, %{review: "changes_requested"}), do: "failed"
  defp next_state("pending", %{checks: "pending"}), do: "seen_pending"

  defp next_state("seen_pending", %{
         checks: "success",
         review: "approved",
         stable_for_seconds: seconds
       })
       when seconds >= 30,
       do: "stable_ready"

  defp next_state(_previous, %{checks: "success", review: "approved", stable_for_seconds: seconds})
       when seconds >= 30,
       do: "stable_ready"

  defp next_state(_previous, %{checks: "success", review: "approved"}), do: "pending"
  defp next_state(_previous, _input), do: "pending"

  defp append(event_type, payload) do
    payload = Map.put(payload, :observed_at, DateTime.utc_now())

    with {:ok, event} <-
           EventStore.append(%{
             stream_id: "pr:#{Map.get(payload, :pr_id, Map.get(payload, :run_id, "unknown"))}",
             event_type: event_type,
             payload: payload,
             metadata: %{
               correlation_id: Map.get(payload, :run_id, Map.get(payload, :pr_id)),
               idempotency_key:
                 "#{event_type}:#{Map.get(payload, :pr_id)}:#{System.unique_integer([:positive])}"
             }
           }) do
      {:ok, %{event: event, projection: ProjectionStore.snapshot(), result: payload}}
    end
  end

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), atomize_value(value)}
      {key, value} -> {key, atomize_value(value)}
    end)
  end

  defp atomize_value(value) when is_map(value), do: atomize_keys(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value
end
