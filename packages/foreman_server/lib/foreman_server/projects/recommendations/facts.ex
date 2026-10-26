defmodule ForemanServer.Projects.Recommendations.Facts do
  @moduledoc """
  The observed facts `ForemanServer.Projects.Recommendations.evaluate/1` reasons
  about, and `collect/2`, the only place that does I/O to gather them.

  Safety rules (asserted by tests):

    * Only existence of FIXED file names/globs is checked, plus the head of two
      fixed files (`.git/config`, `.git/HEAD`); arbitrary repo content is never
      read, and no script from the repo is ever executed. External commands run
      by absolute path found on the server's own `PATH` (never the repo dir),
      from a neutral working directory.
    * Every external call is bounded by `:probe_timeout_ms` (default 5 000); a
      hanging command yields `:timeout`, never a hang. The whole collection is
      bounded by `:total_timeout_ms`.
    * Every fact that could not be observed is `:unavailable` (or `:timeout`),
      and detectors stay silent on those: no false alarms.
  """

  alias ForemanServer.Aggregates.Project.Environment
  alias ForemanServer.ProjectEnvironment
  alias ForemanServer.ProjectionStore
  alias ForemanServer.ProjectSettings
  alias ForemanServer.Workflow.Catalog

  defmodule Probe do
    @moduledoc "I/O seam of `Facts.collect/2`. The default is `Probe.System`."
    @callback exists?(path :: String.t()) :: boolean()
    @callback glob(pattern :: String.t()) :: [String.t()]
    @callback read_head(path :: String.t(), max_bytes :: pos_integer()) ::
                {:ok, binary()} | :error
    @callback find_executable(name :: String.t()) :: String.t() | nil
    @callback cmd(executable :: String.t(), args :: [String.t()], timeout_ms :: pos_integer()) ::
                {:ok, exit_status :: non_neg_integer()} | {:error, :timeout | :failed}
    @callback call(fun :: (-> term()), timeout_ms :: pos_integer()) ::
                {:ok, term()} | {:error, :timeout | :failed}
  end

  defmodule Probe.System do
    @moduledoc false
    @behaviour ForemanServer.Projects.Recommendations.Facts.Probe

    @impl true
    def exists?(path), do: File.exists?(path)

    @impl true
    def glob(pattern), do: pattern |> Path.wildcard() |> Enum.sort()

    @impl true
    def read_head(path, max_bytes) do
      case File.open(path, [:read, :binary]) do
        {:ok, io} ->
          try do
            case IO.binread(io, max_bytes) do
              data when is_binary(data) -> {:ok, data}
              _ -> :error
            end
          after
            File.close(io)
          end

        {:error, _} ->
          :error
      end
    end

    @impl true
    def find_executable(name), do: System.find_executable(name)

    @impl true
    def cmd(executable, args, timeout_ms) do
      call(
        fn ->
          {_out, status} =
            System.cmd(executable, args, cd: System.tmp_dir!(), stderr_to_stdout: true)

          status
        end,
        timeout_ms
      )
    end

    @impl true
    def call(fun, timeout_ms) do
      parent = self()
      ref = make_ref()

      {pid, monitor} =
        spawn_monitor(fn ->
          result =
            try do
              {:ok, fun.()}
            catch
              _kind, _reason -> {:error, :failed}
            end

          send(parent, {ref, result})
        end)

      receive do
        {^ref, result} ->
          Process.demonitor(monitor, [:flush])
          result

        {:DOWN, ^monitor, :process, ^pid, _reason} ->
          {:error, :failed}
      after
        timeout_ms ->
          Process.exit(pid, :kill)
          Process.demonitor(monitor, [:flush])

          receive do
            {^ref, _late} -> :ok
          after
            0 -> :ok
          end

          {:error, :timeout}
      end
    end
  end

  @enforce_keys [:project_id]
  defstruct [
    :project_id,
    :repo_path,
    :project_status,
    :task_provider,
    :beads_db_path,
    has_beads_dir: false,
    br_binary: false,
    files: %{agents_md: false, claude_md: false, ci: [], manifests: []},
    checked_out_branch: :unavailable,
    gh: :unavailable,
    git_remote: :unavailable,
    workflows_installed: :unavailable,
    unmapped_issue_types: :unavailable,
    provider_rows: :unavailable,
    settings: :unavailable,
    env_secret_keys: [],
    env_names: :unavailable,
    memory_count: :unavailable
  ]

  @type tri :: boolean() | :unavailable
  @type t :: %__MODULE__{
          project_id: String.t(),
          repo_path: String.t() | nil,
          project_status: String.t() | nil,
          task_provider: String.t() | nil,
          beads_db_path: String.t() | nil,
          has_beads_dir: boolean(),
          br_binary: boolean(),
          files: %{
            agents_md: boolean(),
            claude_md: boolean(),
            ci: [String.t()],
            manifests: [String.t()]
          },
          checked_out_branch: String.t() | :detached | :unavailable,
          gh: :authenticated | :unauthenticated | :missing | :timeout | :unavailable,
          git_remote: tri(),
          workflows_installed: tri(),
          unmapped_issue_types: [String.t()] | :unavailable,
          provider_rows: [{atom(), :installed | :not_installed}] | :unavailable,
          settings: ProjectSettings.t() | :unavailable,
          env_secret_keys: [String.t()],
          env_names: [String.t()] | :unavailable,
          memory_count: non_neg_integer() | :unavailable
        }

  @ci_patterns [".github/workflows/*.yml", ".github/workflows/*.yaml", ".gitlab-ci.yml"]
  @ci_files [".circleci/config.yml"]
  @manifest_names ~w(mix.exs package.json go.mod pyproject.toml Cargo.toml Gemfile)
  @git_head_sha ~r/\A[0-9a-f]{40}(?:[0-9a-f]{24})?\s*\z/
  @default_probe_timeout_ms 5_000
  @default_total_timeout_ms 15_000

  @doc "Default per-probe timeout."
  @spec probe_timeout_ms() :: pos_integer()
  def probe_timeout_ms, do: @default_probe_timeout_ms

  @doc "Default budget for a whole collection."
  @spec total_timeout_ms() :: pos_integer()
  def total_timeout_ms, do: @default_total_timeout_ms

  @doc """
  Collect facts for `project_id`. Options: `:probe` (module, default
  `Probe.System`), `:probe_timeout_ms`, `:deadline_ms` (monotonic ms after
  which remaining external probes are skipped as `:timeout`).
  """
  @spec collect(String.t(), keyword()) :: {:ok, t()} | {:error, :project_not_found}
  def collect(project_id, opts \\ []) when is_binary(project_id) do
    case ProjectionStore.project(project_id) do
      nil ->
        {:error, :project_not_found}

      project ->
        probe = Keyword.get(opts, :probe, Probe.System)
        timeout = Keyword.get(opts, :probe_timeout_ms, @default_probe_timeout_ms)

        deadline =
          Keyword.get(
            opts,
            :deadline_ms,
            System.monotonic_time(:millisecond) + @default_total_timeout_ms
          )

        {:ok, gather(project_id, project, %{probe: probe, timeout: timeout, deadline: deadline})}
    end
  end

  defp gather(project_id, project, ctx) do
    repo = project[:path]
    settings = ProjectSettings.from_config(project[:config])
    provider = task_provider_name(project[:task_provider])
    beads_db = repo && first_db(ctx.probe, Path.join([repo, ".beads", "*.db"]))
    vars = ProjectEnvironment.environment(project_id, project: project)["vars"]

    %__MODULE__{
      project_id: project_id,
      repo_path: repo,
      project_status: project[:status],
      task_provider: provider,
      beads_db_path: beads_db,
      has_beads_dir: is_binary(repo) and ctx.probe.exists?(Path.join(repo, ".beads")),
      br_binary: ctx.probe.find_executable("br") != nil,
      files: files(ctx.probe, repo),
      checked_out_branch: checked_out_branch(ctx.probe, repo),
      gh: gh_status(ctx),
      git_remote: git_remote(ctx.probe, repo),
      workflows_installed: workflows_installed(ctx),
      unmapped_issue_types: unmapped_types(ctx, project_id, provider),
      provider_rows: provider_rows(ctx),
      settings: settings,
      env_secret_keys: env_secret_keys(vars),
      env_names: env_names(project_id, vars),
      memory_count: memory_count(project_id, ctx)
    }
  end

  defp task_provider_name(%{} = provider) do
    case Map.get(provider, :provider, Map.get(provider, "provider")) do
      name when is_binary(name) -> name
      name when is_atom(name) and not is_nil(name) -> Atom.to_string(name)
      _ -> nil
    end
  end

  defp task_provider_name(_), do: nil

  defp first_db(probe, pattern), do: List.first(probe.glob(pattern))

  defp files(_probe, nil), do: %{agents_md: false, claude_md: false, ci: [], manifests: []}

  defp files(probe, repo) do
    %{
      agents_md: probe.exists?(Path.join(repo, "AGENTS.md")),
      claude_md: probe.exists?(Path.join(repo, "CLAUDE.md")),
      ci:
        (Enum.flat_map(@ci_patterns, &probe.glob(Path.join(repo, &1))) ++
           Enum.filter(Enum.map(@ci_files, &Path.join(repo, &1)), &probe.exists?/1))
        |> Enum.map(&Path.relative_to(&1, repo)),
      manifests: Enum.filter(@manifest_names, &probe.exists?(Path.join(repo, &1)))
    }
  end

  defp gh_status(ctx) do
    with exe when is_binary(exe) <- ctx.probe.find_executable("gh"),
         :ok <- within_deadline(ctx) do
      case ctx.probe.cmd(exe, ["auth", "status"], ctx.timeout) do
        {:ok, 0} -> :authenticated
        {:ok, _nonzero} -> :unauthenticated
        {:error, :timeout} -> :timeout
        {:error, :failed} -> :unavailable
      end
    else
      nil -> :missing
      :timeout -> :timeout
    end
  end

  # Reads only `.git/config`'s head (no git process: a repo's own config can
  # name programs git would run). A worktree's `.git` file is `:unavailable`.
  defp git_remote(_probe, nil), do: :unavailable

  defp git_remote(probe, repo) do
    config = Path.join([repo, ".git", "config"])

    case probe.read_head(config, 65_536) do
      {:ok, body} -> String.contains?(body, ~s([remote "))
      :error -> :unavailable
    end
  end

  # `.git/HEAD` is `ref: refs/heads/<branch>` on a branch and a bare commit id on a
  # detached HEAD. Read as a file for the same reason as `.git/config`; a worktree's
  # `.git` file, a missing repo and any other symbolic ref are `:unavailable`.
  defp checked_out_branch(_probe, nil), do: :unavailable

  defp checked_out_branch(probe, repo) do
    case probe.read_head(Path.join([repo, ".git", "HEAD"]), 256) do
      {:ok, "ref: refs/heads/" <> branch} -> String.trim(branch)
      {:ok, "ref: " <> _other} -> :unavailable
      {:ok, body} -> if Regex.match?(@git_head_sha, body), do: :detached, else: :unavailable
      :error -> :unavailable
    end
  end

  defp workflows_installed(ctx) do
    with :ok <- within_deadline(ctx),
         {:ok, installed?} <- ctx.probe.call(&Catalog.installed?/0, ctx.timeout) do
      installed?
    else
      _ -> :unavailable
    end
  end

  defp unmapped_types(ctx, project_id, "beads") do
    with :ok <- within_deadline(ctx),
         {:ok, {:ok, report}} <- ctx.probe.call(fn -> Catalog.doctor(project_id) end, ctx.timeout) do
      report.unmapped_types
    else
      _ -> :unavailable
    end
  end

  defp unmapped_types(_ctx, _project_id, _provider), do: :unavailable

  defp provider_rows(ctx) do
    with :ok <- within_deadline(ctx),
         {:ok, rows} <-
           ctx.probe.call(&ForemanServerWeb.MCP.Tools.Doctor.rows/0, ctx.timeout) do
      for {:provider, name, status, _hint} <- rows, do: {name, status}
    else
      _ -> :unavailable
    end
  end

  # The plain variables agents actually receive (the environment record's `vars`,
  # else legacy `config.env`), judged by the same name rule `project env set` enforces.
  defp env_secret_keys(vars) do
    for({name, value} <- vars, value != "", Environment.secret_name?(name), do: name)
    |> Enum.sort()
  end

  # Names only, from the projection: plain variables plus the stored secrets.
  defp env_names(project_id, vars) do
    secrets = for %{name: name} <- ProjectionStore.project_secret_names(project_id), do: name
    (Map.keys(vars) ++ secrets) |> Enum.uniq() |> Enum.sort()
  end

  # Project memory (E2) is optional: an unavailable module or a failing read is
  # `:unavailable`, which no detector reports on.
  defp memory_count(project_id, ctx) do
    module = ForemanServer.ProjectMemory

    if Code.ensure_loaded?(module) and function_exported?(module, :list, 1) do
      case ctx.probe.call(fn -> apply(module, :list, [project_id]) end, ctx.timeout) do
        {:ok, {:ok, entries}} when is_list(entries) -> length(entries)
        {:ok, entries} when is_list(entries) -> length(entries)
        _ -> :unavailable
      end
    else
      :unavailable
    end
  end

  defp within_deadline(ctx) do
    if System.monotonic_time(:millisecond) < ctx.deadline, do: :ok, else: :timeout
  end
end
