defmodule ForemanServer.Workflow.PrBody do
  @moduledoc """
  Renders a pull-request body that carries the headings a project requires.

  A project sets `pr_body_headings` (see
  `ForemanServer.Aggregates.Project.Settings`) to the markdown headings its
  pull requests must carry, for example `["## Summary", "## Testing",
  "## Risk", "## How to revert", "## Directed by"]`.

  Foreman fills those headings with the content it has - the task, the run's
  commits and the phase artifact - instead of leaving them empty. A heading
  Foreman has no content for says so explicitly, so a reader never mistakes a
  missing section for a filled one.

  The builder is pure: it reads nothing but its arguments and never invents a
  pull-request title. The caller owns the title.
  """

  alias ForemanServer.Aggregates.Project.Settings
  alias ForemanServer.Workflow.PrBody.Sources

  @enforce_keys [:reason, :detail]
  defstruct [:reason, :detail]

  @typedoc "Why no body could be rendered."
  @type reason :: :invalid_headings | :body_too_large

  @type error :: %__MODULE__{reason: reason(), detail: term()}

  @type result :: {:ok, String.t()} | {:error, error()}

  # GitHub caps a pull-request body at 65535 characters.
  @max_body_bytes 65_535

  # What a heading carries when Foreman has no content for it. Written so the
  # reader knows the section was required and left unfilled, not forgotten.
  @not_recorded "_Not recorded by Foreman._"

  @doc """
  Builds the pull-request body for `headings` from `sources`.

  `headings` are the project's required headings, in order. The content
  Foreman has is placed under them in order; a heading with no content says
  so, and content beyond the last heading is placed under that last heading.

  Returns `{:error, %__MODULE__{}}` when the headings are not valid headings
  or when the rendered body exceeds the pull-request body limit.
  """
  @spec build([String.t()], Sources.t()) :: result()
  def build([], _sources) do
    {:error, %__MODULE__{reason: :invalid_headings, detail: :no_headings}}
  end

  def build(headings, %Sources{} = sources) when is_list(headings) do
    case Settings.validate_pr_body_headings(headings) do
      {:ok, validated} -> render(validated, sources)
      {:error, reason} -> {:error, %__MODULE__{reason: :invalid_headings, detail: reason}}
    end
  end

  def build(headings, _sources) do
    {:error,
     %__MODULE__{reason: :invalid_headings, detail: {:pr_body_headings_invalid, headings}}}
  end

  defp render(headings, sources) do
    body = render_headings(headings, blocks(sources))

    if byte_size(body) > @max_body_bytes do
      {:error, %__MODULE__{reason: :body_too_large, detail: byte_size(body)}}
    else
      {:ok, body}
    end
  end

  # The content Foreman has, in the order it is placed under the headings.
  defp blocks(%Sources{} = sources) do
    [task_block(sources), commits_block(sources), artifact_block(sources)]
    |> Enum.reject(&is_nil/1)
  end

  defp render_headings(headings, blocks) do
    contents = contents_under(headings, blocks)

    headings
    |> Enum.zip(contents)
    |> Enum.map_join("\n\n", fn {heading, content} ->
      heading <> "\n\n" <> render_content(content)
    end)
  end

  defp contents_under(headings, blocks) do
    contents =
      headings
      |> Enum.with_index()
      |> Enum.map(fn {_heading, index} -> Enum.slice(blocks, index, 1) end)

    case contents do
      [] ->
        []

      _ ->
        # Content beyond the last heading belongs under that heading.
        surplus = Enum.drop(blocks, length(headings))
        List.update_at(contents, length(headings) - 1, &(&1 ++ surplus))
    end
  end

  defp render_content([]), do: @not_recorded
  defp render_content(content), do: Enum.join(content, "\n\n")

  defp task_block(%Sources{task_title: title, task_description: description}) do
    case Enum.reject([title, description], &blank?/1) do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp commits_block(%Sources{commits: {:ok, commits}}) do
    case commits do
      [] ->
        nil

      commits ->
        commits
        |> Enum.map(fn {sha, subject} -> "- `#{short_sha(sha)}` #{subject}" end)
        |> Enum.map(&String.trim/1)
        |> Enum.join("\n")
    end
  end

  defp commits_block(%Sources{commits: {:error, detail}}),
    do: "Foreman could not list the run's commits: #{detail}"

  defp artifact_block(%Sources{artifact_path: path, artifact_section: section}) do
    parts =
      []
      |> put_artifact_path(path)
      |> put_artifact_section(section)
      |> Enum.reverse()

    case parts do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp put_artifact_path(parts, path) when is_binary(path), do: ["Artifact: `#{path}`" | parts]
  defp put_artifact_path(parts, _path), do: parts

  defp put_artifact_section(parts, section) when is_binary(section) and section != "",
    do: [section | parts]

  defp put_artifact_section(parts, _section), do: parts

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: true

  defp short_sha(sha) when is_binary(sha), do: String.slice(sha, 0, 7)
  defp short_sha(_sha), do: ""
end
