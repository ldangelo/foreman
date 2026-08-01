defmodule ForemanServer.WorkflowTemplate.Installer do
  @moduledoc "Installs bundled workflow templates into the operator foreman home."

  @standard_workflows ~w(bug default epic feature smoke task)
  @default_timeout 5_000

  @spec install(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def install(opts) when is_list(opts) do
    target_dir = target_dir(opts)

    with :ok <- File.mkdir_p(target_dir),
         {:ok, templates} <- bundled_templates(opts),
         {:ok, all_templates} <- ensure_missing_templates(templates, opts),
         :ok <- write_templates(target_dir, all_templates) do
      {:ok, Enum.sort(Map.keys(all_templates))}
    end
  end

  @spec fetch_remote(keyword()) :: {:ok, [String.t()]} | {:error, term()}
  def fetch_remote(opts) when is_list(opts) do
    target_dir = target_dir(opts)
    names = Keyword.get(opts, :names, @standard_workflows)

    with :ok <- File.mkdir_p(target_dir),
         {:ok, templates} <- fetch_remote_templates(names, opts),
         :ok <- write_templates(target_dir, templates) do
      {:ok, Enum.sort(Map.keys(templates))}
    end
  end

  defp bundled_templates(opts) do
    bundled_dir = Keyword.get(opts, :bundled_dir, bundled_dir())

    if File.dir?(bundled_dir) do
      templates =
        @standard_workflows
        |> Enum.reduce(%{}, fn name, acc ->
          path = Path.join(bundled_dir, "#{name}.yaml")

          case File.read(path) do
            {:ok, content} -> Map.put(acc, name, content)
            {:error, _reason} -> acc
          end
        end)

      {:ok, templates}
    else
      {:ok, %{}}
    end
  end

  defp ensure_missing_templates(templates, opts) do
    missing = @standard_workflows -- Map.keys(templates)

    case missing do
      [] ->
        {:ok, templates}

      _ ->
        with {:ok, remote_templates} <- fetch_remote_templates(missing, opts) do
          {:ok, Map.merge(templates, remote_templates)}
        end
    end
  end

  defp fetch_remote_templates([], _opts), do: {:ok, %{}}

  defp fetch_remote_templates(names, opts) do
    base_url =
      Keyword.get(opts, :url) ||
        Application.get_env(:foreman_server, :workflow_template_url)

    case base_url do
      nil ->
        {:error, :workflow_template_url_not_configured}

      url when is_binary(url) ->
        http_client = Keyword.get(opts, :http_client, &default_http_get/1)

        Enum.reduce_while(names, {:ok, %{}}, fn name, {:ok, acc} ->
          template_url = remote_template_url(url, name)

          case http_client.(template_url) do
            {:ok, content} when is_binary(content) ->
              {:cont, {:ok, Map.put(acc, name, content)}}

            {:error, reason} ->
              {:halt, {:error, {:remote_fetch_failed, name, reason}}}
          end
        end)
    end
  end

  defp write_templates(target_dir, templates) do
    Enum.reduce_while(templates, :ok, fn {name, content}, :ok ->
      path = Path.join(target_dir, "#{name}.yaml")

      case File.write(path, content) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp bundled_dir do
    Application.app_dir(:foreman_server, "priv/defaults/workflows")
  end

  defp target_dir(opts) do
    home_dir = Keyword.get(opts, :home_dir, System.get_env("HOME") || System.user_home!())
    Keyword.get(opts, :target_dir, Path.join([home_dir, ".foreman", "workflows"]))
  end

  defp remote_template_url(base_url, name) do
    base_url
    |> String.trim_trailing("/")
    |> Kernel.<>("/#{name}.yaml")
  end

  defp default_http_get(url) do
    case :httpc.request(:get, {String.to_charlist(url), []}, [timeout: @default_timeout],
           body_format: :binary
         ) do
      {:ok, {{_version, 200, _reason}, _headers, body}} ->
        {:ok, body}

      {:ok, {{_version, status, _reason}, _headers, body}} ->
        {:error, {:http_status, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
