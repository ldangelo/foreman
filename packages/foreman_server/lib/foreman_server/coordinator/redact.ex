defmodule ForemanServer.Coordinator.Redact do
  @moduledoc """
  Persist-time redaction of text about a project: the ONE path every such text takes.

  Pasted bug reports, model replies and thread briefs (the coordinator conversation), a
  coordinator turn's recorded actions and failure messages, question and approval summaries,
  thread transcripts and PR-fix prompts pass the run-log redactor (`WorkerLogPolicy.redact/2`)
  with the project's redaction list (`ProjectEnvironment.secrets/1`: every secret-store value
  of `ProjectEnvironment.min_stored_secret_chars/0` or more characters, whatever its name, plus
  the env values whose names look secret) before they are written to an event or shown, so a
  secret pasted into the conversation never lands in the event log.

  The list costs a projection read and a secret-store file read. It is resolved ONCE per
  document, batch or command (`secrets/1`, or `redactor/1` for a document of many texts) and
  handed to `text/3` and `data/3` (`secrets:`) for every text of it; never once per entry of a
  loop.
  """

  require Logger

  alias ForemanServer.Overwatch.WorkerLogPolicy
  alias ForemanServer.ProjectEnvironment

  @doc """
  The project's redaction list, for a persist or read path that must not raise.

  A `nil` or empty project id (a global or legacy run has no project) has no list, and neither
  has a project whose environment `ProjectEnvironment.resolve/2` refuses: both leave the
  built-in patterns of `WorkerLogPolicy.redact/2` as the only redaction. The refusal is logged
  with the project id and the error code, never a name or a value. An unreadable secret store
  is logged by `ProjectEnvironment` the same way and costs only the store's values.

  `text/3` and `data/3` without `:secrets` keep `ProjectEnvironment.secrets/1`'s stricter
  contract: they raise for such an environment, so a conversation text is never persisted under
  a partial list.
  """
  @spec secrets(String.t() | nil) :: [String.t()]
  def secrets(project_id) when project_id in [nil, ""], do: []

  def secrets(project_id) when is_binary(project_id) do
    case ProjectEnvironment.fetch_secrets(project_id) do
      {:ok, secrets} ->
        secrets

      {:error, {:reserved_project_env_keys, _names}} ->
        Logger.warning(
          "Redact: project #{inspect(project_id)} environment is invalid " <>
            "(reserved_project_env_keys); redacting with the built-in patterns only"
        )

        []
    end
  end

  @doc """
  A one-argument redaction function over the project's list, resolved ONCE here with
  `secrets/1` (never raises): for a caller that redacts many texts of one document, such as a
  transcript page or a prompt, and must not read the list per text.
  """
  @spec redactor(String.t() | nil) :: (String.t() -> String.t())
  def redactor(project_id) do
    secrets = secrets(project_id)
    &text(project_id, &1, secrets: secrets)
  end

  @doc """
  Redact `text` with the project's redaction list, or an explicit `:secrets` option (the list
  of one `secrets/1` call, for redacting several texts; `project_id` is then not consulted).

  Without `:secrets` the list is resolved here, per call. A `nil` or empty `project_id` (a
  global or legacy run) has none: the patterns alone redact. A project whose environment
  `ProjectEnvironment.resolve/2` refuses RAISES `ArgumentError` (`ProjectEnvironment.secrets/1`):
  the coordinator conversation is never persisted under a partial list. A persist or read path
  that must not raise resolves with `secrets/1` (or `redactor/1`) and passes `:secrets`.
  """
  @spec text(String.t() | nil, String.t(), keyword()) :: String.t()
  def text(project_id, text, opts \\ []) when is_binary(text) do
    WorkerLogPolicy.redact(text, secrets_option(project_id, opts))
  end

  @doc """
  `text/3` over JSON-shaped data: every string inside the maps and lists of `data` is redacted
  (the list is resolved as `text/3` does, including for `nil` and for a refused environment);
  keys, structs and every other value are returned as they are.
  """
  @spec data(String.t() | nil, term(), keyword()) :: term()
  def data(project_id, data, opts \\ []), do: scrub(data, secrets_option(project_id, opts))

  defp secrets_option(project_id, opts),
    do: Keyword.get_lazy(opts, :secrets, fn -> project_secrets(project_id) end)

  defp project_secrets(project_id) when project_id in [nil, ""], do: []

  defp project_secrets(project_id) when is_binary(project_id),
    do: ProjectEnvironment.secrets(project_id)

  defp scrub(text, secrets) when is_binary(text), do: WorkerLogPolicy.redact(text, secrets)
  defp scrub(%_{} = struct, _secrets), do: struct

  defp scrub(map, secrets) when is_map(map),
    do: Map.new(map, fn {key, value} -> {key, scrub(value, secrets)} end)

  defp scrub(list, secrets) when is_list(list), do: Enum.map(list, &scrub(&1, secrets))
  defp scrub(other, _secrets), do: other
end
