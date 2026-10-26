defmodule ForemanServer.Webhooks.Github do
  @moduledoc """
  TRD-017: Adapter that turns GitHub `pull_request` webhook payloads into
  `run.pr.update` commands and dispatches them through
  `ForemanServer.CommandGateway`.

  Only payloads whose signature `ForemanServerWeb.Plugs.VerifyGithubSignature`
  already verified reach this module.

  A delivery is attributed to runs by PR URL: every run whose recorded PR
  association is the delivery's `pull_request.html_url` receives the update. GitHub
  sends events for every PR in the repository, so a PR no run owns is `:ignored`
  (HTTP 202), not an error. Nothing in the payload names a run, and nothing the
  sender controls selects one.

  A PR is addressed as `{run_id, repo_id}` (E12): the update goes to the one repository's
  PR association whose url matches, carries `repo_id` only when that repository is not
  the run's primary, and never touches another repository's PR of the same run.

  Handled `pull_request` actions:

    * `closed` with `merged: true`  — `:merged`.
    * `closed` with `merged: false` — `:closed`.
    * `reopened`                    — `:open`.
    * any action while `mergeable_state` is `dirty` — `:conflicted`.

  `blocked` is deliberately not a conflict: it means required checks or reviews are
  pending, which is the normal state of a healthy open PR.

  The command is built by `ForemanServer.PrUpdate`, shared with `PrMonitor`. Its id
  is derived from the observed status and head SHA, so a redelivery (GitHub retries)
  and a poll reporting the same state are deduplicated by the router.

  ## Optional accelerator (spike S4)

  Polling (`ForemanServer.PrMonitor`) is the primary signal source; webhooks only
  make it faster. `check_run` / `check_suite` (`completed`, `rerequested`), `pull_request_review`,
  `pull_request_review_comment`, `pull_request_review_thread`, PR `issue_comment`
  and `pull_request` `synchronize` / `ready_for_review` / `converted_to_draft`
  deliveries are partial payloads, so they carry no state: each one asks
  `ForemanServer.PrWatcher` to re-read the PR it names, if a run owns it. The
  observation path then dedupes by content digest, so a webhook and a poll
  converge on one event. These events are matched by their own top-level key
  *before* the `pull_request` clause (review payloads also contain `action` and
  `pull_request`). A lost delivery is healed by the next poll; GitHub does not retry.
  The delivery is verified (`X-Hub-Signature-256`) before it reaches this module.
  """

  alias ForemanServer.CommandGateway
  alias ForemanServer.GitHub.PrStatus
  alias ForemanServer.PrUpdate
  alias ForemanServer.PrWatcher
  alias ForemanServer.ProjectionStore

  @type result :: :ok | :ignored | {:error, term()}

  @doc """
  Translate a verified webhook payload and dispatch one `run.pr.update` per owning
  run.

  Returns `:ok` when every dispatch succeeded, `:ignored` when the payload is not a
  handled event or no run owns the PR, and `{:error, reason}` for the first failure.
  """
  @spec process(term()) :: result()
  def process(payload) when is_map(payload) do
    case build_refresh_targets(payload) do
      {:ok, pr_urls} ->
        refresh(pr_urls)

      :none ->
        case build_commands(payload) do
          {:ok, commands} -> dispatch_all(commands)
          :ignored -> :ignored
          {:error, _reason} = error -> error
        end
    end
  end

  def process(_other), do: :ignored

  # Webhook payloads are partial (a fork's `check_run.pull_requests` is empty), so
  # they only signal "PR X changed": the watcher re-reads the PR and the observation
  # path decides what is new, exactly as for a poll.
  defp refresh(pr_urls) do
    owned = Enum.filter(pr_urls, &(ProjectionStore.run_ids_for_pr_url(&1) != []))

    if owned != [] and PrWatcher.running?() do
      Enum.each(owned, &PrWatcher.refresh/1)
      :ok
    else
      :ignored
    end
  end

  @check_actions ~w(completed rerequested)
  @review_actions ~w(submitted edited dismissed)
  @comment_actions ~w(created edited deleted)
  @thread_actions ~w(resolved unresolved)
  @pull_request_refresh_actions ~w(synchronize ready_for_review converted_to_draft)

  @doc """
  The PR URLs a non-`pull_request-state` delivery asks to be refreshed
  (spike S4 allowlist): `check_run` / `check_suite` (`completed`, `rerequested`),
  `pull_request_review`, `pull_request_review_comment`, `pull_request_review_thread`,
  PR `issue_comment`, and `pull_request` `synchronize` / `ready_for_review` /
  `converted_to_draft`.

  These keys are discriminated by their own top-level key (`check_run`,
  `review`, `comment`, `thread`, `issue`), BEFORE the `pull_request` clause: review and
  review-comment payloads also carry `action` and `pull_request`, and must not be read
  as a PR state change. `:none` means "not a refresh signal": the caller falls through
  to the state-change path.
  """
  @spec build_refresh_targets(term()) :: {:ok, [String.t()]} | :none
  def build_refresh_targets(%{"check_run" => %{"pull_requests" => prs}, "action" => action} = p)
      when action in @check_actions,
      do: {:ok, repo_pr_urls(prs, p)}

  def build_refresh_targets(%{"check_suite" => %{"pull_requests" => prs}, "action" => action} = p)
      when action in @check_actions,
      do: {:ok, repo_pr_urls(prs, p)}

  def build_refresh_targets(%{"review" => _, "pull_request" => pr, "action" => action})
      when action in @review_actions,
      do: html_urls(pr)

  def build_refresh_targets(%{"comment" => _, "pull_request" => pr, "action" => action})
      when action in @comment_actions,
      do: html_urls(pr)

  def build_refresh_targets(%{"thread" => _, "pull_request" => pr, "action" => action})
      when action in @thread_actions,
      do: html_urls(pr)

  def build_refresh_targets(%{
        "issue" => %{"pull_request" => _} = issue,
        "comment" => _,
        "action" => action
      })
      when action in @comment_actions,
      do: html_urls(issue)

  def build_refresh_targets(%{"pull_request" => pr, "action" => action})
      when action in @pull_request_refresh_actions,
      do: html_urls(pr)

  # A review/comment/thread delivery whose action is not handled is still not a PR
  # state change: swallow it here rather than let the `pull_request` clause read it.
  def build_refresh_targets(%{"pull_request" => _} = payload) do
    if Enum.any?(
         ["check_run", "check_suite", "review", "comment", "thread"],
         &Map.has_key?(payload, &1)
       ),
       do: {:ok, []},
       else: :none
  end

  def build_refresh_targets(%{"check_run" => _}), do: {:ok, []}
  def build_refresh_targets(%{"check_suite" => _}), do: {:ok, []}
  def build_refresh_targets(_other), do: :none

  # Check payloads name PRs by API URL; the PR page URL is the repository's
  # `html_url` plus `/pull/<number>`, which is what runs store.
  defp repo_pr_urls(prs, payload) when is_list(prs) do
    case get_in(payload, ["repository", "html_url"]) do
      repo when is_binary(repo) and repo != "" ->
        for %{"number" => number} <- prs, is_integer(number), do: repo <> "/pull/#{number}"

      _ ->
        []
    end
  end

  defp repo_pr_urls(_prs, _payload), do: []

  defp html_urls(%{"html_url" => url}) when is_binary(url) and url != "", do: {:ok, [url]}
  defp html_urls(_other), do: {:ok, []}

  @doc """
  Pure-translation variant that returns the commands without dispatching.
  """
  @spec build_commands(term()) :: {:ok, [map()]} | :ignored | {:error, term()}
  def build_commands(%{"action" => action, "pull_request" => %{"html_url" => pr_url} = pr})
      when is_binary(pr_url) and pr_url != "" do
    case status(action, pr) do
      nil -> :ignored
      status -> commands_for(pr_url, status, pr)
    end
  end

  def build_commands(_other), do: :ignored

  defp commands_for(pr_url, status, pr) do
    with {:ok, observed} <- observation(status, pr) do
      case ProjectionStore.run_ids_for_pr_url(pr_url) do
        [] ->
          :ignored

        targets ->
          targets
          |> Enum.map(fn {run_id, repo_id} ->
            PrUpdate.command(run_id, pr_url, observed, repo_id)
          end)
          |> collect()
      end
    end
  end

  # GitHub always sends these on a `pull_request` event; one missing is a payload
  # we do not understand, reported by name rather than guessed.
  defp observation(status, pr) do
    with {:ok, head_sha} <- required(pr, ["head", "sha"], :head_sha),
         {:ok, head_branch} <- required(pr, ["head", "ref"], :head_branch),
         {:ok, base_branch} <- required(pr, ["base", "ref"], :base_branch) do
      {:ok,
       %PrStatus{
         status: status,
         head_sha: head_sha,
         head_branch: head_branch,
         base_branch: base_branch
       }}
    end
  end

  defp required(pr, path, name) do
    case get_in(pr, path) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, {:pr_payload_missing, name}}
    end
  end

  defp collect(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, command}, {:ok, acc} -> {:cont, {:ok, [command | acc]}}
      {:error, _} = error, _acc -> {:halt, error}
    end)
    |> case do
      {:ok, commands} -> {:ok, Enum.reverse(commands)}
      {:error, _} = error -> error
    end
  end

  defp dispatch_all(commands) do
    Enum.reduce_while(commands, :ok, fn command, :ok ->
      case CommandGateway.dispatch_system(command) do
        {:ok, _event_spec} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
        {:error, reason, _detail} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp status("closed", %{"merged" => true}), do: :merged
  defp status("closed", _pr), do: :closed
  defp status("reopened", _pr), do: :open
  defp status(_action, %{"mergeable_state" => "dirty"}), do: :conflicted
  defp status(_action, _pr), do: nil
end
