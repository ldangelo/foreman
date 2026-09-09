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

  @start_marker "<!-- FOREMAN_REVIEW_FINDINGS_START -->"
  @end_marker "<!-- FOREMAN_REVIEW_FINDINGS_END -->"
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
end
