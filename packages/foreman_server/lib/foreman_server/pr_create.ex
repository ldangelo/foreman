defmodule ForemanServer.PrCreate do
  @moduledoc """
  The real pull request behind the operator command `run.pr.create` (E9-S5): "Create
  PR" for a thread whose run pushed (or can push) a branch but never proposed it.

  Like `ForemanServer.RunPrMerge`, the external effect (`git push`, `gh pr create`)
  runs BEFORE the command is dispatched - `CommandGateway.dispatch_operator/1` calls
  `execute/1` - and never inside the `Run` aggregate, which the actor re-runs on a
  version conflict (a second `gh pr create`). It reuses `ForemanServer.Workflow.AutoPR`
  unchanged: the same push, the same task-derived title/body and the same
  "commits ahead of the base" rule that the automatic path applies.

  The branch is the run's own worktree branch (`WorktreeCreated`, the last one), the
  base the run's recorded base branch, and `gh`/`git` run from the project checkout
  (the run worktree is gone once the run is terminal). Refusals are typed:
  `{:run_not_found, id}`, `{:unsupported_subject, :jobsite}` (a jobsite thread has no
  run stream; spike E9-SP1), `{:pr_already_associated, url}`, `:no_head_branch`,
  `:no_base_branch`, `:no_commits_to_propose`, `{:project_unresolved, id}` and AutoPR's
  own errors. A PR that already exists for the branch (a retry after the association
  write failed) is adopted, not duplicated; an association whose `PrCreated` was never
  recorded (the dispatch after `execute/1` failed) is resumed by the retry, not refused.

  `set_command_runner/1` is the test seam (3-arity `(cmd, args, opts)` returning
  `{output, exit_code}`); without it the installed `git`/`gh` run.
  """

  alias ForemanServer.{EventStore, PrAssociate, ProjectionStore}
  alias ForemanServer.Workflow.AutoPR

  @runner_key {__MODULE__, :command_runner}

  @type payload :: %{
          run_id: String.t(),
          project_id: String.t(),
          task_id: String.t(),
          pr_url: String.t(),
          head_branch: String.t(),
          base_branch: String.t()
        }

  @doc "Route the `git`/`gh` calls of this module through `fun` (a 3-arity command runner)."
  @spec set_command_runner((String.t(), [String.t()], keyword() -> {String.t(), integer()})) ::
          :ok
  def set_command_runner(fun) when is_function(fun, 3) do
    :persistent_term.put(@runner_key, fun)
  end

  @doc "Remove the runner installed by `set_command_runner/1`."
  @spec clear_command_runner() :: boolean()
  def clear_command_runner, do: :persistent_term.erase(@runner_key)

  @doc """
  Open the PR for `run_id` and associate it with the run. Concurrent calls for one run
  are serialised, so the second observes the first's association.
  """
  @spec execute(term()) :: {:ok, payload()} | {:error, term()}
  def execute(run_id) when is_binary(run_id) and run_id != "" do
    :global.trans({{__MODULE__, run_id}, self()}, fn -> create(run_id) end)
  end

  def execute(_run_id), do: {:error, {:missing_or_invalid, :run_id}}

  defp create(run_id) do
    with {:ok, run} <- fetch_run(run_id),
         {:ok, existing} <- existing_pr(run_id),
         {:ok, head} <- head_branch(run_id),
         {:ok, base} <- base_branch(run),
         {:ok, pr_url} <- open_or_resume(run, run_id, existing, head, base) do
      {:ok,
       %{
         run_id: run_id,
         project_id: run.project_id,
         task_id: run.task_id,
         pr_url: pr_url,
         head_branch: head,
         base_branch: base
       }}
    end
  end

  defp open_or_resume(_run, _run_id, existing, _head, _base) when is_binary(existing),
    do: {:ok, existing}

  defp open_or_resume(run, run_id, nil, head, base) do
    with {:ok, project} <- project(run),
         {:ok, pr_url} <- open(run, project, head, base),
         {:ok, _id} <- PrAssociate.store(run_id, pr_url) do
      {:ok, pr_url}
    end
  end

  defp fetch_run(run_id) do
    case ProjectionStore.run(run_id) do
      %{project_id: p, task_id: t} = run when is_binary(p) and is_binary(t) -> {:ok, run}
      _ -> missing_run(run_id)
    end
  end

  defp missing_run("jobsite:" <> _ = id), do: {:error, {:unsupported_subject, :jobsite, id}}
  defp missing_run(run_id), do: {:error, {:run_not_found, run_id}}

  # The association is written before `run.pr.create` is dispatched. When that dispatch
  # failed, a retry finds the association but no `PrCreated` on the run stream: the PR
  # is already open, so resume with it (nothing is opened twice) and let the retry
  # record the missing fact. With `PrCreated` recorded, the PR was created: refuse.
  defp existing_pr(run_id) do
    case ProjectionStore.pr_association(run_id) do
      {:error, :not_found} ->
        {:ok, nil}

      {:ok, %{pr_url: url}} ->
        case created_recorded?(run_id, url) do
          {:ok, true} -> {:error, {:pr_already_associated, url}}
          {:ok, false} -> {:ok, url}
          {:error, _reason} = error -> error
        end
    end
  end

  defp created_recorded?(run_id, pr_url) do
    with {:ok, events} <- EventStore.read_stream_forward("run:#{run_id}", 0, 99_999_999) do
      {:ok,
       Enum.any?(events, fn event ->
         event.event_type == "PrCreated" and Map.get(event.data, :pr_url) == pr_url
       end)}
    end
  end

  defp head_branch(run_id) do
    case run_id |> ProjectionStore.worktrees_for_run() |> List.last() do
      %{branch: branch} when is_binary(branch) and branch != "" -> {:ok, branch}
      _ -> {:error, :no_head_branch}
    end
  end

  defp base_branch(%{base_branch: base}) when is_binary(base) and base != "", do: {:ok, base}
  defp base_branch(_run), do: {:error, :no_base_branch}

  defp project(%{project_id: project_id}) do
    case ProjectionStore.project_projection(project_id) do
      %{path: path} when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, {:project_unresolved, project_id}}
    end
  end

  defp open(run, repo_path, head, base) do
    context =
      %{run_id: run.run_id, base_branch: base, head_branch: head, cwd: repo_path}
      |> put_task_fields(run.task_id)
      |> put_runner()

    case AutoPR.maybe_create_pr(context) do
      {:ok, pr_url} -> {:ok, pr_url}
      :noop -> {:error, :no_commits_to_propose}
      {:error, {:gh_pr_create_failed, _code, output} = error} -> adopt_existing(output, error)
      {:error, _} = error -> error
    end
  end

  # `gh` answers "a pull request for branch X already exists: <url>" when a previous
  # attempt opened it but the association was never recorded.
  defp adopt_existing(output, error) do
    with true <- String.contains?(output, "already exists"),
         [url] <- Regex.run(~r{https://\S+/pull/\d+}, output) do
      {:ok, url}
    else
      _ -> {:error, error}
    end
  end

  defp put_task_fields(context, task_id) do
    case ProjectionStore.task_projection(task_id) do
      %{} = task ->
        context
        |> put_present(:task_title, task[:title])
        |> put_present(:task_description, task[:description])

      _ ->
        context
    end
  end

  defp put_runner(context) do
    case :persistent_term.get(@runner_key, :unset) do
      :unset -> context
      fun -> Map.put(context, :command_runner, fun)
    end
  end

  defp put_present(map, _key, nil), do: map
  defp put_present(map, _key, ""), do: map
  defp put_present(map, key, value), do: Map.put(map, key, value)
end
