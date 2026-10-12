defmodule ForemanServer.Jobsite.Options do
  @moduledoc """
  Cross-field validation for `Jobsite.run/1` / `Jobsite.Executor` options,
  rejected before any side effect (worktree creation, sandbox creation)
  rather than mid-run.

  `:head` combined with an `:isolated`-kind sandbox provider, or with
  `copy_to_worktree`, is validated inside `Jobsite.Worktree` instead, where
  the provider's `kind/0` and the worktree strategy are both already in
  scope.
  """

  alias ForemanServer.Jobsite.Error

  @spec validate(keyword()) :: :ok | {:error, Error.t()}
  def validate(opts) do
    max_iterations = Keyword.get(opts, :max_iterations, 1)

    cond do
      Keyword.get(opts, :resume_session) not in [nil, false] and max_iterations > 1 ->
        {:error,
         Error.new(
           :resume_with_iterations,
           "resume_session cannot be combined with max_iterations > 1",
           %{max_iterations: max_iterations}
         )}

      Keyword.get(opts, :output) not in [nil, false] and max_iterations > 1 ->
        {:error,
         Error.new(
           :output_with_iterations,
           "output cannot be combined with max_iterations > 1",
           %{max_iterations: max_iterations}
         )}

      true ->
        :ok
    end
  end
end
