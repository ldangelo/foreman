defmodule ForemanServer.Aggregates.ProjectSecret do
  @moduledoc """
  Per-project secret ledger (stream `"project_secret:" <> project_id`).

  Commands `project.secret.set` / `project.secret.unset` are system-only
  (`ForemanServer.ProjectSecrets` dispatches them after the value reached
  `ForemanServer.SecretStore`; they are NOT in the operator allowlist, so a
  value can never ride a command envelope). Payloads carry `project_id`,
  `name`, optional `author_ref` and no value. The aggregate assigns the
  monotonically increasing per-name `version`.
  """
  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.EventCodec
  alias ForemanServer.Events.{ProjectSecretSet, ProjectSecretUnset}
  alias ForemanServer.SecretStore

  @doc "Stream id for a project's secret ledger."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(project_id), do: "project_secret:" <> project_id

  defmodule State do
    @moduledoc "Latest version per secret name and which names are currently set."
    @type t :: %__MODULE__{versions: %{String.t() => pos_integer()}, active: MapSet.t(String.t())}
    defstruct versions: %{}, active: MapSet.new()
  end

  @impl true
  def initial_state, do: %State{}

  @impl true
  def apply_event(%State{} = state, %ProjectSecretSet{name: name, version: version}),
    do: set(state, name, version)

  def apply_event(%State{} = state, %ProjectSecretUnset{name: name, version: version}),
    do: unset(state, name, version)

  def apply_event(%State{} = state, event) do
    case Aggregate.event_type(event) do
      "ProjectSecretSet" ->
        %ProjectSecretSet{name: name, version: version} = decode("ProjectSecretSet", event)
        set(state, name, version)

      "ProjectSecretUnset" ->
        %ProjectSecretUnset{name: name, version: version} = decode("ProjectSecretUnset", event)
        unset(state, name, version)

      _ ->
        state
    end
  end

  defp decode(type, event),
    do: EventCodec.decode!(type, event |> Aggregate.event_payload() |> Map.delete("event_type"))

  defp set(state, name, version),
    do: %State{
      versions: Map.put(state.versions, name, version),
      active: MapSet.put(state.active, name)
    }

  defp unset(state, name, version),
    do: %State{
      versions: Map.put(state.versions, name, version),
      active: MapSet.delete(state.active, name)
    }

  @impl true
  def handle_command(state, %{type: "project.secret.set", payload: payload}) do
    with {:ok, project_id, name, author_ref} <- common(payload) do
      version = Map.get(state.versions, name, 0) + 1

      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "ProjectSecretSet",
         payload: %ProjectSecretSet{
           project_id: project_id,
           name: name,
           version: version,
           at: now(),
           author_ref: author_ref
         }
       }}
    end
  end

  def handle_command(state, %{type: "project.secret.unset", payload: payload}) do
    with {:ok, project_id, name, author_ref} <- common(payload),
         :ok <- require_active(state, name) do
      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "ProjectSecretUnset",
         payload: %ProjectSecretUnset{
           project_id: project_id,
           name: name,
           version: Map.fetch!(state.versions, name) + 1,
           at: now(),
           author_ref: author_ref
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp common(payload) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, name} <- validate_name(Aggregate.get(payload, :name)),
         :ok <- Aggregate.optional_binary(Aggregate.get(payload, :author_ref), :author_ref) do
      {:ok, project_id, name, Aggregate.get(payload, :author_ref)}
    end
  end

  defp validate_name(name) do
    if SecretStore.valid_name?(name),
      do: {:ok, name},
      else: {:error, {:invalid_secret_name, name}}
  end

  defp require_active(state, name) do
    if MapSet.member?(state.active, name),
      do: :ok,
      else: {:error, {:not_found, :project_secret, name}}
  end

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
