# Read-only probes for scripts/e2e/multi_repo.sh, compiled into the harness's Foreman
# node by boot.exs and called over `elixir --rpc-eval` from the shell. Every probe
# prints ONE line of JSON on the caller's stdout and changes nothing.
#
# They exist because the multi-repo read models (worktrees per repository, PR
# associations per repository, the derived `completed_with_errors` flag, event
# payload keys) have no HTTP surface a script could assert against. They call the
# same public readers the dashboard and the CLI use.
defmodule E2EMultiRepoProbe do
  @moduledoc false

  alias ForemanServer.EventStore
  alias ForemanServer.ProjectionStore
  alias ForemanServerWeb.OperatorDashboard

  @doc "Per-repository state of one run, as the product's own read models report it."
  def run(run_id) do
    {:ok, rows} = OperatorDashboard.list_runs(%{})
    dto = Enum.find(rows, &(&1.run_id == run_id))

    emit(%{
      run_id: run_id,
      status: dto && dto.status,
      completed_with_errors: dto && dto.completed_with_errors,
      repositories: ProjectionStore.run_repositories(run_id),
      pr_associations: ProjectionStore.pr_associations_for_run(run_id),
      worktrees: ProjectionStore.worktrees_for_run(run_id)
    })
  end

  @doc """
  Every event that belongs to the run or its task, with the payload keys it carries
  (`keys`) and the ones it carries with a `nil` value (`nil_keys`).
  """
  def events(run_id, task_id) do
    {:ok, events} = EventStore.read_all_streams_forward(0, 99_999_999)

    rows =
      for event <- events,
          payload = payload(event.data),
          mentions?(payload, run_id, task_id) do
        %{
          stream: event.stream_uuid,
          type: event.event_type,
          keys: for({k, v} <- payload, not is_nil(v), do: to_string(k)),
          nil_keys: for({k, nil} <- payload, do: to_string(k))
        }
      end

    emit(rows)
  end

  @doc "Opens (`true`) or closes (`false`) the multi-repo run gate on this node."
  def gate(open?) when is_boolean(open?) do
    Application.put_env(:foreman_server, :multi_repo, runs: open?)
    emit(%{multi_repo: Application.get_env(:foreman_server, :multi_repo)})
  end

  defp mentions?(payload, run_id, task_id) do
    get(payload, :run_id) == run_id or
      (get(payload, :task_id) == task_id and is_nil(get(payload, :run_id)))
  end

  defp payload(%_{} = struct), do: Map.from_struct(struct)
  defp payload(%{} = map), do: map
  defp payload(_other), do: nil

  defp get(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))

  defp emit(term), do: term |> jsonable() |> Jason.encode!() |> IO.puts()

  defp jsonable(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp jsonable(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
  defp jsonable(%_{} = struct), do: struct |> Map.from_struct() |> jsonable()
  defp jsonable(map) when is_map(map), do: Map.new(map, fn {k, v} -> {to_string(k), jsonable(v)} end)
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(value) when value in [nil, true, false], do: value
  defp jsonable(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp jsonable(other) when is_pid(other) or is_reference(other) or is_function(other), do: inspect(other)
  defp jsonable(other), do: other
end
