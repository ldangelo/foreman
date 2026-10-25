defmodule ForemanServer.Projects.AdoptionService do
  @moduledoc """
  Facade over the three ways a session enters a project:

    * `adopt/4` - MOVE a task/run/jobsite (and its session archive) from its
      project into another one (`project.adopt`, mode `move`).
    * `continue/5` - start a NEW thread in a project that continues a session,
      leaving the original untouched (`task.create` + `project.adopt`, mode
      `continue`). The new thread's prompt is seeded from the session archive;
      the provider session itself is NOT forked (no run-start path carries a
      fork id), so the result is always context-seeded.
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
  alias ForemanServer.Projects.{Adoption, AdoptionResult, Continuation}
  alias ForemanServer.Review.Archive

  @kinds ~w(task run jobsite)
  @goal_chars 200

  @type error :: {:error, term()} | {:error, term(), term()}

  @doc "Move `kind`/`subject_id` into `target`. See `ForemanServer.Projects.Adoption` for refusals."
  @spec adopt(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, AdoptionResult.t()} | error()
  def adopt(kind, subject_id, target, _opts \\ [])
      when is_binary(kind) and is_binary(subject_id) and is_binary(target) do
    payload = %{project_id: target, subject_kind: kind, subject_id: subject_id, mode: "move"}

    with {:ok, facts} <- Adoption.resolve(payload),
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
  Continue `kind`/`subject_id` as a new thread in `target`, seeded from the
  session archive plus the operator's `text`. Allowed while the source runs.
  """
  @spec continue(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, AdoptionResult.t()} | error()
  def continue(kind, subject_id, target, text, _opts \\ [])
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
         {:ok, _event} <- create_thread(target, new_task_id, kind, subject_id, facts, text),
         {:ok, event} <- dispatch_adopt(payload) do
      {:ok,
       %AdoptionResult{
         mode: "continue",
         subject_kind: kind,
         subject_id: subject_id,
         project_id: target,
         from_project_id: facts.from_project_id,
         adopted?: not is_nil(event),
         new_task_id: new_task_id,
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

  defp create_thread(target, new_task_id, kind, subject_id, facts, text) do
    fallback = fallback_request(kind, subject_id)
    archive_dir = Enum.find(facts.archive_paths, &String.contains?(&1, "/#{kind}/#{subject_id}"))
    archive_dir = archive_dir || List.first(facts.archive_paths)
    %{prompt: prompt} = Continuation.build(archive_dir, text, fallback)

    CommandGateway.dispatch_operator(%{
      command_id: "adopt-continue-task:#{new_task_id}",
      aggregate_id: "task:" <> new_task_id,
      type: "task.create",
      payload: %{
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
      }
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
