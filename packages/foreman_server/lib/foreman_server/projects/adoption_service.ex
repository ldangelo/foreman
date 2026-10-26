defmodule ForemanServer.Projects.AdoptionService do
  @moduledoc """
  Facade over the three ways a session enters a project:

    * `adopt/4` - MOVE a task/run/jobsite (and its session archive) from its
      project into another one (`project.adopt`, mode `move`). With
      `add_repo: true` a session whose repository the target does not have yet
      gets it attached first (`project.repo.add`, the command behind
      `foreman project repo add`).
    * `continue/5` - start a NEW thread in a project that continues a session,
      leaving the original untouched (`task.create` + `project.adopt`, mode
      `continue`). Two strategies, recorded as the result's `mode`:
      `"context_seeded"` (default: the new thread's prompt is built from the
      session archive and it starts a fresh provider session) and `"forked"`
      (`fork: true`: the first phase of the new thread starts from a FORK of the
      source's provider session, so the agent remembers the conversation; see
      `ForemanServer.Projects.ForkSource`). With `from_source_branch: true` (either
      strategy) the new thread's worktree is cut from the BRANCH of the session
      instead of the project's current branch (`ForemanServer.Projects.SourceBranch`).
    * `mint/3` - create a NEW project from the session's archive manifest and
      move the session into it.

  Every step dispatches through `CommandGateway.dispatch_operator/1` so the
  same aggregates, guards and enrichment apply as for an HTTP caller. Each
  command id is unique per call except the mint steps, which are deterministic
  so a crashed mint is repaired by re-running it.

  Archive manifest sync is best effort and idempotent: a missing archive is
  `:missing`, a failed write is `:failed` (logged); neither fails the adoption.
  """

  require Logger

  alias ForemanServer.{CommandGateway, ProjectionStore}

  alias ForemanServer.Projects.{
    Adoption,
    AdoptionResult,
    Continuation,
    ForkSource,
    RepoValidation,
    SourceBranch
  }

  alias ForemanServer.Review.Archive
  alias ForemanServer.Workflow.{Catalog, PhaseSpec, WorktreeSpec}

  @kinds ~w(task run jobsite)
  @goal_chars 200

  @type error :: {:error, term()} | {:error, term(), term()}

  @doc """
  Move `kind`/`subject_id` into `target`. See `ForemanServer.Projects.Adoption` for refusals.

  Options: `:add_repo` (boolean, default `false`). A session whose repository is not one of
  the target's repositories is refused `{:repo_not_in_project, repo_path}`; with
  `add_repo: true` that repository is attached to the target first, through the operator
  command `project.repo.add` (so its realpath, git work tree and remote-identity checks and
  typed errors apply, and the move is then not attempted when it is refused). A repository
  the target already has is not added again, and a move refused for another reason that is
  known before the attach (an active session, a paused target) attaches nothing.
  """
  @spec adopt(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, AdoptionResult.t()} | error()
  def adopt(kind, subject_id, target, opts \\ [])
      when is_binary(kind) and is_binary(subject_id) and is_binary(target) and is_list(opts) do
    payload = %{project_id: target, subject_kind: kind, subject_id: subject_id, mode: "move"}

    with {:ok, facts} <- resolve_move(payload, flag!(opts, :add_repo, "adopt/4")),
         {:ok, event} <- dispatch_adopt(payload) do
      from = source_project(kind, subject_id, facts.from_project_id)

      {:ok,
       %AdoptionResult{
         mode: "move",
         subject_kind: kind,
         subject_id: subject_id,
         project_id: target,
         from_project_id: from,
         adopted?: not is_nil(event),
         moved: facts.moved,
         archive_updates: sync_archives(facts.archive_paths, target, from, "move")
       }}
    end
  end

  @doc """
  Continue `kind`/`subject_id` as a new thread in `target`, with the operator's
  `text`. Allowed while the source runs; the source is never written to.

  Options: `:fork` (boolean, default `false`). With `fork: true` the thread
  forks the source's provider session (`ForkSource`) instead of being seeded
  from the archive, and the call is refused rather than degraded when it cannot
  be honoured: `{:fork_no_session, kind, id}`, `{:fork_provider_unsupported, p}`,
  `{:fork_provider_mismatch, session_provider, first_phase_provider}`.

  `:from_source_branch` (boolean, default `false`). With `from_source_branch: true`
  the thread's worktree is cut from the branch of the session being continued
  (`SourceBranch`; a run's primary worktree branch, a task's latest run, a
  jobsite's branch) and that branch is the thread's PR base, instead of the
  project's current branch. Refused, never degraded to the current branch:
  `{:source_branch_unknown, kind, id}`, `{:source_branch_not_found, branch,
  repo_path}` (not a local branch of the target's repository),
  `{:source_branch_needs_worktree, branch}` (the workflow runs without a worktree).
  """
  @spec continue(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, AdoptionResult.t()} | error()
  def continue(kind, subject_id, target, text, opts \\ [])
      when is_binary(kind) and is_binary(subject_id) and is_binary(target) and is_binary(text) do
    new_task_id = "continue-" <> Ecto.UUID.generate()

    payload = %{
      project_id: target,
      subject_kind: kind,
      subject_id: subject_id,
      mode: "continue",
      new_task_id: new_task_id
    }

    with {:ok, facts} <- Adoption.resolve(payload),
         {:ok, _} <- require_text(text),
         {:ok, fork} <- resolve_fork(flag!(opts, :fork, "continue/5"), kind, subject_id),
         {:ok, source_branch} <-
           resolve_source_branch(
             flag!(opts, :from_source_branch, "continue/5"),
             kind,
             subject_id,
             target
           ),
         {:ok, _event} <-
           create_thread(target, new_task_id, kind, subject_id, facts, text, fork, source_branch),
         {:ok, event} <- dispatch_adopt(payload) do
      {:ok,
       %AdoptionResult{
         mode: if(fork, do: "forked", else: "context_seeded"),
         subject_kind: kind,
         subject_id: subject_id,
         project_id: target,
         from_project_id: facts.from_project_id,
         adopted?: not is_nil(event),
         new_task_id: new_task_id,
         source_branch: source_branch,
         moved: %{task_ids: [new_task_id], run_ids: [], jobsite_ids: []}
       }}
    end
  end

  @doc """
  Mint a project from the session's archive manifest and move the session into
  it. Options: `:project_id`, `:path` (required when no repo is discoverable),
  `:goal`, `:name`.

  Steps are `project.register` (carrying the goal) then `project.adopt`, each
  with a deterministic command id, so re-running a half-finished mint repairs it.
  """
  @spec mint(String.t(), String.t(), keyword()) :: {:ok, AdoptionResult.t()} | error()
  def mint(kind, subject_id, opts \\ [])
      when is_binary(kind) and is_binary(subject_id) and is_list(opts) do
    with :ok <- require_kind(kind),
         {:ok, facts} <- Adoption.facts(kind, subject_id),
         manifest = manifest_for(facts, kind, subject_id),
         {:ok, path} <- mint_path(opts, manifest, facts),
         :ok <- require_git_working_tree(path),
         :ok <- require_session_repo(facts, path),
         {:ok, project_id, step} <- resolve_mint_project(opts, path),
         {:ok, _} <- register_minted(step, project_id, path, kind, subject_id, opts, manifest),
         {:ok, result} <- adopt_minted(kind, subject_id, project_id) do
      {:ok, %AdoptionResult{result | mode: "mint", minted_project_id: project_id}}
    end
  end

  # -- adopt ------------------------------------------------------------------

  defp dispatch_adopt(%{mode: mode} = payload) do
    command_id =
      case mode do
        "move" ->
          "adopt:#{payload.subject_kind}:#{payload.subject_id}:#{payload.project_id}:" <>
            Ecto.UUID.generate()

        "continue" ->
          "adopt-continue:#{payload.new_task_id}"
      end

    CommandGateway.dispatch_operator(%{
      command_id: command_id,
      aggregate_id: "project:" <> payload.project_id,
      type: "project.adopt",
      payload: payload
    })
    |> normalize_dispatch()
  end

  defp normalize_dispatch({:ok, event}), do: {:ok, event}
  defp normalize_dispatch({:error, _} = error), do: error
  defp normalize_dispatch({:error, _, _} = error), do: error

  # `add_repo: true`: the session's repository, when the target does not have it yet, is attached to
  # the target first and the move is then resolved again. Only that one refusal turns into an attach;
  # every other refusal stands. The option is deliberately NOT part of the `project.adopt` command
  # (a caller of `POST /api/commands` cannot skip the repository check by claiming it): the check
  # in `Adoption.resolve/1` stays strict.
  defp resolve_move(payload, false), do: Adoption.resolve(payload)

  defp resolve_move(%{project_id: target, subject_kind: kind, subject_id: id} = payload, true) do
    case Adoption.resolve(payload) do
      {:error, {:repo_not_in_project, repo_path}} ->
        with :ok <- check_attachable(kind, id, target),
             {:ok, _event} <- attach_repo(target, repo_path, kind, id) do
          Adoption.resolve(payload)
        end

      resolved ->
        resolved
    end
  end

  # Attaching a repository changes the target's configuration, so it must not be left behind by a
  # move refused for a reason already known here. The aggregate stays the authority and re-checks both.
  defp check_attachable(kind, id, target) do
    with {:ok, %{active?: active?, status: status}} <- Adoption.facts(kind, id) do
      cond do
        active? ->
          {:error, {:subject_active, status}}

        match?(%{status: "paused"}, ProjectionStore.project(target)) ->
          {:error, {:project_paused, target}}

        true ->
          :ok
      end
    end
  end

  # The operator command behind `foreman project repo add`: `CommandGateway` canonicalises the path
  # and checks it is a git work tree whose origin is not another repository's, and the aggregate
  # checks the id and uniqueness. The id is the directory name (`RepoValidation.id_from_name/1`),
  # made unique among the target's repositories, so the operator never has to name one.
  defp attach_repo(target, repo_path, kind, subject_id) do
    with {:ok, repo_id} <- repo_id_for(target, repo_path) do
      CommandGateway.dispatch_operator(%{
        command_id: "adopt-add-repo:#{target}:" <> Ecto.UUID.generate(),
        aggregate_id: "project:" <> target,
        type: "project.repo.add",
        payload: %{
          project_id: target,
          repo_id: repo_id,
          path: repo_path,
          added_by: "adoption:#{kind}:#{subject_id}"
        }
      })
      |> normalize_dispatch()
    end
  end

  defp repo_id_for(target, repo_path) do
    with {:ok, base} <- RepoValidation.id_from_name(Path.basename(repo_path)) do
      taken = Enum.map(ProjectionStore.project_repositories(target) || [], & &1.id)
      candidates = [base | Enum.map(2..99, &suffixed_repo_id(base, &1))]

      case Enum.find(candidates, &(&1 not in taken)) do
        nil -> {:error, {:invalid_repo_name, Path.basename(repo_path)}}
        id -> {:ok, id}
      end
    end
  end

  defp suffixed_repo_id(base, n) do
    suffix = "-#{n}"
    String.slice(base, 0, 32 - String.length(suffix)) <> suffix
  end

  # After a move the entity carries `adopted_from`; on an idempotent replay the
  # facts already name the target, so the entity is the better source of truth.
  defp source_project(kind, id, fallback) do
    entity =
      case kind do
        "task" -> ProjectionStore.task_projection(id)
        "run" -> ProjectionStore.run(id)
        "jobsite" -> ProjectionStore.jobsite(id)
      end

    (entity && Map.get(entity, :adopted_from)) || fallback
  end

  defp sync_archives(paths, target, from, mode) do
    now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

    Enum.map(paths, fn path ->
      %{path: path, status: sync_archive(path, target, from, mode, now)}
    end)
  end

  defp sync_archive(path, target, from, mode, now) do
    case Archive.read_manifest(path) do
      {:ok, %{"project_id" => ^target}} ->
        :updated

      {:ok, _manifest} ->
        updates = %{
          "project_id" => target,
          "adopted_from" => from,
          "adopted_at" => now,
          "adopted_mode" => mode
        }

        case Archive.merge_manifest(path, updates) do
          :ok ->
            :updated

          {:error, error} ->
            Logger.warning("project adoption: manifest sync failed: #{inspect(error)}")
            :failed
        end

      {:error, %{code: :archive_missing}} ->
        :missing

      {:error, error} ->
        Logger.warning("project adoption: manifest unreadable: #{inspect(error)}")
        :failed
    end
  end

  # -- continue ---------------------------------------------------------------

  defp require_text(text) do
    if String.trim(text) == "", do: {:error, {:missing_or_invalid, :prompt}}, else: {:ok, text}
  end

  # A boolean option of `adopt/4` / `continue/5`: absent is `false`, anything else that is not a
  # boolean is a programming error, not a "maybe".
  defp flag!(opts, key, function) do
    case Keyword.get(opts, key, false) do
      flag when is_boolean(flag) ->
        flag

      other ->
        raise ArgumentError,
              "#{function} option #{inspect(key)} must be a boolean, got: #{inspect(other)}"
    end
  end

  defp resolve_fork(false, _kind, _subject_id), do: {:ok, nil}

  defp resolve_fork(true, kind, subject_id) do
    with {:ok, source} <- ForkSource.resolve(kind, subject_id),
         :ok <- check_workflow_provider(source, fallback_request(kind, subject_id).workflow_type) do
      {:ok, source}
    end
  end

  # A fork continues the source's conversation in the FIRST phase of the new thread, which must run on
  # the session's provider. Refused here, while the operator is still looking at the answer, when the
  # workflow is known and that phase names its provider; `RunExecutor` refuses the launch anyway
  # (`{:fork_provider_mismatch, ..}`). An unresolvable workflow or a phase that leaves its provider to
  # the default is not a refusal here: it is the launch's to decide.
  defp check_workflow_provider(%ForkSource{provider: provider}, workflow_type)
       when is_binary(workflow_type) do
    with {:ok, %{phases: [first | _]}} <- Catalog.load(workflow_type <> ".yaml"),
         declared when is_binary(declared) <- PhaseSpec.fetch(first, :provider),
         true <- declared != provider do
      {:error, {:fork_provider_mismatch, provider, declared}}
    else
      _unresolved_or_matching -> :ok
    end
  end

  defp check_workflow_provider(_source, _workflow_type), do: :ok

  # `from_source_branch`: the branch must be known (`SourceBranch.resolve/2`) and be a local branch of
  # the repository the new worktree is cut in, the target project's own checkout, which is where
  # `RunExecutor` cuts it. Refused here, while the operator is still looking at the answer, never
  # degraded to the project's current branch.
  defp resolve_source_branch(false, _kind, _subject_id, _target), do: {:ok, nil}

  defp resolve_source_branch(true, kind, subject_id, target) do
    with {:ok, branch} <- SourceBranch.resolve(kind, subject_id),
         :ok <- SourceBranch.ensure_exists(branch, project_path(target)),
         :ok <- check_workflow_worktree(branch, fallback_request(kind, subject_id).workflow_type) do
      {:ok, branch}
    end
  end

  defp project_path(project_id) do
    case ProjectionStore.project(project_id) do
      %{path: path} when is_binary(path) -> path
      _no_path -> nil
    end
  end

  # A workflow that declares `worktree: enabled: false` runs in the project's own checkout: there is no
  # worktree to cut from the branch. `RunExecutor` refuses the launch anyway
  # (`{:source_branch_needs_worktree, branch}`); an unresolvable workflow is the launch's to decide.
  defp check_workflow_worktree(branch, workflow_type) when is_binary(workflow_type) do
    with {:ok, workflow} <- Catalog.load(workflow_type <> ".yaml"),
         %{enabled: false} <- WorktreeSpec.normalize(Map.get(workflow, :worktree)) do
      {:error, {:source_branch_needs_worktree, branch}}
    else
      _unresolved_or_enabled -> :ok
    end
  end

  defp check_workflow_worktree(_branch, _workflow_type), do: :ok

  defp create_thread(target, new_task_id, kind, subject_id, facts, text, fork, source_branch) do
    fallback = fallback_request(kind, subject_id)
    archive_dir = Enum.find(facts.archive_paths, &String.contains?(&1, "/#{kind}/#{subject_id}"))
    archive_dir = archive_dir || List.first(facts.archive_paths)

    {prompt, fork_fields} =
      case fork do
        nil ->
          {Continuation.build(archive_dir, text, fallback, source_branch).prompt, %{}}

        %ForkSource{provider: provider, session_id: session_id} ->
          {Continuation.build_fork(archive_dir, text, source_branch),
           %{fork_provider: provider, fork_session_id: session_id}}
      end

    CommandGateway.dispatch_operator(%{
      command_id: "adopt-continue-task:#{new_task_id}",
      aggregate_id: "task:" <> new_task_id,
      type: "task.create",
      payload:
        Map.merge(
          %{
            task_id: new_task_id,
            project_id: target,
            title: "Continue: " <> (fallback.title || subject_id),
            prompt: prompt,
            workflow_type: fallback.workflow_type,
            source: "adoption",
            # Explicit operator command: dispatch the new thread in one round
            # trip, like `run submit` / the MCP task tool. Not an agent approval path.
            auto_approve: true,
            provider_tracked: false
          },
          put_present(fork_fields, :source_branch, source_branch)
        )
    })
    |> normalize_dispatch()
  end

  defp fallback_request("task", id) do
    task = ProjectionStore.task_projection(id) || %{}
    %{title: task[:title], prompt: task[:prompt], workflow_type: task[:workflow_type]}
  end

  defp fallback_request("run", id) do
    run = ProjectionStore.run(id) || %{}
    task = (run[:task_id] && ProjectionStore.task_projection(run.task_id)) || %{}

    %{
      title: task[:title],
      prompt: task[:prompt],
      workflow_type: task[:workflow_type] || run[:workflow_name]
    }
  end

  defp fallback_request("jobsite", id) do
    jobsite = ProjectionStore.jobsite(id) || %{}
    %{title: jobsite[:name] || id, prompt: nil, workflow_type: nil}
  end

  # -- mint -------------------------------------------------------------------

  defp require_kind(kind) when kind in @kinds, do: :ok
  defp require_kind(kind), do: {:error, {:invalid_subject_kind, kind}}

  defp manifest_for(%{archive_paths: paths}, kind, id) do
    dir = Enum.find(paths, &String.ends_with?(&1, "/#{kind}/#{id}")) || List.first(paths)

    case dir && Archive.read_manifest(dir) do
      {:ok, manifest} -> manifest
      _ -> %{}
    end
  end

  defp mint_path(opts, manifest, facts) do
    case opts[:path] || manifest["repo_path"] || facts.repo_path do
      path when is_binary(path) and path != "" -> {:ok, Path.expand(path)}
      _ -> {:error, {:missing_or_invalid, :path}}
    end
  end

  # Registering a project at a different repo than the session's would strand
  # the session: adopt would then refuse it as `repo_not_in_project`.
  defp require_session_repo(%{repo_path: nil}, _path), do: :ok

  defp require_session_repo(%{repo_path: repo}, path) do
    if Path.expand(repo) == path, do: :ok, else: {:error, {:repo_not_in_project, repo}}
  end

  defp require_git_working_tree(path) do
    if File.exists?(Path.join(path, ".git")),
      do: :ok,
      else: {:error, {:path_not_a_git_working_tree, path}}
  end

  # A second project on a path already owned by a live project would split its
  # history; the operator must adopt into the existing project instead. The one
  # exception is repairing a half-finished mint: an explicit `:project_id` that
  # already exists at this very path resumes at the adopt step.
  defp resolve_mint_project(opts, path) do
    owner =
      Enum.find(ProjectionStore.list_projects(), fn project ->
        project[:status] != "archived" and is_binary(project[:path]) and
          Path.expand(project.path) == path
      end)

    case {opts[:project_id], owner} do
      {id, %{project_id: id}} when is_binary(id) -> {:ok, id, :existing}
      {_id, %{project_id: owner_id}} -> {:error, {:path_in_use, owner_id}}
      {nil, nil} -> {:ok, first_free_id(path |> Path.basename() |> slug(), 1), :new}
      {id, nil} when is_binary(id) and id != "" -> new_explicit_id(id)
      {_, nil} -> {:error, {:missing_or_invalid, :project_id}}
    end
  end

  defp new_explicit_id(id) do
    if ProjectionStore.project(id),
      do: {:error, {:already_exists, :project, id}},
      else: {:ok, id, :new}
  end

  defp first_free_id(base, 1) do
    if ProjectionStore.project(base), do: first_free_id(base, 2), else: base
  end

  defp first_free_id(base, n) do
    candidate = "#{base}-#{n}"
    if ProjectionStore.project(candidate), do: first_free_id(base, n + 1), else: candidate
  end

  defp slug(name) do
    slug =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9._-]+/, "-")
      |> String.trim("-")

    if slug == "", do: "project", else: slug
  end

  defp register_minted(:existing, _project_id, _path, _kind, _subject_id, _opts, _manifest),
    do: {:ok, nil}

  defp register_minted(:new, project_id, path, kind, subject_id, opts, manifest) do
    goal = opts[:goal] || derive_goal(manifest)

    payload =
      %{project_id: project_id, path: path}
      |> put_present(:goal, goal)
      |> put_present(:name, opts[:name])

    CommandGateway.dispatch_operator(%{
      command_id: "adopt-mint:#{kind}:#{subject_id}:register",
      aggregate_id: "project:" <> project_id,
      type: "project.register",
      payload: payload
    })
    |> normalize_dispatch()
  end

  defp adopt_minted(kind, subject_id, project_id) do
    payload = %{
      project_id: project_id,
      subject_kind: kind,
      subject_id: subject_id,
      mode: "move"
    }

    with {:ok, facts} <- Adoption.resolve(payload),
         {:ok, event} <- dispatch_adopt(payload) do
      from = source_project(kind, subject_id, facts.from_project_id)

      {:ok,
       %AdoptionResult{
         mode: "move",
         subject_kind: kind,
         subject_id: subject_id,
         project_id: project_id,
         from_project_id: from,
         adopted?: not is_nil(event),
         moved: facts.moved,
         archive_updates: sync_archives(facts.archive_paths, project_id, from, "mint")
       }}
    end
  end

  defp derive_goal(%{"request" => %{"title" => title}}) when is_binary(title) and title != "",
    do: title

  defp derive_goal(%{"request" => %{"prompt" => prompt}}) when is_binary(prompt) and prompt != "",
    do: String.slice(prompt, 0, @goal_chars)

  defp derive_goal(_manifest), do: nil

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
