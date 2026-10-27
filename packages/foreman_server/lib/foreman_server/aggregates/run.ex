defmodule ForemanServer.Aggregates.Run do
  @moduledoc "Run aggregate: validates run lifecycle commands and folds phase/worker events."
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run.PrWatch
  alias ForemanServer.Workflow.ApproverAuthorizer
  alias ForemanServer.PrGate

  @pr_watch_types PrWatch.command_types()
  @pr_watch_events PrWatch.event_types()

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

  defmodule MergePin do
    @moduledoc """
    What one repository's merge gate holds: the PR it was opened for and, while the gate is
    approved, the head the operator approved and when. A pending gate pins no head.
    """
    defstruct [:pr_url, :head_sha, :approved_at]

    @type t :: %__MODULE__{
            pr_url: String.t() | nil,
            head_sha: String.t() | nil,
            approved_at: integer() | nil
          }
  end

  defmodule Approval do
    @moduledoc """
    The fields of a `merge_approve` command the aggregate accepts, validated: who approved, as
    which authorized identity, and the PR head they reviewed. Nothing else a caller sends is kept.
    """
    @enforce_keys [:approver, :approver_identity, :head_sha]
    defstruct [:approver, :approver_identity, :head_sha]

    @type t :: %__MODULE__{
            approver: String.t(),
            approver_identity: String.t(),
            head_sha: String.t()
          }
  end

  defmodule State do
    @enforce_keys [:exists?]
    defstruct [
      :exists?,
      :run_id,
      :task_id,
      :project_id,
      :status,
      :terminal?,
      :last_sequence,
      :base_branch,
      merge_gates: %{},
      merge_pins: %{},
      phase_status: %{},
      worker_status: %{},
      retry_history: [],
      reported_stall_keys: MapSet.new(),
      pending_steer: [],
      steer_message_ids: MapSet.new(),
      pr_watch: %{},
      pr_fixes: %{}
    ]
  end

  @impl true
  def initial_state,
    do: %State{
      exists?: false,
      run_id: nil,
      task_id: nil,
      project_id: nil,
      status: nil,
      terminal?: false,
      last_sequence: 0,
      merge_gates: %{},
      merge_pins: %{},
      base_branch: nil,
      phase_status: %{},
      worker_status: %{},
      retry_history: [],
      reported_stall_keys: MapSet.new(),
      pending_steer: [],
      steer_message_ids: MapSet.new(),
      pr_watch: %{},
      pr_fixes: %{}
    }

  @doc """
  The merge gate of one repository's PR: `:pending`, `:approved`, or `nil`
  (no PR has been readied for it). `repo_id` `nil` is the run's primary
  repository, which is also where every legacy event (no `repo_id`) folds.
  """
  @spec merge_gate(%State{}, String.t() | nil) :: :pending | :approved | nil
  def merge_gate(%State{merge_gates: gates}, repo_id \\ nil), do: Map.get(gates, repo_id)

  @doc """
  What `repo_id`'s merge gate holds (see `MergePin`), or `nil` when no PR has been readied for it.
  """
  @spec merge_pin(%State{}, String.t() | nil) :: MergePin.t() | nil
  def merge_pin(%State{merge_pins: pins}, repo_id \\ nil), do: Map.get(pins, repo_id)

  @doc """
  Whether `repo_id`'s approval no longer covers the PR as `head_sha` shows it: the gate is
  `:approved` and the head it approved differs. `pr_url` limits the check to an observation of the
  PR the gate holds; `nil` says `head_sha` is that PR's own head. A pending gate holds no approval,
  so it is never stale.
  """
  @spec stale_approval(%State{}, String.t() | nil, String.t(), String.t() | nil) ::
          {:stale, MergePin.t()} | :current
  def stale_approval(%State{} = state, repo_id, head_sha, pr_url \\ nil)
      when is_binary(head_sha) do
    case {merge_gate(state, repo_id), merge_pin(state, repo_id)} do
      {:approved, %MergePin{head_sha: approved} = pin}
      when is_binary(approved) and approved != head_sha ->
        if is_nil(pr_url) or pin.pr_url == pr_url, do: {:stale, pin}, else: :current

      {_gate, _pin} ->
        :current
    end
  end

  @doc """
  Validate the operator-supplied fields of `merge_approve` - `approver`, `approver_identity` (which
  must be on the approver allowlist) and `head_sha` - and keep only those. The aggregate handler
  and `CommandGateway` (which refuses before it reads GitHub) share this one check, so they cannot
  disagree about what a valid approval is. Errors name the field: `{:missing_or_invalid, key}`,
  or `:unauthorized_approver`.
  """
  @spec validate_approval(map()) :: {:ok, Approval.t()} | {:error, term()}
  def validate_approval(payload) when is_map(payload) do
    with {:ok, approver} <-
           Aggregate.required_binary(Aggregate.get(payload, :approver), :approver),
         {:ok, approver_identity} <-
           Aggregate.required_binary(
             Aggregate.get(payload, :approver_identity),
             :approver_identity
           ),
         {:ok, head_sha} <-
           Aggregate.required_binary(Aggregate.get(payload, :head_sha), :head_sha),
         :ok <- ApproverAuthorizer.authorize(approver_identity) do
      {:ok,
       %Approval{approver: approver, approver_identity: approver_identity, head_sha: head_sha}}
    end
  end

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      "RunStarted" ->
        %State{
          state
          | exists?: true,
            run_id: Aggregate.get(payload, :run_id),
            task_id: Aggregate.get(payload, :task_id),
            project_id: Aggregate.get(payload, :project_id),
            status: "awaiting_worker",
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunUpdated" ->
        %State{
          state
          | exists?: true,
            run_id: Aggregate.get(payload, :run_id),
            task_id: Aggregate.get(payload, :task_id) || state.task_id,
            project_id: Aggregate.get(payload, :project_id) || state.project_id
        }

      type when type in ["PrUpdated", "PrRetargeted", "PrReset", "PrMerged"] ->
        PrWatch.apply_event(
          %State{state | exists?: true, run_id: Aggregate.get(payload, :run_id)},
          type,
          payload
        )

      "PrReady" ->
        PrWatch.apply_event(
          %State{
            state
            | exists?: true,
              run_id: Aggregate.get(payload, :run_id),
              merge_gates: put_gate(state, payload, :pending),
              merge_pins: hold_pin(state, payload)
          },
          "PrReady",
          payload
        )

      "MergeGateApproved" ->
        %State{
          state
          | merge_gates: put_gate(state, payload, :approved),
            merge_pins: approve_pin(state, payload),
            run_id: Aggregate.get(payload, :run_id) || state.run_id
        }

      "RunCompleted" ->
        %State{
          state
          | status: "completed",
            terminal?: true,
            run_id: Aggregate.get(payload, :run_id),
            project_id: Aggregate.get(payload, :project_id) || state.project_id,
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunFailed" ->
        %State{
          state
          | status: "failed",
            terminal?: true,
            run_id: Aggregate.get(payload, :run_id),
            project_id: Aggregate.get(payload, :project_id) || state.project_id,
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunBlocked" ->
        %State{
          state
          | status: "blocked",
            terminal?: true,
            run_id: Aggregate.get(payload, :run_id),
            project_id: Aggregate.get(payload, :project_id) || state.project_id,
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunFlaggedStuck" ->
        %State{
          state
          | status: "stuck",
            terminal?: true,
            run_id: Aggregate.get(payload, :run_id),
            project_id: Aggregate.get(payload, :project_id) || state.project_id,
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunStallReported" ->
        status_effect = Aggregate.get(payload, :status_effect)

        %State{
          state
          | status: status_effect || state.status,
            terminal?: status_effect in ["failed", "blocked", "stuck"],
            run_id: Aggregate.get(payload, :run_id) || state.run_id,
            reported_stall_keys:
              MapSet.put(state.reported_stall_keys, Aggregate.get(payload, :idempotency_key)),
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunPaused" ->
        %State{
          state
          | status: "paused",
            run_id: Aggregate.get(payload, :run_id) || state.run_id,
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunResumed" ->
        %State{
          state
          | status: "awaiting_worker",
            terminal?: false,
            run_id: Aggregate.get(payload, :run_id) || state.run_id,
            project_id: Aggregate.get(payload, :project_id) || state.project_id,
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunCancelled" ->
        %State{
          state
          | status: "cancelled",
            terminal?: true,
            run_id: Aggregate.get(payload, :run_id),
            project_id: Aggregate.get(payload, :project_id) || state.project_id,
            last_sequence: Aggregate.get(payload, :sequence, state.last_sequence)
        }

      "RunAlreadyCompleted" ->
        # Idempotent dispatch against a terminal run — state MUST remain unchanged.
        state

      "RunDeleted" ->
        %State{state | status: "deleted", terminal?: true}

      "RunReset" ->
        initial_state()

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
        state = put_worker(state, payload, "running")
        # First worker-acknowledged liveness event flips the run from
        # "awaiting_worker" (admitted but no worker attached) to "in_progress".
        if state.status == "awaiting_worker" do
          %State{state | status: "in_progress"}
        else
          state
        end

      "WorkerHeartbeat" ->
        put_worker(state, payload, "heartbeat")

      "ToolCallFinished" ->
        put_worker(state, payload, "running")

      "RunRecoveryEvent" ->
        # Recovery-scanner emits this on startup for stale runs. The recovery
        # action sequence is owned by the Recovery aggregate; this event is
        # observed here for ordering only and does not change Run state.
        state

      "MergeGatePending" ->
        %State{
          state
          | merge_gates: put_gate(state, payload, :pending),
            merge_pins: hold_pin(state, payload),
            run_id: Aggregate.get(payload, :run_id) || state.run_id
        }

      "RunSteerQueued" ->
        message_id = Aggregate.get(payload, :message_id)

        %State{
          state
          | pending_steer:
              state.pending_steer ++
                [
                  %{
                    message_id: message_id,
                    text: Aggregate.get(payload, :text),
                    resume: Aggregate.get(payload, :resume, true),
                    delivered: false
                  }
                ],
            steer_message_ids: MapSet.put(state.steer_message_ids, message_id)
        }

      # Written to a live provider session, not yet taken by the agent. Still
      # pending: only `RunSteerConsumed` / `RunSteerUndelivered` retire a message.
      "RunSteerDelivered" ->
        message_id = Aggregate.get(payload, :message_id)

        %State{
          state
          | pending_steer:
              Enum.map(state.pending_steer, fn
                %{message_id: ^message_id} = entry -> %{entry | delivered: true}
                entry -> entry
              end)
        }

      "RunSteerUndelivered" ->
        undelivered = MapSet.new(Aggregate.get(payload, :message_ids, []))

        %State{
          state
          | pending_steer:
              Enum.reject(state.pending_steer, &MapSet.member?(undelivered, &1.message_id))
        }

      "RunSteerConsumed" ->
        consumed = MapSet.new(Aggregate.get(payload, :message_ids, []))

        %State{
          state
          | pending_steer:
              Enum.reject(state.pending_steer, &MapSet.member?(consumed, &1.message_id))
        }

      # A secondary repository's base branch (`repo_id` present) is a read-model
      # fact only: `State.base_branch` stays the run primary's.
      "RunBaseBranchRecorded" ->
        base_branch =
          if Aggregate.get(payload, :repo_id),
            do: state.base_branch,
            else: Aggregate.get(payload, :base_branch)

        %State{
          state
          | base_branch: base_branch,
            run_id: Aggregate.get(payload, :run_id) || state.run_id
        }

      # E9 PR-watch events fold into `pr_watch` / `pr_fixes`.
      type when type in @pr_watch_events ->
        PrWatch.apply_event(state, type, payload)

      # E12-S6: a repository's PR could not be created. Records nothing on the run
      # itself (it keeps its status); the per-repository read model folds it.
      "RunRepoPrFailed" ->
        %State{state | run_id: Aggregate.get(payload, :run_id) || state.run_id}

      # foreman-gr27: a worktree cleanup refusal. Like the PR failure it leaves the run's
      # status alone; the projection folds the retained path.
      "RunWorktreeRetained" ->
        %State{state | run_id: Aggregate.get(payload, :run_id) || state.run_id}

      # An event type this fold does not know replays as a no-op: a new event type
      # on a run stream must never make `Aggregate.load/2` crash.
      _other ->
        state
    end
  end

  @impl true
  def handle_command(state, %{type: "run.start", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- Aggregate.optional_binary(Aggregate.get(payload, :task_id), :task_id),
         {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         :ok <- require_workflow_snapshot(Aggregate.get(payload, :workflow_snapshot)),
         :ok <- require_absent(state, run_id) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunStarted",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put(:task_id, Aggregate.get(payload, :task_id))
           |> Map.put(:project_id, project_id)
           |> Map.delete(:status)
           |> Map.drop([:approval_id, :phase_specs])
       }}
    end
  end

  def handle_command(state, %{type: "run.update", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunUpdated",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> drop_lifecycle_fields()
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

  def handle_command(state, %{type: "run.remove", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunDeleted",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put(:project_id, state.project_id)
           |> Map.put_new(:reason, "operator_remove")
       }}
    end
  end

  def handle_command(state, %{type: "run.reset", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- require_resettable(state) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunReset",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put(:project_id, state.project_id)
           |> Map.put_new(:reason, "operator_reset")
       }}
    end
  end

  # run.complete — AC2 sequence guard.
  # On a terminal run, dispatch a `RunAlreadyCompleted` event instead of rejecting
  # — the command is idempotent and state must remain unchanged. The terminal
  # branch uses a relaxed sequence guard (accepts sequence == last_sequence
  # for bounded-retry race recovery, and sequence == last_sequence + 1 for
  # normal idempotent re-dispatch) so the recovery path can converge without
  # the caller having to know the post-race last_sequence.
  def handle_command(state, %{type: "run.complete", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id) do
      case state do
        %State{terminal?: true} ->
          with :ok <- require_terminal_sequence(state, Aggregate.get(payload, :sequence)) do
            {:ok,
             %{
               stream_id: "run:#{run_id}",
               event_type: "RunAlreadyCompleted",
               payload:
                 payload
                 |> Map.put(:run_id, run_id)
                 |> Map.put(:status, state.status)
             }}
          end

        _ ->
          with {:ok, sequence} <- complete_sequence(state, Aggregate.get(payload, :sequence)),
               :ok <- require_sequence(state, sequence) do
            {:ok,
             %{
               stream_id: "run:#{run_id}",
               event_type: "RunCompleted",
               payload:
                 payload
                 |> Map.put(:run_id, run_id)
                 |> Map.put(:sequence, sequence)
                 |> Map.put(:project_id, state.project_id)
             }}
          end
      end
    end
  end

  # run.pause — emits `RunPaused` (NON-terminal; state shape `paused`,
  # `terminal?: false` so `run.resume` is accepted). Pause is distinct
  # from RunCancelled/RunFailed. The terminal-state guard still rejects
  # pause-on-terminal runs so a paused run cannot re-pause with a stale
  # sequence via the normal path; recovery re-dispatch goes through
  # the relaxed `require_terminal_sequence` path if needed.
  def handle_command(state, %{type: "run.pause", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunPaused",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put_new(:reason, "crash_loop")
       }}
    end
  end

  # run.resume — emits `RunResumed` (re-admits a paused run to
  # `status: "awaiting_worker", terminal?: false`). Only accepted from
  # `status: "paused"`; any other status, including every terminal one,
  # is rejected by `require_resumable/1`.
  def handle_command(state, %{type: "run.resume", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- require_resumable(state) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunResumed",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put(:project_id, state.project_id)
           |> Map.put_new(:reason, "operator_resume")
       }}
    end
  end

  # run.cancel — emits `RunCancelled` (terminal, state shape `cancelled`).
  def handle_command(state, %{type: "run.cancel", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunCancelled",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put(:project_id, state.project_id)
           |> Map.put_new(:status, "cancelled")
       }}
    end
  end

  # run.steer — emits `RunSteerQueued` (E6-S4): an operator message for a
  # run, delivered by pausing then resuming the run with the text injected
  # into the next prompt. The event log is the durable mailbox; a
  # re-submitted `message_id` is an idempotent no-op. Steering a terminal
  # run is rejected. `resume: false` keeps the run paused after the
  # steer-pause until an operator resumes it.
  def handle_command(state, %{type: "run.steer", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, message_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :message_id), :message_id),
         {:ok, text} <- Aggregate.required_binary(Aggregate.get(payload, :text), :text),
         :ok <- require_steer_text_length(text),
         :ok <- Aggregate.optional_binary(Aggregate.get(payload, :steered_by), :steered_by),
         {:ok, resume} <- steer_resume_flag(Aggregate.get(payload, :resume)),
         {:ok, override} <- steer_override(Aggregate.get(payload, :approval_mode_override)),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      if MapSet.member?(state.steer_message_ids, message_id) do
        {:ok, nil}
      else
        {:ok,
         %{
           stream_id: "run:#{run_id}",
           event_type: "RunSteerQueued",
           payload:
             %{
               run_id: run_id,
               message_id: message_id,
               text: text,
               steered_by: Aggregate.get(payload, :steered_by),
               resume: resume
             }
             |> Aggregate.put_if(:approval_mode_override, override)
         }}
      end
    end
  end

  # run.steer.consume — system-only: appends `RunSteerConsumed` once the
  # executor has built a prompt carrying the listed messages. Consuming
  # ids that are not pending is a no-op, so a retried dispatch is safe.
  def handle_command(state, %{type: "run.steer.consume", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, message_ids} <- steer_message_ids(Aggregate.get(payload, :message_ids)),
         {:ok, delivery} <- steer_delivery(Aggregate.get(payload, :delivery), "prompt"),
         :ok <- require_exists(state, run_id) do
      pending_ids = MapSet.new(state.pending_steer, & &1.message_id)
      consumable = Enum.filter(message_ids, &MapSet.member?(pending_ids, &1))

      if consumable == [] do
        {:ok, nil}
      else
        {:ok,
         %{
           stream_id: "run:#{run_id}",
           event_type: "RunSteerConsumed",
           payload: %{run_id: run_id, message_ids: consumable, delivery: delivery}
         }}
      end
    end
  end

  # run.steer.deliver - system-only: appends `RunSteerDelivered` once a pending
  # message was written to the live provider session of the running phase
  # (mid-phase steering). The message stays pending until the agent takes it
  # (`RunSteerConsumed`) or the run ends without it (`RunSteerUndelivered`).
  # Re-delivering a message already marked delivered, or one that is not
  # pending, is a no-op so a retried dispatch is safe.
  def handle_command(state, %{type: "run.steer.deliver", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, message_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :message_id), :message_id),
         {:ok, mode} <- steer_delivery(Aggregate.get(payload, :mode), "live"),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      case Enum.find(state.pending_steer, &(&1.message_id == message_id)) do
        %{delivered: false} ->
          {:ok,
           %{
             stream_id: "run:#{run_id}",
             event_type: "RunSteerDelivered",
             payload: %{run_id: run_id, message_id: message_id, mode: mode}
           }}

        _delivered_or_not_pending ->
          {:ok, nil}
      end
    end
  end

  # run.steer.undeliver - system-only: appends `RunSteerUndelivered` for pending
  # messages the run will never take (it went terminal, or its live session
  # closed first). Unlike the other steer commands it IS accepted on a terminal
  # run: surfacing the loss is the point.
  def handle_command(state, %{type: "run.steer.undeliver", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, message_ids} <- steer_message_ids(Aggregate.get(payload, :message_ids)),
         {:ok, reason} <-
           Aggregate.required_binary(Aggregate.get(payload, :reason), :reason),
         :ok <- require_exists(state, run_id) do
      pending_ids = MapSet.new(state.pending_steer, & &1.message_id)
      lost = Enum.filter(message_ids, &MapSet.member?(pending_ids, &1))

      if lost == [] do
        {:ok, nil}
      else
        {:ok,
         %{
           stream_id: "run:#{run_id}",
           event_type: "RunSteerUndelivered",
           payload: %{run_id: run_id, message_ids: lost, reason: reason}
         }}
      end
    end
  end

  # run.record_base_branch — emits `RunBaseBranchRecorded`, persisting
  # the run's PR base branch so a resumed executor reads it back instead
  # of re-deriving it from whatever branch the checkout is on at resume
  # time. Dispatched via `CommandGateway.dispatch_system/2` by
  # `RunExecutor.remember_run_base_branch/1`.
  def handle_command(state, %{type: "run.record_base_branch", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         {:ok, base_branch} <-
           Aggregate.required_binary(Aggregate.get(payload, :base_branch), :base_branch),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunBaseBranchRecorded",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put(:base_branch, base_branch)
       }}
    end
  end

  # run.fail / run.block — no sequence guard
  def handle_command(state, %{type: type, payload: payload})
      when type in ["run.fail", "run.block"] do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      event_type = %{"run.fail" => "RunFailed", "run.block" => "RunBlocked"}[type]

      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: event_type,
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put(:project_id, state.project_id)
       }}
    end
  end

  def handle_command(state, %{type: "run.flag_stuck", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- reject_terminal_mutation(state) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunFlaggedStuck",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put(:project_id, state.project_id)
           |> Map.put_new(:flagged_at, System.system_time(:millisecond))
       }}
    end
  end

  def handle_command(state, %{type: "run.report_stall", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         {:ok, phase_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :phase_id), :phase_id),
         {:ok, idempotency_key} <-
           Aggregate.required_binary(Aggregate.get(payload, :idempotency_key), :idempotency_key),
         {:ok, stall_kind} <- require_known_stall_kind(Aggregate.get(payload, :stall_kind)),
         {:ok, policy} <- require_known_stall_policy(Aggregate.get(payload, :policy)),
         {:ok, threshold_ms} <- require_non_negative_integer(payload, :threshold_ms, true),
         {:ok, idle_ms} <- require_non_negative_integer(payload, :idle_ms, false),
         {:ok, detected_at_ms} <- require_non_negative_integer(payload, :detected_at_ms, false),
         {:ok, reason} <- Aggregate.required_binary(Aggregate.get(payload, :reason), :reason),
         :ok <- reject_duplicate_stall(state, idempotency_key),
         :ok <- reject_terminal_mutation(state) do
      status_effect = status_effect_for(policy)

      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunStallReported",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put(:task_id, state.task_id)
           |> Map.put(:phase_id, phase_id)
           |> Map.put(:stall_kind, stall_kind)
           |> Map.put(:policy, policy)
           |> Map.put(:status_effect, status_effect)
           |> Map.put(:threshold_ms, threshold_ms)
           |> Map.put(:idle_ms, idle_ms)
           |> Map.put(:detected_at_ms, detected_at_ms)
           |> Map.put(:idempotency_key, idempotency_key)
           |> Map.put(:reason, reason)
       }}
    end
  end

  def handle_command(state, %{type: type, payload: payload}) when type in @pr_watch_types do
    with :ok <- allow_pr_lifecycle_on_terminal_runs(state, type) do
      PrWatch.handle(state, type, payload)
    end
  end

  def handle_command(state, %{type: type, payload: payload})
      when type in [
             "run.pr.update",
             "run.pr.retarget",
             "run.pr.reset",
             "run.pr.merge"
           ] do
    event_type =
      %{
        "run.pr.update" => "PrUpdated",
        "run.pr.retarget" => "PrRetargeted",
        "run.pr.reset" => "PrReset",
        "run.pr.merge" => "PrMerged"
      }[type]

    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_pr_lifecycle_on_terminal_runs(state, type),
         :ok <- require_pr_payload(type, payload),
         :ok <- ensure_pr_gate_ok(state, type, run_id, payload) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: event_type,
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  # run.pr.ready — Ensemble reports PR creation. Side-effect: record in
  # MergeGate so run.pr.merge is held until explicit human approval.
  def handle_command(state, %{type: "run.pr.ready", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_pr_lifecycle_on_terminal_runs(state, "run.pr.ready"),
         :ok <- require_pr_payload("run.pr.ready", payload) do
      pr_url = Aggregate.get(payload, :pr_url)
      # PrGate.record_pending calls MergeGate.request_approval internally.
      # A non-primary repository's PR (E12) is held under its own key and never
      # touches the primary's gate.
      :ok = PrGate.record_pending(run_id, pr_url, Aggregate.get(payload, :repo_id))

      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "PrReady",
         payload: Map.put(payload, :run_id, run_id)
       }}
    end
  end

  # merge_approve — explicit human approval after merge gate hold.
  # Verifies approver identity before unblocking run.pr.merge. The approval PINS the head the
  # operator reviewed (`head_sha`, required): `CommandGateway` has already read it back from GitHub,
  # so what is recorded is a commit that was the PR's head when it was approved. A later push voids
  # the approval (`run.pr.rehold`); the pin is never moved to the new head.
  def handle_command(state, %{type: "merge_approve", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         {:ok, repo_key} <- repo_key(payload),
         :ok <- ensure_merge_gate_pending(state, repo_key),
         {:ok, %Approval{} = approval} <- validate_approval(payload) do
      :ok =
        PrGate.record_approved(
          run_id,
          approval.approver,
          approval.approver_identity,
          repo_key
        )

      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "MergeGateApproved",
         payload:
           put_repo_id(
             %{
               run_id: run_id,
               approver: approval.approver,
               approver_identity: approval.approver_identity,
               head_sha: approval.head_sha,
               approved_at: System.system_time(:millisecond)
             },
             repo_key
           )
       }}
    end
  end

  # run.pr.rehold (system, never operator-dispatched) - the PR head moved after the operator approved
  # it. `CommandGateway` sends it after every PR head observation and after a merge attempt that
  # found the head moved. The approval, and the head it pinned, are void: the gate returns to
  # :pending and only a fresh `merge_approve` naming the new head reopens it. The pin is never moved
  # to the new head, so a push can never merge code the operator did not review. A command that finds
  # no stale approval (gate pending, head unchanged, another PR) is a no-op, which is what makes it
  # safe to send after every observation.
  def handle_command(state, %{type: "run.pr.rehold", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         :ok <- allow_pr_lifecycle_on_terminal_runs(state, "run.pr.rehold"),
         {:ok, repo_key} <- repo_key(payload),
         {:ok, pr_url} <- Aggregate.required_binary(Aggregate.get(payload, :pr_url), :pr_url),
         {:ok, head_sha} <-
           Aggregate.required_binary(Aggregate.get(payload, :head_sha), :head_sha) do
      case stale_approval(state, repo_key, head_sha, pr_url) do
        {:stale, %MergePin{head_sha: approved}} ->
          :ok = PrGate.record_pending(run_id, pr_url, repo_key)

          {:ok,
           %{
             stream_id: "run:#{run_id}",
             event_type: "MergeGatePending",
             payload:
               put_repo_id(
                 %{
                   run_id: run_id,
                   pr_url: pr_url,
                   paused_at: System.system_time(:millisecond),
                   reason: "head_moved_since_approval",
                   approved_head_sha: approved,
                   head_sha: head_sha
                 },
                 repo_key
               )
           }}

        :current ->
          {:ok, nil}
      end
    end
  end

  # run.repo_pr_failed (system, never operator-dispatched) - finalisation reports
  # that one repository's PR could not be created. The run completes regardless.
  def handle_command(state, %{type: "run.repo_pr_failed", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         {:ok, repo_id} <- Aggregate.required_binary(Aggregate.get(payload, :repo_id), :repo_id),
         {:ok, reason} <- Aggregate.required_binary(Aggregate.get(payload, :reason), :reason),
         {:ok, at} <- required_integer(payload, :at) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunRepoPrFailed",
         payload: %{run_id: run_id, repo_id: repo_id, reason: reason, at: at}
       }}
    end
  end

  # run.worktree_retained (system, never operator-dispatched) - finalisation reports that
  # the run's worktree could not be removed and stays on disk (foreman-gr27). Accepted on a
  # terminal run: cleanup runs after the run's terminal event.
  def handle_command(state, %{type: "run.worktree_retained", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         {:ok, repo_id} <- Aggregate.required_binary(Aggregate.get(payload, :repo_id), :repo_id),
         {:ok, path} <- Aggregate.required_binary(Aggregate.get(payload, :path), :path),
         {:ok, reason} <- Aggregate.required_binary(Aggregate.get(payload, :reason), :reason),
         {:ok, at} <- required_integer(payload, :at) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunWorktreeRetained",
         payload: %{run_id: run_id, repo_id: repo_id, path: path, reason: reason, at: at}
       }}
    end
  end

  # run.pr.retry (operator-only) - the PR itself is opened by the gateway side
  # effect (`RepoPr.retry/2`), which appends the association and `run.pr.ready`
  # events; the aggregate only validates the addressed run and repository, and
  # accepts it on a terminal run (a PR outlives the run).
  def handle_command(state, %{type: "run.pr.retry", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id),
         :ok <- require_exists(state, run_id),
         {:ok, _repo_id} <- Aggregate.required_binary(Aggregate.get(payload, :repo_id), :repo_id) do
      {:ok, nil}
    end
  end

  def handle_command(state, %{type: "run.recovery_event", payload: payload}) do
    with {:ok, run_id} <- Aggregate.required_binary(Aggregate.get(payload, :run_id), :run_id) do
      {:ok,
       %{
         stream_id: "run:#{run_id}",
         event_type: "RunRecoveryEvent",
         payload:
           payload
           |> Map.put(:run_id, run_id)
           |> Map.put_new(:status, state.status)
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp reject_duplicate_stall(%State{} = state, idempotency_key) do
    if MapSet.member?(state.reported_stall_keys, idempotency_key) do
      {:ok, nil}
    else
      :ok
    end
  end

  defp require_known_stall_kind(kind) when kind in ["agent_no_output", "messaging_no_progress"],
    do: {:ok, kind}

  defp require_known_stall_kind(kind), do: {:error, {:invalid_stall_kind, kind}}

  defp require_known_stall_policy(policy) when policy in ["fail", "attention"], do: {:ok, policy}
  defp require_known_stall_policy(policy), do: {:error, {:invalid_stall_policy, policy}}

  defp require_non_negative_integer(payload, key, positive?) do
    value = Aggregate.get(payload, key)

    cond do
      is_integer(value) and positive? and value > 0 -> {:ok, value}
      is_integer(value) and not positive? and value >= 0 -> {:ok, value}
      true -> {:error, {:invalid_integer, key, value}}
    end
  end

  defp status_effect_for("fail"), do: "failed"
  defp status_effect_for("attention"), do: "blocked"

  defp put_phase(%State{} = state, payload, status) do
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

  defp put_worker(%State{} = state, payload, status) do
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

  # The gate map is keyed by `repo_id`; `nil` is the run's primary repository
  # (and every legacy event, which carries no `repo_id`). A PrReady for one
  # repository re-holds only that repository's gate.
  defp put_gate(%State{merge_gates: gates}, payload, gate) do
    Map.put(gates, gate_key(payload), gate)
  end

  defp gate_key(payload) do
    case Aggregate.get(payload, :repo_id) do
      id when is_binary(id) and id != "" -> id
      _ -> nil
    end
  end

  # A held gate pins no head. `PrReady` and `MergeGatePending` (re)open it for `pr_url` and drop any
  # approval; a payload that names no PR keeps the one the gate already holds.
  defp hold_pin(%State{merge_pins: pins}, payload) do
    key = gate_key(payload)
    pr_url = Aggregate.get(payload, :pr_url) || pin_url(pins, key)
    Map.put(pins, key, %MergePin{pr_url: pr_url})
  end

  # An approval pins `head_sha`. One recorded before heads were pinned names none: it pinned the
  # head the PR watch had last recorded for the PR by then (`state.pr_watch` folds in stream order,
  # so that is exactly the head as of the approval).
  defp approve_pin(%State{merge_pins: pins} = state, payload) do
    key = gate_key(payload)
    pr_url = pin_url(pins, key)

    pin = %MergePin{
      pr_url: pr_url,
      head_sha: pinned_head(Aggregate.get(payload, :head_sha), watched_head(state, pr_url)),
      approved_at: Aggregate.get(payload, :approved_at)
    }

    Map.put(pins, key, pin)
  end

  defp pin_url(pins, key) do
    case Map.get(pins, key) do
      %MergePin{pr_url: url} -> url
      nil -> nil
    end
  end

  defp watched_head(%State{pr_watch: watch}, pr_url) do
    case Map.get(watch, pr_url) do
      %{head_sha: head} -> head
      nil -> nil
    end
  end

  defp pinned_head(head, _watched) when is_binary(head) and head != "", do: head
  defp pinned_head(_absent, watched), do: watched

  # `repo_id` absent/empty selects the primary repository; anything else but a
  # binary is a malformed command, not the primary.
  defp repo_key(payload) do
    case Aggregate.get(payload, :repo_id) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      id when is_binary(id) -> {:ok, id}
      _other -> {:error, {:missing_or_invalid, :repo_id}}
    end
  end

  defp put_repo_id(payload, nil), do: payload
  defp put_repo_id(payload, repo_id), do: Map.put(payload, :repo_id, repo_id)

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

  # Enforces the merge gate: only allow run.pr.merge when the addressed
  # repository's gate is :approved (set by MergeGateApproved event, emitted
  # after merge_approve). The aggregate state is the authoritative source — it
  # survives actor restarts and crash recovery, unlike the ETS-backed MergeGate
  # GenServer.
  defp ensure_pr_gate_ok(state, "run.pr.merge", _run_id, payload) do
    with {:ok, repo_key} <- repo_key(payload) do
      case merge_gate(state, repo_key) do
        :approved -> :ok
        _pending_or_nil -> {:error, :pr_not_acceptable}
      end
    end
  end

  defp ensure_pr_gate_ok(_state, _type, _run_id, _payload), do: :ok

  # Verifies the repository is at the merge gate (merge has been requested but
  # not yet approved). Allows merge_approve only when its gate is still pending.
  # The legacy tuples are unchanged for the primary (`nil`); a named repository
  # gets its id appended.
  defp ensure_merge_gate_pending(state, repo_key) do
    case merge_gate(state, repo_key) do
      :pending -> :ok
      :approved -> {:error, :merge_gate_already_approved}
      nil when is_nil(repo_key) -> {:error, {:merge_gate_not_found, :run}}
      nil -> {:error, {:merge_gate_not_found, :run, repo_key}}
    end
  end

  defp required_integer(payload, key) do
    case Aggregate.get(payload, key) do
      value when is_integer(value) -> {:ok, value}
      other -> {:error, {:missing_or_invalid, key, other}}
    end
  end

  @repo_pr_operator_types ~w(run.pr.retry)

  @doc """
  Operator-only PR commands added by E12-S6 (`run.pr.retry`), declared here so
  `CommandGateway` and `CommandController` allowlists stay in step. Merge
  (`merge_approve`, `run.pr.merge`) and these are never MCP tools.
  """
  @spec repo_pr_operator_types() :: [String.t()]
  def repo_pr_operator_types, do: @repo_pr_operator_types

  # Every PR command (the original lifecycle ones and the E9 watch/fix ones) is
  # accepted on a terminal run: a PR outlives the run that opened it. A command
  # type in neither list is refused with a typed error on a terminal run instead
  # of raising `FunctionClauseError` inside the aggregate actor.
  defp allow_pr_lifecycle_on_terminal_runs(_state, type)
       when type in [
              "run.pr.update",
              "run.pr.ready",
              "run.pr.retarget",
              "run.pr.reset",
              "run.pr.merge",
              "run.pr.rehold"
            ],
       do: :ok

  defp allow_pr_lifecycle_on_terminal_runs(_state, type) when type in @pr_watch_types, do: :ok

  defp allow_pr_lifecycle_on_terminal_runs(%State{terminal?: true, status: status}, _type),
    do: {:error, {:run_terminal, status}}

  defp allow_pr_lifecycle_on_terminal_runs(_state, _type), do: :ok

  defp require_absent(%State{exists?: true}, run_id),
    do: {:error, {:already_exists, :run, run_id}}

  defp require_absent(_state, _run_id), do: :ok

  # `RunStarted` enforces :workflow_snapshot as a required key. The dispatcher
  # bridge supplies a map; reject missing/non-map payloads at the aggregate
  # boundary so the event store never receives an unreplayable event.
  defp require_workflow_snapshot(snapshot) when is_map(snapshot), do: :ok

  defp require_workflow_snapshot(_snapshot),
    do: {:error, {:missing_or_invalid, :workflow_snapshot}}

  defp require_exists(%State{exists?: true, run_id: run_id}, run_id), do: :ok
  defp require_exists(%State{}, run_id), do: {:error, {:not_found, :run, run_id}}

  defp require_sequence(%State{last_sequence: last_sequence}, sequence)
       when is_integer(sequence) and sequence == last_sequence + 1,
       do: :ok

  defp require_sequence(%State{last_sequence: last_sequence}, sequence)
       when is_integer(sequence) and sequence > last_sequence + 1,
       do: {:error, :out_of_order}

  defp require_sequence(%State{}, _sequence), do: {:error, :out_of_order}

  # Sequence normalization for `run.complete` against a non-terminal run.
  # When the caller does not supply a sequence (nil) — common for trusted
  # system actors like RunExecutor completing its own run — derive the
  # next expected sequence from authoritative in-memory state so the
  # aggregate remains the single source of truth for run-stream ordering.
  # An explicitly supplied sequence is passed through for `require_sequence`
  # to validate against the current `last_sequence`.
  defp complete_sequence(%State{last_sequence: last_sequence}, nil),
    do: {:ok, last_sequence + 1}

  defp complete_sequence(_state, sequence) when is_integer(sequence),
    do: {:ok, sequence}

  # Idempotent re-dispatch on a terminal run uses a relaxed sequence guard.
  # `sequence == last_sequence`: the bounded-retry race path — the racing
  # event already advanced last_sequence to the same value the retry
  # re-submits, so accepting the equal sequence converges to RunAlreadyCompleted.
  # `sequence == last_sequence + 1`: a fresh caller-driven idempotent re-dispatch
  # using the next expected sequence, normally observed by callers.
  # Any sequence > last_sequence + 1 is rejected as :out_of_order.
  defp require_terminal_sequence(%State{last_sequence: last_sequence}, sequence)
       when is_integer(sequence) and sequence <= last_sequence + 1,
       do: :ok

  defp require_terminal_sequence(%State{last_sequence: last_sequence}, sequence)
       when is_integer(sequence) and sequence > last_sequence + 1,
       do: {:error, :out_of_order}

  defp require_terminal_sequence(%State{}, nil), do: :ok
  defp require_terminal_sequence(%State{}, _sequence), do: {:error, :out_of_order}
  # NOTE: guard on terminal? rather than status string so any new terminal
  # state (e.g. "stuck") is automatically rejected without list maintenance.
  defp reject_terminal_mutation(%State{terminal?: true, status: status}),
    do: {:error, {:run_terminal, status}}

  defp reject_terminal_mutation(_state), do: :ok

  defp require_resettable(%State{status: status})
       when status in ["failed", "stuck", "blocked", "paused"],
       do: :ok

  defp require_resettable(%State{status: status}), do: {:error, {:run_not_resettable, status}}

  @steer_text_max_chars 8000

  defp require_steer_text_length(text) do
    case String.length(text) do
      n when n <= @steer_text_max_chars -> :ok
      n -> {:error, {:text_too_long, n}}
    end
  end

  defp steer_delivery(nil, default), do: {:ok, default}
  defp steer_delivery(mode, _default) when mode in ["live", "prompt"], do: {:ok, mode}
  defp steer_delivery(_mode, _default), do: {:error, {:missing_or_invalid, :delivery}}

  defp steer_resume_flag(nil), do: {:ok, true}
  defp steer_resume_flag(flag) when is_boolean(flag), do: {:ok, flag}
  defp steer_resume_flag(_flag), do: {:error, {:missing_or_invalid, :resume}}

  # E8 resume-with-override: the one-phase `approval_mode` an approved tool call
  # needs. Only names `Jobsite.Agent` knows are accepted, so the executor's total
  # match on the resumed phase can never see an unknown mode.
  defp steer_override(nil), do: {:ok, nil}

  defp steer_override(name) when is_binary(name) do
    case ForemanServer.Jobsite.Agent.parse_approval_mode(name) do
      {:ok, _mode} -> {:ok, name}
      :error -> {:error, {:invalid_approval_mode_override, name}}
    end
  end

  defp steer_override(_name), do: {:error, {:missing_or_invalid, :approval_mode_override}}

  defp steer_message_ids([_ | _] = ids) do
    if Enum.all?(ids, &(is_binary(&1) and &1 != "")),
      do: {:ok, ids},
      else: {:error, {:missing_or_invalid, :message_ids}}
  end

  defp steer_message_ids(_ids), do: {:error, {:missing_or_invalid, :message_ids}}

  defp require_resumable(%State{status: "paused"}), do: :ok
  defp require_resumable(%State{status: status}), do: {:error, {:run_not_resumable, status}}

  defp allow_delete_on_terminal(%State{status: "deleted"}),
    do: {:error, {:run_terminal, "deleted"}}

  defp allow_delete_on_terminal(_state), do: :ok
end
