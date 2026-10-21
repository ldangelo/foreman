defmodule ForemanServer.ProjectMemory do
  @moduledoc """
  Single entry point for per-project memory, used by MCP tools, HTTP and CLI.

  Content lives on disk under `<project path>/.foreman/memory/` (see
  `ForemanServer.ProjectMemory.Store`); the event log keeps an audit index of
  metadata only (`ProjectMemoryWritten` / `ProjectMemoryForgotten` on stream
  `project_memory:<project_id>`).

  `write/3` and `forget/3` run under a per-project `:global` lock so two
  callers cannot interleave a file write with an index regeneration. Order:
  resolve project -> (archived projects rejected) -> `Store` mutation
  (redacted, capped) -> dispatch the audit command with a deterministic
  `command_id`. If the dispatch fails after the file landed, the previous
  bytes are restored and `{:error, %Error{code: :audit_failed}}` is returned:
  disk and audit index never diverge silently.

  `verify/1` compares on-disk topic hashes with the audit index; `sync/2`
  records every drift as an authored write/forget (content re-read from disk
  and re-redacted) so hand edits keep the trail honest.

  Authors are `%{kind: :agent | :operator | :system, ref: String.t() | nil}`.
  """

  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.ProjectMemory.{Drift, Error, Store, SyncReport, Topic}
  alias ForemanServer.Telemetry
  alias ForemanServer.WorkerEnvironment

  require Logger

  @type author :: %{kind: :agent | :operator | :system, ref: String.t() | nil}
  @type attrs :: %{name: String.t(), description: String.t() | nil, content: String.t()}

  @doc "Write (create or replace) one topic."
  @spec write(String.t(), attrs(), author()) :: {:ok, Topic.t()} | {:error, Error.t()}
  def write(project_id, %{name: name, content: content} = attrs, %{kind: kind} = author)
      when is_binary(project_id) and is_binary(name) and is_binary(content) and
             kind in [:agent, :operator, :system] do
    result =
      with {:ok, path} <- writable_path(project_id) do
        locked(project_id, fn -> do_write(project_id, path, attrs, author) end)
      end

    Telemetry.project_memory_op(:write, Atom.to_string(kind), outcome(result))
    result
  end

  @doc "Forget (delete) one topic."
  @spec forget(String.t(), String.t(), author()) :: {:ok, Topic.t()} | {:error, Error.t()}
  def forget(project_id, name, %{kind: kind} = author)
      when is_binary(project_id) and is_binary(name) and kind in [:agent, :operator, :system] do
    result =
      with {:ok, path} <- writable_path(project_id) do
        locked(project_id, fn -> do_forget(project_id, path, name, author) end)
      end

    Telemetry.project_memory_op(:forget, Atom.to_string(kind), outcome(result))
    result
  end

  @doc "Every topic, sorted by name: disk metadata merged with the audit index."
  @spec list(String.t()) :: {:ok, [Topic.t()]} | {:error, Error.t()}
  def list(project_id) when is_binary(project_id) do
    with {:ok, path} <- readable_path(project_id),
         {:ok, disk} <- Store.list(path) do
      audited = Map.new(ProjectionStore.project_memory(project_id), &{&1.name, &1})
      on_disk = MapSet.new(disk, & &1.name)

      present = Enum.map(disk, &Topic.build(&1, Map.get(audited, &1.name), true))

      missing =
        audited
        |> Enum.reject(fn {name, _} -> MapSet.member?(on_disk, name) end)
        |> Enum.map(fn {_name, audit} -> Topic.from_audit(audit) end)

      {:ok, Enum.sort_by(present ++ missing, & &1.name)}
    end
  end

  @doc "Read one topic's metadata and (already redacted) content."
  @spec read(String.t(), String.t()) :: {:ok, Topic.t(), String.t()} | {:error, Error.t()}
  def read(project_id, name) when is_binary(project_id) and is_binary(name) do
    with {:ok, path} <- readable_path(project_id),
         {:ok, entry, content} <- Store.read(path, name) do
      audit = Enum.find(ProjectionStore.project_memory(project_id), &(&1.name == name))
      {:ok, Topic.build(entry, audit, true), content}
    end
  end

  @doc "The generated MEMORY.md text E3 injects (empty string when there is no memory)."
  @spec index(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def index(project_id) when is_binary(project_id) do
    with {:ok, path} <- readable_path(project_id), do: Store.index(path)
  end

  @doc "Compare on-disk topic files against the audit index."
  @spec verify(String.t()) :: {:ok, Drift.t()} | {:error, Error.t()}
  def verify(project_id) when is_binary(project_id) do
    with {:ok, path} <- readable_path(project_id),
         {:ok, disk} <- Store.list(path) do
      {:ok, drift(disk, ProjectionStore.project_memory(project_id))}
    end
  end

  @doc "Record every drift as an authored write/forget; idempotent."
  @spec sync(String.t(), author()) :: {:ok, SyncReport.t()} | {:error, Error.t()}
  def sync(project_id, %{kind: kind} = author)
      when is_binary(project_id) and kind in [:agent, :operator, :system] do
    with {:ok, path} <- writable_path(project_id) do
      locked(project_id, fn -> do_sync(project_id, path, author) end)
    end
  end

  # --- write / forget --------------------------------------------------

  defp do_write(project_id, path, attrs, author) do
    with {:ok, previous} <- previous_bytes(path, attrs.name),
         {:ok, entry} <- Store.write(path, secrets_for(project_id), attrs) do
      command = write_command(project_id, entry, author)

      case dispatch(command) do
        :ok ->
          {:ok, Topic.build(entry, nil, true)}

        {:error, reason} ->
          rollback(path, attrs.name, previous)
          {:error, audit_failed(reason)}
      end
    end
  end

  defp do_forget(project_id, path, name, author) do
    with {:ok, previous} <- previous_bytes(path, name),
         {:ok, entry} <- Store.forget(path, name) do
      case dispatch(forget_command(project_id, name, entry, author)) do
        :ok ->
          {:ok, Topic.build(entry, nil, false)}

        {:error, reason} ->
          rollback(path, name, previous)
          {:error, audit_failed(reason)}
      end
    end
  end

  defp previous_bytes(path, name) do
    case Store.read_raw(path, name) do
      {:ok, raw} -> {:ok, raw}
      {:error, %Error{code: :not_found}} -> {:ok, nil}
      {:error, %Error{} = error} -> {:error, error}
    end
  end

  defp rollback(path, name, previous) do
    case Store.restore(path, name, previous) do
      :ok ->
        :ok

      {:error, %Error{} = error} ->
        Logger.error("project memory rollback of #{name} failed: #{error.message}")
    end
  end

  defp write_command(project_id, entry, author) do
    %{
      type: "project.memory.write",
      command_id: command_id(project_id, entry.name, entry.sha256),
      aggregate_id: "project_memory:" <> project_id,
      payload: %{
        project_id: project_id,
        name: entry.name,
        description: blank_to_nil(entry.description),
        sha256: entry.sha256,
        bytes: entry.bytes,
        redactions: entry.redactions,
        author_kind: Atom.to_string(author.kind),
        author_ref: Map.get(author, :ref)
      }
    }
  end

  # The event id is derived from `command_id`, so a purely content-derived id
  # would make a later A -> B -> A rewrite (or a re-created, re-forgotten
  # topic) a silent replay of the first A event. Every operation therefore
  # gets a fresh suffix; re-asserting identical content is already a no-op in
  # the aggregate (same sha256), which is the idempotency that matters here.
  defp command_id(project_id, name, discriminator) do
    "project_memory:" <>
      project_id <>
      ":" <>
      name <>
      ":" <>
      discriminator <>
      ":" <>
      Integer.to_string(System.os_time(:microsecond)) <>
      "-" <>
      Integer.to_string(System.unique_integer([:positive]))
  end

  defp forget_command(project_id, name, entry, author) do
    %{
      type: "project.memory.forget",
      command_id: command_id(project_id, name, "forget:" <> entry.sha256),
      aggregate_id: "project_memory:" <> project_id,
      payload: %{
        project_id: project_id,
        name: name,
        author_kind: Atom.to_string(author.kind),
        author_ref: Map.get(author, :ref)
      }
    }
  end

  defp dispatch(command) do
    case CommandGateway.dispatch_system(command) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      {:error, reason, detail} -> {:error, {reason, detail}}
    end
  end

  defp audit_failed(reason),
    do:
      Error.new(:audit_failed, "memory audit command rejected; change rolled back", %{
        reason: inspect(reason)
      })

  # --- verify / sync ---------------------------------------------------

  defp drift(disk, audited) do
    audit = Map.new(audited, &{&1.name, &1})
    disk_by_name = Map.new(disk, &{&1.name, &1})

    %Drift{
      missing_on_disk:
        audit |> Map.keys() |> Enum.reject(&Map.has_key?(disk_by_name, &1)) |> Enum.sort(),
      untracked_on_disk:
        disk_by_name |> Map.keys() |> Enum.reject(&Map.has_key?(audit, &1)) |> Enum.sort(),
      sha_mismatch:
        disk_by_name
        |> Enum.filter(fn {name, entry} ->
          case Map.get(audit, name) do
            nil -> false
            a -> a.sha256 != entry.sha256
          end
        end)
        |> Enum.map(&elem(&1, 0))
        |> Enum.sort()
    }
  end

  defp do_sync(project_id, path, author) do
    with {:ok, disk} <- Store.list(path) do
      drift = drift(disk, ProjectionStore.project_memory(project_id))
      secrets = secrets_for(project_id)

      {recorded, failed} =
        (drift.untracked_on_disk ++ drift.sha_mismatch)
        |> Enum.sort()
        |> Enum.reduce({[], []}, fn name, {ok, bad} ->
          case sync_write(project_id, path, secrets, name, author) do
            :ok -> {[name | ok], bad}
            {:error, %Error{} = error} -> {ok, [{name, error} | bad]}
          end
        end)

      {forgotten, failed} =
        Enum.reduce(drift.missing_on_disk, {[], failed}, fn name, {ok, bad} ->
          audit = Enum.find(ProjectionStore.project_memory(project_id), &(&1.name == name))
          entry = %Store.Entry{name: name, sha256: audit.sha256, bytes: audit.bytes}

          case dispatch(forget_command(project_id, name, entry, author)) do
            :ok -> {[name | ok], bad}
            {:error, reason} -> {ok, [{name, audit_failed(reason)} | bad]}
          end
        end)

      with :ok <- Store.regenerate_index(path) do
        {:ok,
         %SyncReport{
           recorded: Enum.reverse(recorded),
           forgotten: Enum.reverse(forgotten),
           failed: Enum.reverse(failed)
         }}
      end
    end
  end

  defp sync_write(project_id, path, secrets, name, author) do
    with {:ok, entry, content} <- Store.read(path, name),
         {:ok, written} <-
           Store.write(path, secrets, %{
             name: name,
             description: entry.description,
             content: content
           }) do
      case dispatch(write_command(project_id, written, author)) do
        :ok -> :ok
        {:error, reason} -> {:error, audit_failed(reason)}
      end
    end
  end

  # --- project resolution ----------------------------------------------

  defp readable_path(project_id) do
    case ProjectionStore.project(project_id) do
      nil -> {:error, Error.new(:project_not_found, "unknown project", %{project_id: project_id})}
      project -> project_path(project, project_id)
    end
  end

  defp writable_path(project_id) do
    case ProjectionStore.project(project_id) do
      nil ->
        {:error, Error.new(:project_not_found, "unknown project", %{project_id: project_id})}

      %{archived?: true} ->
        {:error, Error.new(:project_archived, "project is archived", %{project_id: project_id})}

      %{status: "archived"} ->
        {:error, Error.new(:project_archived, "project is archived", %{project_id: project_id})}

      project ->
        project_path(project, project_id)
    end
  end

  defp project_path(%{path: path}, _project_id) when is_binary(path) and path != "",
    do: {:ok, path}

  defp project_path(_project, project_id),
    do:
      {:error,
       Error.new(:project_path_unknown, "project has no path on disk", %{project_id: project_id})}

  # The one seam for project secret values; E4 extends it with secret-store values.
  defp secrets_for(project_id),
    do: project_id |> WorkerEnvironment.build_env_map() |> WorkerEnvironment.extract_secrets()

  defp locked(project_id, fun) do
    case :global.trans({{:project_memory, project_id}, self()}, fun, [node()]) do
      :aborted ->
        {:error,
         Error.new(:write_failed, "could not acquire project memory lock", %{
           project_id: project_id
         })}

      result ->
        result
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(text), do: text

  defp outcome({:ok, _}), do: :ok
  defp outcome({:error, %Error{code: code}}), do: code
end
