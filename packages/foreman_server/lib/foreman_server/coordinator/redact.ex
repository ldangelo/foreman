defmodule ForemanServer.Coordinator.Redact do
  @moduledoc """
  Persist-time redaction of coordinator conversation text.

  Pasted bug reports, model replies and thread briefs pass the run-log
  redactor (`WorkerLogPolicy.redact/2`) with the project's configured secrets
  (`WorkerEnvironment.extract_secrets/1`) before they are written to an event,
  so a secret pasted into the conversation never lands in the event log.
  """

  alias ForemanServer.Overwatch.WorkerLogPolicy
  alias ForemanServer.WorkerEnvironment

  @doc "The project's secret values (for repeated redaction of several texts)."
  @spec secrets(String.t()) :: [String.t()]
  def secrets(project_id) when is_binary(project_id) do
    project_id |> WorkerEnvironment.build_env_map() |> WorkerEnvironment.extract_secrets()
  end

  @doc "Redact `text` with the project's secrets (or an explicit `:secrets` option)."
  @spec text(String.t(), String.t(), keyword()) :: String.t()
  def text(project_id, text, opts \\ []) when is_binary(text) do
    secrets = Keyword.get_lazy(opts, :secrets, fn -> secrets(project_id) end)
    WorkerLogPolicy.redact(text, secrets)
  end
end
