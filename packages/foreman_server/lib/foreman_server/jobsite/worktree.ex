defmodule ForemanServer.Jobsite.Worktree do
  @moduledoc """
  Branch strategies for a jobsite run: `:head` (work directly in the
  caller's checkout), `{:branch, name}` (a named, durable branch, reused if
  it already has a registered worktree), or `:merge_to_head` (a temporary
  branch merged back into the caller's current branch on close).
  """

  alias ForemanServer.Jobsite.{Error, Git, Sandbox}

  @enforce_keys [:repo_path, :path, :branch, :strategy, :base_sha]
  @type strategy :: :head | :merge_to_head | {:branch, String.t()}
  @type t :: %__MODULE__{
          repo_path: String.t(),
          path: String.t(),
          branch: String.t(),
          strategy: strategy(),
          base_sha: String.t(),
          target_branch: String.t() | nil,
          temp?: boolean()
        }
  defstruct [:repo_path, :path, :branch, :strategy, :base_sha, :target_branch, temp?: false]

  @spec create(keyword()) :: {:ok, t()} | {:error, Error.t()}
  def create(opts) do
    repo_path = Keyword.get(opts, :repo_path, File.cwd!())
    strategy = Keyword.fetch!(opts, :strategy)
    copy_to_worktree = Keyword.get(opts, :copy_to_worktree, [])
    exclude_paths = Keyword.get(opts, :exclude_paths, [])

    if copy_to_worktree != [] and strategy == :head do
      {:error,
       Error.new(
         :branch_strategy_unsupported,
         "copy_to_worktree is not supported with the :head strategy — it would overwrite the caller's own checkout",
         %{strategy: strategy}
       )}
    else
      with {:ok, worktree} <- do_create(repo_path, strategy, opts) do
        case copy_files(worktree, copy_to_worktree) do
          :ok -> apply_sparse_exclude(worktree, exclude_paths)
          {:error, _} = err -> err
        end
      end
    end
  end

  @doc """
  Attach a sandbox provider to an already-created worktree. The returned
  `Sandbox.t()` has `owns_worktree?: false` — closing it tears down the
  container (or, for the host provider, nothing) but leaves this worktree's
  lifecycle to whoever created it.
  """
  @spec create_sandbox(t(), keyword()) :: {:ok, Sandbox.t()} | {:error, Error.t()}
  def create_sandbox(%__MODULE__{} = worktree, opts) do
    {provider, config} = Keyword.fetch!(opts, :sandbox)
    jobsite_id = Keyword.get(opts, :jobsite_id) || "sandbox-" <> random_hex(16)

    if worktree.strategy == :head and provider.kind() == :isolated do
      {:error,
       Error.new(
         :branch_strategy_unsupported,
         "an :isolated sandbox provider cannot be combined with the :head strategy — there would be nothing to bind its work back into",
         %{strategy: :head, provider: provider.name()}
       )}
    else
      with {:ok, state, sandbox_repo_path, container_id} <- provider.create(config, worktree) do
        {:ok,
         %Sandbox{
           jobsite_id: jobsite_id,
           provider: provider,
           state: state,
           worktree: worktree,
           sandbox_repo_path: sandbox_repo_path,
           container_id: container_id,
           config: config,
           owns_worktree?: false
         }}
      end
    end
  end

  defp do_create(repo_path, :head, _opts) do
    with {:ok, branch} <- Git.current_branch(repo_path),
         {:ok, base_sha} <- Git.head_sha(repo_path) do
      {:ok,
       %__MODULE__{
         repo_path: repo_path,
         path: repo_path,
         branch: branch,
         strategy: :head,
         base_sha: base_sha,
         target_branch: branch,
         temp?: false
       }}
    end
  end

  defp do_create(repo_path, {:branch, name} = strategy, opts) do
    with {:ok, existing} <- Git.worktree_list(repo_path),
         {:ok, target_branch} <- Git.current_branch(repo_path) do
      case Enum.find(existing, fn w -> w.branch == name end) do
        %{path: path} ->
          with {:ok, base_sha} <- Git.head_sha(repo_path) do
            {:ok,
             %__MODULE__{
               repo_path: repo_path,
               path: path,
               branch: name,
               strategy: strategy,
               base_sha: base_sha,
               target_branch: target_branch,
               temp?: false
             }}
          end

        nil ->
          explicit_path = Keyword.get(opts, :path)
          path = explicit_path || default_worktree_path(repo_path, name)
          if is_nil(explicit_path), do: ensure_foreman_gitignore(repo_path)

          with {:ok, base} <- resolve_base(repo_path, Keyword.get(opts, :base)),
               :ok <- Git.worktree_add(repo_path, path, name, base) do
            {:ok,
             %__MODULE__{
               repo_path: repo_path,
               path: path,
               branch: name,
               strategy: strategy,
               base_sha: base,
               target_branch: target_branch,
               temp?: false
             }}
          end
      end
    end
  end

  defp do_create(repo_path, :merge_to_head, opts) do
    with {:ok, target_branch} <- Git.current_branch(repo_path),
         {:ok, base_sha} <- Git.head_sha(repo_path) do
      branch = "jobsite/" <> random_hex(8)
      explicit_path = Keyword.get(opts, :path)
      path = explicit_path || default_worktree_path(repo_path, branch)
      if is_nil(explicit_path), do: ensure_foreman_gitignore(repo_path)

      with :ok <- Git.worktree_add(repo_path, path, branch, base_sha) do
        {:ok,
         %__MODULE__{
           repo_path: repo_path,
           path: path,
           branch: branch,
           strategy: :merge_to_head,
           base_sha: base_sha,
           target_branch: target_branch,
           temp?: true
         }}
      end
    end
  end

  @spec close(t()) :: {:ok, %{preserved_path: String.t() | nil, merged?: boolean()}} | {:error, Error.t()}
  def close(%__MODULE__{strategy: :head}), do: {:ok, %{preserved_path: nil, merged?: false}}

  def close(%__MODULE__{strategy: :merge_to_head} = wt) do
    case Git.merge(wt.repo_path, wt.branch) do
      {:ok, _output} ->
        with :ok <- Git.worktree_remove(wt.repo_path, wt.path),
             :ok <- Git.delete_branch(wt.repo_path, wt.branch) do
          {:ok, %{preserved_path: nil, merged?: true}}
        end

      {:error, {:merge_conflict, output}} ->
        Git.merge_abort(wt.repo_path)
        {:error, Error.new(:merge_conflict, "merge produced conflicts", %{branch: wt.branch, output: output})}
    end
  end

  def close(%__MODULE__{strategy: {:branch, _name}} = wt) do
    if Git.dirty?(wt.path) do
      {:ok, %{preserved_path: wt.path, merged?: false}}
    else
      case Git.worktree_remove(wt.repo_path, wt.path) do
        :ok -> {:ok, %{preserved_path: nil, merged?: false}}
        {:error, _} = err -> err
      end
    end
  end

  defp copy_files(_worktree, []), do: :ok

  defp copy_files(worktree, entries) do
    Enum.reduce_while(entries, :ok, fn rel_path, :ok ->
      source = Path.join(worktree.repo_path, rel_path)
      dest = Path.join(worktree.path, rel_path)

      if File.exists?(source) do
        File.mkdir_p!(Path.dirname(dest))
        File.cp_r!(source, dest)
        {:cont, :ok}
      else
        {:halt, {:error, Error.new(:copy_failed, "copy_to_worktree source does not exist", %{path: source})}}
      end
    end)
  end

  defp apply_sparse_exclude(worktree, []), do: {:ok, worktree}

  defp apply_sparse_exclude(worktree, patterns) do
    case Git.sparse_exclude(worktree.path, patterns) do
      :ok -> {:ok, worktree}
      {:error, _} = err -> err
    end
  end

  defp resolve_base(_repo_path, base) when is_binary(base) and base != "", do: {:ok, base}
  defp resolve_base(repo_path, _absent), do: Git.head_sha(repo_path)

  # A worktree placed at the default `<repo>/.foreman/worktrees/...` path sits
  # INSIDE the host repo's own working tree. Without a `.gitignore` there, the
  # host repo's own `git add -A` (e.g. `Git.commit_all/3` on the host side)
  # picks the nested worktree up as an "embedded git repository" and both
  # pollutes host git status and blocks a later `git worktree remove`. A
  # `foreman init --template` scaffold already writes this file; this is the
  # defensive floor for a script that places a worktree there without having
  # run the scaffold, and it never overwrites an existing `.gitignore`.
  defp ensure_foreman_gitignore(repo_path) do
    path = Path.join([repo_path, ".foreman", ".gitignore"])

    unless File.exists?(path) do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, "logs/\nstate/\nworktrees/\nruns/\n")
    end

    :ok
  end

  defp default_worktree_path(repo_path, name) do
    leaf = String.replace(name, "/", "-")
    Path.join([repo_path, ".foreman", "worktrees", leaf])
  end

  defp random_hex(bytes) do
    bytes
    |> div(2)
    |> max(1)
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
    |> binary_part(0, bytes)
  end
end
