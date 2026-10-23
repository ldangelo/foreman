defmodule ForemanServer.Coordinator.Runner do
  @moduledoc """
  Long-lived reactor that wakes the per-project workers
  (`Coordinator.ProjectWorker`), shaped like `Review.Analyzer`.

  `ProjectionStore.subscribe(replay_existing: false)` means anything appended
  while the server was down is never delivered, and a lost operator message is a
  lost request. So `init/1` subscribes FIRST and then scans
  `ProjectionStore.coordinator_pending_projects/0` (messages no completed turn
  consumed, or an open turn): subscribe-then-scan closes the gap, and a duplicate
  between the two is harmless because the aggregate admits one open turn and
  every command id is deterministic.

  Wake-ups: `CoordinatorMessageAppended` (operator messages and reports) and
  `CoordinatorRestarted`. The Runner never decides what is pending: the worker
  reads the projection.
  """
  use GenServer

  alias ForemanServer.Coordinator.{ProjectWorker, Runtime}
  alias ForemanServer.ProjectionStore

  @wake_events ~w(CoordinatorMessageAppended CoordinatorRestarted)

  def start_link(opts) do
    rt = Keyword.fetch!(opts, :runtime)
    GenServer.start_link(__MODULE__, rt, name: rt.name)
  end

  @doc "Projects with a running worker, and which of them are mid-turn."
  @spec health(Runtime.t()) :: %{workers: [String.t()], busy: [String.t()]}
  def health(%Runtime{} = rt) do
    workers =
      Registry.select(rt.registry, [{{:"$1", :_, :_}, [{:is_binary, :"$1"}], [:"$1"]}])
      |> Enum.sort()

    %{workers: workers, busy: Enum.filter(workers, &ProjectWorker.busy?(rt, &1))}
  end

  @impl true
  def init(%Runtime{} = rt) do
    case ProjectionStore.subscribe(replay_existing: false) do
      :ok ->
        for project_id <- ProjectionStore.coordinator_pending_projects(),
            Runtime.serves?(rt, project_id) do
          ProjectWorker.notify(rt, project_id)
        end

        {:ok, rt}

      {:error, reason} ->
        {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_info({:projection_event, event}, rt) when is_map(event) do
    with type when type in @wake_events <- field(event, :event_type),
         project_id when is_binary(project_id) <- project_id(event),
         true <- Runtime.serves?(rt, project_id) do
      ProjectWorker.notify(rt, project_id)
    end

    {:noreply, rt}
  end

  def handle_info(_other, rt), do: {:noreply, rt}

  defp project_id(event) do
    data = field(event, :data) || field(event, :payload) || event
    field(data, :project_id)
  end

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_other, _key), do: nil
end
