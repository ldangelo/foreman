defmodule ForemanServer.Coordinator.Reporter do
  @moduledoc """
  Brings thread outcomes into the coordinator conversation as reports, so the
  coordinator hears what its threads did (verdicts, failures, cancellations).

  Each reportable event for a thread of a project appends ONE
  `coordinator.append` message (`role: system`, `kind: report`, `thread_ref`,
  `report_key: "<event type>:<subject id>"`); the aggregate deduplicates by
  report key, so duplicate delivery and the startup backfill append nothing a
  second time. A report starts a coordinator turn through the normal wake-up
  (`Runner`), and such a turn has `:machine` authority: it can answer, route a
  follow-up, propose threads or remember, never start work or change settings.

  Loop guards: reports about threads that came from a review gap bead
  (`ProjectionStore.gap_bead?/1`) and reports beyond `report_turns_per_hour` are
  appended `suppressed` (visible in the conversation, no turn); the suppression
  is announced once per hour.

  Reported events (`config :coordinator, :report_events`, default
  `ReviewRecorded` and the failed/cancelled terminals; the completed terminals too
  when `config :review, analysis: false`, since then no verdict will follow).
  PR-ready/CI/approval events of E8/E9 are not on this branch's main and are not
  reported yet.
  """
  use GenServer

  require Logger

  alias ForemanServer.Coordinator.{Commands, Conversation, ReportFormatter, Runtime}
  alias ForemanServer.ProjectionStore

  @run_events ~w(RunCompleted RunFailed RunCancelled)
  @jobsite_events ~w(JobsiteCompleted JobsiteFailed JobsiteCancelled)
  @default_events ~w(ReviewRecorded RunFailed RunCancelled JobsiteFailed JobsiteCancelled)

  def start_link(opts) do
    rt = Keyword.fetch!(opts, :runtime)

    GenServer.start_link(__MODULE__, {rt, Keyword.get(opts, :backfill?, true)}, name: name(rt))
  end

  @doc "Registered name of a runtime's reporter."
  @spec name(Runtime.t() | atom()) :: atom()
  def name(%Runtime{name: name}), do: name(name)
  def name(name) when is_atom(name), do: Module.concat(name, "Reporter")

  @doc "Events reported, honouring config and the review-analysis switch."
  @spec report_events() :: [String.t()]
  def report_events do
    config = Application.get_env(:foreman_server, :coordinator, [])

    case Keyword.get(config, :report_events) do
      list when is_list(list) ->
        list

      nil ->
        if Application.get_env(:foreman_server, :review, [])[:analysis] == false,
          do: @default_events ++ ~w(RunCompleted JobsiteCompleted),
          else: @default_events
    end
  end

  @impl true
  def init({rt, backfill?}) do
    case ProjectionStore.subscribe(replay_existing: false) do
      :ok -> {:ok, %{rt: rt}, if(backfill?, do: {:continue, :backfill}, else: nil)} |> strip_nil()
      {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  defp strip_nil({:ok, state, nil}), do: {:ok, state}
  defp strip_nil(other), do: other

  @impl true
  def handle_continue(:backfill, state) do
    backfill(state.rt)
    {:noreply, state}
  end

  @impl true
  def handle_info({:projection_event, event}, state) when is_map(event) do
    type = field(event, :event_type)

    if type in report_events() do
      data = field(event, :data) || field(event, :payload) || %{}
      safe_handle(state.rt, type, data)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @doc """
  Append reports for terminal threads and reviews of the last
  `report_backfill_hours` that have none yet (events delivered while the server
  was down are never replayed to subscribers).
  """
  @spec backfill(Runtime.t()) :: :ok
  def backfill(%Runtime{} = rt) do
    hours =
      :foreman_server
      |> Application.get_env(:coordinator, [])
      |> Keyword.get(:report_backfill_hours, 24)

    cutoff = System.system_time(:millisecond) - hours * 3_600_000
    inputs = ProjectionStore.thread_inputs()

    for {{kind, id}, review} <- inputs.reviews,
        recent?(review, cutoff),
        "ReviewRecorded" in report_events() do
      handle_event(rt, "ReviewRecorded", Map.merge(review, %{subject_kind: kind, subject_id: id}))
    end

    for run <- inputs.runs,
        terminal_type(run) in report_events(),
        run.last_event_at_ms >= cutoff do
      handle_event(rt, terminal_type(run), %{run_id: run.run_id})
    end

    :ok
  end

  defp recent?(%{at: at}, cutoff) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond) >= cutoff
      _ -> false
    end
  end

  defp recent?(_review, _cutoff), do: false

  defp terminal_type(%{status: "completed"}), do: "RunCompleted"
  defp terminal_type(%{status: "failed"}), do: "RunFailed"
  defp terminal_type(%{status: "cancelled"}), do: "RunCancelled"
  defp terminal_type(_), do: nil

  # A malformed event must never take the reporter down: it is logged and dropped.
  defp safe_handle(rt, type, data) do
    handle_event(rt, type, data)
  rescue
    exception ->
      Logger.warning("coordinator reporter: dropped #{type}: #{Exception.message(exception)}")
      :ok
  end

  # ------------------------------------------------------------------- mapping

  defp handle_event(rt, "ReviewRecorded", data) do
    kind = field(data, :subject_kind)
    id = field(data, :subject_id)

    with project_id when is_binary(project_id) <- field(data, :project_id) || project_of(kind, id) do
      subject =
        kind
        |> subject(id)
        |> Map.update(:bead_id, field(data, :bead_id), &(field(data, :bead_id) || &1))

      review = %{
        verdict: field(data, :verdict),
        scores: field(data, :scores),
        summary: field(data, :summary),
        gap_bead_ids: field(data, :gap_bead_ids)
      }

      report(
        rt,
        project_id,
        "ReviewRecorded",
        id,
        subject,
        ReportFormatter.format("ReviewRecorded", subject, review)
      )
    end
  end

  defp handle_event(rt, type, data) when type in @run_events do
    with id when is_binary(id) <- field(data, :run_id),
         project_id when is_binary(project_id) <- project_of("run", id) do
      subject = subject("run", id)
      report(rt, project_id, type, id, subject, ReportFormatter.format(type, subject, data))
    end
  end

  defp handle_event(rt, type, data) when type in @jobsite_events do
    with id when is_binary(id) <- field(data, :jobsite_id),
         project_id when is_binary(project_id) <- project_of("jobsite", id) do
      subject = subject("jobsite", id)
      report(rt, project_id, type, id, subject, ReportFormatter.format(type, subject, data))
    end
  end

  defp handle_event(_rt, _type, _data), do: :ok

  defp project_of("run", id) when is_binary(id) and id != "",
    do: with(%{project_id: p} <- ProjectionStore.run(id), do: p)

  defp project_of("jobsite", id) when is_binary(id) and id != "",
    do: with(%{project_id: p} <- ProjectionStore.jobsite(id), do: p)

  defp project_of(_, _), do: nil

  defp subject("run", id) do
    run = ProjectionStore.run(id) || %{}
    task = run[:task_id] && ProjectionStore.task_projection(run[:task_id])

    %{
      thread_id: "run:" <> id,
      title: task && Map.get(task, :title),
      reason: run[:failure_reason] && to_string(run[:failure_reason]),
      pr_url: nil,
      task_id: run[:task_id],
      run_id: id,
      bead_id: task && Map.get(task, :external_id)
    }
  end

  defp subject("jobsite", id) do
    jobsite = ProjectionStore.jobsite(id) || %{}

    %{
      thread_id: "jobsite:" <> id,
      title: jobsite[:name],
      reason: nil,
      pr_url: nil,
      task_id: nil,
      run_id: nil,
      jobsite_id: id,
      bead_id: jobsite[:bead_id]
    }
  end

  defp subject(_, id), do: %{thread_id: id, title: nil, reason: nil}

  # ------------------------------------------------------------------ appending

  defp report(rt, project_id, type, subject_id, subject, text) do
    report_key = "#{type}:#{subject_id}"

    attrs = %{
      role: "system",
      kind: "report",
      text: text,
      report_key: report_key,
      thread_ref: thread_ref(subject),
      suppressed: suppress?(project_id, subject)
    }

    attrs = maybe_rate_limit(rt, project_id, attrs)

    case Commands.append(rt.gateway, project_id, "report:" <> report_key, attrs) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning("coordinator reporter: append for #{project_id} failed: #{inspect(other)}")
    end
  end

  defp thread_ref(subject) do
    subject
    |> Map.take([:task_id, :run_id, :jobsite_id])
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  # A report about a thread that came from a review gap bead never becomes new
  # proposals: gap depth is capped at 1.
  defp suppress?(_project_id, %{bead_id: bead_id}) when is_binary(bead_id) and bead_id != "",
    do: ProjectionStore.gap_bead?(bead_id)

  defp suppress?(_project_id, _subject), do: false

  defp maybe_rate_limit(_rt, _project_id, %{suppressed: true} = attrs), do: attrs

  defp maybe_rate_limit(rt, project_id, attrs) do
    limit =
      :foreman_server
      |> Application.get_env(:coordinator, [])
      |> Keyword.get(:report_turns_per_hour, 6)

    with {:ok, conv} <- ProjectionStore.coordinator_state(project_id),
         false <- already_present?(conv, attrs.report_key),
         true <- recent_report_turns(conv) >= limit do
      announce_suppression(rt, project_id)
      %{attrs | suppressed: true}
    else
      _ -> attrs
    end
  end

  defp already_present?(conv, report_key),
    do: Enum.any?(conv.messages, &(&1.report_key == report_key))

  defp recent_report_turns(conv) do
    cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)

    Enum.count(conv.messages, fn m ->
      Conversation.trigger?(m) and m.kind == "report" and at_or_after?(m.at, cutoff)
    end)
  end

  defp at_or_after?(at, cutoff) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, dt, _} -> DateTime.compare(dt, cutoff) != :lt
      _ -> false
    end
  end

  defp at_or_after?(_, _), do: false

  defp announce_suppression(rt, project_id) do
    bucket = DateTime.utc_now() |> Calendar.strftime("%Y%m%d%H")

    Commands.append(rt.gateway, project_id, "report-suppressed:" <> bucket, %{
      role: "system",
      kind: "notice",
      text:
        "Too many thread reports this hour: further reports are listed here but will not start a coordinator turn until the hour rolls over."
    })
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_other, _key), do: nil
end
