defmodule ForemanServerWeb.WorkflowInstallController do
  @moduledoc """
  Workflow installation endpoint.

  `POST /api/admin/workflows/install` accepts a JSON body with optional
  keys `:source_dir`, `:target_dir`, `:remote_url`, `:retry_attempts`,
  and `:retry_delay_ms`, and forwards them to
  `ForemanServer.WorkflowTemplate.Installer.install/1`.

  The installer either copies bundled templates from the application
  `priv/defaults/workflows` directory (default) or fetches templates
  from a remote URL when one is supplied. The body is **not** parsed
  as a manifest; the installer writes its own set of templates to
  the resolved target directory.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.WorkflowTemplate.Installer

  def install(conn, params) do
    opts = build_opts(params)

    case Installer.install(opts) do
      {:ok, paths} ->
        conn
        |> put_status(:created)
        |> json(%{status: "installed", paths: paths})

      {:error, reason} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: inspect(reason)})
    end
  end

  defp build_opts(params) when is_map(params) do
    []
    |> put_opt(params, :target_dir)
    |> put_opt(params, :source_dir)
    |> put_opt(params, :remote_url)
    |> put_int_opt(params, :retry_attempts)
    |> put_int_opt(params, :retry_delay_ms)
  end

  defp build_opts(_), do: []

  defp put_opt(opts, params, key) do
    case get_value(params, key) do
      value when is_binary(value) and value != "" -> Keyword.put(opts, key, value)
      _ -> opts
    end
  end

  defp put_int_opt(opts, params, key) do
    case get_value(params, key) do
      value when is_integer(value) and value > 0 -> Keyword.put(opts, key, value)
      _ -> opts
    end
  end

  defp get_value(map, key) when is_atom(key) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end
end
