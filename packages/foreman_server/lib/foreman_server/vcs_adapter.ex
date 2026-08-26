defmodule ForemanServer.VcsAdapter do
  @moduledoc """
  Behaviour contract for VCS adapters (clone/branch/create_pr/worktree).
  """

  @doc """
  Implementation callback for cloning a repository.
  """
  @callback clone(url :: String.t(), opts :: keyword()) ::
              {:ok, %{path: String.t()}}
              | {:error, :not_found | :auth | :invalid | {:transient, term()}}

  @doc """
  Implementation callback for creating a branch in `path` named `name`.
  """
  @callback branch(path :: String.t(), name :: String.t()) ::
              {:ok, %{branch: String.t()}}
              | {:error, :not_found | :auth | :invalid | {:transient, term()}}

  @doc """
  Implementation callback for creating a pull request.
  """
  @callback create_pr(path :: String.t(), opts :: keyword()) ::
              {:ok, %{url: String.t(), number: non_neg_integer()}}
              | {:error, :not_found | :auth | :invalid | {:transient, term()}}

  @doc """
  Implementation callback for creating a worktree.

  Required opts (all `Keyword.fetch!/2`): `:operation_id`, `:base`,
  `:branch` (nil allowed for detached), `:project_id`, `:run_id`,
  `:phase_id`.

  Returns the captured git stdout/stderr in the `:output` key on success
  so callers can correlate with telemetry.
  """
  @callback create_worktree(
              repo_path :: String.t(),
              worktree_path :: String.t(),
              opts :: keyword()
            ) ::
              {:ok,
               %{path: String.t(), base: String.t(), branch: String.t() | nil, output: String.t()}}
              | {:error, term()}

  @doc """
  Implementation callback for cleaning a worktree.

  Required opts (all `Keyword.fetch!/2`): `:operation_id`, `:repo_path`,
  `:project_id`, `:run_id`, `:phase_id`. The adapter MUST NOT pass
  `--force` to `git worktree remove`; a dirty worktree is returned as
  `{:error, {:git_worktree_clean_failed, _, _}}` for operator inspection.

  The result shape differs by `noop?`:
    * `noop?: true`  — path was absent, no git invocation, no `output` key.
    * `noop?: false` — git worktree remove succeeded, `output` carries
      captured stdout/stderr.
  """
  @callback clean_worktree(worktree_path :: String.t(), opts :: keyword()) ::
              {:ok, %{path: String.t(), cleaned?: true, noop?: false, output: String.t()}}
              | {:ok, %{path: String.t(), cleaned?: true, noop?: true}}
              | {:error, term()}

  @non_transient [:auth, :not_found, :invalid]

  @doc """
  Run a VCS function with retry-on-transient semantics.

  * Retries up to `:max_retries` (default 3) with exponential backoff.
  * Returns `{:ok, result}` on success.
  * Returns `{:error, reason}` after exhausting retries for transient failures.
  * Returns `{:error, reason}` immediately for non-transient errors.
  """
  @spec run(
          module(),
          :clone | :branch | :create_pr | :create_worktree | :clean_worktree,
          [term()],
          keyword()
        ) ::
          {:ok, term()} | {:error, term()}
  def run(module, fun, args, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    base_delay = Keyword.get(opts, :base_delay_ms, 25)
    fun_ref = build_fun(module, fun)

    run_with_retries(fun_ref, args, max_retries, base_delay, 1)
  end

  @doc """
  Classify whether an error reason is transient.
  """
  @spec transient?(term()) :: boolean()
  def transient?({:transient, _}), do: true
  def transient?(_other), do: false

  @doc """
  Returns the list of error atoms classified as non-transient.
  """
  @spec non_transient_errors() :: [atom()]
  def non_transient_errors, do: @non_transient

  defp build_fun(module, :clone),
    do: fn args -> module.clone(Enum.at(args, 0), Enum.at(args, 1) || []) end

  defp build_fun(module, :branch),
    do: fn args -> module.branch(Enum.at(args, 0), Enum.at(args, 1)) end

  defp build_fun(module, :create_pr),
    do: fn args -> module.create_pr(Enum.at(args, 0), Enum.at(args, 1) || []) end

  defp build_fun(module, :create_worktree),
    do: fn args ->
      module.create_worktree(Enum.at(args, 0), Enum.at(args, 1), Enum.at(args, 2) || [])
    end

  defp build_fun(module, :clean_worktree),
    do: fn args ->
      module.clean_worktree(Enum.at(args, 0), Enum.at(args, 1) || [])
    end

  defp run_with_retries(fun, args, max, base_delay, attempt) do
    case fun.(args) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if transient?(reason) and attempt < max do
          Process.sleep((base_delay * :math.pow(2, attempt - 1)) |> trunc())
          run_with_retries(fun, args, max, base_delay, attempt + 1)
        else
          err
        end
    end
  end
end
