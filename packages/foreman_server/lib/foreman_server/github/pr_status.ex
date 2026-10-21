defmodule ForemanServer.GitHub.PrStatus do
  @moduledoc """
  Current state of one GitHub pull request, read with `gh pr view <url> --json`.

  `ForemanServer.PrWatcher` (and the `ForemanServer.PrMonitor` poll loop that
  drives it) reads this once per poll. The struct carries what a
  `run.pr.update` command needs (status, head SHA, head branch, base branch)
  plus what the watcher turns into typed observations (spike S4):

    * `checks` / `checks_state` - the heterogeneous `statusCheckRollup`
      (`CheckRun` and `StatusContext` items) normalised once into
      `%{name, kind, state, conclusion, url, workflow}`; `checks_state` is
      `:failing` when any check failed (FAILURE, TIMED_OUT, CANCELLED,
      ACTION_REQUIRED, STARTUP_FAILURE, StatusContext FAILURE/ERROR), else
      `:pending` when any check is not finished, else `:passing`, and `:none`
      when the PR has no checks.
    * `review_decision` - `:approved | :changes_requested | :review_required`,
      or `nil` when GitHub reports `""`/`null` (no review required or present).
    * `reviews` and `comments` - conversation comments and review summaries,
      bounded (`@max_list` each, newest kept) with a `*_truncated` flag; comment
      bodies are cut at `@max_body` characters. Minimised comments are dropped.
    * `merge_state_status` - the documented `mergeStateStatus` values plus
      `:unknown` (GitHub computes it lazily; `UNKNOWN` is not an error).
    * `threads` - `nil` until `fetch_threads/2` (or `fetch/2` with
      `threads: true`) read the review threads via GraphQL; inline review
      comments and their resolved state are not part of `gh pr view`.

  Every GitHub enum is normalised in exactly one place here (AGENTS.md 5.2:
  one key convention per boundary). `fetch/2` never defaults: a `gh` failure,
  unparsable output, or an unrecognised enum value is a typed `{:error, _}`,
  not a guessed value (AGENTS.md 5.2/5.3).
  """

  @enforce_keys [:status, :head_sha, :head_branch, :base_branch]
  defstruct [
    :status,
    :head_sha,
    :head_branch,
    :base_branch,
    :review_decision,
    :merge_state_status,
    checks: [],
    checks_state: :none,
    checks_truncated: false,
    reviews: [],
    reviews_truncated: false,
    comments: [],
    comments_truncated: false,
    threads: nil,
    threads_truncated: false
  ]

  @type status :: :open | :merged | :closed | :conflicted
  @type check_state :: :passing | :failing | :pending
  @type checks_state :: :none | :pending | :failing | :passing
  @type review_decision :: :approved | :changes_requested | :review_required | nil
  @type merge_state_status ::
          :clean | :dirty | :blocked | :behind | :draft | :has_hooks | :unstable | :unknown | nil

  @type check :: %{
          name: String.t(),
          kind: :check_run | :status_context,
          state: check_state(),
          conclusion: String.t() | nil,
          url: String.t() | nil,
          workflow: String.t() | nil
        }

  @type review :: %{
          id: String.t(),
          author: String.t() | nil,
          state: :approved | :changes_requested | :commented | :dismissed | :pending,
          commit_oid: String.t() | nil,
          submitted_at: String.t() | nil
        }

  @type comment :: %{
          id: String.t(),
          author: String.t() | nil,
          body: String.t(),
          url: String.t() | nil,
          created_at: String.t() | nil
        }

  @type thread :: %{
          id: String.t(),
          resolved: boolean(),
          outdated: boolean(),
          path: String.t() | nil,
          line: non_neg_integer() | nil,
          comments: [comment()]
        }

  @type t :: %__MODULE__{
          status: status(),
          head_sha: String.t(),
          head_branch: String.t(),
          base_branch: String.t(),
          review_decision: review_decision(),
          merge_state_status: merge_state_status(),
          checks: [check()],
          checks_state: checks_state(),
          checks_truncated: boolean(),
          reviews: [review()],
          reviews_truncated: boolean(),
          comments: [comment()],
          comments_truncated: boolean(),
          threads: [thread()] | nil,
          threads_truncated: boolean()
        }

  @type error ::
          :gh_not_installed
          | {:gh_failed, non_neg_integer(), String.t()}
          | {:gh_unparsable, String.t()}
          | {:gh_unexpected_payload, term()}

  @json_fields "state,mergeable,headRefOid,headRefName,baseRefName,statusCheckRollup,reviewDecision,reviews,comments,mergeStateStatus"

  @max_list 100
  @max_body 2000

  @threads_query "query($owner:String!,$name:String!,$number:Int!){repository(owner:$owner,name:$name){pullRequest(number:$number){reviewThreads(first:100){nodes{id isResolved isOutdated path line originalLine comments(first:20){nodes{databaseId author{login} body createdAt url}}}}}}}"

  @fail_conclusions ~w(FAILURE TIMED_OUT CANCELLED ACTION_REQUIRED STARTUP_FAILURE STALE)
  @pass_conclusions ~w(SUCCESS NEUTRAL SKIPPED)
  @pending_check_status ~w(IN_PROGRESS QUEUED PENDING WAITING REQUESTED)
  @merge_states %{
    "CLEAN" => :clean,
    "DIRTY" => :dirty,
    "BLOCKED" => :blocked,
    "BEHIND" => :behind,
    "DRAFT" => :draft,
    "HAS_HOOKS" => :has_hooks,
    "UNSTABLE" => :unstable,
    "UNKNOWN" => :unknown
  }
  @review_states %{
    "APPROVED" => :approved,
    "CHANGES_REQUESTED" => :changes_requested,
    "COMMENTED" => :commented,
    "DISMISSED" => :dismissed,
    "PENDING" => :pending
  }

  @doc """
  Fetch the status of the PR at `pr_url`.

  `opts[:command_runner]` is a 3-arity `(cmd, args, opts)` returning
  `{output, exit_code}`; it defaults to `System.cmd/3` and exists so tests can
  drive the parser without the network. `threads: true` additionally reads the
  review threads (`fetch_threads/2`), but only when the PR has at least one
  review (a PR without reviews cannot have inline review threads), so the
  common poll stays one call.
  """
  @spec fetch(String.t(), keyword()) :: {:ok, t()} | {:error, error()}
  def fetch(pr_url, opts \\ []) when is_binary(pr_url) do
    with {:ok, runner} <- runner(opts),
         {:ok, status} <- run_view(runner, pr_url) do
      if Keyword.get(opts, :threads, false) and status.reviews != [] do
        with_threads(status, pr_url, runner)
      else
        {:ok, status}
      end
    end
  end

  @doc """
  Read the review threads of the PR at `pr_url` through `gh api graphql` and
  return them with the truncated flag. Each thread carries its resolved state,
  path/line (falling back to `originalLine` when the code moved) and comments.
  """
  @spec fetch_threads(String.t(), keyword()) ::
          {:ok, {[thread()], boolean()}} | {:error, error()}
  def fetch_threads(pr_url, opts \\ []) when is_binary(pr_url) do
    with {:ok, runner} <- runner(opts), do: run_threads(runner, pr_url)
  end

  defp runner(opts) do
    case Keyword.fetch(opts, :command_runner) do
      {:ok, runner} ->
        {:ok, runner}

      :error ->
        case System.find_executable("gh") do
          nil -> {:error, :gh_not_installed}
          _path -> {:ok, &System.cmd/3}
        end
    end
  end

  defp with_threads(status, pr_url, runner) do
    case run_threads(runner, pr_url) do
      {:ok, {threads, truncated}} ->
        {:ok, %{status | threads: threads, threads_truncated: truncated}}

      {:error, _} = error ->
        error
    end
  end

  defp run_view(runner, pr_url) do
    case runner.("gh", ["pr", "view", pr_url, "--json", @json_fields], stderr_to_stdout: true) do
      {output, 0} -> parse(output)
      {output, code} -> {:error, {:gh_failed, code, String.trim(output)}}
    end
  end

  defp run_threads(runner, pr_url) do
    with {:ok, owner, name, number} <- parse_pr_url(pr_url) do
      args = [
        "api",
        "graphql",
        "-f",
        "query=" <> @threads_query,
        "-F",
        "owner=" <> owner,
        "-F",
        "name=" <> name,
        "-F",
        "number=" <> Integer.to_string(number)
      ]

      case runner.("gh", args, stderr_to_stdout: true) do
        {output, 0} -> parse_threads(output)
        {output, code} -> {:error, {:gh_failed, code, String.trim(output)}}
      end
    end
  end

  defp parse_pr_url(pr_url) do
    case Regex.run(~r{github\.com/([^/]+)/([^/]+)/pull/(\d+)}, pr_url) do
      [_, owner, name, number] -> {:ok, owner, name, String.to_integer(number)}
      nil -> {:error, {:gh_unexpected_payload, {:unrecognised_pr_url, pr_url}}}
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
    with {:ok, status} <- status(state, mergeable),
         {:ok, checks} <- checks(Map.get(payload, "statusCheckRollup")),
         {:ok, decision} <- review_decision(Map.get(payload, "reviewDecision")),
         {:ok, merge_state} <- merge_state_status(Map.get(payload, "mergeStateStatus")),
         {:ok, reviews} <- reviews(Map.get(payload, "reviews")),
         {:ok, comments} <- comments(Map.get(payload, "comments")) do
      {check_list, checks_truncated} = bound(checks)
      {review_list, reviews_truncated} = bound(reviews)
      {comment_list, comments_truncated} = bound(comments)

      {:ok,
       %__MODULE__{
         status: status,
         head_sha: sha,
         head_branch: head,
         base_branch: base,
         review_decision: decision,
         merge_state_status: merge_state,
         checks: check_list,
         checks_state: checks_state(checks),
         checks_truncated: checks_truncated,
         reviews: review_list,
         reviews_truncated: reviews_truncated,
         comments: comment_list,
         comments_truncated: comments_truncated
       }}
    else
      :error -> {:error, {:gh_unexpected_payload, payload}}
      {:error, _} = error -> error
    end
  end

  defp from_payload(other), do: {:error, {:gh_unexpected_payload, other}}

  defp status("MERGED", _mergeable), do: {:ok, :merged}
  defp status("CLOSED", _mergeable), do: {:ok, :closed}
  defp status("OPEN", "CONFLICTING"), do: {:ok, :conflicted}
  defp status("OPEN", _mergeable), do: {:ok, :open}
  defp status(_state, _mergeable), do: :error

  # -- checks -------------------------------------------------------------

  defp checks(nil), do: {:ok, []}

  defp checks(items) when is_list(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case check(item) do
        {:ok, check} -> {:cont, {:ok, [check | acc]}}
        :error -> {:halt, {:error, {:gh_unexpected_payload, item}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp checks(other), do: {:error, {:gh_unexpected_payload, other}}

  defp check(%{"__typename" => "CheckRun", "name" => name, "status" => status} = item)
       when is_binary(name) do
    conclusion = Map.get(item, "conclusion")

    with {:ok, state} <- check_run_state(status, conclusion) do
      {:ok,
       %{
         name: name,
         kind: :check_run,
         state: state,
         conclusion: blank_to_nil(conclusion),
         url: blank_to_nil(Map.get(item, "detailsUrl")),
         workflow: blank_to_nil(Map.get(item, "workflowName"))
       }}
    end
  end

  defp check(%{"__typename" => "StatusContext", "context" => name, "state" => state} = item)
       when is_binary(name) do
    with {:ok, check_state} <- status_context_state(state) do
      {:ok,
       %{
         name: name,
         kind: :status_context,
         state: check_state,
         conclusion: state,
         url: blank_to_nil(Map.get(item, "targetUrl")),
         workflow: nil
       }}
    end
  end

  defp check(_other), do: :error

  defp check_run_state("COMPLETED", conclusion) when conclusion in @fail_conclusions,
    do: {:ok, :failing}

  defp check_run_state("COMPLETED", conclusion) when conclusion in @pass_conclusions,
    do: {:ok, :passing}

  defp check_run_state(status, _conclusion) when status in @pending_check_status,
    do: {:ok, :pending}

  defp check_run_state(_status, _conclusion), do: :error

  defp status_context_state(state) when state in ["FAILURE", "ERROR"], do: {:ok, :failing}
  defp status_context_state(state) when state in ["PENDING", "EXPECTED"], do: {:ok, :pending}
  defp status_context_state("SUCCESS"), do: {:ok, :passing}
  defp status_context_state(_state), do: :error

  defp checks_state([]), do: :none

  defp checks_state(checks) do
    states = Enum.map(checks, & &1.state)

    cond do
      :failing in states -> :failing
      :pending in states -> :pending
      true -> :passing
    end
  end

  # -- reviews / comments / decision / merge state ---------------------------

  defp review_decision(value) when value in [nil, ""], do: {:ok, nil}
  defp review_decision("APPROVED"), do: {:ok, :approved}
  defp review_decision("CHANGES_REQUESTED"), do: {:ok, :changes_requested}
  defp review_decision("REVIEW_REQUIRED"), do: {:ok, :review_required}
  defp review_decision(other), do: {:error, {:gh_unexpected_payload, {:reviewDecision, other}}}

  defp merge_state_status(nil), do: {:ok, nil}

  defp merge_state_status(value) when is_map_key(@merge_states, value),
    do: {:ok, Map.fetch!(@merge_states, value)}

  defp merge_state_status(other),
    do: {:error, {:gh_unexpected_payload, {:mergeStateStatus, other}}}

  defp reviews(nil), do: {:ok, []}

  defp reviews(items) when is_list(items) do
    collect(items, fn
      %{"id" => id, "state" => state} = item
      when is_binary(id) and is_map_key(@review_states, state) ->
        {:ok,
         %{
           id: id,
           author: login(Map.get(item, "author")),
           state: Map.fetch!(@review_states, state),
           commit_oid: commit_oid(Map.get(item, "commit")),
           submitted_at: blank_to_nil(Map.get(item, "submittedAt"))
         }}

      _other ->
        :error
    end)
  end

  defp reviews(other), do: {:error, {:gh_unexpected_payload, other}}

  defp comments(nil), do: {:ok, []}

  defp comments(items) when is_list(items) do
    items
    |> Enum.reject(&(is_map(&1) and Map.get(&1, "isMinimized") == true))
    |> collect(fn
      %{"id" => id} = item when is_binary(id) ->
        {:ok,
         %{
           id: id,
           author: login(Map.get(item, "author")),
           body: item |> Map.get("body", "") |> truncate_body(),
           url: blank_to_nil(Map.get(item, "url")),
           created_at: blank_to_nil(Map.get(item, "createdAt"))
         }}

      _other ->
        :error
    end)
  end

  defp comments(other), do: {:error, {:gh_unexpected_payload, other}}

  defp collect(items, fun) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        :error -> {:halt, {:error, {:gh_unexpected_payload, item}}}
      end
    end)
    |> case do
      {:ok, list} -> {:ok, Enum.reverse(list)}
      error -> error
    end
  end

  defp login(%{"login" => login}) when is_binary(login), do: login
  defp login(_other), do: nil

  defp commit_oid(%{"oid" => oid}) when is_binary(oid) and oid != "", do: oid
  defp commit_oid(_other), do: nil

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  defp truncate_body(body) when is_binary(body), do: String.slice(body, 0, @max_body)
  defp truncate_body(_body), do: ""

  # Newest kept: GitHub returns oldest first.
  defp bound(list) do
    if length(list) > @max_list, do: {Enum.take(list, -@max_list), true}, else: {list, false}
  end

  # -- threads ------------------------------------------------------------

  defp parse_threads(output) do
    case Jason.decode(output) do
      {:ok,
       %{
         "data" => %{
           "repository" => %{"pullRequest" => %{"reviewThreads" => %{"nodes" => nodes}}}
         }
       }}
      when is_list(nodes) ->
        with {:ok, threads} <- collect(nodes, &thread/1) do
          {list, truncated} = bound(threads)
          {:ok, {list, truncated or length(nodes) >= @max_list}}
        end

      {:ok, other} ->
        {:error, {:gh_unexpected_payload, other}}

      {:error, _} ->
        {:error, {:gh_unparsable, String.slice(output, 0, 200)}}
    end
  end

  defp thread(%{"id" => id, "isResolved" => resolved} = node)
       when is_binary(id) and is_boolean(resolved) do
    comment_nodes = get_in(node, ["comments", "nodes"]) || []

    {:ok,
     %{
       id: id,
       resolved: resolved,
       outdated: Map.get(node, "isOutdated") == true,
       path: blank_to_nil(Map.get(node, "path")),
       line: Map.get(node, "line") || Map.get(node, "originalLine"),
       comments:
         for %{"databaseId" => cid} = c <- comment_nodes do
           %{
             id: to_string(cid),
             author: login(Map.get(c, "author")),
             body: c |> Map.get("body", "") |> truncate_body(),
             url: blank_to_nil(Map.get(c, "url")),
             created_at: blank_to_nil(Map.get(c, "createdAt"))
           }
         end
     }}
  end

  defp thread(_other), do: :error
end
