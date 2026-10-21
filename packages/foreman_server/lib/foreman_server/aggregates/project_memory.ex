defmodule ForemanServer.Aggregates.ProjectMemory do
  @moduledoc """
  Audit aggregate of a project's memory, stream `project_memory:<project_id>`.

  Commands (system-dispatched by `ForemanServer.ProjectMemory`, never on the
  operator allowlist, because content must reach disk before the command):

    * `project.memory.write`  -> `ProjectMemoryWritten`
    * `project.memory.forget` -> `ProjectMemoryForgotten`

  State is `%{entries: %{name => %{sha256, bytes, description, version}}}`.
  Re-asserting an identical sha256 is a no-op (`{:ok, nil}`); forgetting an
  unknown name is `{:error, {:not_found, name}}`. `apply_event/2` ends in a
  catch-all so an unknown event type on the stream never crashes replay.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate
  alias ForemanServer.Events.{ProjectMemoryForgotten, ProjectMemoryWritten}

  @author_kinds ~w(agent operator system)

  @doc "Stream id for a project's memory."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(project_id), do: "project_memory:" <> project_id

  defmodule State do
    @moduledoc "Per-topic audit state."
    @type entry :: %{
            sha256: String.t(),
            bytes: non_neg_integer(),
            description: String.t() | nil,
            version: pos_integer()
          }
    @type t :: %__MODULE__{entries: %{String.t() => entry()}}
    defstruct entries: %{}
  end

  @impl true
  def initial_state, do: %State{}

  @impl true
  def apply_event(%State{} = state, %ProjectMemoryWritten{} = e),
    do: put_entry(state, e.name, e.sha256, e.bytes, e.description, e.version)

  def apply_event(%State{} = state, %ProjectMemoryForgotten{name: name}),
    do: %State{state | entries: Map.delete(state.entries, name)}

  def apply_event(%State{} = state, event) do
    case Aggregate.event_type(event) do
      "ProjectMemoryWritten" ->
        payload = Aggregate.event_payload(event)

        put_entry(
          state,
          Aggregate.get(payload, :name),
          Aggregate.get(payload, :sha256),
          Aggregate.get(payload, :bytes),
          Aggregate.get(payload, :description),
          Aggregate.get(payload, :version) || 1
        )

      "ProjectMemoryForgotten" ->
        name = event |> Aggregate.event_payload() |> Aggregate.get(:name)
        %State{state | entries: Map.delete(state.entries, name)}

      _ ->
        state
    end
  end

  defp put_entry(%State{} = state, name, sha256, bytes, description, version)
       when is_binary(name) and is_binary(sha256) do
    entry = %{sha256: sha256, bytes: bytes, description: description, version: version}
    %State{state | entries: Map.put(state.entries, name, entry)}
  end

  defp put_entry(state, _name, _sha, _bytes, _description, _version), do: state

  @impl true
  def handle_command(%State{} = state, %{type: "project.memory.write", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, name} <- Aggregate.required_binary(Aggregate.get(payload, :name), :name),
         {:ok, sha256} <- validate_sha256(Aggregate.get(payload, :sha256)),
         {:ok, bytes} <- validate_bytes(Aggregate.get(payload, :bytes)),
         {:ok, author_kind} <- validate_author_kind(Aggregate.get(payload, :author_kind)),
         :ok <- optional_binary(payload, :description),
         :ok <- optional_binary(payload, :author_ref),
         {:ok, redactions} <- validate_redactions(Aggregate.get(payload, :redactions)) do
      case Map.get(state.entries, name) do
        %{sha256: ^sha256} ->
          {:ok, nil}

        previous ->
          {:ok,
           %{
             stream_id: stream_id(project_id),
             event_type: "ProjectMemoryWritten",
             payload: %{
               project_id: project_id,
               name: name,
               description: Aggregate.get(payload, :description),
               sha256: sha256,
               bytes: bytes,
               redactions: redactions,
               version: if(previous, do: previous.version + 1, else: 1),
               author_kind: author_kind,
               author_ref: Aggregate.get(payload, :author_ref),
               at: now()
             }
           }}
      end
    end
  end

  def handle_command(%State{} = state, %{type: "project.memory.forget", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, name} <- Aggregate.required_binary(Aggregate.get(payload, :name), :name),
         {:ok, author_kind} <- validate_author_kind(Aggregate.get(payload, :author_kind)),
         :ok <- optional_binary(payload, :author_ref),
         :ok <- ensure_known(state, name) do
      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "ProjectMemoryForgotten",
         payload: %{
           project_id: project_id,
           name: name,
           author_kind: author_kind,
           author_ref: Aggregate.get(payload, :author_ref),
           at: now()
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp ensure_known(%State{entries: entries}, name) do
    if Map.has_key?(entries, name), do: :ok, else: {:error, {:not_found, name}}
  end

  defp validate_sha256(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, value),
      do: {:ok, value},
      else: {:error, {:invalid_sha256, value}}
  end

  defp validate_sha256(_), do: {:error, {:missing_or_invalid, :sha256}}

  defp validate_bytes(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp validate_bytes(_), do: {:error, {:missing_or_invalid, :bytes}}

  defp validate_redactions(nil), do: {:ok, 0}
  defp validate_redactions(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp validate_redactions(_), do: {:error, {:missing_or_invalid, :redactions}}

  defp validate_author_kind(value) when value in @author_kinds, do: {:ok, value}

  defp validate_author_kind(value) when is_binary(value) and value != "",
    do: {:error, {:invalid_author_kind, value}}

  defp validate_author_kind(_), do: {:error, {:missing_or_invalid, :author_kind}}

  defp optional_binary(payload, key),
    do: Aggregate.optional_binary(Aggregate.get(payload, key), key)

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
