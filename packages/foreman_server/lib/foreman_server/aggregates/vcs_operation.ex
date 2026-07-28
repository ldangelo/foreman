defmodule ForemanServer.Aggregates.VcsOperation do
  @moduledoc "VCS operation aggregate: folds worktree/merge/PR gate events and validates terminal operations."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule State do
    @enforce_keys [:exists?, :operation_id, :status, :terminal?]
    defstruct [:exists?, :operation_id, :status, :terminal?]
  end

  @terminal_statuses MapSet.new(["cleaned", "merged", "failed", "blocked"])

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      operation_id: nil,
      status: nil,
      terminal?: false
    }

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "WorktreeCreated" ->
        %State{
          state
          | exists?: true,
            operation_id: Aggregate.get(payload, :operation_id),
            status: "created"
        }

      "WorktreeCleaned" ->
        %State{
          state
          | operation_id: Aggregate.get(payload, :operation_id),
            status: "cleaned",
            terminal?: true
        }

      "VcsMergeRequested" ->
        %State{
          state
          | exists?: true,
            operation_id: Aggregate.get(payload, :operation_id),
            status: "merge_requested"
        }

      "PrGateObserved" ->
        %State{
          state
          | exists?: true,
            operation_id: Aggregate.get(payload, :operation_id),
            status: "pr_observed"
        }

      "VcsPrMerged" ->
        %State{
          state
          | operation_id: Aggregate.get(payload, :operation_id),
            status: "merged",
            terminal?: true
        }
      "MergeFailed" ->
        %State{
          state
          | operation_id: Aggregate.get(payload, :operation_id),
            status: "failed",
            terminal?: true
        }

      "MergeBlocked" ->
        %State{
          state
          | operation_id: Aggregate.get(payload, :operation_id),
            status: "blocked",
            terminal?: true
        }

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
      event =
        case type do
          "vcs.worktree.create" -> %ForemanServer.Events.WorktreeCreated{operation_id: operation_id}
          "vcs.worktree.clean" -> %ForemanServer.Events.WorktreeCleaned{operation_id: operation_id}
          "vcs.merge.request" -> %ForemanServer.Events.VcsMergeRequested{operation_id: operation_id}
          "vcs.pr.observe" -> %ForemanServer.Events.PrGateObserved{operation_id: operation_id}
          "vcs.pr.merge" -> %ForemanServer.Events.VcsPrMerged{operation_id: operation_id}
          "vcs.merge.fail" -> %ForemanServer.Events.MergeFailed{operation_id: operation_id}
          "vcs.merge.block" -> %ForemanServer.Events.MergeBlocked{operation_id: operation_id}
        end

      {:ok, event}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp require_existing_operation_for_terminal(_state, type)
       when type in ["vcs.worktree.create", "vcs.merge.request", "vcs.pr.observe"],
       do: :ok

  defp require_existing_operation_for_terminal(%State{exists?: true}, _type), do: :ok

  defp require_existing_operation_for_terminal(_state, type),
    do: {:error, {:vcs_operation_not_started, type}}

  defp reject_terminal(%State{status: status}, _type) do
    if MapSet.member?(@terminal_statuses, status),
      do: {:error, {:vcs_operation_terminal, status}},
      else: :ok
  end
end
