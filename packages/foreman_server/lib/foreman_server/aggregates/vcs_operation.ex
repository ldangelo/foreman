defmodule ForemanServer.Aggregates.VcsOperation do
  @moduledoc "VCS operation aggregate: folds worktree/merge/PR gate events and validates terminal operations."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @terminal_statuses MapSet.new(["cleaned", "merged", "failed", "blocked"])

  @impl true
  def initial_state, do: %{exists?: false, status: nil}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "WorktreeCreated" ->
        state |> Map.merge(payload) |> Map.put(:exists?, true) |> Map.put(:status, "created")

      "WorktreeCleaned" ->
        state |> Map.merge(payload) |> Map.put(:status, "cleaned") |> Map.put(:terminal?, true)

      "VcsMergeRequested" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:status, "merge_requested")

      "PrGateObserved" ->
        state |> Map.merge(payload) |> Map.put(:exists?, true) |> Map.put(:status, "pr_observed")

      "PrMerged" ->
        state |> Map.merge(payload) |> Map.put(:status, "merged") |> Map.put(:terminal?, true)

      "MergeFailed" ->
        state |> Map.merge(payload) |> Map.put(:status, "failed") |> Map.put(:terminal?, true)

      "MergeBlocked" ->
        state |> Map.merge(payload) |> Map.put(:status, "blocked") |> Map.put(:terminal?, true)

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: type, payload: payload})
      when type in [
             "vcs.worktree.create",
             "vcs.worktree.clean",
             "vcs.merge.request",
             "vcs.pr.observe",
             "vcs.pr.merge",
             "vcs.merge.fail",
             "vcs.merge.block"
           ] do
    with {:ok, operation_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :operation_id), :operation_id),
         :ok <- require_existing_operation_for_terminal(state, type),
         :ok <- reject_terminal(state, type) do
      event_type =
        %{
          "vcs.worktree.create" => "WorktreeCreated",
          "vcs.worktree.clean" => "WorktreeCleaned",
          "vcs.merge.request" => "VcsMergeRequested",
          "vcs.pr.observe" => "PrGateObserved",
          "vcs.pr.merge" => "PrMerged",
          "vcs.merge.fail" => "MergeFailed",
          "vcs.merge.block" => "MergeBlocked"
        }[type]

      {:ok,
       %{
         stream_id: "vcs:#{operation_id}",
         event_type: event_type,
         payload: Map.put(payload, :operation_id, operation_id)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_existing_operation_for_terminal(_state, type)
       when type in ["vcs.worktree.create", "vcs.merge.request", "vcs.pr.observe"],
       do: :ok

  defp require_existing_operation_for_terminal(%{exists?: true}, _type), do: :ok

  defp require_existing_operation_for_terminal(_state, type),
    do: {:error, {:vcs_operation_not_started, type}}

  defp reject_terminal(%{status: status}, _type) do
    if MapSet.member?(@terminal_statuses, status),
      do: {:error, {:vcs_operation_terminal, status}},
      else: :ok
  end
end
