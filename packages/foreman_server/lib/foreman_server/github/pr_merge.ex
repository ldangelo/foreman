defmodule ForemanServer.GitHub.PrMerge do
  @moduledoc """
  Squash-merges one GitHub pull request with `gh pr merge`.

  The merge is pinned to `head_sha` with `--match-head-commit`: GitHub refuses it
  if the PR's head moved since the approval was given, so commits pushed after a
  human approved the PR can never be merged unreviewed.

  The strategy is fixed at squash, matching how this repository lands PRs.
  """

  @type error ::
          :gh_not_installed
          | {:gh_merge_failed, non_neg_integer(), String.t()}

  @doc """
  Merge the PR at `pr_url`, requiring its head to still be `head_sha`.

  `opts[:command_runner]` is a 3-arity `(cmd, args, opts)` returning
  `{output, exit_code}`; it defaults to `System.cmd/3` and exists so tests can
  drive this without the network or a real PR.
  """
  @spec merge(String.t(), String.t(), keyword()) :: :ok | {:error, error()}
  def merge(pr_url, head_sha, opts \\ [])
      when is_binary(pr_url) and is_binary(head_sha) and head_sha != "" do
    case Keyword.fetch(opts, :command_runner) do
      {:ok, runner} -> run(runner, pr_url, head_sha)
      :error -> run_installed_gh(pr_url, head_sha)
    end
  end

  defp run_installed_gh(pr_url, head_sha) do
    case System.find_executable("gh") do
      nil -> {:error, :gh_not_installed}
      _path -> run(&System.cmd/3, pr_url, head_sha)
    end
  end

  defp run(runner, pr_url, head_sha) do
    args = ["pr", "merge", pr_url, "--squash", "--match-head-commit", head_sha]

    case runner.("gh", args, stderr_to_stdout: true) do
      {_output, 0} -> :ok
      {output, code} -> {:error, {:gh_merge_failed, code, String.trim(output)}}
    end
  end
end
