defmodule ForemanServer.Workflow.RunRepoRequest do
  @moduledoc """
  The `run.repo.request` decision procedure (E12 S10, S3 §12): a thread asks to
  add a repository to its OWN run. System-authored (dispatched through
  `CommandGateway.dispatch_system/2`; never an operator command, never merge or
  approve).

  Policy lives in the project and is operator-edited only (`project.update`):
  `repo_allowlist` (absolute path prefixes; EMPTY = feature off) and
  `max_repos_per_run` (default 4). For EVERY request, in this order:

    1. The run must exist and not be terminal.
    2. The target is resolved to a canonical `realpath` (the registered path
       for a `repo_id`), so a symlink cannot escape the allowlist.
    3. The canonical path must be inside the allowlist (`/`-bounded prefixes:
       `/srv/repos` does not match `/srv/repos-evil`). An empty allowlist
       therefore denies registered repositories too.
    4. A target already attached to the run (its primary, a planned extra, or a
       created worktree) succeeds idempotently, BEFORE the cap check.
    5. A new attachment must fit `max_repos_per_run`, counting the run's
       primary plus every extra, and must pass the multi-repo run gate
       (`RunRepoSet.runs_enabled?/0`; attaching makes the run multi-repo, so it
       is refused as `:multi_repo_runs_disabled` while the gate is closed).
    6. An unregistered path must be a git work tree whose remote is not another
       repository's (`RepoValidation.check_candidate/2`); it is registered by a
       system `project.repo.add` (`added_by: "run:<id>"`).
    7. `Workflow.RepoAttach` creates the worktree (effective the NEXT phase).

  Every outcome, allowed or denied, appends one `RunRepoRequested` audit event
  to `run_repo_audit:<run_id>` with the deterministic command id
  `run-repo-audit:<request command id>`: a retry of the same request stays
  idempotent, a later request for the same path audits itself.
  """

  alias ForemanServer.Aggregates.RunRepoAudit
  alias ForemanServer.CommandGateway
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Projects.RepoValidation
  alias ForemanServer.Workflow.{RepoAttach, RunRepoSet}

  require Logger

  @type result :: {:ok, map()} | {:error, term()}

  @doc """
  Runs one request. `command` is `%{command_id: id, payload: %{run_id: id,
  repo_id: id | repo_path: path, requested_by: who}}` (atom or string keys in
  the payload). Returns `{:ok, %{run_id, repo_id, status, effective}}` or the
  typed denial (`{:repo_not_allowed, path}`, `{:max_repos_exceeded, max}`,
  `{:unknown_repo, id}`, a `RepoValidation` error, ...).
  """
  @spec execute(map()) :: result()
  def execute(%{command_id: command_id, payload: payload}) when is_map(payload) do
    run_id = field(payload, :run_id)

    with {:ok, run_id} <- require_binary(run_id, :run_id),
         {:ok, target} <- target(payload),
         {:ok, run} <- fetch_run(run_id) do
      ctx = %{
        run_id: run_id,
        run: run,
        project_id: run.project_id,
        repos: ProjectionStore.project_repositories(run.project_id) || [],
        requested_by: field(payload, :requested_by) || "run:" <> run_id
      }

      outcome = decide(ctx, target)
      audit(ctx, command_id, target, outcome)
      reply(run_id, outcome)
    end
  end

  def execute(_command), do: {:error, {:invalid_envelope, :run_repo_request}}

  # --- decision ----------------------------------------------------------------

  # `{:allowed, repo_id, path, status}` | `{:denied, error, reason, repo_id | nil, path}`
  defp decide(ctx, target) do
    with :ok <- require_live(ctx),
         {:ok, resolved} <- resolve(ctx, target),
         :ok <- check_allowlist(ctx, resolved) do
      case resolved.repo do
        %{id: id} -> decide_registered(ctx, resolved, id)
        nil -> decide_unregistered(ctx, resolved)
      end
    end
  end

  defp decide_registered(ctx, resolved, repo_id) do
    if repo_id in attached_ids(ctx) do
      {:allowed, repo_id, resolved.path, "already_attached"}
    else
      with :ok <- check_new_attachment(ctx, resolved) do
        attach(ctx, repo_id, resolved.path, "attached")
      end
    end
  end

  defp decide_unregistered(ctx, resolved) do
    with :ok <- check_new_attachment(ctx, resolved),
         {:ok, info} <- check_candidate(resolved, ctx),
         {:ok, repo_id} <- register(ctx, info.path) do
      attach(ctx, repo_id, info.path, "registered_and_attached")
    end
  end

  defp require_live(%{run: run, run_id: run_id}) do
    if Map.get(run, :terminal?) == true,
      do: denied({:run_terminal, run_id}, "run_terminal", nil, "run:" <> run_id),
      else: :ok
  end

  defp resolve(ctx, {:repo_id, id}) do
    case Enum.find(ctx.repos, &(&1.id == id)) do
      nil -> denied({:unknown_repo, id}, "unknown_repo", nil, "repo:" <> id)
      repo -> canonical(repo.path, repo, repo.path)
    end
  end

  defp resolve(ctx, {:repo_path, path}) do
    with true <-
           absolute?(path) || denied({:repo_not_allowed, path}, "path_not_absolute", nil, path),
         {:ok, real} <- RepoValidation.canonical_path(path) do
      {:ok, %{path: real, repo: registered_at(ctx.repos, real), requested: path}}
    else
      {:error, {:denied, _, _, _, _}} = denial -> denial
      {:error, _} -> denied({:repo_not_allowed, path}, "path_unresolvable", nil, path)
    end
  end

  defp canonical(path, repo, requested) do
    case RepoValidation.canonical_path(path) do
      {:ok, real} ->
        {:ok, %{path: real, repo: repo, requested: requested}}

      {:error, _} ->
        denied({:repo_not_allowed, requested}, "path_unresolvable", repo.id, requested)
    end
  end

  defp registered_at(repos, real) do
    Enum.find(repos, fn %{path: path} ->
      case RepoValidation.canonical_path(path) do
        {:ok, canonical} -> canonical == real
        _ -> path == real
      end
    end)
  end

  defp check_allowlist(ctx, resolved) do
    repo_id = resolved.repo && resolved.repo.id

    case allowlist(ctx.project_id) do
      [] ->
        denied(
          {:repo_not_allowed, resolved.requested},
          "allowlist_empty",
          repo_id,
          resolved.requested
        )

      entries ->
        if Enum.any?(entries, &within?(resolved.path, &1)),
          do: :ok,
          else:
            denied(
              {:repo_not_allowed, resolved.requested},
              "not_in_allowlist",
              repo_id,
              resolved.requested
            )
    end
  end

  defp allowlist(project_id) do
    case ProjectionStore.project_settings(project_id) do
      %ForemanServer.ProjectSettings{repo_allowlist: entries} when is_list(entries) ->
        entries
        |> Enum.filter(&(is_binary(&1) and &1 != ""))
        |> Enum.map(&canonical_entry/1)

      _ ->
        []
    end
  end

  # An entry that is itself a symlink (macOS `/tmp`) is compared by its real
  # target, because candidates are canonical.
  defp canonical_entry(entry) do
    case RepoValidation.canonical_path(entry) do
      {:ok, real} -> real
      {:error, _} -> Path.expand(entry)
    end
  end

  defp within?(path, entry) do
    root = String.trim_trailing(entry, "/")
    path == root or String.starts_with?(path, root <> "/")
  end

  # The run's repositories: its effective primary, the extras its task/run
  # planned, and every created worktree. The primary counts toward the cap.
  defp attached_ids(ctx) do
    request = run_request(ctx)
    project_primary = ctx.repos |> Enum.find(& &1.primary) |> then(&(&1 && &1.id))
    primary = non_empty(Map.get(request, :repo_id)) || project_primary
    planned = List.wrap(Map.get(request, :repo_ids))

    created =
      for %{repo_id: repo_id, status: "created"} <- ProjectionStore.worktrees_for_run(ctx.run_id),
          is_binary(repo_id),
          do: repo_id

    Enum.uniq(Enum.reject([primary | planned ++ created], &is_nil/1))
  end

  defp run_request(ctx) do
    source =
      case ProjectionStore.tasks_by_run_id(ctx.run_id) do
        [task | _] -> task
        [] -> ctx.run
      end

    %{repo_id: Map.get(source, :repo_id), repo_ids: Map.get(source, :repo_ids)}
  end

  defp non_empty(value) when is_binary(value) and value != "", do: value
  defp non_empty(_), do: nil

  # A new attachment makes the run multi-repo, so it is held to the same
  # run-start gate (`RunRepoSet.gate/1`): a thread cannot widen a run past what
  # an operator-started run may be until multi-repo runs are released.
  defp check_new_attachment(ctx, resolved) do
    with :ok <- check_cap(ctx, resolved) do
      if not RunRepoSet.runs_enabled?(),
        do:
          denied(
            :multi_repo_runs_disabled,
            "multi_repo_runs_disabled",
            resolved.repo && resolved.repo.id,
            resolved.path
          ),
        else: :ok
    end
  end

  defp check_cap(ctx, resolved) do
    max = RunRepoSet.cap(ctx.project_id)

    if length(attached_ids(ctx)) + 1 > max,
      do:
        denied(
          {:max_repos_exceeded, max},
          "max_repos_exceeded",
          resolved.repo && resolved.repo.id,
          resolved.path
        ),
      else: :ok
  end

  defp check_candidate(resolved, ctx) do
    case RepoValidation.check_candidate(resolved.path, ctx.repos) do
      {:ok, info} ->
        {:ok, info}

      {:error, error} ->
        denied(error, reason_code(error), nil, resolved.requested)
    end
  end

  # System `project.repo.add`, `added_by: "run:<id>"`. The command id is
  # deterministic per (run, canonical path), the repo id per path, so a retry
  # can never register twice.
  defp register(ctx, path) do
    repo_id = new_repo_id(path, ctx.repos)

    result =
      CommandGateway.dispatch_system(%{
        type: "project.repo.add",
        command_id: "run-repo-add:#{ctx.run_id}:#{path_digest(path)}",
        aggregate_id: "project:#{ctx.project_id}",
        payload: %{
          project_id: ctx.project_id,
          repo_id: repo_id,
          path: path,
          added_by: "run:" <> ctx.run_id
        }
      })

    case result do
      {:ok, _} -> {:ok, repo_id}
      {:error, reason} -> denied(reason, "register_failed", nil, path)
      {:error, reason, _detail} -> denied(reason, "register_failed", nil, path)
    end
  end

  defp attach(ctx, repo_id, path, status) do
    case RepoAttach.attach(ctx.run_id, repo_id) do
      {:ok, :already_attached} when status == "attached" ->
        {:allowed, repo_id, path, "already_attached"}

      {:ok, _} ->
        {:allowed, repo_id, path, status}

      {:error, reason} ->
        denied(reason, "attach_failed", repo_id, path)
    end
  end

  # --- repo id -----------------------------------------------------------------

  defp new_repo_id(path, repos) do
    taken = MapSet.new(["main" | Enum.map(repos, & &1.id)])
    base = slug(Path.basename(path))

    Stream.concat([base], Stream.map(2..1000, &suffixed(base, &1)))
    |> Enum.find(&(not MapSet.member?(taken, &1)))
  end

  defp suffixed(base, n) do
    suffix = "-" <> Integer.to_string(n)
    String.slice(base, 0, 32 - String.length(suffix)) <> suffix
  end

  defp slug(name) do
    cleaned =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9-]+/, "-")
      |> String.trim("-")
      |> String.slice(0, 32)
      |> String.trim("-")

    if cleaned == "", do: "repo", else: cleaned
  end

  defp path_digest(path),
    do: :crypto.hash(:sha256, path) |> Base.encode16(case: :lower) |> binary_part(0, 12)

  # --- audit and reply -----------------------------------------------------------

  defp audit(ctx, command_id, target, outcome) do
    {decision, reason, repo_id, path} =
      case outcome do
        {:allowed, repo_id, path, status} -> {"allowed", status, repo_id, path}
        {:error, {:denied, _error, reason, repo_id, path}} -> {"denied", reason, repo_id, path}
      end

    result =
      CommandGateway.dispatch_system(%{
        type: "run.repo.audit.record",
        command_id: "run-repo-audit:" <> command_id,
        aggregate_id: RunRepoAudit.stream_id(ctx.run_id),
        payload: %{
          run_id: ctx.run_id,
          project_id: ctx.project_id,
          requested_path: path || target_label(target),
          repo_id: repo_id,
          decision: decision,
          reason: reason,
          requested_by: ctx.requested_by
        }
      })

    case result do
      {:ok, _} ->
        :ok

      other ->
        Logger.error(
          "run repo request audit write failed for #{ctx.run_id} (#{decision}/#{reason}): #{inspect(other)}"
        )
    end
  end

  defp target_label({:repo_id, id}), do: "repo:" <> id
  defp target_label({:repo_path, path}), do: path

  defp reply(run_id, {:allowed, repo_id, _path, status}) do
    {:ok, %{run_id: run_id, repo_id: repo_id, status: status, effective: "next_phase"}}
  end

  defp reply(_run_id, {:error, {:denied, error, _reason, _repo_id, _path}}), do: {:error, error}

  # `with` falls through on `{:error, _}`; a denial is always this tagged shape.
  defp denied(error, reason, repo_id, path),
    do: {:error, {:denied, error, reason, repo_id, path}}

  defp reason_code({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_code({tag, _, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_code(tag) when is_atom(tag), do: Atom.to_string(tag)
  defp reason_code(_), do: "invalid"

  # --- input -------------------------------------------------------------------

  defp target(payload) do
    case {field(payload, :repo_id), field(payload, :repo_path)} do
      {id, _} when is_binary(id) and id != "" -> {:ok, {:repo_id, id}}
      {_, path} when is_binary(path) and path != "" -> {:ok, {:repo_path, path}}
      _ -> {:error, :repo_id_or_repo_path_required}
    end
  end

  defp fetch_run(run_id) do
    case ProjectionStore.run(run_id) do
      %{project_id: project_id} = run when is_binary(project_id) -> {:ok, run}
      _ -> {:error, {:not_found, :run, run_id}}
    end
  end

  defp require_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp require_binary(value, key), do: {:error, {:missing_or_invalid, key, value}}

  defp absolute?(path), do: Path.type(path) == :absolute

  defp field(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
