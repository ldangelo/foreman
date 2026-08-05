defmodule ForemanServer.Telemetry do
  @moduledoc false

  @command_dispatch [:foreman, :command, :dispatch]
  @aggregate_rehydrated [:foreman, :aggregate, :rehydrated]
  @worker_heartbeat [:foreman, :worker, :heartbeat]
  @worker_exit [:foreman, :worker, :exit]
  @agent_runtime_invocation_complete [:foreman, :agent_runtime, :invocation, :complete]
  @run_stuck [:foreman, :run, :stuck]

  @all_events [
    @command_dispatch,
    @aggregate_rehydrated,
    @worker_heartbeat,
    @worker_exit,
    @agent_runtime_invocation_complete,
    @run_stuck
  ]

  def all_events, do: @all_events

  def execute(event, measurements, metadata \\ %{}) do
    :telemetry.execute(event, measurements, metadata)
  end

  def attach_many(handler_id, events, handler, config \\ nil) do
    :telemetry.attach_many(handler_id, events, handler, config)
  end

  def command_dispatch(duration_ms, append_latency_ms, status, aggregate_id) do
    execute(
      @command_dispatch,
      %{duration_ms: duration_ms, append_latency_ms: append_latency_ms},
      %{
        status: status,
        aggregate_id: aggregate_id
      }
    )
  end

  def aggregate_rehydrated(event_count) do
    execute(@aggregate_rehydrated, %{event_count: event_count}, %{})
  end

  def worker_heartbeat(measurements \\ %{count: 1}, metadata \\ %{}) do
    execute(@worker_heartbeat, measurements, metadata)
  end

  def worker_exit(measurements \\ %{count: 1}, metadata \\ %{}) do
    execute(@worker_exit, measurements, metadata)
  end

  @doc """
  Emits `[:foreman, :run, :stuck]` when StuckDetector flags a run.

  Measurements:
    * `:idle_ms` — wall-clock milliseconds since the run's last event
      (last phase or worker heartbeat).

  Metadata:
    * `:run_id` — the run that has been flagged.
    * `:threshold_ms` — the threshold the detector compared against.
  """
  @spec run_stuck(non_neg_integer(), non_neg_integer(), String.t()) :: :ok
  def run_stuck(idle_ms, threshold_ms, run_id)
      when is_integer(idle_ms) and idle_ms >= 0 and is_binary(run_id) do
    execute(@run_stuck, %{idle_ms: idle_ms}, %{
      run_id: run_id,
      threshold_ms: threshold_ms
    })
  end

  @typedoc """
  Closed measurement set permitted for the agent runtime completion event.

  Prompts, context, output content, credentials, and adapter metadata MUST
  NOT appear here. The helper constructs the measurements map explicitly
  from these keys so any extras supplied by callers are dropped.
  """
  @type completion_measurements :: %{
          required(:duration_us) => non_neg_integer(),
          required(:attempt_count) => non_neg_integer(),
          optional(atom()) => term()
        }
  @type completion_metadata :: %{
          required(:status) => atom(),
          required(:task_type) => atom() | nil,
          required(:attempted_backends) => [atom()],
          required(:successful_backend) => atom() | nil,
          required(:final_backend) => atom() | nil,
          optional(atom()) => term()
        }
  @doc """
  Emits `[:foreman, :agent_runtime, :invocation, :complete]`. This is the
  sole completion emission per agent runtime call (TRD-009).

  Both argument maps are pattern-matched for required keys; missing keys
  raise `FunctionClauseError` instead of silently emitting a partial event.
  Only the whitelisted keys are projected into the emitted measurement
  and metadata maps, so any sensitive extras (prompt, context, output
  content, credentials, adapter metadata) are dropped before emission.

  See `t:completion_measurements` and `t:completion_metadata` for the
  closed field sets.
  """

  @spec agent_runtime_execute(completion_measurements(), completion_metadata(), keyword()) :: :ok
  def agent_runtime_execute(
        %{duration_us: duration_us, attempt_count: attempt_count},
        %{
          status: status,
          task_type: task_type,
          attempted_backends: attempted_backends,
          successful_backend: successful_backend,
          final_backend: final_backend
        },
        _opts \\ []
      )
      when is_integer(duration_us) and duration_us >= 0 and
             is_integer(attempt_count) and attempt_count >= 0 and
             is_atom(status) and
             (is_atom(task_type) or is_nil(task_type)) and
             is_list(attempted_backends) and
             (is_atom(successful_backend) or is_nil(successful_backend)) and
             (is_atom(final_backend) or is_nil(final_backend)) do
    execute(
      @agent_runtime_invocation_complete,
      %{duration_us: duration_us, attempt_count: attempt_count},
      %{
        status: status,
        task_type: task_type,
        attempted_backends: attempted_backends,
        successful_backend: successful_backend,
        final_backend: final_backend
      }
    )
  end
end
