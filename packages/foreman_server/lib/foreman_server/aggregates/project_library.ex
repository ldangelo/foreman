defmodule ForemanServer.Aggregates.ProjectLibrary do
  @moduledoc """
  Metadata aggregate of a project's library, stream `project_library:<project_id>`.

  Commands (system-dispatched by `ForemanServer.Library`, never on the operator
  allowlist, because the bytes must reach disk before the command):

    * `project.library.add`     -> `ProjectLibraryAdded`
    * `project.library.replace` -> `ProjectLibraryReplaced`
    * `project.library.remove`  -> `ProjectLibraryRemoved`

  State is `%{entries: %{entry_id => %{name, kind, file_count, bytes,
  manifest_sha256}}}`. Guards, each with a distinct tuple:

    * `{:too_many_folders, max}` - adding a `folder` entry when `max` already exist
      (`file` and `produced` entries are exempt)
    * `{:duplicate_name, name}` - another entry already has the name
    * `{:duplicate_entry, entry_id}` - the entry id is already in use (add)
    * `{:not_found, entry_id}` - replace/remove of an unknown entry

  Replacing with an identical manifest digest is a no-op (`{:ok, nil}`).
  `apply_event/2` ends in a catch-all so an unknown event type never crashes replay.
  """

  @behaviour ForemanServer.Aggregate

  alias ForemanServer.Aggregate

  @author_kinds ~w(agent operator system)
  @kinds ~w(file folder produced)
  @max_folders 10
  @sha_pattern ~r/\A[0-9a-f]{64}\z/

  @doc "Stream id for a project's library."
  @spec stream_id(String.t()) :: String.t()
  def stream_id(project_id), do: "project_library:" <> project_id

  @doc "Maximum number of `folder` entries per project."
  @spec max_folders() :: pos_integer()
  def max_folders, do: @max_folders

  defmodule State do
    @moduledoc "Per-entry library state."
    @type entry :: %{
            name: String.t(),
            kind: String.t(),
            file_count: non_neg_integer(),
            bytes: non_neg_integer(),
            manifest_sha256: String.t()
          }
    @type t :: %__MODULE__{entries: %{String.t() => entry()}}
    defstruct entries: %{}
  end

  @impl true
  def initial_state, do: %State{}

  @impl true
  def apply_event(%State{} = state, event) do
    payload = Aggregate.event_payload(event)

    case Aggregate.event_type(event) do
      type when type in ["ProjectLibraryAdded", "ProjectLibraryReplaced"] ->
        put_entry(state, payload)

      "ProjectLibraryRemoved" ->
        %State{state | entries: Map.delete(state.entries, Aggregate.get(payload, :entry_id))}

      _ ->
        state
    end
  end

  defp put_entry(%State{} = state, payload) do
    entry_id = Aggregate.get(payload, :entry_id)

    if is_binary(entry_id) do
      entry = %{
        name: Aggregate.get(payload, :name),
        kind: Aggregate.get(payload, :kind),
        file_count: Aggregate.get(payload, :file_count) || 0,
        bytes: Aggregate.get(payload, :bytes) || 0,
        manifest_sha256: Aggregate.get(payload, :manifest_sha256)
      }

      %State{state | entries: Map.put(state.entries, entry_id, entry)}
    else
      state
    end
  end

  @impl true
  def handle_command(%State{} = state, %{type: "project.library.add", payload: payload}) do
    with {:ok, common} <- common(payload),
         :ok <- ensure_new(state, common),
         :ok <- ensure_folder_room(state, common.kind) do
      {:ok, event("ProjectLibraryAdded", common, payload, %{})}
    end
  end

  def handle_command(%State{} = state, %{type: "project.library.replace", payload: payload}) do
    with {:ok, common} <- common(payload),
         {:ok, previous} <- fetch_entry(state, common.entry_id),
         :ok <- ensure_name_free(state, common.entry_id, common.name) do
      if previous.manifest_sha256 == common.manifest_sha256 do
        {:ok, nil}
      else
        {:ok,
         event("ProjectLibraryReplaced", common, payload, %{
           previous_manifest_sha256: previous.manifest_sha256
         })}
      end
    end
  end

  def handle_command(%State{} = state, %{type: "project.library.remove", payload: payload}) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, entry_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :entry_id), :entry_id),
         {:ok, author_kind} <- validate_author_kind(Aggregate.get(payload, :author_kind)),
         :ok <- Aggregate.optional_binary(Aggregate.get(payload, :author_ref), :author_ref),
         {:ok, entry} <- fetch_entry(state, entry_id) do
      {:ok,
       %{
         stream_id: stream_id(project_id),
         event_type: "ProjectLibraryRemoved",
         payload: %{
           project_id: project_id,
           entry_id: entry_id,
           name: entry.name,
           author_kind: author_kind,
           author_ref: Aggregate.get(payload, :author_ref),
           at: now()
         }
       }}
    end
  end

  def handle_command(_state, _command), do: :unhandled

  defp common(payload) do
    with {:ok, project_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :project_id), :project_id),
         {:ok, entry_id} <-
           Aggregate.required_binary(Aggregate.get(payload, :entry_id), :entry_id),
         {:ok, name} <- Aggregate.required_binary(Aggregate.get(payload, :name), :name),
         {:ok, kind} <- validate_kind(Aggregate.get(payload, :kind)),
         {:ok, sha} <- validate_sha256(Aggregate.get(payload, :manifest_sha256)),
         {:ok, file_count} <- non_neg(Aggregate.get(payload, :file_count), :file_count),
         {:ok, bytes} <- non_neg(Aggregate.get(payload, :bytes), :bytes),
         {:ok, author_kind} <- validate_author_kind(Aggregate.get(payload, :author_kind)),
         :ok <- Aggregate.optional_binary(Aggregate.get(payload, :author_ref), :author_ref) do
      {:ok,
       %{
         project_id: project_id,
         entry_id: entry_id,
         name: name,
         kind: kind,
         manifest_sha256: sha,
         file_count: file_count,
         bytes: bytes,
         author_kind: author_kind
       }}
    end
  end

  defp event(type, common, payload, extra) do
    body =
      Map.merge(
        %{
          project_id: common.project_id,
          entry_id: common.entry_id,
          name: common.name,
          kind: common.kind,
          file_count: common.file_count,
          bytes: common.bytes,
          manifest_sha256: common.manifest_sha256,
          source: Aggregate.get(payload, :source),
          skipped_summary: Aggregate.get(payload, :skipped_summary) || %{},
          author_kind: common.author_kind,
          author_ref: Aggregate.get(payload, :author_ref),
          at: now()
        },
        extra
      )

    %{stream_id: stream_id(common.project_id), event_type: type, payload: body}
  end

  defp ensure_new(state, common) do
    cond do
      Map.has_key?(state.entries, common.entry_id) ->
        {:error, {:duplicate_entry, common.entry_id}}

      true ->
        ensure_name_free(state, common.entry_id, common.name)
    end
  end

  defp ensure_name_free(state, entry_id, name) do
    taken? =
      Enum.any?(state.entries, fn {id, entry} -> id != entry_id and entry.name == name end)

    if taken?, do: {:error, {:duplicate_name, name}}, else: :ok
  end

  defp ensure_folder_room(state, "folder") do
    folders = Enum.count(state.entries, fn {_id, entry} -> entry.kind == "folder" end)
    if folders >= @max_folders, do: {:error, {:too_many_folders, @max_folders}}, else: :ok
  end

  defp ensure_folder_room(_state, _kind), do: :ok

  defp fetch_entry(state, entry_id) do
    case Map.fetch(state.entries, entry_id) do
      {:ok, entry} -> {:ok, entry}
      :error -> {:error, {:not_found, entry_id}}
    end
  end

  defp validate_kind(kind) when kind in @kinds, do: {:ok, kind}
  defp validate_kind(kind) when is_binary(kind), do: {:error, {:invalid_kind, kind}}
  defp validate_kind(_), do: {:error, {:missing_or_invalid, :kind}}

  defp validate_sha256(value) when is_binary(value) do
    if Regex.match?(@sha_pattern, value),
      do: {:ok, value},
      else: {:error, {:invalid_sha256, value}}
  end

  defp validate_sha256(_), do: {:error, {:missing_or_invalid, :manifest_sha256}}

  defp non_neg(value, _key) when is_integer(value) and value >= 0, do: {:ok, value}
  defp non_neg(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp validate_author_kind(value) when value in @author_kinds, do: {:ok, value}

  defp validate_author_kind(value) when is_binary(value) and value != "",
    do: {:error, {:invalid_author_kind, value}}

  defp validate_author_kind(_), do: {:error, {:missing_or_invalid, :author_kind}}

  defp now, do: DateTime.to_iso8601(DateTime.utc_now())
end
