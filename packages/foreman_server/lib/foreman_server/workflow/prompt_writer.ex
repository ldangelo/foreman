defmodule ForemanServer.Workflow.PromptWriter do
  @moduledoc """
  Filesystem discipline for prompt file mutation.

  Validates containment against `Catalog.root()/prompts/`, rejects filenames
  containing path separators or `..` segments, and writes atomically via a
  temp file + `File.rename/2`.
  """

  alias ForemanServer.Workflow.Catalog

  # -------------------------------------------------------------------
  # Public API
  # -------------------------------------------------------------------

  @doc """
  Write a prompt file to the catalog's prompts directory.

  The `name` is the prompt stem (e.g. `"assess"`), which is combined
  with `.md` to form the filename. The resolved path is validated to
  remain within `Catalog.root()/prompts/`.

  Returns `{:ok, path}` on success or an error tuple.
  """
  @spec write_prompt(String.t(), String.t()) ::
          {:ok, Path.t()}
          | {:error,
             :outside_catalog
             | :invalid_filename}
  def write_prompt(name, content)
      when is_binary(name) and is_binary(content) do
    filename = name <> ".md"

    with :ok <- validate_filename(filename),
         :ok <- validate_containment(filename) do
      write_prompt_unchecked(filename, content)
    end
  end

  @doc """
  Delete a prompt file from the catalog's prompts directory.

  The `name` is the prompt stem (e.g. `"assess"`), which is combined
  with `.md` to form the filename.

  Returns `:ok` if the file was deleted, `{:error, :not_found}` if it
  did not exist, or an error tuple.
  """
  @spec delete_prompt(String.t()) ::
          :ok
          | {:error, :not_found | :invalid_filename | :outside_catalog}
  def delete_prompt(name) when is_binary(name) do
    filename = name <> ".md"

    with :ok <- validate_filename(filename),
         :ok <- validate_containment(filename) do
      delete_prompt_unchecked(filename)
    end
  end

  # -------------------------------------------------------------------
  # Validation helpers
  # -------------------------------------------------------------------

  defp validate_filename(filename) do
    if String.contains?(filename, "/") or
         String.contains?(filename, "\\") or
         String.contains?(filename, "..") do
      {:error, :invalid_filename}
    else
      :ok
    end
  end

  defp validate_containment(filename) do
    root = Catalog.root()
    prompts_dir = Path.join(root, "prompts")
    absolute_path = Path.absname(Path.join(prompts_dir, filename))
    prompts_dir_absolute = Path.absname(prompts_dir)

    if String.starts_with?(absolute_path, prompts_dir_absolute <> "/") do
      :ok
    else
      {:error, :outside_catalog}
    end
  end

  # -------------------------------------------------------------------
  # Internal writer
  # -------------------------------------------------------------------

  defp write_prompt_unchecked(filename, content) do
    root = Catalog.root()
    prompts_dir = Path.join(root, "prompts")
    final_path = Path.join(prompts_dir, filename)
    tmp_path = "#{final_path}.tmp.#{:os.system_time(:millisecond)}"

    with :ok <- ensure_prompts_dir(prompts_dir),
         :ok <- File.write(tmp_path, content),
         :ok <- File.rename(tmp_path, final_path) do
      {:ok, final_path}
    else
      {:error, reason} ->
        File.rm(tmp_path)
        {:error, reason}
    end
  end

  defp delete_prompt_unchecked(filename) do
    root = Catalog.root()
    prompts_dir = Path.join(root, "prompts")
    target_path = Path.join(prompts_dir, filename)

    case File.rm(target_path) do
      :ok ->
        :ok

      {:error, :enoent} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp ensure_prompts_dir(prompts_dir) do
    case File.mkdir_p(prompts_dir) do
      :ok -> :ok
      {:error, :eexist} -> :ok
      {:error, _} = error -> error
    end
  end
end
