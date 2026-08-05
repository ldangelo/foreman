defmodule ForemanServer.WorkflowTemplate.Installer do
  @moduledoc """
  Installs workflow templates into a Foreman workflows directory.
  """

  @template_names ~w(discover assess plan implement verify release)
  @template_files Enum.map(@template_names, &"#{&1}.yaml")
  @default_retry_attempts 3
  @default_retry_delay_ms 250

  @type option ::
          {:home_dir, Path.t()}
          | {:target_dir, Path.t()}
          | {:source_dir, Path.t()}
          | {:remote_url, String.t()}
          | {:retry_attempts, pos_integer()}
          | {:retry_delay_ms, non_neg_integer()}

  @spec install([option()]) :: {:ok, [Path.t()]} | {:error, term()}
  def install(opts) when is_list(opts) do
    source_dir = Keyword.get(opts, :source_dir, bundled_source_dir())

    if bundled_templates_available?(source_dir) do
      copy_bundled_templates(source_dir, target_dir(opts))
    else
      fetch_remote(opts)
    end
  end

  @spec fetch_remote([option()]) :: {:ok, [Path.t()]} | {:error, term()}
  def fetch_remote(opts) when is_list(opts) do
    with {:ok, remote_url} <- remote_url(opts),
         {:ok, downloads} <- download_templates(remote_url, opts),
         {:ok, installed_paths} <- write_downloads(target_dir(opts), downloads) do
      {:ok, installed_paths}
    end
  end

  defp bundled_source_dir do
    Application.app_dir(:foreman_server, "priv/defaults/workflows")
  end

  defp bundled_templates_available?(source_dir) do
    File.dir?(source_dir) and
      Enum.all?(@template_files, fn filename ->
        File.regular?(Path.join(source_dir, filename))
      end)
  end

  defp copy_bundled_templates(source_dir, destination_dir) do
    with :ok <- File.mkdir_p(destination_dir),
         {:ok, manifest_paths} <- copy_manifests(source_dir, destination_dir),
         {:ok, prompt_paths} <- copy_prompts(source_dir, destination_dir) do
      {:ok, manifest_paths ++ prompt_paths}
    end
  end


  defp copy_manifests(source_dir, destination_dir) do
    @template_files
    |> Enum.reduce_while({:ok, []}, fn filename, {:ok, paths} ->
      source_path = Path.join(source_dir, filename)
      destination_path = Path.join(destination_dir, filename)

      case File.cp(source_path, destination_path) do
        :ok -> {:cont, {:ok, [destination_path | paths]}}
        {:error, reason} -> {:halt, {:error, {:copy_failed, source_path, reason}}}
      end
    end)
    |> reverse_ok_paths()
  end

  defp copy_prompts(source_dir, destination_dir) do
    source_prompts = Path.join(source_dir, "prompts")
    destination_prompts = Path.join(destination_dir, "prompts")

    cond do
      not File.dir?(source_prompts) ->
        {:ok, []}

      :ok != File.mkdir_p(destination_prompts) ->
        {:error, {:mkdir_failed, destination_prompts}}

      true ->
        source_prompts
        |> File.ls!()
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn filename, {:ok, paths} ->
          source_path = Path.join(source_prompts, filename)
          destination_path = Path.join(destination_prompts, filename)

          case File.cp(source_path, destination_path) do
            :ok -> {:cont, {:ok, [destination_path | paths]}}
            {:error, reason} -> {:halt, {:error, {:copy_failed, source_path, reason}}}
          end
        end)
        |> reverse_ok_paths()
    end
  end

  defp remote_url(opts) do
    case Keyword.get(
           opts,
           :remote_url,
           Application.get_env(:foreman_server, :workflow_remote_url)
         ) do
      nil -> {:error, :missing_remote_url}
      url when is_binary(url) and url != "" -> {:ok, url}
      url -> {:error, {:invalid_remote_url, url}}
    end
  end

  defp download_templates(remote_url, opts) do
    attempts = Keyword.get(opts, :retry_attempts, @default_retry_attempts)
    delay_ms = Keyword.get(opts, :retry_delay_ms, @default_retry_delay_ms)

    @template_files
    |> Enum.reduce_while({:ok, []}, fn filename, {:ok, downloads} ->
      case download_template(
             remote_template_url(remote_url, filename),
             filename,
             attempts,
             delay_ms
           ) do
        {:ok, body} -> {:cont, {:ok, [{filename, body} | downloads]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> reverse_ok_downloads()
  end

  defp download_template(url, filename, attempts, delay_ms) when attempts > 0 do
    case curl_get(url) do
      {:ok, body} ->
        {:ok, body}

      {:error, _reason} when attempts > 1 ->
        Process.sleep(delay_ms)
        download_template(url, filename, attempts - 1, delay_ms)

      {:error, reason} ->
        {:error, {:download_failed, filename, reason}}
    end
  end

  defp curl_get(url) do
    case System.find_executable("curl") do
      nil ->
        {:error, :curl_not_found}

      curl ->
        args = ["--fail", "--silent", "--show-error", "--location", url]

        case System.cmd(curl, args, stderr_to_stdout: true) do
          {body, 0} ->
            {:ok, body}

          {error_output, status} ->
            {:error, {:curl_failed, status, String.trim(error_output)}}
        end
    end
  end

  defp write_downloads(destination_dir, downloads) do
    with :ok <- File.mkdir_p(destination_dir) do
      downloads
      |> Enum.reduce_while({:ok, []}, fn {filename, body}, {:ok, paths} ->
        destination_path = Path.join(destination_dir, filename)

        case File.write(destination_path, body) do
          :ok -> {:cont, {:ok, [destination_path | paths]}}
          {:error, reason} -> {:halt, {:error, {:write_failed, destination_path, reason}}}
        end
      end)
      |> reverse_ok_paths()
    end
  end

  defp target_dir(opts) do
    case Keyword.get(opts, :target_dir) do
      nil ->
        Path.join([Keyword.get(opts, :home_dir, System.user_home!()), ".foreman", "workflows"])

      path ->
        path
    end
  end

  defp remote_template_url(base_url, filename) do
    cond do
      String.contains?(base_url, "%{file}") ->
        String.replace(base_url, "%{file}", filename)

      String.contains?(base_url, "{file}") ->
        String.replace(base_url, "{file}", filename)

      true ->
        base_url
        |> ensure_trailing_slash()
        |> URI.merge(filename)
        |> to_string()
    end
  end

  defp ensure_trailing_slash(url) do
    if String.ends_with?(url, "/") do
      url
    else
      url <> "/"
    end
  end

  defp reverse_ok_paths({:ok, paths}), do: {:ok, Enum.reverse(paths)}
  defp reverse_ok_paths({:error, _reason} = error), do: error

  defp reverse_ok_downloads({:ok, downloads}), do: {:ok, Enum.reverse(downloads)}
  defp reverse_ok_downloads({:error, _reason} = error), do: error
end

defmodule WorkflowTemplate.Installer do
  @moduledoc false

  defdelegate install(opts), to: ForemanServer.WorkflowTemplate.Installer
  defdelegate fetch_remote(opts), to: ForemanServer.WorkflowTemplate.Installer
end
