defmodule ForemanServer.Workflow.ReviewFindings do
  @moduledoc """
  Extracts the unresolved-review-findings block a `review` phase writes into
  its artifact, for inclusion in a PR body.

  The block is delimited by literal HTML comments so it survives Markdown
  rendering in the artifact itself:

      <!-- FOREMAN_REVIEW_FINDINGS_START -->
      - `lib/foo.ex:12` Major — unchecked nil
      <!-- FOREMAN_REVIEW_FINDINGS_END -->

  Absent, empty, and unterminated blocks are all `:none` — a PR body is not
  the place to surface a malformed artifact, and the artifact itself is
  already named in the PR body by path.
  """

  @start_marker "<!-- FOREMAN_REVIEW_FINDINGS_START -->"
  @end_marker "<!-- FOREMAN_REVIEW_FINDINGS_END -->"
  @max_bytes 4000
  @truncation_notice "\n… truncated; see the phase artifact for the full list."

  @doc """
  Extracts the findings block from the artifact at `path`.

  Reads the file and delegates to `extract_from/1`. Returns `:none` for a
  `nil` path, a missing/unreadable file, or a file with no valid block.
  """
  @spec extract(String.t() | nil) :: {:ok, String.t()} | :none
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
  between the start/end markers, or `:none` when the markers are absent,
  unterminated, or delimit only blank content.
  """
  @spec extract_from(String.t()) :: {:ok, String.t()} | :none
  def extract_from(contents) when is_binary(contents) do
    with [_before, rest] <- String.split(contents, @start_marker, parts: 2),
         [block, _after] <- String.split(rest, @end_marker, parts: 2),
         trimmed when trimmed != "" <- String.trim(block) do
      {:ok, truncate(trimmed)}
    else
      _ -> :none
    end
  end

  # Truncates a findings block over 4000 bytes, appending a truncation notice suffix.
  defp truncate(block) when byte_size(block) <= @max_bytes, do: block
  defp truncate(block), do: String.slice(block, 0, @max_bytes) <> @truncation_notice
end
