defmodule ForemanServer.GitHub.PrStatus do
  @moduledoc """
  Current state of one GitHub pull request, read with `gh pr view <url> --json`.

  `ForemanServer.PrMonitor` polls this as the fallback for missed webhooks. The
  struct carries exactly what a `run.pr.update` command needs from GitHub
  (status, head SHA, head branch, base branch); the run's own ids come from the
  run projection, never from GitHub.

  `fetch/2` never defaults: a `gh` failure, unparsable output, or an
  unrecognised `state` is a typed `{:error, _}`, not a guessed status
  (AGENTS.md 5.2/5.3).
  """

  @enforce_keys [:status, :head_sha, :head_branch, :base_branch]
  defstruct [:status, :head_sha, :head_branch, :base_branch]

  @type status :: :open | :merged | :closed | :conflicted

  @type t :: %__MODULE__{
          status: status(),
          head_sha: String.t(),
          head_branch: String.t(),
          base_branch: String.t()
        }

  @type error ::
          :gh_not_installed
          | {:gh_failed, non_neg_integer(), String.t()}
          | {:gh_unparsable, String.t()}
          | {:gh_unexpected_payload, term()}

  @json_fields "state,mergeable,headRefOid,headRefName,baseRefName"

  @doc """
  Fetch the status of the PR at `pr_url`.

  `opts[:command_runner]` is a 3-arity `(cmd, args, opts)` returning
  `{output, exit_code}`; it defaults to `System.cmd/3` and exists so tests can
  drive the parser without the network.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def fetch(pr_url, opts \\ []) when is_binary(pr_url) do
    case Keyword.fetch(opts, :command_runner) do
      {:ok, runner} -> run(runner, pr_url)
      :error -> run_installed_gh(pr_url)
    end
  end

  defp run_installed_gh(pr_url) do
    case System.find_executable("gh") do
      nil -> {:error, :gh_not_installed}
      _path -> run(&System.cmd/3, pr_url)
    end
  end

  defp run(runner, pr_url) do
    case runner.("gh", ["pr", "view", pr_url, "--json", @json_fields], stderr_to_stdout: true) do
      {output, 0} -> parse(output)
      {output, code} -> {:error, {:gh_failed, code, String.trim(output)}}
    end
  end

  defp parse(output) do
    case Jason.decode(output) do
      {:ok, decoded} -> from_payload(decoded)
      {:error, _} -> {:error, {:gh_unparsable, String.slice(output, 0, 200)}}
    end
  end

  defp from_payload(
         %{
           "state" => state,
           "mergeable" => mergeable,
           "headRefOid" => sha,
           "headRefName" => head,
           "baseRefName" => base
         } = payload
       )
       when is_binary(sha) and sha != "" and is_binary(head) and head != "" and
              is_binary(base) and base != "" do
    case status(state, mergeable) do
      {:ok, status} ->
        {:ok, %__MODULE__{status: status, head_sha: sha, head_branch: head, base_branch: base}}

      :error ->
        {:error, {:gh_unexpected_payload, payload}}
    end
  end

  defp from_payload(other), do: {:error, {:gh_unexpected_payload, other}}

  defp status("MERGED", _mergeable), do: {:ok, :merged}
  defp status("CLOSED", _mergeable), do: {:ok, :closed}
  defp status("OPEN", "CONFLICTING"), do: {:ok, :conflicted}
  defp status("OPEN", _mergeable), do: {:ok, :open}
  defp status(_state, _mergeable), do: :error
end
