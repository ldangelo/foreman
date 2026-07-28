defmodule ForemanServer.Aggregates.Run do
  @moduledoc "Run aggregate: validates run lifecycle commands and folds phase/worker events."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  defmodule PhaseStatus do
    @moduledoc "Phase status keyed by phase_id."
    @enforce_keys [:phase_id]
    defstruct [:phase_id, :status, metadata: %{}]
  end

  defmodule WorkerStatus do
    @moduledoc "Worker status keyed by worker_id."
    @enforce_keys [:worker_id]
    defstruct [:worker_id, :status, metadata: %{}]
  end

  defmodule RetryEntry do
    @moduledoc "A retry attempt entry in the history."
    @enforce_keys [:attempt]
    defstruct [:attempt, :run_id, :reason, metadata: %{}]
  end

  defmodule State do
    @enforce_keys [:exists?]
    defstruct [
      :exists?,
      :run_id,
      :task_id,
      :status,
      :terminal?,
      :last_sequence,
      phase_status: %{},
      worker_status: %{},
      retry_history: []
    ]
  end
  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      run_id: nil,
      task_id: nil,
      status: nil,
      terminal?: false,
      last_sequence: 0,
      phase_status: %{},
      worker_status: %{},
      retry_history: []
    }

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
            status: "in_progress"
        }

      "RunUpdated" ->
        %State{
          state
          | exists?: true,
            run_id: Aggregate.get(payload, :run_id),
            task_id: Aggregate.get(payload, :task_id) || state.task_id
        }

      type when type in ["PrUpdated", "PrReady", "PrRetargeted", "PrReset", "PrMerged"] ->
        %State{state | exists?: true, run_id: Aggregate.get(payload, :run_id)}

      "RunCompleted" ->
        %State{
          state
          | status: "completed",
            terminal?: true,
            run_id: Aggregate.get(payload, :run_id),
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunFailed" ->
        %State{
          state
          | status: "failed",
            terminal?: true,
            run_id: Aggregate.get(payload, :run_id),
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunBlocked" ->
        %State{
          state
          | status: "blocked",
            terminal?: true,
            run_id: Aggregate.get(payload, :run_id),
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunDeleted" ->
        %State{state | status: "deleted", terminal?: true}

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
       %ForemanServer.Events.RunStarted{
         run_id: run_id,
         task_id: Aggregate.get(payload, :task_id)
       }}
    end
  end

  def handle_command(state, %{type: "run.update", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      {:ok,
       %ForemanServer.Events.RunUpdated{
         run_id: run_id,
         task_id: Aggregate.get(payload, :task_id)
       }}
    end
  end

  def handle_command(state, %{type: "run.delete", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_delete_on_terminal(state) do
      {:ok, %ForemanServer.Events.RunDeleted{run_id: run_id}}
    end
  end

  # run.complete — AC2 sequence guard
  def handle_command(state, %{type: "run.complete", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- require_sequence(state, Aggregate.get(payload, :sequence)),
         :ok <- reject_terminal_mutation(state) do
      {:ok,
       %ForemanServer.Events.RunCompleted{
         run_id: run_id,
         sequence: Aggregate.get(payload, :sequence)
       }}
    end
  end

  # run.fail — no sequence guard
  def handle_command(state, %{type: "run.fail", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      {:ok, %ForemanServer.Events.RunFailed{run_id: run_id}}
    end
  end

  # run.block — no sequence guard
  def handle_command(state, %{type: "run.block", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      {:ok, %ForemanServer.Events.RunBlocked{run_id: run_id}}
    end
  end

  def handle_command(state, %{type: "run.pr.update", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_pr_lifecycle_on_terminal_runs(state, "run.pr.update"),
         :ok <- require_pr_payload("run.pr.update", payload) do
      {:ok,
       %ForemanServer.Events.PrUpdated{
         run_id: run_id,
         project_id: Aggregate.get(payload, :project_id),
         task_id: Aggregate.get(payload, :task_id),
         pr_url: Aggregate.get(payload, :pr_url),
         branch_name: Aggregate.get(payload, :branch_name),
         head_sha: Aggregate.get(payload, :head_sha),
         base_branch: Aggregate.get(payload, :base_branch),
         phase: Aggregate.get(payload, :phase)
       }}
    end
  end

  def handle_command(state, %{type: "run.pr.ready", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_pr_lifecycle_on_terminal_runs(state, "run.pr.ready"),
         :ok <- require_pr_payload("run.pr.ready", payload) do
      {:ok,
       %ForemanServer.Events.PrReady{
         run_id: run_id,
         project_id: Aggregate.get(payload, :project_id),
         task_id: Aggregate.get(payload, :task_id),
         pr_url: Aggregate.get(payload, :pr_url),
         branch_name: Aggregate.get(payload, :branch_name),
         head_sha: Aggregate.get(payload, :head_sha),
         base_branch: Aggregate.get(payload, :base_branch)
       }}
    end
  end

  def handle_command(state, %{type: "run.pr.retarget", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_pr_lifecycle_on_terminal_runs(state, "run.pr.retarget"),
         :ok <- require_pr_payload("run.pr.retarget", payload) do
      {:ok,
       %ForemanServer.Events.PrRetargeted{
         run_id: run_id,
         project_id: Aggregate.get(payload, :project_id),
         task_id: Aggregate.get(payload, :task_id),
         pr_url: Aggregate.get(payload, :pr_url),
         branch_name: Aggregate.get(payload, :branch_name),
         old_base_branch: Aggregate.get(payload, :old_base_branch),
         new_base_branch: Aggregate.get(payload, :new_base_branch),
         head_sha: Aggregate.get(payload, :head_sha)
       }}
    end
  end

  def handle_command(state, %{type: "run.pr.reset", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_pr_lifecycle_on_terminal_runs(state, "run.pr.reset"),
         :ok <- require_pr_payload("run.pr.reset", payload) do
      {:ok,
       %ForemanServer.Events.PrReset{
         run_id: run_id,
         project_id: Aggregate.get(payload, :project_id),
         task_id: Aggregate.get(payload, :task_id),
         pr_url: Aggregate.get(payload, :pr_url),
         branch_name: Aggregate.get(payload, :branch_name),
         action: Aggregate.get(payload, :action),
         reason: Aggregate.get(payload, :reason)
       }}
    end
  end

  def handle_command(state, %{type: "run.pr.merge", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_pr_lifecycle_on_terminal_runs(state, "run.pr.merge"),
         :ok <- require_pr_payload("run.pr.merge", payload) do
      {:ok,
       %ForemanServer.Events.PrMerged{
         run_id: run_id,
         project_id: Aggregate.get(payload, :project_id),
         task_id: Aggregate.get(payload, :task_id),
         pr_url: Aggregate.get(payload, :pr_url),
         branch_name: Aggregate.get(payload, :branch_name)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp put_phase(state, payload, status) do
    phase_id = Aggregate.get(payload, :phase_id)

    if is_binary(phase_id) and phase_id != "" do
      entry = %PhaseStatus{
        phase_id: phase_id,
        status: status,
        metadata: Map.drop(payload, [:phase_id])
      }

      %State{state | phase_status: Map.put(state.phase_status, phase_id, entry)}
    else
      state
    end
  end

  defp put_worker(state, payload, status) do
    worker_id = Aggregate.get(payload, :worker_id)

    if is_binary(worker_id) and worker_id != "" do
      entry = %WorkerStatus{
        worker_id: worker_id,
        status: status,
        metadata: Map.drop(payload, [:worker_id])
      }

      %State{state | worker_status: Map.put(state.worker_status, worker_id, entry)}
    else
      state
    end
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

  defp require_absent(_state, _run_id), do: :ok

  defp require_exists(%State{exists?: true, run_id: run_id}, run_id), do: :ok
  defp require_exists(%State{}, run_id), do: {:error, {:not_found, :run, run_id}}

  defp require_sequence(%State{last_sequence: last_sequence}, sequence)
       when is_integer(sequence) and sequence == last_sequence + 1,
       do: :ok
  defp require_sequence(%State{last_sequence: last_sequence}, sequence)
       when is_integer(sequence) and sequence > last_sequence + 1,
       do: {:error, :out_of_order}
  defp require_sequence(%State{}, nil), do: :ok
  defp require_sequence(%State{}, _sequence), do: {:error, :out_of_order}
  # NOTE: MapSet.member? is not guard-safe in older Elixir; using literal type guard
  defp reject_terminal_mutation(%State{status: status})
       when status in ["completed", "failed", "blocked", "cancelled", "deleted"],
       do: {:error, {:run_terminal, status}}

  defp reject_terminal_mutation(_state), do: :ok

  defp allow_delete_on_terminal(%State{status: "deleted"}),
    do: {:error, {:run_terminal, "deleted"}}

  defp allow_delete_on_terminal(_state), do: :ok
end
