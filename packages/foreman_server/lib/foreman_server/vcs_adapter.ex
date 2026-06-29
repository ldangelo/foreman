defmodule ForemanServer.VcsAdapter do
  @moduledoc "Event-owned VCS/worktree adapter boundary for Git and Jujutsu backends."

  alias ForemanServer.{EventStore, ProjectionStore}

  @type backend :: :git | :jujutsu
  @type worktree_result :: {:ok, map()} | {:error, term()}

  @spec create_worktree(map()) :: worktree_result()
  def create_worktree(input) when is_map(input) do
    input = atomize_keys(input)

    with {:ok, backend} <- backend(Map.get(input, :backend, :git)),
         {:ok, run_id} <- required_binary(Map.get(input, :run_id), :run_id),
         {:ok, workspace_id} <-
           required_binary(Map.get(input, :workspace_id, run_id), :workspace_id),
         {:ok, project_path} <- required_binary(Map.get(input, :project_path), :project_path),
         {:ok, base_ref} <- required_binary(Map.get(input, :base_ref, "HEAD"), :base_ref) do
      branch = Map.get(input, :branch, "foreman/#{run_id}")

      worktree_path =
        Map.get(input, :worktree_path, Path.join([project_path, ".foreman", "worktrees", run_id]))

      stale = observe_stale(worktree_path)
      policy = Map.get(input, :stale_policy, "reuse")
      effects = stale_effects(stale, policy, backend)

      payload = %{
        operation_id: Map.get(input, :operation_id, "vcs-#{run_id}"),
        run_id: run_id,
        workspace_id: workspace_id,
        backend: Atom.to_string(backend),
        project_path: project_path,
        worktree_path: worktree_path,
        branch: branch,
        base_ref: base_ref,
        revision: Map.get(input, :revision, base_ref),
        stale: stale,
        stale_policy: policy,
        effects: effects,
        adapter: adapter_details(backend)
      }

      append("WorktreeCreated", payload)
    end
  end

  @spec cleanup_worktree(map()) :: worktree_result()
  def cleanup_worktree(input) when is_map(input) do
    input = atomize_keys(input)

    with {:ok, backend} <- backend(Map.get(input, :backend, :git)),
         {:ok, run_id} <- required_binary(Map.get(input, :run_id), :run_id),
         {:ok, worktree_path} <- required_binary(Map.get(input, :worktree_path), :worktree_path) do
      append("WorktreeCleaned", %{
        operation_id: Map.get(input, :operation_id, "cleanup-#{run_id}"),
        run_id: run_id,
        backend: Atom.to_string(backend),
        worktree_path: worktree_path,
        effects: [%{action: "remove_worktree", path: worktree_path}],
        adapter: adapter_details(backend)
      })
    end
  end

  @spec merge_branch(map()) :: worktree_result()
  def merge_branch(input) when is_map(input) do
    input = atomize_keys(input)

    with {:ok, backend} <- backend(Map.get(input, :backend, :git)),
         {:ok, run_id} <- required_binary(Map.get(input, :run_id), :run_id),
         {:ok, branch} <- required_binary(Map.get(input, :branch), :branch),
         {:ok, target} <- required_binary(Map.get(input, :target, "main"), :target) do
      append("VcsMergeRequested", %{
        operation_id: Map.get(input, :operation_id, "merge-#{run_id}"),
        run_id: run_id,
        backend: Atom.to_string(backend),
        branch: branch,
        target: target,
        effects: [%{action: merge_action(backend), branch: branch, target: target}],
        adapter: adapter_details(backend)
      })
    end
  end

  @spec create_pr(map()) :: worktree_result()
  def create_pr(input) when is_map(input) do
    input = atomize_keys(input)

    with {:ok, backend} <- backend(Map.get(input, :backend, :git)),
         {:ok, run_id} <- required_binary(Map.get(input, :run_id), :run_id),
         {:ok, branch} <- required_binary(Map.get(input, :branch), :branch),
         {:ok, base_branch} <- required_binary(Map.get(input, :base_branch, "main"), :base_branch) do
      append("VcsPrRequested", %{
        operation_id: Map.get(input, :operation_id, "pr-#{run_id}"),
        run_id: run_id,
        task_id: Map.get(input, :task_id),
        backend: Atom.to_string(backend),
        branch: branch,
        base_branch: base_branch,
        draft: Map.get(input, :draft, false),
        title: Map.get(input, :title),
        body: Map.get(input, :body),
        effects: [%{action: pr_action(backend), branch: branch, base_branch: base_branch, draft: Map.get(input, :draft, false)}],
        adapter: adapter_details(backend)
      })
    end
  end

  @spec adapters() :: [map()]
  def adapters do
    [adapter_details(:git), adapter_details(:jujutsu)]
  end

  defp append(event_type, payload) do
    with {:ok, event} <-
           EventStore.append(%{
             stream_id: "vcs:#{payload.run_id}",
             event_type: event_type,
             payload: Map.put(payload, :observed_at, DateTime.utc_now()),
             metadata: %{
               correlation_id: payload.run_id,
               idempotency_key: "#{event_type}:#{payload.operation_id}"
             }
           }) do
      {:ok, %{event: event, projection: ProjectionStore.snapshot(), result: payload}}
    end
  end

  defp observe_stale(worktree_path) do
    if File.exists?(worktree_path),
      do: %{exists: true, path: worktree_path},
      else: %{exists: false}
  end

  defp stale_effects(%{exists: false}, _policy, _backend), do: [%{action: "create_worktree"}]

  defp stale_effects(%{exists: true, path: path}, "clean", _backend),
    do: [%{action: "remove_stale_worktree", path: path}, %{action: "create_worktree"}]

  defp stale_effects(%{exists: true, path: path}, "rebase", backend),
    do: [%{action: "reuse_worktree", path: path}, %{action: rebase_action(backend)}]

  defp stale_effects(%{exists: true, path: path}, _policy, _backend),
    do: [%{action: "reuse_worktree", path: path}]

  defp backend(:git), do: {:ok, :git}
  defp backend(:jujutsu), do: {:ok, :jujutsu}
  defp backend("git"), do: {:ok, :git}
  defp backend("jujutsu"), do: {:ok, :jujutsu}
  defp backend("jj"), do: {:ok, :jujutsu}
  defp backend(value), do: {:error, {:unsupported_vcs_backend, value}}

  defp adapter_details(:git),
    do: %{
      backend: "git",
      commands: %{worktree: "git worktree", rebase: "git rebase", merge: "git merge"}
    }

  defp adapter_details(:jujutsu),
    do: %{
      backend: "jujutsu",
      commands: %{worktree: "jj workspace", rebase: "jj rebase", merge: "jj git push"}
    }

  defp rebase_action(:git), do: "git_rebase"
  defp rebase_action(:jujutsu), do: "jj_rebase"
  defp merge_action(:git), do: "git_merge"
  defp merge_action(:jujutsu), do: "jj_bookmark_merge"
  defp pr_action(:git), do: "gh_pr_create"
  defp pr_action(:jujutsu), do: "jj_git_pr_create"

  defp required_binary(value, _key) when is_binary(value) and value != "", do: {:ok, value}
  defp required_binary(_value, key), do: {:error, {:missing_or_invalid, key}}

  defp atomize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_binary(key) -> {String.to_atom(key), atomize_value(value)}
      {key, value} -> {key, atomize_value(value)}
    end)
  end

  defp atomize_value(value) when is_map(value), do: atomize_keys(value)
  defp atomize_value(value) when is_list(value), do: Enum.map(value, &atomize_value/1)
  defp atomize_value(value), do: value
end
