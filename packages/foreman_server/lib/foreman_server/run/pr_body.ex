defmodule ForemanServer.Run.PrBody do
  @moduledoc """
  Fallback PR body for a `command:` phase commit that produced no
  `FOREMAN_PR_BODY` artifact (see `ForemanServer.Run.AutoPR` and
  `docs/reference/agent-protocol.md`).

  The project setting `pr_body_headings` (list of markdown heading lines)
  shapes the body: each configured heading is emitted in order with content
  pulled from the task prompt and the phase artifact's non-protocol files.
  Without a configured list the builder falls back to the two legacy sections
  (`## Summary` / `## Testing`) so existing projects are unchanged.
  """

  @enforce_keys [:subject, :body]
  defstruct [:subject, :subject_source, :body, :headings_used, :truncated]

  @type t :: %__MODULE__{
          subject: String.t(),
          subject_source: :first_non_empty_line | :task_subject,
          body: String.t(),
          headings_used: [String.t()],
          truncated: boolean()
        }

  @max_body_bytes 65_536
  @max_lines 200
  @generic_subjects ~w(todo fix this task patch changes update docs wip)
  @default_headings ["## Summary", "## Testing"]

  @spec build(keyword()) :: {:ok, t()} | :error
  def build(opts \\ []) do
    with {:ok, artifact} <- artifact_files(Keyword.get(opts, :artifact_dir)),
         {:ok, source, subject} <- subject(opts, artifact),
         {:ok, headings} <- headings(Keyword.get(opts, :headings)),
         {:ok, body, truncated} <- body(source, subject, headings) do
      {:ok,
       %__MODULE__{
         subject: subject,
         subject_source: source,
         body: body,
         headings_used: headings,
         truncated: truncated
       }}
    else
      _ -> :error
    end
  end

  # Explicit task subject wins; otherwise the artifact's first usable line.
  # The artifact path never falls back to the task prompt: `task_body` is
  # always trimmed, so an empty line is unattainable.
  defp subject(opts, artifact) do
    case task_subject(Keyword.get(opts, :task_subject)) do
      {:ok, subject} -> {:ok, :task_subject, subject}
      :error -> artifact_subject(artifact)
    end
  end

  defp task_subject(subject) when is_binary(subject) do
    case String.trim(subject) do
      "" -> :error
      trimmed -> {:ok, clipped_subject(trimmed)}
    end
  end

  defp task_subject(_), do: :error

  defp artifact_subject([_ | _] = files) do
    case Enum.find_value(files, &first_usable_line/1) do
      nil -> :error
      line -> {:ok, :first_non_empty_line, line}
    end
  end

  defp artifact_subject(_), do: :error

  defp first_usable_line({_path, contents}) do
    contents
    |> String.split(~r/\r\n|\r|\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&generic_subject?/1)
    |> case do
      [line | _] when line != "" -> {:ok, clipped_subject(line)}
      _ -> nil
    end
  end

  defp clipped_subject(line) do
    line
    |> String.split("@", parts: 2)
    |> hd()
    |> String.trim()
    |> then(&String.slice(&1, 0, 72))
    |> case do
      "" -> "docs: update project documentation"
      subject -> subject
    end
  end

  defp generic_subject?(line) do
    stripped =
      line
      |> String.replace_leading("#", "")
      |> String.replace_leading("*", "")
      |> String.replace_leading("-", "")
      |> String.trim()
      |> String.trim_trailing(":")
      |> String.downcase()

    stripped == "" or stripped in @generic_subjects
  end

  # Settings are stored as validated heading lines. An empty, non-list or
  # all-blank list falls back to the legacy headings so an unset (or cleared)
  # setting keeps the previous two-section body; an invalid entry fails the
  # build rather than emitting a partial body.
  defp headings(list) when is_list(list) do
    case Enum.map(list, &heading_entry/1) |> Enum.reject(&is_nil/1) do
      [] -> {:ok, @default_headings}
      cleaned -> {:ok, cleaned}
    end
  end

  defp headings(_), do: {:ok, @default_headings}

  defp heading_entry(heading) when is_binary(heading) do
    trimmed = String.trim(heading)

    if trimmed != "" && String.valid?(trimmed) && !String.match?(trimmed, ~r/[[:cntrl:]]/u) do
      trimmed
    end
  end

  defp heading_entry(_), do: nil

  defp artifact_files(dir) when is_binary(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        case Enum.flat_map(names, &artifact_file(dir, &1)) do
          [] -> :error
          files -> {:ok, files}
        end

      _ ->
        :error
    end
  end

  defp artifact_files(_), do: :error

  defp artifact_file(dir, name) do
    path = Path.join(dir, name)

    cond do
      File.dir?(path) -> []
      Path.extname(name) in [".md", ".markdown", ".txt"] -> read_artifact_file(path, name)
      true -> []
    end
  end

  defp read_artifact_file(path, name) do
    case File.read(path) do
      {:ok, contents} -> [{name, contents}]
      _ -> []
    end
  end

  # Each heading gets one distinct non-protocol artifact; the last heading (the
  # implicit "everything else" bucket) receives the remaining artifacts, so
  # fewer artifacts than headings still produce a complete body. The task
  # subject line and the artifact files already placed above stay in
  # `remaining`, so the same text can appear under "Summary" and under the
  # final catch-all heading.
  defp body(source, subject, headings) do
    initial = {:ok, [], [], false}

    {label, chunks, remaining, truncated} =
      headings
      |> Enum.with_index()
      |> Enum.reduce_while(initial, fn {heading, index}, {:ok, labels, bodies, saw_truncation} ->
        last? = index == length(headings) - 1

        case section(source, subject, headings, bodies, remaining, heading, last?) do
          {:ok, chunk, rest, chunk_truncated?} ->
            {:cont, {:ok, [heading | labels], [chunk | bodies], saw_truncation or chunk_truncated?}}

          :error ->
            {:halt, :error}
        end
      end)

    case label do
      :error ->
        :error

      _ ->
        rendered =
          headings
          |> Enum.zip(Enum.reverse(chunks))
          |> Enum.map_join("\n\n", fn {heading, chunk} -> heading <> "\n\n" <> chunk end)

        clamp_rendered(rendered, Enum.reverse(chunks), remaining, truncated)
    end
  end

  # `bodies` are the chunks already placed under earlier headings, in order.
  # A subject derived from an artifact is omitted from the first section (it is
  # that artifact's first line) so it is not duplicated there; the first
  # artifact is still shown whole under the final catch-all heading.
  defp section(:first_non_empty_line, subject, headings, bodies, files, _heading, false) do
    case files do
      [] ->
        {:ok, no_content(), files, false}

      [{_name, contents} | _] ->
        if already_present?(bodies, subject, contents) do
          {:ok, no_content(), files, false}
        else
          {:ok, drop_subject_line(contents, subject), files, false}
        end
    end
  end

  defp section(:task_subject, _subject, _headings, _bodies, [{name, contents} | rest], _heading, false) do
    {:ok, "**#{name}**\n\n" <> contents, rest, false}
  end

  defp section(_source, _subject, _headings, _bodies, [], _heading, false), do: {:ok, no_content(), [], false}

  defp section(_source, subject, _headings, _bodies, files, _heading, true) do
    chunks = Enum.map(files, fn {name, contents} -> "**#{name}**\n\n" <> contents end)
    text = Enum.join(chunks, "\n\n")
    clamped = clamp_text(text, @max_body_bytes)

    body =
      case chunks do
        [] -> no_content()
        _ -> clamped
      end

    {:ok, body, [], clamped != text}
  end

  # The subject was copied out of `contents`, so it can never appear in
  # `bodies` before the artifact it came from; that is checked so an exact
  # duplicate can never be emitted, whatever the order.
  defp already_present?(bodies, subject, contents) do
    Enum.any?(bodies, fn chunk ->
      chunk == contents || String.contains?(chunk, "\n" <> subject <> "\n")
    end)
  end

  defp drop_subject_line(contents, subject) do
    contents
    |> String.split("\n")
    |> Enum.drop_while(&(String.trim(&1) == ""))
    |> case do
      [first | rest] ->
        cond do
          String.trim(first) == subject -> Enum.join(rest, "\n") |> String.trim_trailing()
          subject != "" && String.starts_with?(first, subject) -> subject <> " …"
          true -> contents
        end

      [] ->
        contents
    end
  end

  defp no_content, do: "_No phase artifact content was produced._"

  defp clamp_rendered(rendered, chunks, remaining, truncated) do
    cond do
      remaining == [] && byte_size(rendered) <= @max_body_bytes ->
        {:ok, rendered, truncated}

      true ->
        case clamp_from_chunks(chunks, @max_body_bytes) do
          {:ok, clamped} -> {:ok, clamped, true}
          :error -> {:ok, fallback_body(), true}
        end
    end
  end

  # Drop whole sections from the end until the body fits, keeping at least one.
  defp clamp_from_chunks(chunks, budget) do
    headings_and_chunks = Enum.zip(default_headings_for(chunks), chunks)

    Enum.reduce_while(Enum.reverse(Enum.with_index(headings_and_chunks)), :error, fn {pair, index}, _acc ->
      candidate =
        headings_and_chunks
        |> Enum.take(index + 1)
        |> Enum.map_join("\n\n", fn {heading, chunk} -> heading <> "\n\n" <> chunk end)

      if byte_size(candidate) <= budget do
        {:halt, {:ok, candidate}}
      else
        {:cont, :error}
      end
    end)
  end

  # When truncated we no longer know which configured heading each chunk
  # belonged to, so the clamped body is labelled with the legacy headings; the
  # `truncated` flag on the struct is what tells the reader.
  defp default_headings_for(chunks) do
    case chunks do
      [_] -> ["## Summary"]
      [_ | _] -> @default_headings
    end
  end

  defp clamp_text(text, max) do
    cond do
      byte_size(text) <= max ->
        text

      true ->
        lines = String.split(text, "\n")

        {kept, _} =
          Enum.reduce_while(Enum.with_index(lines), {[], 0}, fn {line, _}, {acc, size} ->
            addition = byte_size(line) + if(acc == [], do: 0, else: 1)

            if addition + size > max - 20 do
              {:halt, {acc, size}}
            else
              {:cont, {[line | acc], addition + size}}
            end
          end)

        prefix = kept |> Enum.reverse() |> Enum.join("\n")
        prefix <> "\n\n[truncated]"
    end
  end

  defp fallback_body do
    """
    ## Summary

    #{no_content()}

    ## Testing

    #{no_content()}
    """
    |> String.trim_trailing()
  end
end
