defmodule ForemanServer.Coordinator.Redact do
  @moduledoc """
  Persist-time redaction of coordinator conversation text.

  Pasted bug reports, model replies and thread briefs pass the run-log
  redactor (`WorkerLogPolicy.redact/2`) with the project's redaction list
  (`ProjectEnvironment.secrets/1`: every secret-store value, whatever its name, plus
  the env values whose names look secret) before they are written to an event, so a
  secret pasted into the conversation never lands in the event log.
  """

  alias ForemanServer.Overwatch.WorkerLogPolicy
  alias ForemanServer.ProjectEnvironment

  @doc """
  Redact `text` with the project's redaction list, or an explicit `:secrets` option (the
  list of one `ProjectEnvironment.secrets/1` call, for redacting several texts).
  """
  @spec text(String.t(), String.t(), keyword()) :: String.t()
  def text(project_id, text, opts \\ []) when is_binary(text) do
    secrets = Keyword.get_lazy(opts, :secrets, fn -> ProjectEnvironment.secrets(project_id) end)
    WorkerLogPolicy.redact(text, secrets)
  end
end
