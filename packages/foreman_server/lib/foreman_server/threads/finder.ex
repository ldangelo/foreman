defmodule ForemanServer.Threads.Finder do
  @moduledoc """
  Deterministic lookup of the thread an operator request most likely refers to.

  No LLM is involved; the coordinator decides what to do with the answer.
  Candidates are ranked by, in order:

    1. `:external_id` - the thread's task is bound to the given bead/external id
    2. `:branch` - the thread's worktree/jobsite branch equals the given branch
    3. `:pr` - the thread's PR matches the given URL or PR number (`"12"`, `"#12"`)
    4. `:text` - lower-cased token Jaccard overlap between the query and the
       task title plus the first #{200} characters of its prompt, at or above
       #{0.5}

  Only the first three are exact matches (`score` 1.0); they include resolved
  threads so a caller can tell a resolved thread exists. Text matches are
  `suggested` only and skip resolved and deleted threads. Ties resolve by
  newest `updated_at`, then thread id.
  """

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Threads
  alias ForemanServer.Threads.Thread

  defmodule Candidate do
    @moduledoc "One ranked thread match."
    @enforce_keys [:thread_id, :reason, :score]
    @type reason :: :external_id | :branch | :pr | :text
    @type t :: %__MODULE__{
            thread_id: String.t(),
            reason: reason(),
            score: float(),
            title: String.t() | nil,
            status: String.t() | nil,
            branch: String.t() | nil,
            resolved: boolean()
          }
    defstruct [:thread_id, :reason, :score, :title, :status, :branch, resolved: false]
  end

  @default_limit 5
  @text_threshold 0.5
  @prompt_head_chars 200
  @reason_rank %{external_id: 0, branch: 1, pr: 2, text: 3}
  @stopwords ~w(a an and are as at be by for from in into is it of on or the this that to with)

  @type opts :: [
          external_id: String.t() | nil,
          branch: String.t() | nil,
          pr: String.t() | nil,
          text: String.t() | nil,
          limit: pos_integer()
        ]

  @doc """
  Ranked candidates for `project_id`, or `{:error, :no_criteria}` when no
  criterion is given (blank values count as absent).
  """
  @spec find(String.t(), opts() | map()) :: {:ok, [Candidate.t()]} | {:error, :no_criteria}
  def find(project_id, opts) when is_binary(project_id) and (is_list(opts) or is_map(opts)) do
    criteria = %{
      external_id: blank_to_nil(fetch(opts, :external_id)),
      branch: blank_to_nil(fetch(opts, :branch)),
      pr: blank_to_nil(fetch(opts, :pr)),
      text: blank_to_nil(fetch(opts, :text))
    }

    if Enum.all?(Map.values(criteria), &is_nil/1) do
      {:error, :no_criteria}
    else
      {:ok, rank(project_id, criteria, limit(fetch(opts, :limit)))}
    end
  end

  @doc "String-keyed wire form of a candidate (REST and MCP)."
  @spec to_dto(Candidate.t()) :: %{String.t() => term()}
  def to_dto(%Candidate{} = c) do
    %{
      "thread_id" => c.thread_id,
      "reason" => Atom.to_string(c.reason),
      "score" => c.score,
      "title" => c.title,
      "status" => c.status,
      "branch" => c.branch,
      "resolved" => c.resolved,
      "suggested" => c.reason == :text
    }
  end

  defp rank(project_id, criteria, limit) do
    tasks =
      for task <- ProjectionStore.list_tasks(),
          task[:project_id] == project_id,
          into: %{},
          do: {task[:task_id], task}

    project_id
    |> Threads.list(limit: Threads.max_limit())
    |> Enum.flat_map(fn %Thread{} = thread ->
      task = thread.task_id && Map.get(tasks, thread.task_id)

      case match(thread, task, criteria) do
        nil -> []
        {reason, score} -> [{thread, reason, score}]
      end
    end)
    |> Enum.sort_by(fn {thread, reason, score} ->
      {Map.fetch!(@reason_rank, reason), -score, -(thread.updated_at || 0), thread.id}
    end)
    |> Enum.take(limit)
    |> Enum.map(fn {thread, reason, score} ->
      %Candidate{
        thread_id: thread.id,
        reason: reason,
        score: score,
        title: thread.title,
        status: thread.status,
        branch: thread.branch,
        resolved: thread.resolved
      }
    end)
  end

  defp match(thread, task, criteria) do
    cond do
      criteria.external_id && task && task[:external_id] == criteria.external_id ->
        {:external_id, 1.0}

      criteria.branch && thread.branch == criteria.branch ->
        {:branch, 1.0}

      criteria.pr && pr_match?(thread.pr_url, criteria.pr) ->
        {:pr, 1.0}

      criteria.text && text_candidate?(thread) ->
        text_score(task, criteria.text)

      true ->
        nil
    end
  end

  defp text_candidate?(%Thread{resolved: true}), do: false
  defp text_candidate?(%Thread{status: "deleted"}), do: false
  defp text_candidate?(%Thread{}), do: true

  defp text_score(nil, _text), do: nil

  defp text_score(task, text) do
    head = task |> Map.get(:prompt) |> to_string() |> String.slice(0, @prompt_head_chars)
    score = jaccard(tokens(text), tokens("#{task[:title]} #{head}"))
    if score >= @text_threshold, do: {:text, score}, else: nil
  end

  defp jaccard(a, b) do
    union = MapSet.size(MapSet.union(a, b))
    if union == 0, do: 0.0, else: MapSet.size(MapSet.intersection(a, b)) / union
  end

  defp tokens(text) do
    text
    |> String.downcase()
    |> String.split(~r/[^[:alnum:]]+/u, trim: true)
    |> Enum.reject(&(&1 in @stopwords))
    |> MapSet.new()
  end

  defp pr_match?(nil, _pr), do: false

  defp pr_match?(pr_url, pr) do
    pr = String.trim_leading(pr, "#")

    pr_url == pr or
      (Regex.match?(~r/\A\d+\z/, pr) and pr_number(pr_url) == pr)
  end

  defp pr_number(url) do
    case Regex.run(~r{/(\d+)/?\z}, url) do
      [_, number] -> number
      nil -> nil
    end
  end

  defp limit(value) when is_integer(value) and value >= 1, do: min(value, Threads.max_limit())
  defp limit(_), do: @default_limit

  defp fetch(opts, key) when is_list(opts), do: Keyword.get(opts, key)
  defp fetch(opts, key) when is_map(opts), do: Map.get(opts, key)

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_), do: nil
end
