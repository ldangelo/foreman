defmodule ForemanServerWeb.AdoptionController do
  @moduledoc """
  `POST /api/project-adoptions` - bring a session into a project.

  Body (string keys): `subject_kind` (`task|run|jobsite`), `subject_id`, and

    * `mode: "move"` (default) with `target_project_id` - re-home the session.
      `add_repo: true` first attaches the session's repository to the target when the
      target does not have it (`project.repo.add`, the command behind
      `foreman project repo add`; its typed refusals are returned as they are, and the
      move is then not attempted) instead of refusing `repo_not_in_project`;
    * `mode: "continue"` with `target_project_id` and `prompt` - start a new
      thread that continues it (the original is untouched). `fork: true` makes
      the thread fork the session's provider session (the agent remembers the
      conversation) instead of seeding the prompt from the archive; it is
      refused with a typed 422 (`fork_no_session`, `fork_provider_unsupported`,
      `fork_provider_mismatch`), never degraded, when it cannot be honoured. The
      response `mode` is `forked` or `context_seeded`. `from_source_branch: true`
      (with or without `fork`) cuts the thread's worktree from the BRANCH of the
      session instead of the project's current branch, and that branch is the
      thread's PR base; it is refused with a typed 422 (`source_branch_unknown`,
      `source_branch_not_found`, `source_branch_needs_worktree`), never degraded to
      the current branch. The response `source_branch` names the branch;
    * `mode: "mint"` with optional `new_project: {id, path, goal, name}` - create
      a project from the session archive manifest and move the session into it.

  The options are boolean when present and each is valid for one mode only: `fork`
  and `from_source_branch` with `mode: "continue"`, `add_repo` with `mode: "move"`.

  Not an MCP tool: re-homing work is an operator decision. The response is a
  whitelisted projection of `ForemanServer.Projects.AdoptionResult`.
  """

  use ForemanServerWeb, :controller

  alias ForemanServer.Projects.{AdoptionResult, AdoptionService}

  def create(conn, params) do
    kind = params["subject_kind"]
    id = params["subject_id"]
    mode = params["mode"] || "move"

    with :ok <- require_binary(kind, "subject_kind"),
         :ok <- require_binary(id, "subject_id"),
         {:ok, result} <- run(mode, kind, id, params) do
      conn |> put_status(:created) |> json(%{adoption: dto(result)})
    else
      {:error, :invalid_params, detail} ->
        conn |> put_status(:bad_request) |> json(%{error: "invalid_params", detail: detail})

      {:error, reason} ->
        render_error(conn, reason)

      {:error, reason, detail} ->
        render_error(conn, {reason, detail})
    end
  end

  defp run("move", kind, id, params) do
    with :ok <- reject_flag(params, "fork", "continue", "move"),
         :ok <- reject_flag(params, "from_source_branch", "continue", "move"),
         {:ok, add_repo} <- flag(params, "add_repo"),
         {:ok, target} <- target(params),
         do: AdoptionService.adopt(kind, id, target, add_repo: add_repo)
  end

  defp run("continue", kind, id, params) do
    with {:ok, target} <- target(params),
         :ok <- require_binary(params["prompt"], "prompt"),
         :ok <- reject_flag(params, "add_repo", "move", "continue"),
         {:ok, fork} <- flag(params, "fork"),
         {:ok, from_source_branch} <- flag(params, "from_source_branch") do
      AdoptionService.continue(kind, id, target, params["prompt"],
        fork: fork,
        from_source_branch: from_source_branch
      )
    end
  end

  defp run("mint", kind, id, params) do
    with :ok <- reject_flag(params, "fork", "continue", "mint"),
         :ok <- reject_flag(params, "from_source_branch", "continue", "mint"),
         :ok <- reject_flag(params, "add_repo", "move", "mint") do
      new_project = params["new_project"]

      opts =
        if is_map(new_project) do
          [
            project_id: new_project["id"],
            path: new_project["path"],
            goal: new_project["goal"],
            name: new_project["name"]
          ]
        else
          []
        end

      AdoptionService.mint(kind, id, opts)
    end
  end

  defp run(mode, _kind, _id, _params),
    do: {:error, :invalid_params, "mode must be move, continue or mint, got #{inspect(mode)}"}

  defp target(params) do
    case require_binary(params["target_project_id"], "target_project_id") do
      :ok -> {:ok, params["target_project_id"]}
      error -> error
    end
  end

  # An option absent is `false`; anything but a boolean is a malformed request, not a "maybe".
  defp flag(params, key) do
    case Map.get(params, key, false) do
      flag when is_boolean(flag) -> {:ok, flag}
      _other -> {:error, :invalid_params, "#{key} must be a boolean"}
    end
  end

  # An option that belongs to one mode: asking for it on another is a mistake to name, not to ignore.
  defp reject_flag(params, key, only_mode, mode) do
    case flag(params, key) do
      {:ok, false} ->
        :ok

      {:ok, true} ->
        {:error, :invalid_params, "#{key} is only valid with mode #{only_mode}, not #{mode}"}

      {:error, _, _} = error ->
        error
    end
  end

  defp require_binary(value, _field) when is_binary(value) and value != "", do: :ok
  defp require_binary(_value, field), do: {:error, :invalid_params, "#{field} is required"}

  defp dto(%AdoptionResult{} = result) do
    %{
      "mode" => result.mode,
      "subject_kind" => result.subject_kind,
      "subject_id" => result.subject_id,
      "project_id" => result.project_id,
      "from_project_id" => result.from_project_id,
      "adopted" => result.adopted?,
      "new_task_id" => result.new_task_id,
      "source_branch" => result.source_branch,
      "minted_project_id" => result.minted_project_id,
      "moved" => %{
        "task_ids" => result.moved.task_ids,
        "run_ids" => result.moved.run_ids,
        "jobsite_ids" => result.moved.jobsite_ids
      },
      "archive_updates" =>
        Enum.map(result.archive_updates, fn %{path: path, status: status} ->
          %{"path" => path, "status" => Atom.to_string(status)}
        end)
    }
  end

  defp render_error(conn, reason) do
    {code, status} = classify(reason)

    conn
    |> put_status(status)
    |> json(%{error: code, detail: inspect(reason)})
  end

  defp classify({tag, _} = _reason) when tag in [:project_not_found],
    do: {"project_not_found", :not_found}

  defp classify({:subject_not_found, _, _}), do: {"subject_not_found", :not_found}
  defp classify({tag, _}) when is_atom(tag), do: {Atom.to_string(tag), :unprocessable_entity}
  defp classify({tag, _, _}) when is_atom(tag), do: {Atom.to_string(tag), :unprocessable_entity}

  defp classify({{tag, _} = _inner, _detail}) when is_atom(tag),
    do: {Atom.to_string(tag), :unprocessable_entity}

  defp classify(tag) when is_atom(tag), do: {Atom.to_string(tag), :unprocessable_entity}
  defp classify(_other), do: {"adoption_failed", :unprocessable_entity}
end
