defmodule ForemanServer.Workflow.ReviewFindings do
  @moduledoc """
  The typed findings block a `review` phase writes into its artifact, and the
  PR-body section rendered from it.

  The block is a JSON document between two literal HTML-comment marker lines
  (so it survives Markdown rendering in the artifact itself):

      <!-- FOREMAN_REVIEW_FINDINGS_START -->
      {"schema": "foreman.review_findings/1", "reviewed": true, "findings": [...]}
      <!-- FOREMAN_REVIEW_FINDINGS_END -->

  `read/1` and `parse/1` answer `{:recorded, record}`, `:absent` (no block: the
  review evidence is missing, which is NOT a clean review) or `{:malformed,
  reason}`; `section/1` and `pr_section/2` render the one PR-body section both
  `AutoPR` and `PhasePR` use (AGENTS.md 5.7: one implementation). The findings
  are the review agent's claims: parsed and bounded here, never verified.
  """

  require Logger

  # The typed schema (TRD-013). The findings are claims written by the review
  # agent: this parser makes them typed and bounded, it cannot make them true,
  # so they are never a machine-observed input of the risk rubric.

  @start_marker "<!-- FOREMAN_REVIEW_FINDINGS_START -->"
  @end_marker "<!-- FOREMAN_REVIEW_FINDINGS_END -->"

  @schema "foreman.review_findings/1"
  @severities ~w(critical major minor nitpick)
  @dispositions ~w(fixed declined open)
  @severity_atoms %{
    "critical" => :critical,
    "major" => :major,
    "minor" => :minor,
    "nitpick" => :nitpick
  }
  @disposition_atoms %{"fixed" => :fixed, "declined" => :declined, "open" => :open}
  @finding_keys ~w(severity path line description disposition source)
  @top_keys ~w(schema reviewed findings)
  @max_block_bytes 32_768
  @max_artifact_bytes 4 * 1024 * 1024
  @max_line 1_000_000_000
  @max_findings 100
  @max_description 1000
  @max_path 1024
  @max_source 64
  @max_detail 500

  @reasons [
    :unterminated_block,
    :multiple_blocks,
    :legacy_format,
    :invalid_json,
    :unknown_schema,
    :invalid_field,
    :too_large,
    :too_many_findings
  ]

  @type severity :: :critical | :major | :minor | :nitpick
  @type disposition :: :fixed | :declined | :open
  @type reason ::
          :unterminated_block
          | :multiple_blocks
          | :legacy_format
          | :invalid_json
          | :unknown_schema
          | :invalid_field
          | :too_large
          | :too_many_findings
  @type defect :: reason | :unreadable

  defmodule Finding do
    @moduledoc "One finding the review agent claims (never machine-observed)."
    @enforce_keys [:severity, :path, :line, :description, :disposition, :source]
    defstruct [:severity, :path, :line, :description, :disposition, :source]

    @type t :: %__MODULE__{
            severity: ForemanServer.Workflow.ReviewFindings.severity(),
            path: String.t(),
            line: pos_integer() | nil,
            description: String.t(),
            disposition: ForemanServer.Workflow.ReviewFindings.disposition(),
            source: String.t()
          }
  end

  defmodule Record do
    @moduledoc "A parsed, recorded findings block: typed findings plus the SHA-256 of the artifact contents."
    @enforce_keys [:findings, :artifact_sha256]
    defstruct [:findings, :artifact_sha256]

    @type t :: %__MODULE__{
            findings: [ForemanServer.Workflow.ReviewFindings.Finding.t()],
            artifact_sha256: String.t()
          }
  end

  @doc """
  Reads the artifact once and parses it. `nil` is `:absent`; a file that cannot
  be read is `{:error, {:unreadable, reason}}` (never a clean record); a file
  over #{@max_artifact_bytes} bytes is `{:malformed, :too_large}` and is not
  read.
  """
  @spec read(String.t() | nil) ::
          {:recorded, Record.t()}
          | :absent
          | {:malformed, reason}
          | {:error, {:unreadable, File.posix()}}
  def read(nil), do: :absent

  def read(path) when is_binary(path) do
    with {:ok, %File.Stat{size: size}} when size <= @max_artifact_bytes <- File.stat(path),
         {:ok, contents} <- File.read(path) do
      # The file may have grown between the stat and the read.
      if byte_size(contents) > @max_artifact_bytes,
        do: {:malformed, :too_large},
        else: parse(contents)
    else
      {:ok, %File.Stat{}} -> {:malformed, :too_large}
      {:error, reason} -> {:error, {:unreadable, reason}}
    end
  end

  @doc """
  Parses artifact contents: `{:recorded, %Record{}}` for exactly one counted
  marker pair holding a valid block, `:absent` when no marker is counted (NOT a
  clean review), `{:malformed, reason}` for every other shape.

  `findings: []` with `reviewed: true` is the one clean outcome.
  """
  @spec parse(String.t()) :: {:recorded, Record.t()} | :absent | {:malformed, reason}
  def parse(contents) when is_binary(contents) do
    case extract_block(contents, @start_marker, @end_marker) do
      :absent -> :absent
      {:error, reason} -> {:malformed, reason}
      {:ok, block} -> parse_block(block, contents)
    end
  end

  @doc """
  Scans `contents` for one counted marker pair and returns the text between.

  A line counts as a marker only when, trailing whitespace trimmed, it equals
  the marker exactly and lies outside a fenced code block. A fence opens on a
  line starting (after at most three spaces) with three or more backticks or
  tildes, closes on a later line starting (after at most three spaces) with at
  least as many of the same character and nothing else, and runs to the end of
  the file when never closed.

  Returns `{:ok, block}`, `:absent` (no counted marker), or
  `{:error, :multiple_blocks}` (a second counted start or end) /
  `{:error, :unterminated_block}` (a lone, misordered or never-closed marker).
  """
  @spec extract_block(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | :absent | {:error, :multiple_blocks | :unterminated_block}
  def extract_block(contents, start_marker, end_marker)
      when is_binary(contents) and is_binary(start_marker) and is_binary(end_marker) do
    lines = String.split(contents, "\n")
    {starts, ends} = counted_markers(lines, start_marker, end_marker)

    case {starts, ends} do
      {[], []} ->
        :absent

      {[s], [e]} when s < e ->
        {:ok, lines |> Enum.slice((s + 1)..(e - 1)//1) |> Enum.join("\n")}

      {[_, _ | _], _} ->
        {:error, :multiple_blocks}

      {_, [_, _ | _]} ->
        {:error, :multiple_blocks}

      _ ->
        {:error, :unterminated_block}
    end
  end

  @doc """
  Maps a malformed result or the read error of `read/1` to the closed event
  `defect` code and a detail text of at most #{@max_detail} characters.
  """
  @spec defect({:malformed, reason} | {:error, {:unreadable, term()}}) ::
          {defect, String.t()}
  def defect({:malformed, reason}) when reason in @reasons, do: {reason, reason_detail(reason)}

  def defect({:error, {:unreadable, reason}}) do
    {:unreadable,
     String.slice("the artifact could not be read: #{inspect(reason)}", 0, @max_detail)}
  end

  @doc """
  Counts the unresolved findings by severity: every `open` finding and every
  `declined` critical or major finding (a decline is the agent's say-so).
  `fixed` findings and declined minor or nitpick findings are not counted.
  """
  @spec unresolved(Record.t() | [Finding.t()]) :: %{severity => non_neg_integer()}
  def unresolved(%Record{findings: findings}), do: unresolved(findings)

  def unresolved(findings) when is_list(findings) do
    base = %{critical: 0, major: 0, minor: 0, nitpick: 0}

    Enum.reduce(findings, base, fn %Finding{severity: sev} = f, acc ->
      if unresolved?(f), do: Map.update!(acc, sev, &(&1 + 1)), else: acc
    end)
  end

  defp unresolved?(%Finding{disposition: :open}), do: true

  defp unresolved?(%Finding{disposition: :declined, severity: sev}),
    do: sev in [:critical, :major]

  defp unresolved?(%Finding{}), do: false

  # --- PR-body section (TRD-014) ---

  @max_listed 20
  @listed_description 300
  @listed_path 200
  @severity_order %{critical: 0, major: 1, minor: 2, nitpick: 3}
  @section_heading "\n## Review findings (the review agent's report)\n\n"

  @doc """
  Reads the artifact at `artifact_path` and renders the PR-body section (see
  `section/1`). A block that is not `:recorded` is logged as a warning naming
  `caller` (`"AutoPR"`, `"PhasePR"`), so the missing evidence is visible in the
  server log as well as in the body.
  """
  @spec pr_section(String.t() | nil, String.t()) :: String.t()
  def pr_section(artifact_path, caller) when is_binary(caller) do
    result = read(artifact_path)

    case result do
      {:recorded, _record} ->
        :ok

      :absent ->
        Logger.warning("#{caller} found no review findings block in #{inspect(artifact_path)}")

      other ->
        {defect, detail} = defect(other)

        Logger.warning(
          "#{caller} could not read review findings in #{inspect(artifact_path)}: #{defect} (#{detail})"
        )
    end

    section(result)
  end

  @doc """
  Renders the one PR-body section from a `read/1` result. The text is bounded:
  at most #{@max_listed} unresolved findings are listed, each path and
  description cut and flattened to one line, because the body is a `gh` write
  and the findings are the agent's untrusted text.

  `:recorded` lists the unresolved findings (every `open` one and every
  `declined` critical or major one) and counts the fixed and declined ones;
  `:absent` says the review evidence is missing; `{:malformed, _}` and an
  unreadable artifact name the defect. None of them says a block that could not
  be read held no findings.
  """
  @spec section(
          {:recorded, Record.t()}
          | :absent
          | {:malformed, reason}
          | {:error, {:unreadable, File.posix()}}
        ) :: String.t()
  def section({:recorded, %Record{findings: findings}}) do
    unresolved =
      findings
      |> Enum.filter(&unresolved?/1)
      |> Enum.sort_by(&Map.fetch!(@severity_order, &1.severity))

    fixed = Enum.count(findings, &(&1.disposition == :fixed))
    declined = Enum.count(findings, &(&1.disposition == :declined))

    @section_heading <>
      "Written by the review agent and not verified by Foreman.\n\n" <>
      unresolved_text(unresolved) <>
      "\nFixed: #{fixed}. Declined: #{declined} " <>
      "(a declined critical or major finding is listed above as unresolved).\n"
  end

  def section(:absent) do
    @section_heading <>
      "The review evidence is missing: the review artifact has no findings block. " <>
      "This is not a clean review. Check the review artifact.\n"
  end

  def section(error) do
    {defect, detail} = defect(error)

    @section_heading <>
      "The review evidence is malformed or unreadable (`#{defect}`): #{detail}. " <>
      "This is not a clean review. Check the review artifact.\n"
  end

  defp unresolved_text([]), do: "The review agent reported nothing unresolved.\n"

  defp unresolved_text(unresolved) do
    listed = Enum.take(unresolved, @max_listed)
    more = length(unresolved) - length(listed)

    "Unresolved (#{length(unresolved)}):\n\n" <>
      Enum.map_join(listed, "", &finding_line/1) <>
      if(more > 0,
        do: "- … and #{more} more unresolved; see the review artifact.\n",
        else: ""
      )
  end

  defp finding_line(%Finding{} = f) do
    path = flatten(f.path, @listed_path)
    location = if f.line, do: "#{path}:#{f.line}", else: path
    declined = if f.disposition == :declined, do: " (declined by the agent)", else: ""

    "- **#{f.severity}** `#{String.replace(location, "`", "'")}`#{declined} — " <>
      flatten(f.description, @listed_description) <> "\n"
  end

  # One line, bounded: the agent's text must not break the list or grow the body.
  defp flatten(text, max) do
    flat = text |> String.split() |> Enum.join(" ")

    if String.length(flat) > max, do: String.slice(flat, 0, max) <> "…", else: flat
  end

  defp reason_detail(:unterminated_block),
    do: "a findings marker has no matching partner, or the markers are out of order"

  defp reason_detail(:multiple_blocks),
    do: "more than one findings marker pair is present; quote marker lines inside a code fence"

  defp reason_detail(:legacy_format),
    do: "the findings block is empty or uses the earlier Markdown bullet format"

  defp reason_detail(:invalid_json), do: "the findings block is not valid JSON"
  defp reason_detail(:unknown_schema), do: "the findings block does not declare schema #{@schema}"

  defp reason_detail(:invalid_field),
    do:
      "a findings field is missing, unknown, of the wrong type, out of its closed set or over its bound"

  defp reason_detail(:too_large), do: "the findings block is over #{@max_block_bytes} bytes"

  defp reason_detail(:too_many_findings),
    do: "the findings block holds more than #{@max_findings} findings"

  # --- marker scan ---

  defp counted_markers(lines, start_marker, end_marker) do
    {_fence, starts, ends} =
      lines
      |> Enum.with_index()
      |> Enum.reduce({nil, [], []}, fn {raw, idx}, {fence, starts, ends} ->
        # A CRLF artifact: the line ending is not part of the line.
        line = String.trim_trailing(raw, "\r")

        case fence do
          nil ->
            trimmed = String.trim_trailing(line)

            cond do
              trimmed == start_marker -> {nil, [idx | starts], ends}
              trimmed == end_marker -> {nil, starts, [idx | ends]}
              true -> {fence_open(line), starts, ends}
            end

          open ->
            if fence_closes?(line, open), do: {nil, starts, ends}, else: {open, starts, ends}
        end
      end)

    {Enum.reverse(starts), Enum.reverse(ends)}
  end

  # A fence opens on up to three spaces then three or more backticks or tildes.
  # A backtick fence's info string may not hold a backtick (so an inline code
  # span such as ```x``` is not a fence); a tilde fence's may.
  defp fence_open(line) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})(.*)$/, line) do
      [_, ticks, info] ->
        if String.starts_with?(ticks, "`") and String.contains?(info, "`"),
          do: nil,
          else: {String.first(ticks), String.length(ticks)}

      _ ->
        nil
    end
  end

  defp fence_closes?(line, {char, len}) do
    case Regex.run(~r/^ {0,3}(`{3,}|~{3,})[ \t]*$/, line) do
      [_, run] -> String.first(run) == char and String.length(run) >= len
      _ -> false
    end
  end

  # --- block parse ---

  defp parse_block(block, _contents) when byte_size(block) > @max_block_bytes,
    do: {:malformed, :too_large}

  defp parse_block(block, contents) do
    if legacy?(block), do: {:malformed, :legacy_format}, else: decode_block(block, contents)
  end

  defp legacy?(block) do
    case block |> String.split("\n") |> Enum.find(&(String.trim(&1) != "")) do
      nil -> true
      line -> Regex.match?(~r/^\s*[-*+](\s|$)/, line)
    end
  end

  defp decode_block(block, contents) do
    # `:ordered_objects` keeps a repeated key visible, which a plain map decode
    # would silently collapse to the last value.
    case Jason.decode(block, objects: :ordered_objects) do
      {:error, _} ->
        {:malformed, :invalid_json}

      {:ok, decoded} ->
        case unique_keys(decoded) do
          :duplicate_key -> {:malformed, :invalid_field}
          {:ok, doc} -> dispatch_doc(doc, contents)
        end
    end
  end

  defp dispatch_doc(%{"schema" => @schema} = doc, contents), do: validate_doc(doc, contents)
  defp dispatch_doc(%{}, _contents), do: {:malformed, :unknown_schema}
  defp dispatch_doc(_other, _contents), do: {:malformed, :invalid_json}

  defp unique_keys(%Jason.OrderedObject{values: pairs}) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      with false <- Map.has_key?(acc, key),
           {:ok, value} <- unique_keys(value) do
        {:cont, {:ok, Map.put(acc, key, value)}}
      else
        _ -> {:halt, :duplicate_key}
      end
    end)
  end

  defp unique_keys(list) when is_list(list) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case unique_keys(item) do
        {:ok, item} -> {:cont, {:ok, [item | acc]}}
        :duplicate_key -> {:halt, :duplicate_key}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      :duplicate_key -> :duplicate_key
    end
  end

  defp unique_keys(scalar), do: {:ok, scalar}

  defp validate_doc(doc, contents) do
    cond do
      Enum.sort(Map.keys(doc)) != Enum.sort(@top_keys) -> {:malformed, :invalid_field}
      doc["reviewed"] != true -> {:malformed, :invalid_field}
      not is_list(doc["findings"]) -> {:malformed, :invalid_field}
      length(doc["findings"]) > @max_findings -> {:malformed, :too_many_findings}
      true -> build_findings(doc["findings"], contents)
    end
  end

  defp build_findings(items, contents) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case build_finding(item) do
        {:ok, finding} -> {:cont, {:ok, [finding | acc]}}
        :error -> {:halt, :error}
      end
    end)
    |> case do
      {:ok, acc} ->
        {:recorded,
         %Record{
           findings: Enum.reverse(acc),
           artifact_sha256: :crypto.hash(:sha256, contents) |> Base.encode16(case: :lower)
         }}

      :error ->
        {:malformed, :invalid_field}
    end
  end

  defp build_finding(%{} = item) do
    with true <- Enum.sort(Map.keys(item)) == Enum.sort(@finding_keys),
         %{
           "severity" => severity,
           "path" => path,
           "line" => line,
           "description" => description,
           "disposition" => disposition,
           "source" => source
         } = item,
         true <- severity in @severities,
         true <- disposition in @dispositions,
         true <- bounded_string?(path, @max_path) and clean_text?(path, :line),
         true <-
           bounded_string?(description, @max_description) and String.trim(description) != "" and
             clean_text?(description, :multiline),
         true <-
           bounded_string?(source, @max_source) and String.trim(source) != "" and
             clean_text?(source, :line),
         true <- is_nil(line) or (is_integer(line) and line > 0 and line <= @max_line) do
      {:ok,
       %Finding{
         severity: Map.fetch!(@severity_atoms, severity),
         path: path,
         line: line,
         description: description,
         disposition: Map.fetch!(@disposition_atoms, disposition),
         source: source
       }}
    else
      _ -> :error
    end
  end

  defp build_finding(_), do: :error

  defp bounded_string?(value, max), do: is_binary(value) and String.length(value) <= max

  # The agent's text reaches the event store and the PR body: no NUL, ESC, CR or
  # other C0 control character and no DEL. A description may keep `\n` and `\t`;
  # a path and a source are one line and keep neither.
  defp clean_text?(value, :multiline), do: not Regex.match?(~r/[\x00-\x08\x0B-\x1F\x7F]/u, value)
  defp clean_text?(value, :line), do: not Regex.match?(~r/[\x00-\x1F\x7F]/u, value)
end
