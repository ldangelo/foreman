# Read-only probe for scripts/e2e/multi_repo_agent.sh, loaded into the harness's Foreman node over
# `elixir --rpc-eval 'Code.require_file(...)'` and called the same way. Every probe prints ONE line of
# JSON on the caller's stdout and changes nothing.
#
# It exists because the order of a run's events (which phase was running when a repository's worktree
# appeared) and the audit stream of repository requests have no HTTP surface a script could assert on.
defmodule E2EAgentRepoProbe do
  @moduledoc false

  alias ForemanServer.{Aggregate, EventStore}

  @fields ~w(repo_id decision reason requested_by requested_path phase_id index name operation_id worktree_path)a

  @doc """
  Every event that carries the run's id, oldest first: the phase events (`phase:<run>:<n>` streams), the
  worktree events (`vcs_operation:wt-<run>[-<repo>]`), the audit events (`run_repo_audit:<run>`) and the
  run's own. Each row has the event type, its wall-clock time (epoch ms), the stream it came from and the
  payload fields the harness asserts on. The whole log is read: the harness database holds one run.
  """
  def timeline(run_id) do
    {:ok, events} = EventStore.read_all_streams_forward(0, 99_999_999)

    rows =
      for event <- events,
          Aggregate.get(event.data, :run_id) == run_id do
        fields = for field <- @fields, value = Aggregate.get(event.data, field), into: %{}, do: {field, value}

        Map.merge(fields, %{
          stream: event.stream_uuid,
          type: event.event_type,
          at_ms: DateTime.to_unix(event.created_at, :millisecond)
        })
      end

    rows |> Enum.sort_by(& &1.at_ms) |> emit()
  end

  @doc """
  The `TaskCreated` events of the tasks one fan-out created (task id `<fanout_id>-<repo_id>`), as the event
  recorded them. The task read model drops `source`, so the link back to the fan-out is only visible here.
  """
  def fanout_tasks(fanout_id) do
    prefix = fanout_id <> "-"
    {:ok, events} = EventStore.read_all_streams_forward(0, 99_999_999)

    rows =
      for %{event_type: "TaskCreated"} = event <- events,
          task_id = Aggregate.get(event.data, :task_id),
          String.starts_with?(task_id, prefix) do
        %{
          task_id: task_id,
          source: Aggregate.get(event.data, :source),
          repo_id: Aggregate.get(event.data, :repo_id),
          workflow_type: Aggregate.get(event.data, :workflow_type)
        }
      end

    emit(rows)
  end

  defp emit(term), do: term |> jsonable() |> Jason.encode!() |> IO.puts()

  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()
  defp jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(value) when value in [nil, true, false], do: value
  defp jsonable(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp jsonable(other), do: other
end
