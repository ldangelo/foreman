defmodule ForemanServer.Coordinator.SetupProposer do
  @moduledoc """
  Posts the first-turn setup proposal (`Coordinator.SetupProposal`) into a
  project's coordinator conversation.

  Triggers, all through `propose/3`:

    * `ProjectRegistered` - the project's first conversation message;
    * startup catch-up - `ProjectionStore.subscribe(replay_existing: false)` loses
      events appended while the server was down, so `init/1` subscribes FIRST and
      then scans for active projects whose conversation has no message at all
      (subscribe-then-scan, like `Coordinator.Runner`); a duplicate between the
      two is harmless;
    * `/setup` - an operator-authored message with exactly that text asks for a
      fresh proposal (`SetupProposal.request?/1`; `Conversation.trigger?/1` keeps
      such a message away from the model).

  The proposal is a deterministic `coordinator.append` (`role: system`,
  `kind: setup_proposal`). The first one has the message id and `report_key`
  `setup_proposal:<project>`, so registration, re-delivery, a restart and the
  catch-up all append it once; each `/setup` has its own id derived from the
  request message. It is built from `Recommendations.recommend_bounded/1` in a
  task under the runtime's task supervisor (collecting can take seconds and must
  not block the subscriber). A failed collection is logged and appends nothing:
  never a partial proposal; `/setup` or the next start retries. No provider is
  called, and a project the runtime does not serve (`Runtime.serves?/2`) is
  skipped.
  """
  use GenServer

  require Logger

  alias ForemanServer.Coordinator.{Commands, Runtime, SetupProposal}
  alias ForemanServer.ProjectionStore
  alias ForemanServer.Projects.Recommendations

  @type request :: :initial | {:request, message_id :: String.t()}

  def start_link(opts) do
    rt = Keyword.fetch!(opts, :runtime)
    GenServer.start_link(__MODULE__, {rt, Keyword.get(opts, :catch_up?, true)}, name: name(rt))
  end

  @doc "Registered name of a runtime's proposer."
  @spec name(Runtime.t() | atom()) :: atom()
  def name(%Runtime{name: name}), do: name(name)
  def name(name) when is_atom(name), do: Module.concat(name, "SetupProposer")

  @impl true
  def init({rt, catch_up?}) do
    case ProjectionStore.subscribe(replay_existing: false) do
      :ok when catch_up? -> {:ok, rt, {:continue, :catch_up}}
      :ok -> {:ok, rt}
      {:error, reason} -> {:stop, {:projection_subscribe_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:catch_up, rt) do
    run(rt, fn -> catch_up(rt) end)
    {:noreply, rt}
  end

  @impl true
  def handle_info({:projection_event, event}, rt) when is_map(event) do
    data = field(event, :data) || field(event, :payload) || %{}

    case field(event, :event_type) do
      "ProjectRegistered" -> start(rt, field(data, :project_id), :initial)
      "CoordinatorMessageAppended" -> start_requested(rt, data)
      _other -> :ok
    end

    {:noreply, rt}
  end

  def handle_info(_other, rt), do: {:noreply, rt}

  @doc """
  Post a proposal for `project_id` (`:initial`, or `{:request, message_id}` for a
  `/setup`). Returns `:ok`, or `:error` after logging why nothing was appended.
  """
  @spec propose(Runtime.t(), String.t(), request()) :: :ok | :error
  def propose(%Runtime{} = rt, project_id, request) when is_binary(project_id) do
    case Recommendations.recommend_bounded(project_id) do
      {:ok, recommendations} ->
        append(rt, project_id, request, SetupProposal.format(project_id, recommendations))

      {:error, reason} ->
        Logger.warning(
          "setup proposal for #{project_id}: recommendations unavailable (#{inspect(reason)}); " <>
            "nothing posted"
        )

        :error
    end
  rescue
    exception ->
      Logger.warning(
        "setup proposal for #{project_id}: #{Exception.message(exception)}; nothing posted"
      )

      :error
  end

  @doc """
  Propose to every active project this runtime serves whose conversation has no
  message yet (the startup catch-up), one at a time.
  """
  @spec catch_up(Runtime.t()) :: :ok
  def catch_up(%Runtime{} = rt) do
    ProjectionStore.list_projects()
    |> Enum.filter(&active?/1)
    |> Enum.map(& &1.project_id)
    |> Enum.filter(&(is_binary(&1) and Runtime.serves?(rt, &1) and empty_conversation?(&1)))
    |> Enum.sort()
    |> Enum.each(&propose(rt, &1, :initial))
  end

  defp active?(project), do: project[:archived?] != true and project[:status] != "archived"

  defp empty_conversation?(project_id) do
    match?({:ok, %{messages: []}}, ProjectionStore.coordinator_state(project_id))
  end

  defp start_requested(rt, data) do
    message = %{
      role: field(data, :role),
      source: field(data, :source),
      text: field(data, :text)
    }

    message_id = field(data, :message_id)

    if is_binary(message_id) and SetupProposal.request?(message),
      do: start(rt, field(data, :project_id), {:request, message_id})
  end

  defp start(rt, project_id, request) when is_binary(project_id) do
    if Runtime.serves?(rt, project_id), do: run(rt, fn -> propose(rt, project_id, request) end)
  end

  defp start(_rt, _project_id, _request), do: :ok

  defp run(rt, fun) do
    case Task.Supervisor.start_child(rt.task_sup, fun) do
      {:ok, _pid} -> :ok
      {:error, reason} -> Logger.warning("setup proposer: task did not start: #{inspect(reason)}")
    end
  end

  defp append(rt, project_id, request, text) do
    {message_id, attrs} = identity(project_id, request)
    attrs = Map.merge(attrs, %{role: "system", kind: "setup_proposal", text: text})

    case Commands.append(rt.gateway, project_id, message_id, attrs) do
      {:ok, _event} ->
        :ok

      other ->
        Logger.warning("setup proposal for #{project_id}: append failed: #{inspect(other)}")
        :error
    end
  end

  defp identity(project_id, :initial) do
    key = "setup_proposal:" <> project_id
    {key, %{report_key: key}}
  end

  defp identity(project_id, {:request, message_id}) when is_binary(message_id),
    do: {"setup_proposal:#{project_id}:#{message_id}", %{}}

  defp field(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp field(_other, _key), do: nil
end
