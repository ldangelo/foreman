defmodule ForemanServer.Aggregates.VcsOperation do
  @moduledoc "VCS operation aggregate: folds legacy worktree/merge events and validates VCS lifecycle events."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @terminal_statuses MapSet.new(["blocked", "cleaned", "completed", "failed", "merged"])
  @legacy_commands [
    "vcs.worktree.create",
    "vcs.worktree.clean",
    "vcs.merge.request",
    "vcs.pr.observe",
    "vcs.pr.merge",
    "vcs.merge.fail",
    "vcs.merge.block"
  ]
  @lifecycle_commands ["vcs.operation.start", "vcs.operation.complete", "vcs.operation.fail"]

  @impl true
  def initial_state, do: %{exists?: false, status: nil, terminal?: false}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "VcsOperationStarted" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:status, "started")
        |> Map.put(:terminal?, false)

      "VcsOperationCompleted" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:status, "completed")
        |> Map.put(:terminal?, true)

      "VcsOperationFailed" ->
        state
        |> Map.merge(payload)
        |> Map.put(:exists?, true)
        |> Map.put(:status, "failed")
        |> Map.put(:terminal?, true)

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
  def handle_command(state, %{type: type, payload: payload}) do
    if type in @legacy_commands or type in @lifecycle_commands do
      with {:ok, operation_id} <-
             Aggregate.required_binary(Aggregate.get(payload, :operation_id), :operation_id),
           :ok <- validate_transition(state, type) do
        {:ok,
         %{
           stream_id: "vcs:#{operation_id}",
           event_type: event_type(type),
           payload: Map.put(payload, :operation_id, operation_id)
         }}
      end
    else
      :unhandled
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp validate_transition(state, "vcs.operation.start") do
    cond do
      Map.get(state, :exists?) and not Map.get(state, :terminal?, false) ->
        {:error, {:vcs_operation_already_started, Map.get(state, :status)}}

      Map.get(state, :terminal?, false) ->
        {:error, {:vcs_operation_terminal, Map.get(state, :status)}}

      true ->
        :ok
    end
  end

  defp validate_transition(state, type) do
    with :ok <- require_existing_operation_for_terminal(state, type),
         :ok <- reject_terminal(state, type) do
      :ok
    end
  end

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

  defp event_type("vcs.operation.start"), do: "VcsOperationStarted"
  defp event_type("vcs.operation.complete"), do: "VcsOperationCompleted"
  defp event_type("vcs.operation.fail"), do: "VcsOperationFailed"
  defp event_type("vcs.worktree.create"), do: "WorktreeCreated"
  defp event_type("vcs.worktree.clean"), do: "WorktreeCleaned"
  defp event_type("vcs.merge.request"), do: "VcsMergeRequested"
  defp event_type("vcs.pr.observe"), do: "PrGateObserved"
  defp event_type("vcs.pr.merge"), do: "PrMerged"
  defp event_type("vcs.merge.fail"), do: "MergeFailed"
  defp event_type("vcs.merge.block"), do: "MergeBlocked"
end
