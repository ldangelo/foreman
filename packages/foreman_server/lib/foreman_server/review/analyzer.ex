defmodule ForemanServer.Review.Analyzer do
  @moduledoc """
  Reacts to terminal run/jobsite events and records an automated review verdict.

  Subscribes to `ProjectionStore` (no replay: a restart must not re-review
  history) and, for exactly `RunCompleted`, `RunFailed`, `RunCancelled`,
  `JobsiteCompleted`, `JobsiteFailed` and `JobsiteCancelled`, resolves a
  `Review.Subject` and runs `analyze/1` under
  `ForemanServer.Review.TaskSupervisor` so a slow evaluator never blocks the
  projection subscriber.

  At most one analysis per subject runs at a time, and at most
  `config :foreman_server, :review, max_concurrent_analyses:` run at once: a
  terminal event for a subject whose analysis is running or queued is dropped,
  and one that finds every slot taken waits in a first-in-first-out queue until
  a slot frees (`start_analysis/3`, `drain/1`). The queue is in memory, like the
  tasks it feeds: nothing is replayed after a restart.

  `RunCancelled` and `RunFailed` are recorded before the run's executor has
  finished with the run's archive, so their task first waits (bounded) for the
  executor to exit (`settle_run/2`).

  `analyze/1` order: finalize archive -> evaluate -> write `analysis.json`/`.md`
  -> `BeadSink.publish/2` -> dispatch `review.record`. A failed evaluation is
  still recorded as an `undetermined` verdict: an analysis that silently did not
  happen would be indistinguishable from a run nobody reviewed.

  A subject that cannot be resolved (no repo path, unknown run, ...) is recorded
  as `undetermined` when its project id is known, because `ReviewRecorded`
  requires one; otherwise it is logged at `:error` and dropped.

  A review recorded `undetermined` is re-run with `rerun/2` (`analyze/2` with
  `rerun: true`): the subject is rebuilt from the review's archive and manifest
  (the run or jobsite need not still be projected), the archive is not
  finalized again, and the new verdict supersedes the old one under its own
  command id. Any other recorded verdict is final.
  """

  use GenServer

  require Logger

  alias ForemanServer.AgentRuntime.JidoHarness.FailureCause
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
  # `run.cancel` and a phase-failure `run.fail` are recorded before the run's
  # executor has finished with the archive, so the workflow door waits (bounded)
  # for it to exit first; see `settle_run/2`.
  @executor_settle_ms 30_000
  @executor_poll_ms 100
  @task_supervisor ForemanServer.Review.TaskSupervisor
  # The only event-payload fields this module reads; see `unwrap_data/1`.
  @payload_keys [:run_id, :jobsite_id]
  @default_max_concurrent_analyses 3

  @type unresolved :: %{
          kind: :run | :jobsite,
          subject_id: String.t(),
          project_id: String.t() | nil
        }

  @type subject_key :: {:run | :jobsite, String.t()}
  # What runs for a subject: a terminal event to resolve and review, or the re-run of an
  # `undetermined` review whose subject was already rebuilt from its archive.
  @type job :: {:event, String.t(), event_payload()} | {:rerun, Subject.t()}

  # `in_flight` maps a subject to the monitor of the task analysing it; `queue` holds, in
  # arrival order, the `{job, subject_key}` pairs waiting for a slot, `queued` their keys.
  @type state :: %{
          in_flight: %{subject_key() => reference()},
          queue: :queue.queue({job(), subject_key()}),
          queued: MapSet.t(subject_key())
        }

  @type rerun_error ::
          :not_reviewed
          | {:not_rerunnable, String.t()}
          | :already_running
          | {:archive_unusable, Error.t()}
          | :analysis_disabled

  # A terminal event's payload as normalised by `unwrap_data/1`: atom-keyed, with
  # an absent field left out.
  @type event_payload :: %{optional(:run_id) => String.t(), optional(:jobsite_id) => String.t()}

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @impl true
  def init(_opts) do
    # Fail at boot on a bound that cannot be honoured, not at the first terminal event.
    _ = max_concurrent_analyses()

    case ProjectionStore.subscribe(replay_existing: false) do
      :ok -> {:ok, %{in_flight: %{}, queue: :queue.new(), queued: MapSet.new()}}
      {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @doc """
  Re-run the review of a subject whose recorded review is `undetermined` (the reviewer
  failed: a provider rate limit, a killed process; the work was never judged).

  The subject is rebuilt from the review's archive, so the run or jobsite need not
  still be projected. Returns `:ok` once the re-run is accepted (it runs, or queues
  for a slot, like any analysis) or an error naming why not: no review recorded
  (`:not_reviewed`), a real verdict already recorded (`{:not_rerunnable, verdict}`),
  an analysis of the subject running or queued (`:already_running`), an archive that
  cannot be read (`{:archive_unusable, error}`), or analysis switched off
  (`:analysis_disabled`). A verdict other than `undetermined` is never re-run.
  """
  @spec rerun(:run | :jobsite, String.t()) :: :ok | {:error, rerun_error()}
  def rerun(kind, subject_id) when kind in [:run, :jobsite] and is_binary(subject_id) do
    GenServer.call(__MODULE__, {:rerun, kind, subject_id})
  catch
    :exit, {:noproc, _call} -> {:error, :analysis_disabled}
  end

  @impl true
  def handle_call({:rerun, kind, subject_id}, _from, state) do
    key = {kind, subject_id}

    with :ok <- reject_busy(state, key),
         {:ok, review} <- rerunnable(kind, subject_id),
         {:ok, %Subject{} = subject} <- subject_from_archive(kind, subject_id, review) do
      {:reply, :ok, start_analysis({:rerun, subject}, key, state)}
    else
      {:error, _reason} = error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:projection_event, event}, state) when is_map(event) do
    type = event_type(event)

    if type in @terminal_events do
      payload = unwrap_data(event)
      {:noreply, start_analysis({:event, type, payload}, subject_key(type, payload), state)}
    else
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    in_flight = Map.reject(state.in_flight, fn {_key, task_ref} -> task_ref == ref end)
    {:noreply, drain(%{state | in_flight: in_flight})}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc false
  @spec handle_event(String.t(), event_payload()) :: :ok
  def handle_event(type, payload) do
    settle_run(type, Map.get(payload, :run_id))

    case subject_from_event(type, payload) do
      {:ok, %Subject{} = subject} -> analyze(subject)
      {:unresolved, ctx, error} -> record_unresolved(ctx, error)
    end
  rescue
    exception ->
      Logger.error(
        "review analyzer: #{type} handling crashed: #{Exception.format(:error, exception, __STACKTRACE__)}"
      )

      :ok
  end

  @doc """
  Build the `%Subject{}` for a terminal event, or `{:unresolved, ctx, error}`
  when the projections cannot supply it.
  """
  @spec subject_from_event(String.t(), event_payload()) ::
          {:ok, Subject.t()} | {:unresolved, unresolved(), Error.t()}
  def subject_from_event(type, payload)
      when type in ["RunCompleted", "RunFailed", "RunCancelled"] do
    run_id = Map.get(payload, :run_id)
    ctx = %{kind: :run, subject_id: run_id, project_id: nil}
    status = Map.fetch!(@event_status, type)

    with :ok <- require_id(run_id, ctx, "event carries no run_id"),
         {:ok, run} <- fetch(ProjectionStore.run(run_id), ctx, "run #{run_id} is not projected"),
         ctx = %{ctx | project_id: Map.get(run, :project_id)},
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
         request_title: task && Map.get(task, :title),
         request_text: task && (Map.get(task, :prompt) || Map.get(task, :description)),
         workflow_name: Map.get(run, :workflow_name)
       }}
    end
  end

  def subject_from_event(type, payload)
      when type in ["JobsiteCompleted", "JobsiteFailed", "JobsiteCancelled"] do
    jobsite_id = Map.get(payload, :jobsite_id)
    ctx = %{kind: :jobsite, subject_id: jobsite_id, project_id: nil}
    status = Map.fetch!(@event_status, type)

    with :ok <- require_id(jobsite_id, ctx, "event carries no jobsite_id"),
         {:ok, jobsite} <-
           fetch(
             ProjectionStore.jobsite(jobsite_id),
             ctx,
             "jobsite #{jobsite_id} is not projected"
           ),
         ctx = %{ctx | project_id: Map.get(jobsite, :project_id)},
         {:ok, repo_path} <-
           fetch(
             non_empty(Map.get(jobsite, :repo_path)),
             ctx,
             "jobsite #{jobsite_id} has no repo_path"
           ) do
      {:ok,
       %Subject{
         kind: :jobsite,
         subject_id: jobsite_id,
         project_id: ctx.project_id,
         repo_path: repo_path,
         archive_dir: Archive.dir(:jobsite, jobsite_id, repo_path),
         status: status,
         bead_id: non_empty(Map.get(jobsite, :bead_id))
       }}
    end
  end

  # One analysis per subject at a time. The recorded review is the durable guard
  # (`analyze/1` skips a reviewed subject and `review.record` is idempotent by
  # command id), but it is written last, after the evaluator has run and the bead
  # sink has posted its comment and filed its gap beads. A second terminal event
  # for a subject whose analysis is still running (a reset run failing again, a
  # duplicate delivery) would pass that check and repeat those side effects, none
  # of which is idempotent. The running analysis records the review, so the
  # duplicate is dropped.
  defp start_analysis(job, key, state) do
    cond do
      key != nil and (Map.has_key?(state.in_flight, key) or MapSet.member?(state.queued, key)) ->
        {kind, subject_id} = key

        Logger.info(
          "review analyzer: #{kind} #{subject_id} ignored; its analysis is already running or queued"
        )

        state

      key != nil and map_size(state.in_flight) >= max_concurrent_analyses() ->
        {kind, subject_id} = key

        Logger.info(
          "review analyzer: #{kind} #{subject_id} queued; #{map_size(state.in_flight)} analyses already running"
        )

        %{
          state
          | queue: :queue.in({job, key}, state.queue),
            queued: MapSet.put(state.queued, key)
        }

      true ->
        launch(job, key, state)
    end
  end

  defp launch(job, key, state) do
    case Task.Supervisor.start_child(@task_supervisor, fn -> run_job(job) end) do
      {:ok, pid} ->
        track(state, key, pid)

      other ->
        Logger.error(
          "review analyzer: could not start analysis task for #{inspect(key)}: #{inspect(other)}"
        )

        state
    end
  end

  defp run_job({:event, type, payload}), do: handle_event(type, payload)
  defp run_job({:rerun, %Subject{} = subject}), do: rerun_subject(subject)

  # A finished analysis frees its slot for the next queued subject, oldest first.
  defp drain(state) do
    with true <- map_size(state.in_flight) < max_concurrent_analyses(),
         {{:value, {job, key}}, queue} <- :queue.out(state.queue) do
      drain(launch(job, key, %{state | queue: queue, queued: MapSet.delete(state.queued, key)}))
    else
      _nothing_to_start -> state
    end
  end

  # An event carrying no subject id cannot be guarded: `handle_event/2` logs and
  # drops it.
  defp track(state, nil, _pid), do: state

  defp track(state, key, pid),
    do: %{state | in_flight: Map.put(state.in_flight, key, Process.monitor(pid))}

  defp reject_busy(state, key) do
    if Map.has_key?(state.in_flight, key) or MapSet.member?(state.queued, key),
      do: {:error, :already_running},
      else: :ok
  end

  defp rerunnable(kind, subject_id) do
    case ProjectionStore.review(Atom.to_string(kind), subject_id) do
      nil -> {:error, :not_reviewed}
      %{verdict: "undetermined"} = review -> {:ok, review}
      %{verdict: verdict} -> {:error, {:not_rerunnable, verdict}}
    end
  end

  # The subject of a re-run is rebuilt from the archive the first review wrote, not
  # from the run or jobsite projections: the archive is what is reviewed, and it
  # outlives them.
  defp subject_from_archive(kind, subject_id, review) do
    with {:ok, dir} <- recorded_archive_dir(review, kind, subject_id),
         {:ok, manifest} <- Archive.read_manifest(dir),
         {:ok, repo_path} <- manifest_repo_path(manifest, dir) do
      request = request_block(manifest)

      {:ok,
       %Subject{
         kind: kind,
         subject_id: subject_id,
         project_id: non_empty(Map.get(review, :project_id)) || non_empty(manifest["project_id"]),
         repo_path: repo_path,
         archive_dir: dir,
         status: non_empty(manifest["status"]) || "unknown",
         bead_id: non_empty(manifest["bead_id"]) || non_empty(Map.get(review, :bead_id)),
         request_title: non_empty(request["title"]),
         request_text: non_empty(request["prompt"]),
         workflow_name: non_empty(request["workflow_name"])
       }}
    else
      {:error, %Error{} = error} -> {:error, {:archive_unusable, error}}
    end
  end

  defp recorded_archive_dir(review, kind, subject_id) do
    case non_empty(Map.get(review, :archive_path)) do
      nil ->
        {:error,
         Error.new(:archive_missing, "the recorded review names no archive", %{
           kind: kind,
           subject_id: subject_id
         })}

      dir ->
        {:ok, dir}
    end
  end

  defp manifest_repo_path(manifest, dir) do
    case non_empty(manifest["repo_path"]) do
      nil -> {:error, Error.new(:archive_malformed, "manifest has no repo_path", %{path: dir})}
      repo_path -> {:ok, repo_path}
    end
  end

  defp request_block(%{"request" => %{} = request}), do: request
  defp request_block(_manifest), do: %{}

  defp subject_key("Run" <> _, payload), do: keyed(:run, Map.get(payload, :run_id))
  defp subject_key("Jobsite" <> _, payload), do: keyed(:jobsite, Map.get(payload, :jobsite_id))

  defp keyed(kind, id) when is_binary(id) and id != "", do: {kind, id}
  defp keyed(_kind, _id), do: nil

  # The archive must not be read until the run's executor has finished with it.
  # Two terminal events are recorded before that:
  #
  #   * `RunCancelled`: a cancelled run never reaches `cleanup_run_worktree/2`
  #     (the executor's capture point), so the archive is built here from the
  #     projections once the executor has stopped writing. The run's worktree is
  #     retained on cancel, so the diff includes the uncommitted work the agent
  #     left behind.
  #   * `RunFailed`: `RunExecutor.emit_phase_failure/4` dispatches `run.fail` and
  #     only afterwards does `finalize_terminal_and_stop/2` capture the archive
  #     (`cleanup_run_worktree/2` -> `Capture.close_run/2`). The executor does
  #     that capture itself, so there is nothing to add here but the wait.
  #
  # `RunCompleted` is deliberately not waited for: `finalize_run/1` captures
  # before `run.complete` and the executor then stays alive, so a wait would
  # always run to its timeout. A run with no registered executor (it has already
  # stopped) proceeds at once.
  defp settle_run("RunCancelled", run_id) when is_binary(run_id) and run_id != "" do
    await_executor_exit("RunCancelled", run_id)
    Capture.close_cancelled_run(run_id)
  end

  defp settle_run("RunFailed", run_id) when is_binary(run_id) and run_id != "",
    do: await_executor_exit("RunFailed", run_id)

  defp settle_run(_type, _run_id), do: :ok

  defp await_executor_exit(type, run_id) do
    deadline = System.monotonic_time(:millisecond) + @executor_settle_ms
    await_executor_exit(type, run_id, deadline)
  end

  defp await_executor_exit(type, run_id, deadline) do
    cond do
      Registry.lookup(ForemanServer.RunExecutorRegistry, run_id) == [] ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning(
          "review analyzer: executor for run #{run_id} still alive #{@executor_settle_ms}ms after #{type}; proceeding anyway"
        )

      true ->
        Process.sleep(@executor_poll_ms)
        await_executor_exit(type, run_id, deadline)
    end
  end

  @doc """
  Synchronously review one subject and record the result. Always returns `:ok`;
  every failure is logged and, where possible, carried in the recorded verdict.

  `rerun: true` re-reviews a subject whose recorded review is `undetermined`
  (see `rerun/2`); without it, a subject that already has a review is skipped.
  """
  @spec analyze(Subject.t(), keyword()) :: :ok
  def analyze(%Subject{} = subject, opts \\ []) do
    kind = Atom.to_string(subject.kind)

    case {ProjectionStore.review(kind, subject.subject_id), Keyword.get(opts, :rerun, false)} do
      {nil, false} ->
        review_subject(subject, nil)

      {%{verdict: "undetermined"} = previous, true} ->
        review_subject(subject, previous)

      {nil, true} ->
        Logger.warning(
          "review analyzer: #{kind} #{subject.subject_id} has no review to re-run; skipping"
        )

        :ok

      {_recorded, _rerun} ->
        Logger.info("review analyzer: #{kind} #{subject.subject_id} already reviewed; skipping")
        :ok
    end
  end

  defp rerun_subject(%Subject{} = subject) do
    analyze(subject, rerun: true)
  rescue
    exception ->
      Logger.error(
        "review analyzer: re-run of #{subject.kind} #{subject.subject_id} crashed: " <>
          Exception.format(:error, exception, __STACKTRACE__)
      )

      :ok
  end

  defp review_subject(subject, previous) do
    verdict = produce_verdict(subject, previous)
    analysis_note = write_analysis(subject, verdict)
    {gap_bead_ids, sink_note} = publish(subject, verdict)

    summary =
      ([verdict.summary] ++ verdict.notes ++ [sink_note, analysis_note])
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    dispatch_record(subject, verdict, summary, gap_bead_ids, analysis_note == nil, previous)
  end

  # ---------------------------------------------------------------------

  defp produce_verdict(subject, previous) do
    with :ok <- finalize(subject, previous),
         {:ok, %Verdict{} = verdict} <- evaluate(subject) do
      lineage(verdict, previous)
    else
      {:error, %Error{} = error} -> error |> undetermined() |> lineage(previous)
    end
  end

  defp finalize(subject, nil), do: Capture.finalize(subject)

  # A re-run reviews the archive the first review finalized. Finalizing again would
  # rebuild a run's transcript from run logs that may no longer exist.
  defp finalize(_subject, _previous), do: :ok

  defp lineage(verdict, nil), do: verdict

  defp lineage(%Verdict{} = verdict, %{at: at, summary: summary}) do
    first = summary |> String.split("\n\n", parts: 2) |> hd() |> String.slice(0, 300)

    %Verdict{
      verdict
      | notes: ["re-run of the review recorded undetermined at #{at}: #{first}" | verdict.notes]
    }
  end

  defp evaluate(subject) do
    evaluator().evaluate(subject)
  rescue
    exception ->
      {:error,
       Error.new(
         :evaluator_failed,
         "evaluator raised: " <> reason_text(Exception.message(exception)),
         %{exception: inspect(exception.__struct__)}
       )}
  catch
    kind, reason ->
      {:error,
       Error.new(:evaluator_failed, "evaluator #{kind}: " <> reason_text(inspect(reason)), %{})}
  end

  defp undetermined(%Error{code: code, message: message, details: details}) do
    spent = if is_map(details), do: Map.get(details, :usage), else: nil
    notes = if is_map(details), do: Map.get(details, :notes, []), else: []

    verdict = %Verdict{
      verdict: :undetermined,
      error_code: code,
      summary: message,
      notes: notes
    }

    case spent do
      %{usage: %ForemanServer.Usage{} = usage, model: model, provider: provider} ->
        %Verdict{verdict | usage: usage, model: model, usage_provider: provider}

      _ ->
        verdict
    end
  end

  defp verdict_usage(%ForemanServer.Usage{} = usage) do
    if ForemanServer.Usage.empty?(usage),
      do: nil,
      else: ForemanServer.Usage.to_event_fields(usage)
  end

  defp verdict_usage(_), do: nil

  # Returns nil on success, otherwise a note for the recorded summary.
  defp write_analysis(subject, verdict) do
    json = Jason.encode!(Verdict.to_map(verdict), pretty: true)

    with :ok <- Archive.write_file(subject.archive_dir, "analysis.json", Archive.redact(json)),
         :ok <-
           Archive.write_file(
             subject.archive_dir,
             "analysis.md",
             Archive.redact(Verdict.to_markdown(verdict))
           ) do
      nil
    else
      {:error, %Error{code: code}} ->
        Logger.warning(
          "review analyzer: analysis write failed for #{subject.subject_id}: #{code}"
        )

        "analysis write failed: #{code}"
    end
  end

  defp publish(subject, verdict) do
    case BeadSink.publish(subject, verdict) do
      {:ok, %BeadSink.Result{gap_bead_ids: ids, note: note}} -> {ids, note}
      {:error, %Error{code: code}} -> {[], "bead sink failed: #{code}"}
    end
  rescue
    exception ->
      Logger.error("review analyzer: bead sink crashed: #{Exception.message(exception)}")
      {[], "bead sink failed: crashed"}
  end

  defp dispatch_record(subject, verdict, summary, gap_bead_ids, analysis_written?, previous) do
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
      model: verdict.model,
      usage: verdict_usage(verdict.usage),
      usage_provider: verdict.usage_provider,
      at: DateTime.to_iso8601(DateTime.utc_now())
    }

    dispatch(kind, subject.subject_id, payload, previous)
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

  # The first record of a subject is its stream id; the record that supersedes an
  # `undetermined` one carries the superseded record's timestamp, so a re-run is
  # idempotent (the same command id replays to nothing) yet each re-run of a subject that
  # fails again is a new command.
  defp dispatch(kind, subject_id, payload, previous \\ nil) do
    id = "review:" <> kind <> ":" <> subject_id

    command = %{
      type: "review.record",
      command_id: command_id(id, previous),
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

  defp command_id(id, nil), do: id
  defp command_id(id, %{at: at}), do: id <> ":supersedes:" <> at

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
    case Map.get(run, :task_id) do
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

  # The event boundary. A projection event reaches this module as an `%EventData{}`,
  # a `%{event_type:, payload:}` map or a string-keyed envelope, and its payload may
  # be keyed either way: the Run and Jobsite aggregates atom-key the ids they emit,
  # while a payload that went through JSON or `Aggregate.Actor`'s typed-struct path
  # is string-keyed. `event_type/1` and `unwrap_data/1` are the only readers of
  # either convention: everything downstream gets atoms, and the payload is
  # normalised once to the only fields this module reads (`@payload_keys`, an
  # explicit list: no atom is minted from event data). An absent key stays absent.
  defp event_type(event) do
    case fetch_either_key(event, :event_type) do
      {:ok, type} -> type
      :error -> nil
    end
  end

  defp unwrap_data(%{data: data}), do: unwrap_data(data)
  defp unwrap_data(%{"data" => data}), do: unwrap_data(data)
  defp unwrap_data(%{payload: payload}), do: unwrap_data(payload)

  defp unwrap_data(map) when is_map(map) do
    Enum.reduce(@payload_keys, %{}, fn key, acc ->
      case fetch_either_key(map, key) do
        {:ok, value} -> Map.put(acc, key, value)
        :error -> acc
      end
    end)
  end

  defp unwrap_data(_), do: %{}

  # `Map.fetch/2`, not `||`: a present value is never mistaken for an absent key.
  defp fetch_either_key(map, key) do
    case Map.fetch(map, key) do
      {:ok, _value} = found -> found
      :error -> Map.fetch(map, Atom.to_string(key))
    end
  end

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

  # Parsed once per use so a test or an operator changing it is honoured. A bound that
  # cannot be honoured (not a positive integer) is a loud failure at boot, not a stall.
  defp max_concurrent_analyses do
    case Keyword.get(config(), :max_concurrent_analyses, @default_max_concurrent_analyses) do
      bound when is_integer(bound) and bound >= 1 ->
        bound

      other ->
        raise ArgumentError,
              "config :foreman_server, :review, max_concurrent_analyses must be a positive " <>
                "integer, got #{inspect(other)}"
    end
  end

  defp reason_text(text), do: FailureCause.sanitize(text, Archive.env_secrets())
end
