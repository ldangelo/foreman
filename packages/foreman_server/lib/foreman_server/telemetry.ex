defmodule ForemanServer.Telemetry do
  @moduledoc false

  @command_dispatch [:foreman, :command, :dispatch]
  @aggregate_rehydrated [:foreman, :aggregate, :rehydrated]
  @run_admission_start [:foreman, :run_admission, :start]
  @project_read [:foreman_server, :project, :read]
  @project_list [:foreman_server, :project, :list]
  @project_register [:foreman_server, :project, :register]
  @project_update [:foreman_server, :project, :update]
  @project_archive [:foreman_server, :project, :archive]
  @worker_heartbeat [:foreman, :worker, :heartbeat]
  @worker_exit [:foreman, :worker, :exit]
  @agent_runtime_invocation_complete [:foreman, :agent_runtime, :invocation, :complete]
  @run_stuck [:foreman, :run, :stuck]
  @reconciler_terminal_release [:foreman_server, :reconciler, :terminal_release]
  @reconciler_orphan_retry [:foreman_server, :reconciler, :orphan_retry]
  @task_provider_beads_create_skipped_watcher_import [
    :foreman_server,
    :task_provider,
    :beads,
    :create,
    :skipped_watcher_import
  ]
  @task_provider_beads_create_failure [
    :foreman_server,
    :task_provider,
    :beads,
    :create,
    :failure
  ]
  @mcp_tool_call [:foreman_server, :mcp, :tool, :call]
  @mcp_policy_refused [:foreman_server, :mcp, :policy, :refused]
  @work_submitted [:foreman_server, :work, :submitted]
  @work_terminal [:foreman_server, :work, :terminal]

  @all_events [
    @command_dispatch,
    @aggregate_rehydrated,
    @run_admission_start,
    @project_read,
    @project_list,
    @project_register,
    @project_update,
    @project_archive,
    @worker_heartbeat,
    @worker_exit,
    @agent_runtime_invocation_complete,
    @run_stuck,
    @reconciler_terminal_release,
    @reconciler_orphan_retry,
    @task_provider_beads_create_skipped_watcher_import,
    @task_provider_beads_create_failure,
    @mcp_tool_call,
    @mcp_policy_refused,
    @work_submitted,
    @work_terminal
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

  def run_admission_start(project_id, run_id, task_id) do
    execute(@run_admission_start, %{count: 1}, %{
      project_id: project_id,
      run_id: run_id,
      task_id: task_id
    })
  end

  def project_read(duration_ms, metadata \\ %{})
      when is_integer(duration_ms) and duration_ms >= 0 and is_map(metadata) do
    execute(@project_read, %{duration_ms: duration_ms}, metadata)
  end

  def project_list(duration_ms, count, metadata \\ %{})
      when is_integer(duration_ms) and duration_ms >= 0 and is_integer(count) and count >= 0 and
             is_map(metadata) do
    execute(@project_list, %{duration_ms: duration_ms, count: count}, metadata)
  end

  def project_register(duration_ms, metadata \\ %{}) do
    project_lifecycle(@project_register, duration_ms, metadata)
  end

  def project_update(duration_ms, metadata \\ %{}) do
    project_lifecycle(@project_update, duration_ms, metadata)
  end

  def project_archive(duration_ms, metadata \\ %{}) do
    project_lifecycle(@project_archive, duration_ms, metadata)
  end

  defp project_lifecycle(event, duration_ms, metadata)
       when is_integer(duration_ms) and duration_ms >= 0 and is_map(metadata) do
    execute(event, %{duration_ms: duration_ms}, metadata)
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

  def reconciler_terminal_release(duration_ms, metadata \\ %{})
      when is_integer(duration_ms) and duration_ms >= 0 and is_map(metadata) do
    execute(@reconciler_terminal_release, %{duration_ms: duration_ms}, metadata)
  end

  def reconciler_orphan_retry(duration_ms, metadata \\ %{})
      when is_integer(duration_ms) and duration_ms >= 0 and is_map(metadata) do
    execute(@reconciler_orphan_retry, %{duration_ms: duration_ms}, metadata)
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
          required(:task_type) => atom() | String.t() | nil,
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
             (is_atom(task_type) or is_binary(task_type) or is_nil(task_type)) and
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
  # ---------------------------------------------------------------------------
  # MCP telemetry (TRD-042)
  # ---------------------------------------------------------------------------

  @doc """
  Emits `[:foreman_server, :mcp, :tool, :call]`.
  Metadata whitelist: `tool`, `outcome` only — never arguments or tokens.
  """
  @spec mcp_tool_call(non_neg_integer(), String.t(), atom() | String.t()) :: :ok
  def mcp_tool_call(duration_us, tool, outcome)
      when is_integer(duration_us) and duration_us >= 0 and is_binary(tool) do
    execute(
      @mcp_tool_call,
      %{duration_us: duration_us},
      %{
        tool: tool,
        outcome: outcome
      }
    )
  end

  @doc """
  Emits `[:foreman_server, :mcp, :policy, :refused]`.
  Metadata whitelist: `tool`, `reason` only.
  """
  @spec mcp_policy_refused(String.t(), atom() | String.t()) :: :ok
  def mcp_policy_refused(tool, reason) when is_binary(tool) do
    execute(
      @mcp_policy_refused,
      %{},
      %{
        tool: tool,
        reason: reason
      }
    )
  end

  @doc """
  Emits `[:foreman_server, :work, :submitted]`.
  Metadata whitelist: `work_id`, `run_id`, `workflow`, `project_id`, `prompt_bytes` —
  never the prompt body.
  """
  @spec work_submitted(String.t(), String.t(), String.t(), String.t(), non_neg_integer()) :: :ok
  def work_submitted(work_id, run_id, workflow, project_id, prompt_bytes)
      when is_binary(work_id) and is_binary(run_id) and is_binary(workflow) and
             is_binary(project_id) and is_integer(prompt_bytes) and prompt_bytes >= 0 do
    execute(
      @work_submitted,
      %{prompt_bytes: prompt_bytes},
      %{
        work_id: work_id,
        run_id: run_id,
        workflow: workflow,
        project_id: project_id
      }
    )
  end

  @doc """
  Emits `[:foreman_server, :work, :terminal]`.
  Metadata: `work_id`, `run_id`, `status`.
  """
  @spec work_terminal(String.t(), String.t(), atom(), non_neg_integer()) :: :ok
  def work_terminal(work_id, run_id, status, duration_us)
      when is_binary(work_id) and is_binary(run_id) and is_atom(status) and
             is_integer(duration_us) and duration_us >= 0 do
    execute(
      @work_terminal,
      %{duration_us: duration_us},
      %{
        work_id: work_id,
        run_id: run_id,
        status: status
      }
    )
  end
end
