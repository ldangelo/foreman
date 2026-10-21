defmodule ForemanServer.Review.Prompt do
  @moduledoc """
  Renders the reviewer prompt from `priv/review/analysis_prompt.md`.

  Placeholders look like `{{name}}`. Substitution is single-pass, so text
  substituted in is never rescanned; a placeholder the renderer does not know
  raises, as does a missing template or manifest.
  """

  alias ForemanServer.Review.{Archive, Subject}

  @template_rel "review/analysis_prompt.md"
  @placeholder ~r/\{\{([a-z_]+)\}\}/

  @doc "Render the prompt for `subject`, reading its manifest from the archive. Raises on any failure."
  @spec render(Subject.t()) :: String.t()
  def render(%Subject{archive_dir: dir} = subject) do
    case Archive.read_manifest(dir) do
      {:ok, manifest} -> render(subject, manifest)
      {:error, error} -> raise "review prompt: cannot read manifest: #{inspect(error)}"
    end
  end

  @doc "Render the prompt for `subject` with an already-read `manifest`. Raises on any failure."
  @spec render(Subject.t(), map()) :: String.t()
  def render(%Subject{} = subject, manifest) when is_map(manifest) do
    values = %{
      "request_title" => subject.request_title || "(no title)",
      "request_text" => request_text(subject),
      "subject_kind" => Atom.to_string(subject.kind),
      "subject_id" => subject.subject_id,
      "status" => to_string(subject.status),
      "archive_dir" => Path.expand(subject.archive_dir),
      "diff_path" => archive_path(subject, "diff.patch"),
      "changed_files_path" => archive_path(subject, "changed-files.txt"),
      "transcript_path" => archive_path(subject, "transcript.jsonl"),
      "manifest_path" => archive_path(subject, "manifest.json"),
      "manifest_json" => Jason.encode!(manifest, pretty: true)
    }

    Regex.replace(@placeholder, template!(), fn _whole, name ->
      case values do
        %{^name => value} -> value
        _ -> raise "review prompt: unfilled placeholder {{#{name}}}"
      end
    end)
  end

  defp request_text(%Subject{request_text: text}) when is_binary(text) and text != "", do: text
  defp request_text(_), do: "(the archive's request.md holds the request; no text was projected)"

  defp archive_path(subject, name), do: Path.join(Path.expand(subject.archive_dir), name)

  defp template! do
    path = Path.join(:code.priv_dir(:foreman_server), @template_rel)

    case File.read(path) do
      {:ok, template} -> template
      {:error, reason} -> raise "review prompt: cannot read template #{path}: #{inspect(reason)}"
    end
  end
end
