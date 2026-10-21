defmodule ForemanServer.PrWatchFold do
  @moduledoc """
  Pure fold of the E9 PR-watch events into `ProjectionStore`'s `pr_watch`
  read model: `%{run_id => %{pr_url => record}}`.

  A record is one watched PR of one run (keyed `{run_id, pr_url}`; `repo_id` is
  carried, nullable, for the multi-repo future). Fields: `pr_url`, `repo_id`,
  `project_id`, `task_id`, `status` (`"open" | "conflicted" | "merged" |
  "closed"`), `head_sha`, `base_branch`, `branch_name`, `checks_state`,
  `failing` (names), `checks_digest`, `checks_seq`, `review_decision`,
  `review_digest`, `review_seq`, `comment_ids`, `thread_ids`, `watching` (+
  `stop_reason` once stopped: `operator | merged | closed`),
  `fix` (attempts, in-flight, last outcome, exhausted kinds), `updated_at`.

  Never raises: an event whose payload lacks a usable `run_id` / `pr_url` is
  logged at `:warning` and skipped, because this runs inside
  `ProjectionStore.init/1`'s replay, where a raise would stop the application at
  boot. Payloads arrive with atom keys (live) or string keys (replayed from the
  JSON event log); both are read through `get/2`.
  """

  require Logger

  @events ~w(PrUpdated PrReady PrMerged PrChecksChanged PrReviewChanged PrFixRequested
             PrFixStarted PrFixFinished PrFixExhausted PrWatchStopped PrWatchStarted)

  @type watch_record :: map()
  @type t :: %{String.t() => %{String.t() => watch_record()}}

  @doc "Event types this fold consumes."
  @spec events() :: [String.t()]
  def events, do: @events

  @doc "The record of a freshly seen PR."
  @spec new_record(String.t(), String.t()) :: watch_record()
  def new_record(run_id, pr_url) do
    %{
      run_id: run_id,
      pr_url: pr_url,
      repo_id: nil,
      project_id: nil,
      task_id: nil,
      status: nil,
      head_sha: nil,
      base_branch: nil,
      branch_name: nil,
      checks_state: nil,
      failing: [],
      checks_digest: nil,
      checks_seq: 0,
      review_decision: nil,
      review_digest: nil,
      review_seq: 0,
      comment_ids: [],
      thread_ids: [],
      watching: true,
      stop_reason: nil,
      fix: new_fix(),
      updated_at: nil
    }
  end

  defp new_fix do
    %{
      attempts: %{},
      in_flight: nil,
      in_flight_kind: nil,
      in_flight_attempt: nil,
      in_flight_head_sha: nil,
      last_outcome: %{},
      last_fix_head_sha: nil,
      last_finished_at: nil,
      exhausted: %{}
    }
  end

  @doc """
  Fold one event into the watch map. Unrelated events and malformed payloads
  return `watch` unchanged.
  """
  @spec fold(t(), String.t(), map()) :: t()
  def fold(watch, type, payload) when type in @events and is_map(payload) do
    run_id = get(payload, :run_id)
    pr_url = get(payload, :pr_url)

    if present?(run_id) and present?(pr_url) do
      record = watch |> Map.get(run_id, %{}) |> Map.get(pr_url) || new_record(run_id, pr_url)

      updated =
        record
        |> common(payload)
        |> apply_event(type, payload)

      Map.update(watch, run_id, %{pr_url => updated}, &Map.put(&1, pr_url, updated))
    else
      Logger.warning("PrWatchFold: #{type} without usable run_id/pr_url skipped")
      watch
    end
  end

  def fold(watch, _type, _payload), do: watch

  defp common(record, payload) do
    record
    |> put(:project_id, get(payload, :project_id))
    |> put(:task_id, get(payload, :task_id))
    |> put(:repo_id, get(payload, :repo_id))
    |> put(:updated_at, get(payload, :_projection_event_at_ms))
  end

  defp apply_event(record, "PrUpdated", payload) do
    record
    |> put(:status, status(get(payload, :pr_status)))
    |> put(:head_sha, get(payload, :head_sha))
    |> put(:base_branch, get(payload, :base_branch))
    |> put(:branch_name, get(payload, :branch_name))
  end

  defp apply_event(record, "PrReady", payload) do
    record
    |> Map.put(:status, record.status || "open")
    |> put(:head_sha, get(payload, :head_sha))
    |> put(:base_branch, get(payload, :base_branch))
    |> put(:branch_name, get(payload, :branch_name))
  end

  defp apply_event(record, "PrMerged", _payload), do: %{record | status: "merged"}

  defp apply_event(record, "PrChecksChanged", payload) do
    record
    |> put(:status, status(get(payload, :pr_status)))
    |> put(:head_sha, get(payload, :head_sha))
    |> put(:base_branch, get(payload, :base_branch))
    |> put(:branch_name, get(payload, :branch_name))
    |> Map.put(:checks_state, get(payload, :checks_state))
    |> Map.put(:failing, failing_names(get(payload, :failing)))
    |> Map.put(:checks_digest, get(payload, :digest))
    |> Map.put(:checks_seq, get(payload, :observation_seq) || record.checks_seq)
  end

  defp apply_event(record, "PrReviewChanged", payload) do
    record
    |> put(:status, status(get(payload, :pr_status)))
    |> put(:head_sha, get(payload, :head_sha))
    |> Map.put(:review_decision, get(payload, :review_decision))
    |> Map.put(:review_digest, get(payload, :digest))
    |> Map.put(:review_seq, get(payload, :observation_seq) || record.review_seq)
    |> Map.put(:comment_ids, list(get(payload, :comment_ids)))
    |> Map.put(:thread_ids, list(get(payload, :thread_ids)))
  end

  defp apply_event(record, "PrFixRequested", payload) do
    kind = get(payload, :kind)

    update_fix(record, fn fix ->
      %{
        fix
        | attempts: Map.put(fix.attempts, kind, get(payload, :attempt)),
          in_flight: :requested,
          in_flight_kind: kind,
          in_flight_attempt: get(payload, :attempt),
          in_flight_head_sha: get(payload, :head_sha)
      }
    end)
  end

  defp apply_event(record, "PrFixStarted", payload) do
    update_fix(record, fn fix -> %{fix | in_flight: get(payload, :jobsite_id)} end)
  end

  defp apply_event(record, "PrFixFinished", payload) do
    kind = get(payload, :kind)

    update_fix(record, fn fix ->
      %{
        fix
        | in_flight: nil,
          in_flight_kind: nil,
          in_flight_attempt: nil,
          in_flight_head_sha: nil,
          last_outcome: Map.put(fix.last_outcome, kind, get(payload, :outcome)),
          last_fix_head_sha: get(payload, :new_head_sha) || fix.last_fix_head_sha,
          last_finished_at: get(payload, :finished_at)
      }
    end)
  end

  defp apply_event(record, "PrFixExhausted", payload) do
    update_fix(record, fn fix ->
      %{fix | exhausted: Map.put(fix.exhausted, get(payload, :kind), get(payload, :head_sha))}
    end)
  end

  defp apply_event(record, "PrWatchStopped", payload),
    do: %{record | watching: false, stop_reason: get(payload, :reason)}

  defp apply_event(record, "PrWatchStarted", _payload),
    do: %{record | watching: true, stop_reason: nil}

  defp update_fix(record, fun), do: %{record | fix: fun.(record.fix)}

  defp failing_names(failing) when is_list(failing),
    do: for(item <- failing, name = get(item, :name), is_binary(name), do: name)

  defp failing_names(_other), do: []

  defp list(value) when is_list(value), do: value
  defp list(_other), do: []

  defp status(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp status(value), do: value

  defp put(record, _key, nil), do: record
  defp put(record, key, value), do: Map.put(record, key, value)

  defp present?(value), do: is_binary(value) and value != ""

  defp get(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp get(_other, _key), do: nil
end
