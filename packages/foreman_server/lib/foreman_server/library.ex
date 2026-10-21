defmodule ForemanServer.Library do
  @moduledoc """
  Single entry point for a project's library: files and folders every agent of the
  project can read (Claude "Project knowledge" parity). Used by HTTP, MCP and the CLI.

  Content lives on disk under `<project path>/.foreman/library/` (see
  `ForemanServer.Library.Store`; only that path is gitignored). The event log keeps
  a metadata-only audit/index (`ProjectLibraryAdded` / `Replaced` / `Removed` on
  stream `project_library:<project_id>`).

  `add/4`, `replace/5` and `remove/3` run under a per-project `:global` lock in this
  order: resolve project (reject archived) -> plan with `Library.Ingest` -> cheap
  guards (duplicate name, folder cap) -> write to disk -> dispatch the system
  command. If the dispatch fails, the disk change is rolled back (new entry removed,
  old entry restored), so disk and the audit index never diverge. Every result
  carries skipped files so a client can show what was left out.

  Delivery to agents: `env/1` is `%{"FOREMAN_LIBRARY_PATH" => abs_dir}` when the
  library has at least one entry and `%{}` otherwise; `index/1` renders the markdown
  list used by the standing project context. Agents on the host read the absolute
  path (nothing is linked or copied into the worktree, because Foreman commits
  everything in the worktree); docker jobsites mount it read-only at `/library`.

  Authors are `%{kind: :agent | :operator | :system, ref: String.t() | nil}`.
  """

  alias ForemanServer.CommandGateway
  alias ForemanServer.Library.{Entry, Error, Ingest, Plan, Store}
  alias ForemanServer.ProjectionStore

  @type author :: %{kind: :agent | :operator | :system, ref: String.t() | nil}
  @type result :: %{entry: Entry.t(), skipped: [Plan.Skip.t()]}

  @orphan_max_age_seconds 3_600
  @read_max_bytes 1_048_576
  @index_files_per_entry 25

  @doc "Maximum bytes returned by `read/3`."
  @spec read_max_bytes() :: pos_integer()
  def read_max_bytes, do: @read_max_bytes

  @doc """
  Adds an entry. `attrs`: `:name` (optional), `:source` (string-keyed map stored on
  the event/entry, default `%{"kind" => "upload"}`), `:limits` (test override).
  """
  @spec add(String.t(), Ingest.source(), map(), author()) ::
          {:ok, result()} | {:error, Error.t()}
  def add(project_id, source, attrs, %{kind: kind} = author)
      when is_binary(project_id) and is_map(attrs) and kind in [:agent, :operator, :system] do
    with {:ok, path} <- writable_path(project_id),
         {:ok, plan} <- Ingest.plan(source, plan_opts(attrs)) do
      locked(project_id, fn -> do_add(project_id, path, plan, attrs, author) end)
    end
  end

  @doc "Replaces the files of an existing entry (name and kind are kept unless `attrs[:name]` is given)."
  @spec replace(String.t(), String.t(), Ingest.source(), map(), author()) ::
          {:ok, result()} | {:error, Error.t()}
  def replace(project_id, entry_id, source, attrs, %{kind: kind} = author)
      when is_binary(project_id) and is_binary(entry_id) and is_map(attrs) and
             kind in [:agent, :operator, :system] do
    with {:ok, path} <- writable_path(project_id),
         {:ok, existing} <- Store.read_entry(Store.root(path), entry_id),
         {:ok, plan} <-
           Ingest.plan(source, plan_opts(Map.put_new(attrs, :name, existing.name))) do
      plan = %Plan{plan | kind: existing.kind}
      locked(project_id, fn -> do_replace(project_id, path, existing, plan, attrs, author) end)
    end
  end

  @doc "Removes an entry and its files."
  @spec remove(String.t(), String.t(), author()) :: {:ok, Entry.t()} | {:error, Error.t()}
  def remove(project_id, entry_id, %{kind: kind} = author)
      when is_binary(project_id) and is_binary(entry_id) and kind in [:agent, :operator, :system] do
    with {:ok, path} <- writable_path(project_id) do
      locked(project_id, fn -> do_remove(project_id, path, entry_id, author) end)
    end
  end

  @doc "Every entry, sorted by name."
  @spec list(String.t()) :: {:ok, [Entry.t()]} | {:error, Error.t()}
  def list(project_id) when is_binary(project_id) do
    with {:ok, path} <- readable_path(project_id) do
      root = Store.root(path)
      Store.sweep(root, @orphan_max_age_seconds)
      Store.list(root)
    end
  end

  @doc "One entry's metadata."
  @spec get(String.t(), String.t()) :: {:ok, Entry.t()} | {:error, Error.t()}
  def get(project_id, entry_id) when is_binary(project_id) and is_binary(entry_id) do
    with {:ok, path} <- readable_path(project_id),
         do: Store.read_entry(Store.root(path), entry_id)
  end

  @doc "Reads one file (at most 1 MiB) of an entry by its entry-relative path."
  @spec read(String.t(), String.t(), String.t()) :: {:ok, binary()} | {:error, Error.t()}
  def read(project_id, entry_id, rel_path)
      when is_binary(project_id) and is_binary(entry_id) and is_binary(rel_path) do
    with {:ok, path} <- readable_path(project_id) do
      Store.read_file(Store.root(path), entry_id, rel_path, @read_max_bytes)
    end
  end

  @doc """
  `%{"FOREMAN_LIBRARY_PATH" => dir}` when the project's library has at least one
  entry, else `%{}`. Never raises: an unknown project or unreadable disk is `%{}`.
  """
  @spec env(String.t() | nil) :: %{optional(String.t()) => String.t()}
  def env(project_id) do
    case dir(project_id) do
      {:ok, dir} -> %{"FOREMAN_LIBRARY_PATH" => dir}
      :none -> %{}
    end
  end

  @doc "The absolute library directory when it has at least one entry, else `:none`."
  @spec dir(String.t() | nil) :: {:ok, String.t()} | :none
  def dir(project_id) when is_binary(project_id) do
    with {:ok, path} <- readable_path(project_id),
         root = Store.root(path),
         {:ok, [_ | _]} <- Store.list(root) do
      {:ok, Path.expand(root)}
    else
      _ -> :none
    end
  end

  def dir(_project_id), do: :none

  @doc """
  How a sandbox sees the library: `%{env: env, mounts: mounts}`.

  `:host` sandboxes read the absolute host directory (`env` only). `:docker`
  sandboxes get a read-only bind mount at `/library` (the real read-only guarantee)
  and the variable points at the mount. An empty library yields
  `%{env: %{}, mounts: []}`. Nothing is ever written into the worktree.
  """
  @spec delivery(String.t() | nil, :host | :docker) :: %{env: map(), mounts: [map()]}
  def delivery(project_id, sandbox) when sandbox in [:host, :docker] do
    case {dir(project_id), sandbox} do
      {:none, _} ->
        %{env: %{}, mounts: []}

      {{:ok, host_dir}, :host} ->
        %{env: %{"FOREMAN_LIBRARY_PATH" => host_dir}, mounts: []}

      {{:ok, host_dir}, :docker} ->
        %{
          env: %{"FOREMAN_LIBRARY_PATH" => "/library"},
          mounts: [%{host_path: host_dir, sandbox_path: "/library", readonly?: true}]
        }
    end
  end

  @doc """
  Markdown list of the library for the standing project context: one block per entry
  with its read path under `$FOREMAN_LIBRARY_PATH` and up to #{@index_files_per_entry}
  files. `""` for an empty library.
  """
  @spec index(String.t()) :: {:ok, String.t()} | {:error, Error.t()}
  def index(project_id) when is_binary(project_id) do
    with {:ok, entries} <- list(project_id), do: {:ok, render_index(entries)}
  end

  @doc false
  @spec render_index([Entry.t()]) :: String.t()
  def render_index([]), do: ""

  def render_index(entries) do
    header =
      "Files are read-only: read them from $FOREMAN_LIBRARY_PATH.\n"

    body =
      Enum.map_join(entries, "\n", fn e ->
        files =
          e.files
          |> Enum.take(@index_files_per_entry)
          |> Enum.map_join("\n", &"  - #{&1.path} (#{&1.bytes} bytes)")

        more =
          if e.file_count > @index_files_per_entry,
            do: "\n  - ... #{e.file_count - @index_files_per_entry} more files",
            else: ""

        "- #{e.name} (#{e.kind}, #{e.file_count} files, #{e.bytes} bytes): " <>
          "$FOREMAN_LIBRARY_PATH/#{e.entry_id}/files/\n" <> files <> more
      end)

    header <> "\n" <> body <> "\n"
  end

  # -- add / replace / remove --------------------------------------------

  defp do_add(project_id, path, plan, attrs, author) do
    root = Store.root(path)

    with :ok <- Store.ensure_ready(path),
         :ok <- precheck_add(project_id, plan),
         _ = Store.sweep(root, @orphan_max_age_seconds),
         entry_id = Store.new_entry_id(plan.name),
         {:ok, entry, pending} <-
           Store.write(root, entry_id, plan, source: source_meta(attrs, plan)) do
      finish(pending, dispatch(add_command(project_id, entry, plan, author)), fn ->
        {:ok, %{entry: entry, skipped: plan.skipped}}
      end)
    end
  end

  defp do_replace(project_id, path, existing, plan, attrs, author) do
    root = Store.root(path)

    with :ok <- Store.ensure_ready(path),
         :ok <- precheck_name(project_id, existing.entry_id, plan.name),
         _ = Store.sweep(root, @orphan_max_age_seconds),
         {:ok, entry, pending} <-
           Store.write(root, existing.entry_id, plan,
             replace?: true,
             source: source_meta(attrs, plan)
           ) do
      command = replace_command(project_id, entry, plan, author)
      finish(pending, dispatch(command), fn -> {:ok, %{entry: entry, skipped: plan.skipped}} end)
    end
  end

  defp do_remove(project_id, path, entry_id, author) do
    root = Store.root(path)

    with {:ok, entry, pending} <- Store.remove(root, entry_id) do
      finish(pending, dispatch(remove_command(project_id, entry, author)), fn -> {:ok, entry} end)
    end
  end

  # Disk first, then the audit command; a rejected command restores the disk.
  defp finish(pending, :ok, ok_fun) do
    Store.commit(pending)
    ok_fun.()
  end

  defp finish(pending, {:error, reason}, _ok_fun) do
    Store.rollback(pending)
    {:error, dispatch_error(reason)}
  end

  defp dispatch(command) do
    case CommandGateway.dispatch_system(command) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
      {:error, reason, detail} -> {:error, {reason, detail}}
    end
  end

  defp dispatch_error({:too_many_folders, max}),
    do:
      Error.new(:too_many_folders, "a project holds at most #{max} library folders", %{max: max})

  defp dispatch_error({:duplicate_name, name}),
    do:
      Error.new(:duplicate_name, "a library entry named #{inspect(name)} already exists", %{
        name: name
      })

  defp dispatch_error({:not_found, id}),
    do: Error.new(:not_found, "unknown library entry #{id}", %{id: id})

  defp dispatch_error(reason),
    do:
      Error.new(:dispatch_failed, "library command rejected; change rolled back", %{
        reason: inspect(reason)
      })

  defp precheck_add(project_id, plan) do
    entries = ProjectionStore.project_library(project_id)

    cond do
      Enum.any?(entries, &(&1.name == plan.name)) ->
        {:error, dispatch_error({:duplicate_name, plan.name})}

      plan.kind == :folder and
          Enum.count(entries, &(&1.kind == "folder")) >=
            ForemanServer.Aggregates.ProjectLibrary.max_folders() ->
        {:error,
         dispatch_error(
           {:too_many_folders, ForemanServer.Aggregates.ProjectLibrary.max_folders()}
         )}

      true ->
        :ok
    end
  end

  defp precheck_name(project_id, entry_id, name) do
    taken? =
      project_id
      |> ProjectionStore.project_library()
      |> Enum.any?(&(&1.name == name and &1.entry_id != entry_id))

    if taken?, do: {:error, dispatch_error({:duplicate_name, name})}, else: :ok
  end

  defp plan_opts(attrs) do
    [name: Map.get(attrs, :name), limits: Map.get(attrs, :limits, %{})]
  end

  defp source_meta(attrs, plan) do
    base = Map.get(attrs, :source) || %{"kind" => "upload"}
    Map.put_new(base, "file_count", length(plan.files))
  end

  defp add_command(project_id, entry, plan, author) do
    %{
      type: "project.library.add",
      command_id: "project_library:#{project_id}:#{entry.entry_id}:#{entry.manifest_sha256}",
      aggregate_id: "project_library:" <> project_id,
      payload: payload(project_id, entry, plan, author)
    }
  end

  defp replace_command(project_id, entry, plan, author) do
    %{
      type: "project.library.replace",
      command_id:
        "project_library:#{project_id}:#{entry.entry_id}:#{entry.manifest_sha256}:replace:" <>
          unique_suffix(),
      aggregate_id: "project_library:" <> project_id,
      payload: payload(project_id, entry, plan, author)
    }
  end

  # Replace and remove need a fresh id each time: the event id is derived from
  # `command_id`, so a deterministic one would silently drop an A -> B -> A rewrite.
  defp remove_command(project_id, entry, author) do
    %{
      type: "project.library.remove",
      command_id: "project_library:#{project_id}:#{entry.entry_id}:remove:" <> unique_suffix(),
      aggregate_id: "project_library:" <> project_id,
      payload: %{
        project_id: project_id,
        entry_id: entry.entry_id,
        author_kind: Atom.to_string(author.kind),
        author_ref: Map.get(author, :ref)
      }
    }
  end

  defp unique_suffix,
    do: "#{System.os_time(:microsecond)}-#{System.unique_integer([:positive])}"

  defp payload(project_id, entry, plan, author) do
    %{
      project_id: project_id,
      entry_id: entry.entry_id,
      name: entry.name,
      kind: Atom.to_string(entry.kind),
      file_count: entry.file_count,
      bytes: entry.bytes,
      manifest_sha256: entry.manifest_sha256,
      source: entry.source,
      skipped_summary: Plan.skipped_summary(plan.skipped),
      author_kind: Atom.to_string(author.kind),
      author_ref: Map.get(author, :ref)
    }
  end

  # -- project resolution --------------------------------------------------

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

  defp locked(project_id, fun) do
    case :global.trans({{:project_library, project_id}, self()}, fun, [node()]) do
      :aborted ->
        {:error,
         Error.new(:write_failed, "could not acquire library lock", %{project_id: project_id})}

      result ->
        result
    end
  end
end
