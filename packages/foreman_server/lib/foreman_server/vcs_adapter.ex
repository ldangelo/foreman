defmodule ForemanServer.VcsAdapter do
  @moduledoc """
  TRD-018: Behaviour for VCS provider adapters (GitHub, GitLab, etc.).

  Implementations must return tagged tuples so the retry helper can
  distinguish transient failures (`:transient`) from non-transient
  failures (`:auth`, `:not_found`, `:invalid`).

  ## Example

      defmodule MyAdapter do
        @behaviour ForemanServer.VcsAdapter

        @impl true
        def clone(_url, _opts) do
          with {:ok, path} <- git_clone(_url) do
            {:ok, %{path: path}}
          end
        end

        @impl true
        def branch(_path, _name), do: ...
      end

      ForemanServer.VcsAdapter.run(MyAdapter, :branch, [path, name])
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

  @non_transient [:auth, :not_found, :invalid]

  @doc """
  Run a VCS function with retry-on-transient semantics.

  * Retries up to `:max_retries` (default 3) with exponential backoff.
  * Returns `{:ok, result}` on success.
  * Returns `{:error, reason}` after exhausting retries for transient failures.
  * Returns `{:error, reason}` immediately for non-transient errors.
  """
  @spec run(module(), :clone | :branch | :create_pr, [term()], keyword()) ::
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

  defp run_with_retries(fun, args, max, base_delay, attempt) do
    case fun.(args) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        if transient?(reason) and attempt < max do
          Process.sleep(base_delay * Integer.pow(2, attempt - 1))
          run_with_retries(fun, args, max, base_delay, attempt + 1)
        else
          err
        end
    end
  end
end
