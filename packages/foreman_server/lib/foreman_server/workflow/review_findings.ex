defmodule ForemanServer.Workflow.ReviewFindings do
  @moduledoc """
  Extracts the unresolved-review-findings block a `review` phase writes into
  its artifact, for inclusion in a PR body.

  The block is delimited by literal HTML comments so it survives Markdown
  rendering in the artifact itself:

      <!-- FOREMAN_REVIEW_FINDINGS_START -->
      - `lib/foo.ex:12` Major — unchecked nil
      <!-- FOREMAN_REVIEW_FINDINGS_END -->

  Absent and empty blocks are `:none` — a review phase that genuinely found
  nothing has no findings to surface. An unterminated block (a start marker
  with no matching end marker) is a distinct outcome, `{:error,
  :unterminated_block}`: the phase wrote findings and failed to close its
  markers, so the findings exist in the artifact but must not silently
  vanish — that is exactly the silent-drop failure mode this module exists
  to prevent (AGENTS.md §5.3: absent and malformed are not one code).
  Callers log a warning and surface the artifact path in the PR body instead
  of dropping the block.
  """

  # The typed schema (TRD-013). The findings are claims written by the review
  # agent: this parser makes them typed and bounded, it cannot make them true,
  # so they are never a machine-observed input of the risk rubric. `extract/1`
  # and `extract_from/1` below are the earlier, untyped reader the PR-body
  # builders still call until TRD-014/TRD-034 move them onto `read/1`.

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
  be read is `{:error, {:unreadable, reason}}` (never a clean record).
  """
  @spec read(String.t() | nil) ::
          {:recorded, Record.t()}
          | :absent
          | {:malformed, reason}
          | {:error, {:unreadable, File.posix()}}
  def read(nil), do: :absent

  def read(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> parse(contents)
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
      |> Enum.reduce({nil, [], []}, fn {line, idx}, {fence, starts, ends} ->
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
  # span such as ```x``` is not a fence).
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
    case Jason.decode(block) do
      {:error, _} ->
        {:malformed, :invalid_json}

      {:ok, %{"schema" => @schema} = doc} ->
        validate_doc(doc, contents)

      {:ok, %{}} ->
        {:malformed, :unknown_schema}

      {:ok, _other} ->
        {:malformed, :invalid_json}
    end
  end

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
         true <- bounded_string?(path, @max_path),
         true <- bounded_string?(description, @max_description) and String.trim(description) != "",
         true <- bounded_string?(source, @max_source) and String.trim(source) != "",
         true <- is_nil(line) or (is_integer(line) and line > 0) do
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

  @max_bytes 4000
  @truncation_notice "\n… truncated; see the phase artifact for the full list."

  @doc """
  Extracts the findings block from the artifact at `path`.

  Reads the file and delegates to `extract_from/1`. Returns `:none` for a
  `nil` path or a missing/unreadable file (the artifact itself is already
  named in the PR body by path, so an unreadable file is not surfaced as a
  distinct error here). See `extract_from/1` for the unterminated-block
  outcome.
  """
  @spec extract(String.t() | nil) :: {:ok, String.t()} | :none | {:error, :unterminated_block}
  def extract(nil), do: :none

  def extract(path) when is_binary(path) do
    case File.read(path) do
      {:ok, contents} -> extract_from(contents)
      {:error, _reason} -> :none
    end
  end

  @doc """
  Extracts the findings block from already-read artifact `contents`.

  Returns `{:ok, block}` with the trimmed (and possibly truncated) text
  between the start/end markers, `:none` when the start marker is absent or
  the delimited block is blank, or `{:error, :unterminated_block}` when a
  start marker has no matching end marker.
  """
  @spec extract_from(String.t()) :: {:ok, String.t()} | :none | {:error, :unterminated_block}
  def extract_from(contents) when is_binary(contents) do
    case String.split(contents, @start_marker, parts: 2) do
      [_before, rest] ->
        case String.split(rest, @end_marker, parts: 2) do
          [block, _after] ->
            case String.trim(block) do
              "" -> :none
              trimmed -> {:ok, truncate(trimmed)}
            end

          _ ->
            {:error, :unterminated_block}
        end

      _ ->
        :none
    end
  end

  # Truncates a findings block over 4000 bytes, appending a truncation notice
  # suffix. Byte-safe: `String.slice/3` counts grapheme clusters, not bytes,
  # so a block full of multi-byte characters could exceed `@max_bytes` after
  # "truncation" under a grapheme-based slice.
  defp truncate(block) when byte_size(block) <= @max_bytes, do: block

  defp truncate(block) do
    block
    |> binary_slice(0, @max_bytes)
    |> drop_partial_codepoint()
    |> Kernel.<>(@truncation_notice)
  end

  defp drop_partial_codepoint(binary) do
    if String.valid?(binary),
      do: binary,
      else: drop_partial_codepoint(binary_part(binary, 0, byte_size(binary) - 1))
  end

  @doc """
  Builds the PR-body section for an unterminated findings block.

  Shared by `PhasePR` and `AutoPR` (AGENTS.md §5.7: one implementation, not
  duplicated per caller) so an unterminated block still names the artifact in
  the PR body instead of silently vanishing. Callers additionally log a
  warning naming their own module.
  """
  @spec unterminated_section(String.t()) :: String.t()
  def unterminated_section(artifact_path) do
    "\n## Unresolved review findings\n\n" <>
      "The review phase left an unterminated findings block in `#{artifact_path}`; " <>
      "its content could not be extracted. Check that artifact directly.\n"
  end
end
