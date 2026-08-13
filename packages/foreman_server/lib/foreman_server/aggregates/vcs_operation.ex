defmodule ForemanServer.Aggregates.VcsOperation do
  @moduledoc "VCS operation aggregate: folds worktree/merge/PR gate events and validates terminal operations."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.EventCodec
  alias ForemanServer.Events.{WorktreeCreated, WorktreeCleaned}

  defmodule State do
    @enforce_keys [:exists?, :operation_id, :status, :terminal?]
    defstruct [
      :exists?,
      :operation_id,
      :project_id,
      :run_id,
      :phase_id,
      :status,
      :terminal?,
      :worktree_path,
      :branch,
      :base_ref,
      :cleanup
    ]
  end

  @terminal_statuses MapSet.new(["cleaned", "merged", "failed", "blocked"])

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      operation_id: nil,
      project_id: nil,
      run_id: nil,
      phase_id: nil,
      status: nil,
      terminal?: false,
      worktree_path: nil,
      branch: nil,
      base_ref: nil,
      cleanup: nil
    }

  @impl true
  def apply_event(state, event) do
    case Aggregate.event_type(event) do
      "WorktreeCreated" ->
        payload =
          event
          |> Aggregate.event_payload()
          |> Map.delete(:event_type)
          |> Map.delete("event_type")

        apply_typed_event(state, EventCodec.decode!("WorktreeCreated", payload))

      "WorktreeCleaned" ->
        payload =
          event
          |> Aggregate.event_payload()
          |> Map.delete(:event_type)
          |> Map.delete("event_type")

        apply_typed_event(state, EventCodec.decode!("WorktreeCleaned", payload))

      _ ->
        apply_untyped_event(state, event)
    end
  end

  defp apply_typed_event(state, %WorktreeCreated{} = e) do
    %State{
      state
      | exists?: true,
        operation_id: e.operation_id,
        project_id: e.project_id,
        run_id: e.run_id,
        phase_id: e.phase_id,
        status: "created",
        worktree_path: e.worktree_path,
        branch: e.branch,
        base_ref: e.base_ref,
        cleanup: e.cleanup
    }
  end

  defp apply_typed_event(state, %WorktreeCleaned{} = e) do
    %State{
      state
      | operation_id: e.operation_id,
        project_id: e.project_id,
        run_id: e.run_id,
        phase_id: e.phase_id,
        status: "cleaned",
        terminal?: true,
        worktree_path: e.worktree_path || state.worktree_path
    }
  end

  defp apply_untyped_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
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

      "PrMerged" ->
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

      "VcsOperationStarted" ->
        %State{state | status: "started", operation_id: Aggregate.get(payload, :operation_id)}

      "VcsOperationCompleted" ->
        %State{
          state
          | status: "completed",
            terminal?: true,
            operation_id: Aggregate.get(payload, :operation_id)
        }

      "VcsOperationFailed" ->
        %State{
          state
          | status: "failed",
            terminal?: true,
            operation_id: Aggregate.get(payload, :operation_id)
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
  def handle_command(
        state,
        %{type: "vcs.worktree.create", payload: payload}
      ) do
    with {:ok, operation_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :operation_id), :operation_id),
         {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         {:ok, worktree_path} <-
           Aggregate.required_binary(Aggregate.get(payload, :worktree_path), :worktree_path),
         :ok <- require_existing_operation_for_terminal(state, "vcs.worktree.create"),
         :ok <- reject_terminal(state, "vcs.worktree.create") do
      {:ok,
       %{
         stream_id: "vcs:#{operation_id}",
         event_type: "WorktreeCreated",
         payload:
           Map.merge(payload, %{
             operation_id: operation_id,
             project_id: project_id,
             run_id: run_id,
             phase_id: phase_id,
             worktree_path: worktree_path
           })
       }}
    end
  end

  def handle_command(
        state,
        %{type: "vcs.worktree.clean", payload: payload}
      ) do
    with {:ok, operation_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :operation_id), :operation_id),
         {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         :ok <- require_existing_operation_for_terminal(state, "vcs.worktree.clean"),
         :ok <- reject_terminal(state, "vcs.worktree.clean"),
         :ok <- validate_correlation(state, operation_id, project_id, run_id, phase_id) do
      {:ok,
       %{
         stream_id: "vcs:#{operation_id}",
         event_type: "WorktreeCleaned",
         payload:
           Map.merge(payload, %{
             operation_id: operation_id,
             project_id: project_id,
             run_id: run_id,
             phase_id: phase_id
           })
       }}
    end
  end

  defp validate_correlation(
         %State{operation_id: op, project_id: p, run_id: r, phase_id: ph},
         op,
         p,
         r,
         ph
       ),
       do: :ok

  defp validate_correlation(_state, _op, _p, _r, _ph),
    do: {:error, :correlation_mismatch}

  def handle_command(state, %{type: type, payload: payload})
      when type in [
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

  def handle_command(_state, %{type: "vcs_operation.start", payload: payload}) do
    with {:ok, operation_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :operation_id), :operation_id) do
      {:ok,
       %{
         stream_id: "vcs_operation:#{operation_id}",
         event_type: "VcsOperationStarted",
         payload: payload
       }}
    end
  end

  def handle_command(_state, %{type: "vcs_operation.complete", payload: payload}) do
    with {:ok, operation_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :operation_id), :operation_id) do
      {:ok,
       %{
         stream_id: "vcs_operation:#{operation_id}",
         event_type: "VcsOperationCompleted",
         payload: payload
       }}
    end
  end

  def handle_command(_state, %{type: "vcs_operation.fail", payload: payload}) do
    with {:ok, operation_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :operation_id), :operation_id) do
      {:ok,
       %{
         stream_id: "vcs_operation:#{operation_id}",
         event_type: "VcsOperationFailed",
         payload: payload
       }}
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
