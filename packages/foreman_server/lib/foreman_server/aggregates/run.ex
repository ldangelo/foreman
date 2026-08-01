defmodule ForemanServer.Aggregates.Run do
  @moduledoc "Run aggregate: validates run lifecycle commands and folds legacy run/worker phase events."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.{Aggregate, PrGate}

  defmodule State do
    @moduledoc false
    @enforce_keys [:exists?, :terminal?]
    defstruct [
      :exists?,
      :run_id,
      :task_id,
      :project_id,
      :status,
      :terminal?,
      :current_phase,
      :phase_order,
      :worktree_path,
      :branch,
      :base_ref,
      :pr_url,
      :pr_number,
      :association_id,
      :head_sha,
      :base_branch,
      :pr_state,
      phase_status: %{},
      worker_status: %{},
      retry_history: []
    ]

    @type t :: %__MODULE__{
            exists?: boolean(),
            run_id: String.t() | nil,
            task_id: String.t() | nil,
            project_id: String.t() | nil,
            status: String.t() | nil,
            terminal?: boolean(),
            current_phase: String.t() | nil,
            phase_order: [String.t()] | nil,
            worktree_path: String.t() | nil,
            branch: String.t() | nil,
            base_ref: String.t() | nil,
            pr_url: String.t() | nil,
            pr_number: String.t() | nil,
            association_id: String.t() | nil,
            head_sha: String.t() | nil,
            base_branch: String.t() | nil,
            pr_state: String.t() | nil,
            phase_status: %{optional(String.t()) => String.t()},
            worker_status: %{optional(String.t()) => String.t()},
            retry_history: [map()]
          }
  end

  @terminal_statuses MapSet.new(["completed", "failed", "blocked", "cancelled", "deleted"])

  @impl true
  def initial_state, do: %State{exists?: false, terminal?: false}

  @impl true
  def apply_event(state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "RunStarted" ->
        %State{
          state
          | exists?: true,
            run_id: Aggregate.get(payload, :run_id),
            task_id: Aggregate.get(payload, :task_id),
            project_id: Aggregate.get(payload, :project_id),
            status: "in_progress",
            terminal?: false,
            current_phase: Aggregate.get(payload, :current_phase),
            phase_order: Aggregate.get(payload, :phase_order),
            worktree_path: Aggregate.get(payload, :worktree_path),
            branch: Aggregate.get(payload, :branch),
            base_ref: Aggregate.get(payload, :base_ref)
        }

      "RunUpdated" ->
        s1 = %State{state | exists?: true}

        s1
        |> apply_opt(:pr_url, Aggregate.get(payload, :pr_url))
        |> apply_opt(:head_sha, Aggregate.get(payload, :head_sha))
        |> apply_opt(:base_branch, Aggregate.get(payload, :base_branch))
        |> apply_opt(:worktree_path, Aggregate.get(payload, :worktree_path))
        |> apply_opt(:branch, Aggregate.get(payload, :branch))
        |> apply_opt(:base_ref, Aggregate.get(payload, :base_ref))
        |> apply_opt(:current_phase, Aggregate.get(payload, :current_phase))
        |> apply_opt(:phase_order, Aggregate.get(payload, :phase_order))

      type when type in ["PrUpdated", "PrReady", "PrRetargeted", "PrReset", "PrMerged"] ->
        s1 = %State{state | exists?: true}

        s1
        |> apply_opt(:pr_url, Aggregate.get(payload, :pr_url))
        |> apply_opt(:head_sha, Aggregate.get(payload, :head_sha))
        |> apply_opt(:base_branch, Aggregate.get(payload, :base_branch))
        |> apply_opt(:pr_state, pr_state_for_event(type, payload, state))

      "PrAssociated" ->
        %State{state | exists?: true}
        |> apply_opt(:pr_url, Aggregate.get(payload, :pr_url))
        |> apply_opt(:pr_number, Aggregate.get(payload, :pr_number))
        |> apply_opt(:association_id, Aggregate.get(payload, :association_id))
        |> apply_opt(:pr_state, Aggregate.get(payload, :pr_state) || state.pr_state || "open")

      "RunCompleted" ->
        %State{state | status: "completed", terminal?: true}

      "RunFailed" ->
        %State{state | status: "failed", terminal?: true}

      "RunBlocked" ->
        %State{state | status: "blocked", terminal?: true}

      "RunPaused" ->
        %State{state | status: "paused", terminal?: false}

      "RunFlaggedStuck" ->
        %State{state | status: "stuck"}

      "RunDeleted" ->
        %State{state | status: "deleted", terminal?: true}

      # No-op: run already terminal, state unchanged
      "RunAlreadyCompleted" ->
        state

      "PhaseStarted" ->
        put_phase(state, payload, "in_progress")

      "PhaseCompleted" ->
        put_phase(state, payload, "completed")

      "PhaseFailed" ->
        put_phase(state, payload, "failed")

      "PhaseTimedOut" ->
        put_phase(state, payload, "timed_out")

      "PhaseRetried" ->
        put_phase(state, payload, "retrying")

      "WorkerStarted" ->
        put_worker(state, payload, "running")

      "WorkerHeartbeat" ->
        put_worker(state, payload, "heartbeat")

      "ToolCallFinished" ->
        put_worker(state, payload, "running")

      _ ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "run.start", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_absent(state, run_id) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunStarted",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put(:status, "in_progress")
           |> drop_lifecycle_fields()
       }}
    end
  end

  def handle_command(state, %{type: "run.update", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state),
         :ok <- allow_merge_pending_transition(run_id, payload) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunUpdated",
         payload: payload |> Map.put(:run_id, run_id) |> drop_lifecycle_fields()
       }}
    end
  end

  def handle_command(state, %{type: "run.delete", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_delete_on_terminal(state) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunDeleted",
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  def handle_command(state, %{type: "run.complete", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id) do
      if MapSet.member?(@terminal_statuses, state.status) do
        # Idempotent: run is already terminal — append RunAlreadyCompleted, state unchanged
        {:ok,
         %{
           stream_id: "run:#{run_id}",
           event_type: "RunAlreadyCompleted",
           payload: Map.put(payload, :run_id, run_id)
         }}
      else
        {:ok,
         %{
           stream_id: "run:#{run_id}",
           event_type: "RunCompleted",
           payload: Map.put(payload, :run_id, run_id)
         }}
      end
    end
  end

  def handle_command(state, %{type: "run.phase.nudge", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "PhaseNudged",
         payload: Map.merge(payload, %{run_id: run_id, phase_id: phase_id})
       }}
    end
  end

  def handle_command(state, %{type: type, payload: payload})
      when type in ["run.fail", "run.block", "run.pause"] do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      event_type = %{"run.fail" => "RunFailed", "run.block" => "RunBlocked", "run.pause" => "RunPaused"}[type]

      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: event_type,
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  # Idempotent: if already stuck, return error so StuckDetector skips telemetry.
  def handle_command(state, %{type: "run.flag_stuck", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      if state.status == "stuck" do
        {:error, :already_stuck}
      else
        {:ok,
         %{
           stream_id: "run:#{run_id}",
           event_type: "RunFlaggedStuck",
           payload: Map.put(payload, :run_id, run_id)
         }}
      end
    end
  end

  def handle_command(state, %{type: "run.recover", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         {:ok, outcome} <- Aggregate.required_binary(Aggregate.get(payload, :outcome), :outcome) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunRecoveryEvent",
         payload: payload |> Map.put(:run_id, run_id) |> Map.put(:outcome, outcome)
       }}
    end
  end

  def handle_command(state, %{type: type, payload: payload})
      when type in [
             "run.pr.update",
             "run.pr.ready",
             "run.pr.retarget",
             "run.pr.reset",
             "run.pr.merge"
           ] do
    event_type =
      %{
        "run.pr.update" => "PrUpdated",
        "run.pr.ready" => "PrReady",
        "run.pr.retarget" => "PrRetargeted",
        "run.pr.reset" => "PrReset",
        "run.pr.merge" => "PrMerged"
      }[type]

    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_pr_lifecycle_on_terminal_runs(state, type),
         :ok <- require_pr_payload(type, payload) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: event_type,
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  def handle_command(state, %{type: "pr.associate", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- require_status(state, "completed"),
         {:ok, pr_url} <- Aggregate.required_binary(Aggregate.get(payload, :pr_url), :pr_url),
         {:ok, pr_number} <-
           Aggregate.required_binary(Aggregate.get(payload, :pr_number), :pr_number) do
      association_id = "#{run_id}:#{pr_url}"

      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "PrAssociated",
         payload: %{
           run_id: run_id,
           pr_url: pr_url,
           pr_number: pr_number,
           association_id: association_id
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  # ─── Private helpers ────────────────────────────────────────────────────────

  defp put_phase(state, payload, status) do
    case Aggregate.get(payload, :phase_id) do
      phase_id when is_binary(phase_id) and phase_id != "" ->
        %State{
          state
          | current_phase: phase_id,
            phase_status: Map.put(state.phase_status || %{}, phase_id, status)
        }

      _ ->
        state
    end
  end

  defp put_worker(state, payload, status) do
    case Aggregate.get(payload, :worker_id) do
      worker_id when is_binary(worker_id) and worker_id != "" ->
        %State{
          state
          | worker_status: Map.put(state.worker_status || %{}, worker_id, status)
        }

      _ ->
        state
    end
  end

  # ─── apply_opt: conditional struct field update, returns %State{} ─────────────
  defp apply_opt(s, _field, nil), do: s
  defp apply_opt(s, :current_phase, v), do: %State{s | current_phase: v}
  defp apply_opt(s, :phase_order, v), do: %State{s | phase_order: v}
  defp apply_opt(s, :worktree_path, v), do: %State{s | worktree_path: v}
  defp apply_opt(s, :branch, v), do: %State{s | branch: v}
  defp apply_opt(s, :base_ref, v), do: %State{s | base_ref: v}
  defp apply_opt(s, :pr_url, v), do: %State{s | pr_url: v}
  defp apply_opt(s, :pr_number, v), do: %State{s | pr_number: v}
  defp apply_opt(s, :association_id, v), do: %State{s | association_id: v}
  defp apply_opt(s, :head_sha, v), do: %State{s | head_sha: v}
  defp apply_opt(s, :base_branch, v), do: %State{s | base_branch: v}
  defp apply_opt(s, :pr_state, v), do: %State{s | pr_state: v}


  defp drop_lifecycle_fields(payload) do
    Map.drop(payload, [
      :status,
      "status",
      :terminal?,
      "terminal?",
      :completed_at,
      "completed_at",
      :failed_at,
      "failed_at",
      :blocked_at,
      "blocked_at"
    ])
  end

  defp require_pr_payload(type, payload) do
    required =
      [:project_id, :task_id, :pr_url, :branch_name]
      |> Kernel.++(
        case type do
          "run.pr.update" -> [:head_sha, :base_branch, :phase]
          "run.pr.ready" -> [:head_sha, :base_branch]
          "run.pr.retarget" -> [:old_base_branch, :new_base_branch, :head_sha]
          "run.pr.reset" -> [:action, :reason]
          "run.pr.merge" -> []
        end
      )

    with :ok <- require_required_binaries(payload, required),
         :ok <- validate_pr_reset_action(type, Aggregate.get(payload, :action)) do
      :ok
    end
  end

  defp require_required_binaries(_payload, []), do: :ok

  defp require_required_binaries(payload, [key | rest]) do
    with {:ok, _value} <- Aggregate.required_binary(Aggregate.get(payload, key), key) do
      require_required_binaries(payload, rest)
    end
  end

  defp validate_pr_reset_action("run.pr.reset", "closed"), do: :ok

  defp validate_pr_reset_action("run.pr.reset", action),
    do: {:error, {:invalid_pr_reset_action, action}}

  defp validate_pr_reset_action(_type, _action), do: :ok

  defp pr_state_for_event("PrUpdated", payload, state),
    do: Aggregate.get(payload, :pr_state) || state.pr_state

  defp pr_state_for_event("PrReady", _payload, _state), do: "open"
  defp pr_state_for_event("PrReset", _payload, _state), do: "closed"
  defp pr_state_for_event("PrMerged", _payload, _state), do: "merged"
  defp pr_state_for_event("PrRetargeted", _payload, state), do: state.pr_state

  defp allow_merge_pending_transition(run_id, payload) do
    if merge_pending_transition?(payload) do
      PrGate.check(run_id)
    else
      :ok
    end
  end

  defp merge_pending_transition?(payload) do
    current_phase = Aggregate.get(payload, :current_phase)
    phase_id = Aggregate.get(payload, :phase_id)
    status = Aggregate.get(payload, :status)

    current_phase in ["merge-pending", "merge_pending"] or
      phase_id in ["merge-pending", "merge_pending"] or
      status in ["merge-pending", "merge_pending"]
  end

  defp allow_pr_lifecycle_on_terminal_runs(_state, type)
       when type in [
              "run.pr.update",
              "run.pr.ready",
              "run.pr.retarget",
              "run.pr.reset",
              "run.pr.merge"
            ],
       do: :ok

  defp require_absent(%State{exists?: true}, run_id),
    do: {:error, {:already_exists, :run, run_id}}

  defp require_absent(%State{}, _run_id), do: :ok

  defp require_exists(%State{exists?: true}, _run_id), do: :ok
  defp require_exists(%State{}, run_id), do: {:error, {:not_found, :run, run_id}}

  defp require_status(%State{status: status}, expected) do
    if status == expected,
      do: :ok,
      else: {:error, {:invalid_run_status, expected, status}}
  end

  defp reject_terminal_mutation(%State{status: status}) do
    if MapSet.member?(@terminal_statuses, status),
      do: {:error, {:run_terminal, status}},
      else: :ok
  end

  # Allow delete for terminal runs that are not already deleted.
  defp allow_delete_on_terminal(%State{status: "deleted"}),
    do: {:error, {:run_terminal, "deleted"}}

  defp allow_delete_on_terminal(%State{}), do: :ok
end
