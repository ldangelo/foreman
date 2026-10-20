defmodule ForemanServer.Review.BeadSink do
  @moduledoc """
  Publishes a review verdict back to the bead that originated the work.

  For a subject with a `bead_id` it posts the verdict as a bead comment and
  files one `foreman-exec` bead per identified gap. Gap beads are also labelled
  `foreman-gap`. A source bead that an earlier review filed as a gap bead
  (recorded in the event log, so no `br show` is needed) is not expanded
  further (depth cap of 1). The suppression is reported in the returned `note`.

  Subjects without a `bead_id` are a no-op and never touch the task provider.
  """

  require Logger

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Review.Error
  alias ForemanServer.Review.Gap
  alias ForemanServer.Review.Subject
  alias ForemanServer.Review.Verdict
  alias ForemanServer.TaskProvider.Registry

  @gap_label "foreman-gap"
  @exec_label "foreman-exec"
  @truncation_marker "\n\n[…truncated]"

  @type result :: %{gap_bead_ids: [String.t()], note: String.t() | nil}

  @spec publish(Subject.t(), Verdict.t()) :: {:ok, result()} | {:error, Error.t()}
  def publish(%Subject{bead_id: nil} = subject, %Verdict{}) do
    Logger.info(
      "review bead sink skipped: #{subject.kind} #{subject.subject_id} has no originating bead"
    )

    {:ok, %{gap_bead_ids: [], note: nil}}
  end

  def publish(%Subject{bead_id: bead_id, project_id: project_id} = subject, %Verdict{})
      when is_binary(bead_id) and (is_nil(project_id) or project_id == "") do
    Logger.info(
      "review bead sink skipped: #{subject.kind} #{subject.subject_id} has bead #{bead_id} but no project_id"
    )

    {:ok, %{gap_bead_ids: [], note: "no project_id: bead step skipped"}}
  end

  def publish(%Subject{bead_id: bead_id} = subject, %Verdict{} = verdict)
      when is_binary(bead_id) do
    with {:ok, provider, cfg} <- resolve_provider(subject),
         :ok <- post_comment(provider, cfg, subject, verdict) do
      suppressed? = files_gaps?(verdict) and ProjectionStore.gap_bead?(bead_id)
      file_gaps(provider, subject, verdict, suppressed?)
    end
  end

  # -- provider resolution ---------------------------------------------------

  defp resolve_provider(%Subject{project_id: project_id} = subject) do
    case Registry.project_config(project_id) do
      {:ok, %{provider_module: mod, config: cfg}} ->
        {:ok, mod, cfg}

      {:error, reason} ->
        {:error,
         Error.new(
           :bead_unresolved,
           "no task provider resolvable for project #{inspect(project_id)}",
           %{reason: reason, bead_id: subject.bead_id}
         )}
    end
  end

  defp files_gaps?(%Verdict{verdict: :undetermined}), do: false
  defp files_gaps?(%Verdict{gaps: []}), do: false
  defp files_gaps?(%Verdict{}), do: true

  # -- comment ---------------------------------------------------------------

  defp post_comment(provider, cfg, subject, verdict) do
    body = comment_body(subject, verdict)

    case provider.annotate(subject.bead_id, body, cfg) do
      {:ok, _comment} ->
        :ok

      {:error, reason} ->
        {:error,
         Error.new(:bead_write_failed, "could not post review comment on #{subject.bead_id}", %{
           bead_id: subject.bead_id,
           reason: describe(reason)
         })}
    end
  end

  defp comment_body(subject, verdict) do
    max = config!(:max_comment_bytes)
    pointer = "\n\nFull analysis: " <> Path.join(subject.archive_dir, "analysis.md")
    markdown = Verdict.to_markdown(verdict)

    if byte_size(markdown) + byte_size(pointer) <= max do
      markdown <> pointer
    else
      budget = max(max - byte_size(pointer) - byte_size(@truncation_marker), 0)
      truncate_utf8(markdown, budget) <> @truncation_marker <> pointer
    end
  end

  defp truncate_utf8(binary, limit) when byte_size(binary) <= limit, do: binary

  defp truncate_utf8(binary, limit) do
    binary |> binary_part(0, limit) |> drop_partial_tail()
  end

  defp drop_partial_tail(<<>>), do: <<>>

  defp drop_partial_tail(binary) do
    if String.valid?(binary) do
      binary
    else
      drop_partial_tail(binary_part(binary, 0, byte_size(binary) - 1))
    end
  end

  # -- gap beads -------------------------------------------------------------

  defp file_gaps(provider, subject, verdict, suppressed?) do
    cond do
      not files_gaps?(verdict) ->
        {:ok, %{gap_bead_ids: [], note: nil}}

      to_string(subject.status) == "cancelled" ->
        {:ok,
         %{
           gap_bead_ids: [],
           note: "gap creation suppressed: #{subject.kind} was cancelled, so unfinished work is not filed as gaps"
         }}

      suppressed? ->
        {:ok,
         %{
           gap_bead_ids: [],
           note: "gap creation suppressed: source bead is itself a foreman-gap bead"
         }}

      true ->
        create_gaps(provider, subject, verdict)
    end
  end

  defp create_gaps(provider, subject, %Verdict{gaps: gaps}) do
    cap = config!(:max_gap_beads)
    {selected, dropped} = Enum.split(gaps, cap)

    results =
      selected
      |> Enum.with_index(1)
      |> Enum.map(fn {gap, index} ->
        {index, gap, provider.create(subject.project_id, gap_attrs(subject, gap, index))}
      end)

    ids = for {_i, _gap, {:ok, %{id: id}}} <- results, do: id

    failures =
      for {index, _gap, {:error, reason}} <- results, do: "gap #{index}: #{describe(reason)}"

    notes =
      Enum.reject(
        [
          failures != [] && "gap bead creation failed (#{Enum.join(failures, "; ")})",
          dropped != [] &&
            "#{length(dropped)} gap(s) beyond max_gap_beads=#{cap} not filed"
        ],
        &(&1 == false)
      )

    note = if notes == [], do: nil, else: Enum.join(notes, "; ")

    if ids == [] and failures != [] do
      {:error,
       Error.new(:bead_write_failed, "every gap bead creation failed", %{
         bead_id: subject.bead_id,
         failures: failures
       })}
    else
      {:ok, %{gap_bead_ids: ids, note: note}}
    end
  end

  defp gap_attrs(subject, %Gap{} = gap, index) do
    %{
      title: gap.title,
      description: gap_description(subject, gap),
      priority: priority(gap.severity),
      task_type: task_type(gap.severity),
      task_id: "review:#{subject.kind}:#{subject.subject_id}",
      command_id: "review:#{subject.subject_id}:gap:#{index}",
      labels: [@exec_label, @gap_label]
    }
  end

  defp priority(:major), do: 1
  defp priority(:minor), do: 3

  defp task_type(:major), do: "bug"
  defp task_type(:minor), do: "chore"

  defp gap_description(subject, gap) do
    """
    #{gap.description}

    Dimension: #{gap.dimension}
    Severity: #{gap.severity}

    Found by automated review of #{subject.kind} #{subject.subject_id}, which was working on bead #{subject.bead_id}.
    Session archive: #{subject.archive_dir}
    Full analysis: #{Path.join(subject.archive_dir, "analysis.md")}
    """
    |> String.trim_trailing()
  end

  # -- helpers ---------------------------------------------------------------

  defp config!(key) do
    :foreman_server |> Application.get_env(:review, []) |> Keyword.fetch!(key)
  end

  defp describe(%{code: code, message: message}), do: "#{code}: #{message}"
  defp describe(other), do: inspect(other)
end
