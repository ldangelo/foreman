defmodule ForemanServer.TestSupport.PrReadyGithub do
  @moduledoc """
  Test helper: the `gh pr view` GitHub answers when `PrReadySignal` reads the head of record.

  `install!/1` routes `PrReadySignal`'s `gh` read through a scripted GitHub for ONE test and
  removes it in `on_exit`. `heads` is a map of PR url => head sha, or a 1-arity function from a
  PR url to a sha, `{:error, code}` (the `gh` read fails with that exit code) or `nil`.
  Every `gh` call is sent to the installing process as `{:pr_ready_gh, pr_url}`.
  """

  alias ForemanServer.PrReadySignal

  @doc "A well-formed 40-hex head sha, distinct per `seed` (a string)."
  @spec sha(String.t()) :: String.t()
  def sha(seed) when is_binary(seed) do
    :sha |> :crypto.hash(seed) |> Base.encode16(case: :lower)
  end

  @doc "The `gh pr view --json` answer for a PR whose head is `sha`."
  @spec view_reply(String.t(), keyword()) :: {String.t(), 0}
  def view_reply(sha, opts \\ []) do
    {Jason.encode!(%{
       "state" => "OPEN",
       "mergeable" => "MERGEABLE",
       "headRefOid" => sha,
       "headRefName" => Keyword.get(opts, :head_branch, "feature"),
       "baseRefName" => Keyword.get(opts, :base_branch, "main"),
       "statusCheckRollup" => [],
       "reviewDecision" => "",
       "reviews" => [],
       "comments" => [],
       "mergeStateStatus" => "CLEAN"
     }), 0}
  end

  @doc "A 3-arity runner that answers `gh pr view` from `heads` and reports to `test_pid`."
  @spec runner(pid(), map() | (String.t() -> String.t() | {:error, integer()})) ::
          (String.t(), [String.t()], keyword() -> {String.t(), integer()})
  def runner(test_pid, heads) do
    fn "gh", ["pr", "view", pr_url | _], _opts ->
      send(test_pid, {:pr_ready_gh, pr_url})

      case head_for(heads, pr_url) do
        sha when is_binary(sha) -> view_reply(sha)
        {:error, code} -> {"gh: could not resolve to a PullRequest", code}
        nil -> {"gh: no such pull request", 1}
      end
    end
  end

  @doc "Install the scripted GitHub on `PrReadySignal` until the calling test exits."
  @spec install!(map() | (String.t() -> String.t() | {:error, integer()} | nil)) :: :ok
  def install!(heads) do
    PrReadySignal.set_command_runner(runner(self(), heads))
    ExUnit.Callbacks.on_exit(&PrReadySignal.clear_command_runner/0)
    :ok
  end

  defp head_for(heads, pr_url) when is_function(heads, 1), do: heads.(pr_url)
  defp head_for(heads, pr_url) when is_map(heads), do: Map.get(heads, pr_url)
end
