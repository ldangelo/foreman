defmodule ForemanServer.Workflow.Loader do
  @moduledoc "Hot workflow loader. TRD-2026-4212be7e / HLW-T002 / TRD-092."

  require Logger

  @workflow_dir "priv/workflows"

  def load_all do
    case File.ls(@workflow_dir) do
      {:ok, files} ->
        files
        |> Enum.map(&load_file/1)
        |> Enum.reject(&is_nil/1)

      {:error, reason} ->
        Logger.warning("Cannot list #{@workflow_dir}: #{inspect(reason)}")
        []
    end
  end

  def load_file(filename) do
    path = Path.join(@workflow_dir, filename)

    case Path.extname(filename) do
      ext when ext in [".yaml", ".yml"] -> load_yaml(path)
      ".ex" -> load_ex(path)
      _ -> nil
    end
  end

  defp load_yaml(path) do
    with {:ok, content} <- File.read(path) do
      {:ok, %{path: path, format: :yaml, content: content}}
    end
  end

  defp load_ex(path) do
    with {:ok, content} <- File.read(path) do
      {:ok, %{path: path, format: :elixir_dsl, content: content}}
    end
  end
end
