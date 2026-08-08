defmodule ForemanServer.Workflow.Catalog do
  @moduledoc """
  Supervised workflow catalog. Owns the loaded and validated workflow
  snapshots and prompt bodies in memory, auto-installs the bundled
  templates when the runtime directory is empty, and reloads files
  when the directory changes.

  ## Responsibilities

    * **Auto-install** — when the configured root contains no `*.yaml`
      files, `init/1` invokes `ForemanServer.WorkflowTemplate.Installer`
      to populate it from the bundled `priv/defaults/workflows` source.
    * **Synchronous load** — every manifest in the root is parsed via
      `ForemanServer.Workflow.Interpreter.load/1` during `init/1` so the
      first command after boot finds the catalog ready. Every `*.md`
      file under `prompts/` is also loaded into memory.
    * **Hot reload** — a periodic poll compares the on-disk mtime and
      content of every manifest and prompt against the in-memory entry;
      out-of-date entries are re-parsed and replaced atomically. Files
      that vanish are removed from the catalog.
    * **Prompt read API** — `read_prompt/1` returns the latest prompt
      body. `ForemanServer.Workflow.RunExecutor` reads prompts through
      the catalog so prompt edits are picked up by the next phase.

  The poll interval is `Application.get_env(:foreman_server,
  :workflow_catalog_poll_ms, 2_000)`. Telemetry is emitted on every
  install, load, and reload so operators can observe changes:

      [:foreman_server, :workflow, :installed]
      [:foreman_server, :workflow, :manifest, :loaded]
      [:foreman_server, :workflow, :manifest, :reload, :ok]
      [:foreman_server, :workflow, :manifest, :reload, :error]
      [:foreman_server, :workflow, :manifest, :removed]
      [:foreman_server, :workflow, :prompt, :loaded]
      [:foreman_server, :workflow, :prompt, :reload, :ok]
      [:foreman_server, :workflow, :prompt, :reload, :error]
      [:foreman_server, :workflow, :prompt, :removed]
  """

  use GenServer

  alias ForemanServer.Workflow.AssetCatalog
  alias ForemanServer.Workflow.Interpreter
  alias ForemanServer.WorkflowTemplate.Installer

  @type manifest_entry :: %{
          workflow: map(),
          manifest_path: Path.t(),
          file_digest: String.t() | nil,
          mtime: integer() | nil
        }

  @type prompt_entry :: %{
          content: String.t(),
          prompt_path: Path.t(),
          file_digest: String.t() | nil,
          mtime: integer() | nil
        }

  @type state :: %{
          catalog: AssetCatalog.t(),
          manifests: %{String.t() => manifest_entry()},
          prompts: %{String.t() => prompt_entry()}
        }

  ## Public API

  @doc """
  Start the catalog rooted at the given directory (default:
  `~/.foreman/workflows`).
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, server())
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc false
  # Configurable lookup so tests can substitute an isolated Catalog.
  def server, do: Application.get_env(:foreman_server, :workflow_catalog, __MODULE__)

  @doc "Load a workflow manifest by filename (e.g. `\"implement.yaml\"`)."
  @spec load(String.t()) :: {:ok, map()} | {:error, term()}
  def load(filename) when is_binary(filename), do: GenServer.call(server(), {:load, filename})

  @doc """
  Read the latest prompt body for the given absolute prompt path.
  Returns `{:ok, content}` on hit; `{:error, :prompt_not_tracked}` if the
  catalog has no entry for that basename.
  """
  @spec read_prompt(Path.t()) :: {:ok, String.t()} | {:error, term()}
  def read_prompt(path) when is_binary(path) do
    GenServer.call(server(), {:read_prompt, Path.basename(path)})
  end

  @doc "All currently loaded manifest filenames."
  @spec manifests() :: [String.t()]
  def manifests, do: GenServer.call(server(), :manifests)

  @doc "All currently tracked prompt filenames."
  @spec prompt_filenames() :: [String.t()]
  def prompt_filenames, do: GenServer.call(server(), :prompt_filenames)

  @doc "True when at least one manifest is loaded."
  @spec installed?() :: boolean()
  def installed?, do: GenServer.call(server(), :installed?)

  @doc "The on-disk root the catalog is using."
  @spec root() :: Path.t()
  def root, do: GenServer.call(server(), :root)

  @doc "Trigger an immediate reload pass. Returns `:ok`."
  @spec reload() :: :ok
  def reload, do: GenServer.call(server(), :reload)

  ## GenServer

  @impl true
  def init(opts) do
    catalog =
      case Keyword.get(opts, :catalog) do
        %AssetCatalog{} = c -> c
        _ -> AssetCatalog.default()
      end

    state = %{catalog: catalog, manifests: %{}, prompts: %{}}
    state = ensure_installed(state)
    state = load_manifests(state)
    state = load_prompts(state)
    schedule_poll()
    {:ok, state}
  end

  @impl true
  def handle_call({:load, filename}, _from, state) do
    case Map.fetch(state.manifests, filename) do
      {:ok, %{workflow: workflow}} ->
        {:reply, {:ok, workflow}, state}

      :error ->
        {:reply, {:error, {:workflow_not_loaded, filename}}, state}
    end
  end

  def handle_call({:read_prompt, basename}, _from, state) do
    case Map.fetch(state.prompts, basename) do
      {:ok, %{content: content}} ->
        {:reply, {:ok, content}, state}

      :error ->
        {:reply, {:error, :prompt_not_tracked}, state}
    end
  end

  def handle_call(:manifests, _from, state) do
    {:reply, state.manifests |> Map.keys() |> Enum.sort(), state}
  end

  def handle_call(:prompt_filenames, _from, state) do
    {:reply, state.prompts |> Map.keys() |> Enum.sort(), state}
  end

  def handle_call(:installed?, _from, state) do
    {:reply, map_size(state.manifests) > 0, state}
  end

  def handle_call(:root, _from, state) do
    {:reply, state.catalog.root, state}
  end

  def handle_call(:reload, _from, state) do
    {:reply, :ok, scan(state)}
  end

  @impl true
  def handle_info(:poll, state) do
    {:noreply, poll(state)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, _state), do: :ok

  ## Internal

  defp ensure_installed(%{catalog: %AssetCatalog{root: root}} = state) do
    if File.dir?(root) and not Enum.empty?(AssetCatalog.manifests(state.catalog)) do
      state
    else
      install(state)
    end
  end

  defp install(state) do
    case Installer.install(target_dir: state.catalog.root) do
      {:ok, _paths} ->
        :telemetry.execute(
          [:foreman_server, :workflow, :installed],
          %{count: 1},
          %{root: state.catalog.root}
        )

        state

      {:error, reason} ->
        :telemetry.execute(
          [:foreman_server, :workflow, :install, :error],
          %{},
          %{root: state.catalog.root, reason: reason}
        )

        state
    end
  end

  defp load_manifests(state) do
    paths = AssetCatalog.manifests(state.catalog)
    Enum.reduce(paths, state, &load_one_manifest/2)
  end

  defp load_prompts(state) do
    paths = AssetCatalog.prompts(state.catalog)
    Enum.reduce(paths, state, &load_one_prompt/2)
  end

  defp scan(state) do
    state = reconcile_manifests(state)
    reconcile_prompts(state)
  end

  defp poll(state) do
    state = scan(state)
    schedule_poll()
    state
  end

  defp reconcile_manifests(state) do
    paths = AssetCatalog.manifests(state.catalog)
    on_disk = MapSet.new(paths, &Path.basename/1)
    current = state.manifests |> Map.keys() |> MapSet.new()

    state
    |> apply_manifest_paths(paths)
    |> drop_vanished_manifests(current, on_disk)
  end

  defp apply_manifest_paths(state, paths) do
    Enum.reduce(paths, state, fn path, acc -> load_one_manifest(path, acc) end)
  end

  defp drop_vanished_manifests(state, current, on_disk) do
    vanished = MapSet.difference(current, on_disk)

    Enum.reduce(vanished, state, fn filename, acc ->
      :telemetry.execute(
        [:foreman_server, :workflow, :manifest, :removed],
        %{},
        %{filename: filename}
      )

      %{acc | manifests: Map.delete(acc.manifests, filename)}
    end)
  end

  defp reconcile_prompts(state) do
    paths = AssetCatalog.prompts(state.catalog)
    on_disk = MapSet.new(paths, &Path.basename/1)
    current = state.prompts |> Map.keys() |> MapSet.new()

    state
    |> apply_prompt_paths(paths)
    |> drop_vanished_prompts(current, on_disk)
  end

  defp apply_prompt_paths(state, paths) do
    Enum.reduce(paths, state, fn path, acc -> load_one_prompt(path, acc) end)
  end

  defp drop_vanished_prompts(state, current, on_disk) do
    vanished = MapSet.difference(current, on_disk)

    Enum.reduce(vanished, state, fn filename, acc ->
      :telemetry.execute(
        [:foreman_server, :workflow, :prompt, :removed],
        %{},
        %{filename: filename}
      )

      %{acc | prompts: Map.delete(acc.prompts, filename)}
    end)
  end

  defp schedule_poll do
    interval = Application.get_env(:foreman_server, :workflow_catalog_poll_ms, 2_000)
    Process.send_after(self(), :poll, interval)
  end

  defp load_one_manifest(path, state) do
    filename = Path.basename(path)

    case read_manifest_entry(path) do
      {:ok, entry} ->
        cond do
          not Map.has_key?(state.manifests, filename) ->
            :telemetry.execute(
              [:foreman_server, :workflow, :manifest, :loaded],
              %{},
              %{filename: filename}
            )

            put_manifest(state, filename, entry)

          manifest_changed?(state, filename, entry) ->
            :telemetry.execute(
              [:foreman_server, :workflow, :manifest, :reload, :ok],
              %{},
              %{filename: filename}
            )

            put_manifest(state, filename, entry)

          true ->
            state
        end

      {:error, reason} ->
        :telemetry.execute(
          [:foreman_server, :workflow, :manifest, :reload, :error],
          %{},
          %{filename: filename, reason: reason}
        )

        state
    end
  end

  defp put_manifest(state, filename, entry) do
    %{state | manifests: Map.put(state.manifests, filename, entry)}
  end

  defp manifest_changed?(state, filename, new_entry) do
    case Map.fetch(state.manifests, filename) do
      {:ok, old} ->
        old.file_digest != new_entry.file_digest or old.mtime != new_entry.mtime

      :error ->
        true
    end
  end

  defp read_manifest_entry(path) do
    with {:ok, raw} <- Interpreter.load(path),
         {:ok, resolved} <- resolve_workflow(resolve_catalog(path), raw, path) do
      {:ok,
       %{
         workflow: resolved,
         manifest_path: path,
         file_digest: AssetCatalog.digest(path),
         mtime: mtime(path)
       }}
    end
  end

  defp resolve_catalog(path) do
    root = Path.dirname(path)
    AssetCatalog.new(root)
  end

  defp resolve_workflow(catalog, workflow, path) do
    try do
      resolved = %{
        name: workflow["name"],
        description: workflow["description"],
        phases:
          Enum.map(workflow["phases"], fn phase ->
            resolved_phase =
              phase
              |> Map.put(:prompt_path, AssetCatalog.resolve_prompt(catalog, phase["prompt"]))
              |> Map.put(:artifact_template, phase["artifact"])
              |> Map.put(:command, phase["command"])
              |> Map.put(:required_file, phase["requiredFile"])
              |> Map.put(:bash, phase["bash"])
              |> Map.put(:index, phase["index"])
              |> Map.put(:models, phase["models"])
              |> Map.put(:max_turns, phase["maxTurns"])
              |> Map.put(:mail, phase["mail"])
            action =
              cond do
                is_binary(phase["command"]) and phase["command"] != "" -> :command
                is_binary(phase["bash"]) and phase["bash"] != "" -> :bash
                true -> :prompt
              end

            Map.put(resolved_phase, :action, action)
          end),
        manifest_path: path,
        digest: workflow["digest"]
      }

      {:ok, resolved}
    rescue
      e in [KeyError] -> {:error, {:resolution_failed, Exception.message(e)}}
    end
  end

  defp load_one_prompt(path, state) do
    filename = Path.basename(path)

    case read_prompt_entry(path) do
      {:ok, entry} ->
        cond do
          not Map.has_key?(state.prompts, filename) ->
            :telemetry.execute(
              [:foreman_server, :workflow, :prompt, :loaded],
              %{},
              %{filename: filename}
            )

            put_prompt(state, filename, entry)

          prompt_changed?(state, filename, entry) ->
            :telemetry.execute(
              [:foreman_server, :workflow, :prompt, :reload, :ok],
              %{},
              %{filename: filename}
            )

            put_prompt(state, filename, entry)

          true ->
            state
        end

      {:error, reason} ->
        :telemetry.execute(
          [:foreman_server, :workflow, :prompt, :reload, :error],
          %{},
          %{filename: filename, reason: reason}
        )

        state
    end
  end

  defp put_prompt(state, filename, entry) do
    %{state | prompts: Map.put(state.prompts, filename, entry)}
  end

  defp prompt_changed?(state, filename, new_entry) do
    case Map.fetch(state.prompts, filename) do
      {:ok, old} ->
        old.file_digest != new_entry.file_digest or old.mtime != new_entry.mtime

      :error ->
        true
    end
  end

  defp read_prompt_entry(path) do
    with {:ok, content} <- File.read(path) do
      digest =
        :crypto.hash(:sha256, content)
        |> Base.encode16(case: :lower)
        |> binary_part(0, 16)

      {:ok,
       %{
         content: content,
         prompt_path: path,
         file_digest: digest,
         mtime: mtime(path)
       }}
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: m}} -> m
      {:error, _} -> nil
    end
  end
end
