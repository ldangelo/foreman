defmodule ForemanServer.Jobsite.Logging do
  @moduledoc """
  Builds the `on_event` callback threaded through `Jobsite.AgentRunner.run/4`
  from a `:logging` option — `{:file, path}` (default
  `<repo>/.foreman/logs/<name-or-id>.log`) or `:stdout` — plus an optional
  user-supplied `:on_event` 1-arity function.

  Exceptions raised by the user function are caught and logged, never
  propagated: a broken forwarder must not kill a run.
  """

  require Logger

  @spec default_path(String.t(), String.t()) :: String.t()
  def default_path(repo_path, name_or_id) do
    Path.join([repo_path, ".foreman", "logs", "#{name_or_id}.log"])
  end

  @doc """
  Returns `{log_path, on_event_fun}`. `log_path` is `nil` for `:stdout`.
  `logging_spec` is `{:file, path} | :stdout | nil` (`nil` uses the default
  file path).
  """
  @spec build(term(), String.t(), String.t(), (map() -> any()) | nil) ::
          {String.t() | nil, (map() -> :ok)}
  def build(logging_spec, repo_path, name_or_id, user_on_event) do
    {target, path} = resolve_target(logging_spec, repo_path, name_or_id)

    fun = fn event ->
      write(target, event)
      invoke_user_fun(user_on_event, event)
      :ok
    end

    {path, fun}
  end

  defp resolve_target(:stdout, _repo_path, _name_or_id), do: {:stdout, nil}

  defp resolve_target({:file, path}, _repo_path, _name_or_id),
    do: {{:file, open_file!(path)}, path}

  defp resolve_target(nil, repo_path, name_or_id) do
    path = default_path(repo_path, name_or_id)
    {{:file, open_file!(path)}, path}
  end

  defp open_file!(path) do
    File.mkdir_p!(Path.dirname(path))
    {:ok, io} = File.open(path, [:append, :utf8])
    io
  end

  defp write(:stdout, event), do: IO.puts(format(event))
  defp write({:file, io}, event), do: IO.write(io, format(event) <> "\n")

  defp format(event) do
    Jason.encode!(%{
      type: Map.get(event, :type),
      timestamp: Map.get(event, :timestamp),
      text: extract_text(event)
    })
  end

  defp extract_text(%{payload: %{"text" => text}}), do: text
  defp extract_text(_event), do: nil

  defp invoke_user_fun(nil, _event), do: :ok

  defp invoke_user_fun(fun, event) when is_function(fun, 1) do
    fun.(event)
    :ok
  rescue
    error ->
      Logger.error(
        "Jobsite logging on_event callback raised: #{Exception.format(:error, error, __STACKTRACE__)}"
      )

      :ok
  end
end
