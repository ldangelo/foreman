defmodule ForemanServer.Review.Analyzer do
  @moduledoc """
  Reacts to terminal run/jobsite events and records an automated review verdict.

  Subscribes to `ProjectionStore` (no replay: a restart must not re-review
  history) and, for exactly `RunCompleted`, `RunFailed`, `RunCancelled`,
  `JobsiteCompleted`, `JobsiteFailed` and `JobsiteCancelled`, resolves a
  `Review.Subject` and runs `analyze/1` under
  `ForemanServer.Review.TaskSupervisor` so a slow evaluator never blocks the
  projection subscriber.

  `analyze/1` order: finalize archive -> evaluate -> write `analysis.json`/`.md`
  -> `BeadSink.publish/2` -> dispatch `review.record`. A failed evaluation is
  still recorded as an `undetermined` verdict: an analysis that silently did not
  happen would be indistinguishable from a run nobody reviewed.

  A subject that cannot be resolved (no repo path, unknown run, ...) is recorded
  as `undetermined` when its project id is known, because `ReviewRecorded`
  requires one; otherwise it is logged at `:error` and dropped.
  """

  use GenServer

  require Logger

  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Archive
  alias ForemanServer.Review.BeadSink
  alias ForemanServer.Review.Capture
  alias ForemanServer.Review.Error
  alias ForemanServer.Review.Subject
  alias ForemanServer.Review.Verdict

  @terminal_events ~w(RunCompleted RunFailed RunCancelled JobsiteCompleted JobsiteFailed JobsiteCancelled)
  @event_status %{
    "RunCompleted" => "completed",
    "RunFailed" => "failed",
    "RunCancelled" => "cancelled",
    "JobsiteCompleted" => "completed",
    "JobsiteFailed" => "failed",
    "JobsiteCancelled" => "cancelled"
  }
  # `run.cancel` is recorded before the run's executor has actually stopped, so
  # the workflow door waits (bounded) for it to exit before capturing the diff.
  @executor_settle_ms 30_000
  @executor_poll_ms 100
  @task_supervisor ForemanServer.Review.TaskSupervisor

  @type unresolved :: %{kind: :run | :jobsite, subject_id: String.t(), project_id: String.t() | nil}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    case ProjectionStore.subscribe(replay_existing: false) do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_info({:projection_event, event}, state) when is_map(event) do
    type = Map.get(event, :event_type) || Map.get(event, "event_type")

    if type in @terminal_events do
      payload = unwrap_data(event)

      case Task.Supervisor.start_child(@task_supervisor, fn -> handle_event(type, payload) end) do
        {:ok, _pid} ->
          :ok

        other ->
          Logger.error("review analyzer: could not start analysis task for #{type}: #{inspect(other)}")
      end
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc false
  @spec handle_event(String.t(), map()) :: :ok
  def handle_event(type, payload) do
    if type == "RunCancelled", do: settle_cancelled_run(field(payload, :run_id))

    case subject_from_event(type, payload) do
      {:ok, %Subject{} = subject} -> analyze(subject)
      {:unresolved, ctx, error} -> record_unresolved(ctx, error)
    end
  rescue
    exception ->
      Logger.error("review analyzer: #{type} handling crashed: #{Exception.format(:error, exception, __STACKTRACE__)}")
      :ok
  end

  @doc """
  Build the `%Subject{}` for a terminal event, or `{:unresolved, ctx, error}`
  when the projections cannot supply it.
  """
  @spec subject_from_event(String.t(), map()) ::
          {:ok, Subject.t()} | {:unresolved, unresolved(), Error.t()}
  def subject_from_event(type, payload) when type in ["RunCompleted", "RunFailed", "RunCancelled"] do
    run_id = field(payload, :run_id)
    ctx = %{kind: :run, subject_id: run_id, project_id: nil}
    status = Map.fetch!(@event_status, type)

    with :ok <- require_id(run_id, ctx, "event carries no run_id"),
         {:ok, run} <- fetch(ProjectionStore.run(run_id), ctx, "run #{run_id} is not projected"),
         ctx = %{ctx | project_id: field(run, :project_id)},
         {:ok, repo_path} <- run_repo_path(run_id, ctx),
         {:ok, task} <- run_task(run, ctx) do
      {:ok,
       %Subject{
         kind: :run,
         subject_id: run_id,
         project_id: ctx.project_id,
         repo_path: repo_path,
         archive_dir: Archive.dir(:run, run_id, repo_path),
         status: status,
         bead_id: task && Capture.bead_id_for_task(task),
         request_title: task && field(task, :title),
         request_text: task && (field(task, :prompt) || field(task, :description)),
         workflow_name: field(run, :workflow_name)
       }}
    end
  end

  def subject_from_event(type, payload) when type in ["JobsiteCompleted", "JobsiteFailed", "JobsiteCancelled"] do
    jobsite_id = field(payload, :jobsite_id)
    ctx = %{kind: :jobsite, subject_id: jobsite_id, project_id: nil}
    status = Map.fetch!(@event_status, type)

    with :ok <- require_id(jobsite_id, ctx, "event carries no jobsite_id"),
         {:ok, jobsite} <-
           fetch(ProjectionStore.jobsite(jobsite_id), ctx, "jobsite #{jobsite_id} is not projected"),
         ctx = %{ctx | project_id: field(jobsite, :project_id)},
         {:ok, repo_path} <-
           fetch(non_empty(field(jobsite, :repo_path)), ctx, "jobsite #{jobsite_id} has no repo_path") do
      {:ok,
       %Subject{
         kind: :jobsite,
         subject_id: jobsite_id,
         project_id: ctx.project_id,
         repo_path: repo_path,
         archive_dir: Archive.dir(:jobsite, jobsite_id, repo_path),
         status: status,
         bead_id: non_empty(field(jobsite, :bead_id))
       }}
    end
  end

  # A cancelled run never reaches `cleanup_run_worktree/2` (the executor's
  # capture point), so the archive is built here from the projections once the
  # executor has stopped writing. The run's worktree is retained on cancel, so
  # the diff includes the uncommitted work the agent left behind.
  defp settle_cancelled_run(run_id) when is_binary(run_id) and run_id != "" do
    deadline = System.monotonic_time(:millisecond) + @executor_settle_ms
    await_executor_exit(run_id, deadline)
    Capture.close_cancelled_run(run_id)
  end

  defp settle_cancelled_run(_no_run_id), do: :ok

  defp await_executor_exit(run_id, deadline) do
    cond do
      Registry.lookup(ForemanServer.RunExecutorRegistry, run_id) == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning("review analyzer: executor for cancelled run #{run_id} still alive after #{@executor_settle_ms}ms; capturing anyway")

      true ->
        Process.sleep(@executor_poll_ms)
        await_executor_exit(run_id, deadline)
    end
  end

  @doc """
  Synchronously review one subject and record the result. Always returns `:ok`;
  every failure is logged and, where possible, carried in the recorded verdict.
  """
  @spec analyze(Subject.t()) :: :ok
  def analyze(%Subject{} = subject) do
    kind = Atom.to_string(subject.kind)

    if ProjectionStore.review(kind, subject.subject_id) do
      Logger.info("review analyzer: #{kind} #{subject.subject_id} already reviewed; skipping")
      :ok
    else
      verdict = produce_verdict(subject)
      analysis_note = write_analysis(subject, verdict)
      {gap_bead_ids, sink_note} = publish(subject, verdict)

      summary =
        [verdict.summary, sink_note, analysis_note]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n\n")

      dispatch_record(subject, verdict, summary, gap_bead_ids, analysis_note == nil)
    end
  end

  # ---------------------------------------------------------------------

  defp produce_verdict(subject) do
    with :ok <- Capture.finalize(subject),
         {:ok, %Verdict{} = verdict} <- evaluate(subject) do
      verdict
    else
      {:error, %Error{} = error} -> undetermined(error)
    end
  end

  defp evaluate(subject) do
    evaluator().evaluate(subject)
  rescue
    exception ->
      {:error,
       Error.new(:evaluator_failed, "evaluator raised: " <> Exception.message(exception), %{
         exception: inspect(exception.__struct__)
       })}
  catch
    kind, reason ->
      {:error,
       Error.new(:evaluator_failed, "evaluator #{kind}: #{inspect(reason)}", %{})}
  end

  defp undetermined(%Error{code: code, message: message}) do
    %Verdict{verdict: :undetermined, error_code: code, summary: message}
  end

  # Returns nil on success, otherwise a note for the recorded summary.
  defp write_analysis(subject, verdict) do
    json = Jason.encode!(Verdict.to_map(verdict), pretty: true)

    with :ok <- Archive.write_file(subject.archive_dir, "analysis.json", json),
         :ok <- Archive.write_file(subject.archive_dir, "analysis.md", Verdict.to_markdown(verdict)) do
      nil
    else
      {:error, %Error{code: code}} ->
        Logger.warning("review analyzer: analysis write failed for #{subject.subject_id}: #{code}")
        "analysis write failed: #{code}"
    end
  end

  defp publish(subject, verdict) do
    case BeadSink.publish(subject, verdict) do
      {:ok, %{gap_bead_ids: ids, note: note}} -> {ids, note}
      {:error, %Error{code: code}} -> {[], "bead sink failed: #{code}"}
    end
  rescue
    exception ->
      Logger.error("review analyzer: bead sink crashed: #{Exception.message(exception)}")
      {[], "bead sink failed: crashed"}
  end

  defp dispatch_record(subject, verdict, summary, gap_bead_ids, analysis_written?) do
    kind = Atom.to_string(subject.kind)

    payload = %{
      subject_kind: kind,
      subject_id: subject.subject_id,
      project_id: subject.project_id,
      bead_id: subject.bead_id,
      verdict: Atom.to_string(verdict.verdict),
      scores: Map.new(verdict.scores, fn {dim, score} -> {Atom.to_string(dim), score} end),
      summary: summary,
      gap_bead_ids: gap_bead_ids,
      archive_path: subject.archive_dir,
      analysis_path: if(analysis_written?, do: Path.join(subject.archive_dir, "analysis.md")),
      evaluator: evaluator_name(),
      error_code: verdict.error_code && Atom.to_string(verdict.error_code),
      at: DateTime.to_iso8601(DateTime.utc_now())
    }

    dispatch(kind, subject.subject_id, payload)
  end

  defp record_unresolved(%{project_id: project_id} = ctx, %Error{} = error)
       when is_binary(project_id) and project_id != "" do
    Logger.warning("review analyzer: unresolved #{ctx.kind} #{ctx.subject_id}: #{error.message}")
    kind = Atom.to_string(ctx.kind)

    dispatch(kind, ctx.subject_id, %{
      subject_kind: kind,
      subject_id: ctx.subject_id,
      project_id: project_id,
      bead_id: nil,
      verdict: "undetermined",
      scores: nil,
      summary: error.message,
      gap_bead_ids: [],
      archive_path: nil,
      analysis_path: nil,
      evaluator: evaluator_name(),
      error_code: Atom.to_string(error.code),
      at: DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  defp record_unresolved(ctx, %Error{} = error) do
    Logger.error(
      "review analyzer: dropping #{ctx.kind} #{inspect(ctx.subject_id)}: #{error.message} " <>
        "(no project_id, so no review can be recorded)"
    )
  end

  defp dispatch(kind, subject_id, payload) do
    id = "review:" <> kind <> ":" <> subject_id

    command = %{
      type: "review.record",
      command_id: id,
      aggregate_id: id,
      payload: payload
    }

    case CommandGateway.dispatch_system(command) do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.error("review analyzer: review.record for #{id} rejected: #{inspect(reason)}")
        :ok
    end
  end

  # ---------------------------------------------------------------------

  defp run_repo_path(run_id, ctx) do
    case Capture.run_repo_path(run_id) do
      {:ok, path} -> {:ok, path}
      {:error, %Error{} = error} -> {:unresolved, ctx, error}
    end
  end

  # A run always belongs to a task; a missing task projection is unresolvable,
  # not "a run with no request".
  defp run_task(run, ctx) do
    case field(run, :task_id) do
      id when is_binary(id) and id != "" ->
        fetch(ProjectionStore.task_projection(id), ctx, "task #{id} is not projected")

      _ ->
        {:ok, nil}
    end
  end

  defp require_id(id, _ctx, _msg) when is_binary(id) and id != "", do: :ok
  defp require_id(_id, ctx, msg), do: unresolved(ctx, msg)

  defp fetch(nil, ctx, msg), do: unresolved(ctx, msg)
  defp fetch(value, _ctx, _msg), do: {:ok, value}

  defp unresolved(ctx, msg),
    do: {:unresolved, ctx, Error.new(:subject_unresolved, msg, %{subject_id: ctx.subject_id})}

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_), do: nil

  defp field(map, key) when is_map(map), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp unwrap_data(%{data: data}), do: unwrap_data(data)
  defp unwrap_data(%{"data" => data}), do: unwrap_data(data)
  defp unwrap_data(%{payload: payload}), do: unwrap_data(payload)
  defp unwrap_data(map) when is_map(map), do: map
  defp unwrap_data(_), do: %{}

  defp evaluator, do: Keyword.fetch!(config(), :evaluator)

  defp evaluator_name do
    case evaluator() do
      ForemanServer.Review.Evaluator.Agent ->
        provider = get_in(config(), [:agent, :provider])
        "agent:" <> to_string(provider)

      module ->
        inspect(module)
    end
  end

  defp config, do: Application.get_env(:foreman_server, :review, [])
end
