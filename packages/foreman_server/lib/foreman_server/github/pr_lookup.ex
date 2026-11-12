defmodule ForemanServer.GitHub.PrLookup do
  @moduledoc """
  The pull request GitHub already has for a head and a base branch (TRD-004, precondition
  P-2): `gh pr list` run in the project checkout through the injectable runner of
  `ForemanServer.Idempotency.Reconcilers.Command`.

      gh pr list --state <open|closed> --head <head> --base <base> \\
        --json url,number,state,headRefOid,isCrossRepository --limit 5

  `--head` takes a branch NAME and matches it whatever repository the PR's head is in, so a
  fork's PR of the same branch name comes back too (`isCrossRepository: true`); `--state
  closed` returns merged PRs as well (probed with gh 2.103.3). A PR is therefore the run's
  only when it is this repository's and its head is the commit the run pushed:

    * `find/4` drops every PR with `isCrossRepository: true`: a fork's PR is not the run's PR
      and is never adopted;
    * given `:expected_head`, the first remaining PR whose `headRefOid` equals it is
      `{:ok, %Pr{}}`; no PR left is `:none`; a PR of this repository with another head is
      `{:error, {:pr_lookup_mismatch, url, expected, actual}}`, never adopted;
    * without `:expected_head`, the first remaining PR is `{:ok, %Pr{}}`.

  A lookup that cannot be trusted is an error and never a PR: `{:gh_failed, code, output}`
  for a non-zero exit, `{:unparsable_pr_list, text}` for an answer that is not JSON,
  `{:unexpected_pr_list_payload, term}` for JSON that is not a list of items with a `url`, a
  `number`, a known `state`, a `headRefOid` and a boolean `isCrossRepository` (one bad item
  rejects the answer), and `Command.run/4`'s own error (`{:command_not_run, ...}`,
  `{:timeout, ms}`, ...) when `gh` could not be run. A caller that must act anyway (creation
  stays the loud authority) reads every error as "nothing found" and carries on.

  `opts`: `:cwd` (required, the checkout `gh` runs in), `:command_runner` (a 3-arity
  `(cmd, args, opts)` returning `{output, exit_code}`; `System.cmd/3` by default),
  `:expected_head` (a commit SHA) and `:timeout_ms` (`Command.run/4`; unbounded by default).
  Absent options are omitted, never `nil`; a present option of another type raises.
  """

  alias ForemanServer.Idempotency.Reconcilers.Command

  defmodule Pr do
    @moduledoc "A pull request of this repository, as `gh pr list` reports it."
    @enforce_keys [:url, :number, :state, :head_sha]
    defstruct [:url, :number, :state, :head_sha]

    @type t :: %__MODULE__{
            url: String.t(),
            number: pos_integer(),
            state: :open | :closed | :merged,
            head_sha: String.t()
          }
  end

  @type state :: :open | :closed

  @type error ::
          {:pr_lookup_mismatch, url :: String.t(), expected :: String.t(), actual :: String.t()}
          | {:gh_failed, integer(), String.t()}
          | {:unexpected_pr_list_payload, term()}
          | {:unparsable_pr_list, String.t()}
          | term()

  @type result :: {:ok, Pr.t()} | :none | {:error, error()}

  @json_fields "url,number,state,headRefOid,isCrossRepository"
  @limit "5"
  @states %{"OPEN" => :open, "CLOSED" => :closed, "MERGED" => :merged}

  @doc """
  The PR of this repository for `head` and `base` in `state` (`:open`, or `:closed`, which
  includes merged PRs). See the module doc for the answers.
  """
  @spec find(state(), String.t(), String.t(), keyword()) :: result()
  def find(state, head, base, opts)
      when state in [:open, :closed] and is_binary(head) and head != "" and is_binary(base) and
             base != "" and is_list(opts) do
    cwd = fetch_cwd!(opts)
    expected = fetch_expected_head!(opts)
    runner = Keyword.get(opts, :command_runner) || (&System.cmd/3)

    args = [
      "pr",
      "list",
      "--state",
      Atom.to_string(state),
      "--head",
      head,
      "--base",
      base,
      "--json",
      @json_fields,
      "--limit",
      @limit
    ]

    case Command.run(runner, "gh", args, [cd: cwd] ++ Keyword.take(opts, [:timeout_ms])) do
      {:ok, {output, 0}} ->
        with {:ok, prs} <- parse(output), do: pick(prs, expected)

      {:ok, {output, code}} ->
        {:error, {:gh_failed, code, String.trim(output)}}

      {:error, _reason} = error ->
        error
    end
  end

  @doc "`find/4` for the open PR."
  @spec find_open(String.t(), String.t(), keyword()) :: result()
  def find_open(head, base, opts), do: find(:open, head, base, opts)

  defp fetch_cwd!(opts) do
    case Keyword.fetch(opts, :cwd) do
      {:ok, cwd} when is_binary(cwd) and cwd != "" ->
        cwd

      other ->
        raise ArgumentError,
              "PrLookup needs opts[:cwd], the checkout gh runs in; got #{inspect(other)}"
    end
  end

  defp fetch_expected_head!(opts) do
    case Keyword.fetch(opts, :expected_head) do
      :error ->
        nil

      {:ok, sha} when is_binary(sha) ->
        case normalize_sha(sha) do
          {:ok, sha} -> sha
          :error -> raise ArgumentError, "PrLookup opts[:expected_head] is blank"
        end

      {:ok, other} ->
        raise ArgumentError,
              "PrLookup opts[:expected_head] must be a commit SHA string, got #{inspect(other)}"
    end
  end

  defp parse(output) do
    text = String.trim(output)

    case Jason.decode(text) do
      {:ok, items} when is_list(items) -> parse_items(items)
      {:ok, other} -> {:error, {:unexpected_pr_list_payload, other}}
      {:error, _} -> {:error, {:unparsable_pr_list, String.slice(text, 0, 200)}}
    end
  end

  # `{:ok, [{cross_repository?, %Pr{}}]}`, or the whole answer as the unexpected payload
  # when any item is unusable: a PR this code cannot classify is never skipped.
  defp parse_items(items) do
    items
    |> Enum.reduce_while({:ok, []}, fn item, {:ok, parsed} ->
      case parse_item(item) do
        {:ok, entry} -> {:cont, {:ok, [entry | parsed]}}
        :error -> {:halt, {:error, {:unexpected_pr_list_payload, items}}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      {:error, _} = error -> error
    end
  end

  defp parse_item(%{
         "url" => url,
         "number" => number,
         "state" => state,
         "headRefOid" => head_sha,
         "isCrossRepository" => cross_repository?
       })
       when is_binary(url) and url != "" and is_integer(number) and number > 0 and
              is_binary(head_sha) and is_boolean(cross_repository?) do
    with {:ok, state} <- Map.fetch(@states, state),
         {:ok, head_sha} <- normalize_sha(head_sha) do
      {:ok, {cross_repository?, %Pr{url: url, number: number, state: state, head_sha: head_sha}}}
    end
  end

  defp parse_item(_item), do: :error

  defp normalize_sha(sha) do
    case sha |> String.trim() |> String.downcase() do
      "" -> :error
      sha -> {:ok, sha}
    end
  end

  defp pick(parsed, expected) do
    case for({false, pr} <- parsed, do: pr) do
      [] -> :none
      [first | _] = prs -> choose(prs, first, expected)
    end
  end

  defp choose(_prs, first, nil), do: {:ok, first}

  defp choose(prs, first, expected) do
    case Enum.find(prs, &(&1.head_sha == expected)) do
      %Pr{} = pr -> {:ok, pr}
      nil -> {:error, {:pr_lookup_mismatch, first.url, expected, first.head_sha}}
    end
  end
end
