defmodule ForemanServer.TestSupport.FakeTaskProvider do
  @moduledoc """
  A scriptable `ForemanServer.TaskProvider` for the task-provider effect tests
  (TRD-015). It lives under `test/support` so it compiles to a real module that the
  registry and the project projector can load by name.

  Its state is an in-memory table keyed by the project's `database_path` (the one
  value a project's provider config always carries, so no pid has to travel through
  an event): `issues` (id => status and assignee), `calls` (every call it received,
  in order), a per-op `crash` (`:before` or `:after`: the call blocks forever, once
  it has applied or before it applies, so the test can kill the calling process
  exactly as a crash would), a per-op `script` of results returned instead of
  applying, and how `get/2` answers (`get_mode`).

  Start it once per test with `start_supervised!(FakeTaskProvider)`.
  """

  @behaviour ForemanServer.TaskProvider

  use Agent

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProviders.ProviderError

  @doc false
  def start_link(_opts \\ []), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  @doc "The module name as a project's `task_provider.provider` string."
  @spec provider_ref() :: String.t()
  def provider_ref, do: Atom.to_string(__MODULE__)

  @spec put_issue(String.t(), String.t(), String.t(), String.t() | nil) :: :ok
  def put_issue(db, id, status, assignee \\ nil) do
    update(db, fn s -> put_in(s, [:issues, id], %{status: status, assignee: assignee}) end)
  end

  @doc "The status the provider holds for `id`, or `nil`."
  @spec status(String.t(), String.t()) :: String.t() | nil
  def status(db, id), do: get_in(state(db), [:issues, id, :status])

  @doc "Every call received, oldest first, as `{op, issue_id}`."
  @spec calls(String.t()) :: [{atom(), String.t()}]
  def calls(db), do: Enum.reverse(state(db).calls)

  @doc "Make `op` block forever (`:before` applying, or `:after`), telling `notify` first."
  @spec crash(String.t(), atom(), :before | :after, pid()) :: :ok
  def crash(db, op, when_, notify) when when_ in [:before, :after] do
    update(db, fn s -> put_in(s, [:crash, op], {when_, notify}) end)
  end

  @doc "Stop `op` from blocking."
  @spec clear_crash(String.t(), atom()) :: :ok
  def clear_crash(db, op), do: update(db, fn s -> update_in(s, [:crash], &Map.delete(&1, op)) end)
  @doc "Results returned by successive calls of `op`, instead of applying them."
  @spec script(String.t(), atom(), [term()]) :: :ok
  def script(db, op, results), do: update(db, fn s -> put_in(s, [:script, op], results) end)

  @doc "How `get/2` answers: `:ok` (default), `{:error, term}`, `:raise`, `:exit` or `:hang`."
  @spec get_mode(String.t(), term()) :: :ok
  def get_mode(db, mode), do: update(db, fn s -> Map.put(s, :get_mode, mode) end)

  @spec error(String.t(), boolean()) :: ProviderError.t()
  def error(message, retryable?),
    do: %ProviderError{
      code: "FAKE_#{if(retryable?, do: "TRANSIENT", else: "PERMANENT")}",
      message: message,
      hint: "",
      retryable?: retryable?,
      context: %{}
    }

  # --- ForemanServer.TaskProvider ---

  @impl true
  def name, do: "fake_task_provider"

  @impl true
  def capabilities,
    do: %{
      provider_id: :fake_task_provider,
      contract_version: "br.capabilities.v1",
      id_format: "fake:%s",
      supports: [:claim, :close, :reopen, :list_ready]
    }

  @impl true
  def available?, do: true

  @impl true
  def create(_project_id, _attrs), do: {:error, error("create unsupported", false)}

  @impl true
  def list_ready(_config, _opts), do: {:ok, []}

  @impl true
  def get(id, config) do
    db = db(config)

    case Map.get(state(db), :get_mode, :ok) do
      :ok -> fetch(db, id)
      {:error, reason} -> {:error, reason}
      :raise -> raise "fake provider get failed"
      :exit -> exit(:fake_provider_down)
      :hang -> Process.sleep(:infinity)
    end
  end

  @impl true
  def claim(id, actor, config), do: act(db(config), :claim, id, "in_progress", actor)

  @impl true
  def complete(id, _token, config), do: act(db(config), :complete, id, "closed", :keep)

  @impl true
  def fail(id, _token, config), do: act(db(config), :fail, id, "blocked", :keep)

  @impl true
  def reopen(id, _comment, config) do
    case act(db(config), :reopen, id, "open", nil) do
      {:ok, _issue} -> :ok
      other -> other
    end
  end

  @impl true
  def set_priority(_id, _priority, _config), do: :ok

  @impl true
  def add_dependency(_id, _depends_on, _config), do: :ok

  @impl true
  def annotate(_id, _body, _config), do: {:error, :not_implemented}

  @doc "Every issue the provider holds (the boot scan's `coordination_status/1`)."
  @spec coordination_status(map()) :: {:ok, [Issue.t()]}
  def coordination_status(config) do
    db = db(config)
    {:ok, state(db).issues |> Map.keys() |> Enum.sort() |> Enum.map(&issue(db, &1))}
  end

  # --- internals ---

  defp act(db, op, id, new_status, assignee) do
    state = update_get(db, fn s -> {s, record(s, op, id)} end)

    case take_script(db, op) do
      {:scripted, result} ->
        result

      :none ->
        case get_in(state, [:crash, op]) do
          {:before, notify} ->
            send(notify, {:in_call, op, :before})
            Process.sleep(:infinity)

          {:after, notify} ->
            apply_change(db, id, new_status, assignee)
            send(notify, {:in_call, op, :after})
            Process.sleep(:infinity)

          nil ->
            apply_change(db, id, new_status, assignee)
        end
    end
  end

  defp apply_change(db, id, new_status, assignee) do
    update(db, fn s ->
      update_in(s, [:issues, id], fn
        nil -> %{status: new_status, assignee: if(assignee == :keep, do: nil, else: assignee)}
        %{} = held -> %{held | status: new_status, assignee: assignee_for(held, assignee)}
      end)
    end)

    fetch(db, id)
  end

  defp assignee_for(held, :keep), do: held.assignee
  defp assignee_for(_held, assignee), do: assignee

  defp record(s, op, id), do: Map.update!(s, :calls, &[{op, id} | &1])

  defp take_script(db, op) do
    update_get(db, fn s ->
      case get_in(s, [:script, op]) do
        [result | rest] -> {{:scripted, result}, put_in(s, [:script, op], rest)}
        _ -> {:none, s}
      end
    end)
  end

  defp fetch(db, id) do
    case get_in(state(db), [:issues, id]) do
      nil -> {:error, error("issue #{id} not found", false)}
      _ -> {:ok, issue(db, id)}
    end
  end

  defp issue(db, id) do
    %{status: status, assignee: assignee} = get_in(state(db), [:issues, id])

    %Issue{
      id: id,
      title: id,
      status: status,
      priority: 2,
      dependencies: [],
      assignee: assignee,
      description: nil,
      notes: nil,
      design: nil,
      labels: [],
      metadata: %{}
    }
  end

  defp db(%{} = config), do: Map.get(config, "database_path") || Map.get(config, :database_path)

  defp state(db), do: Agent.get(__MODULE__, &Map.get(&1, db, empty()))

  defp update(db, fun) do
    Agent.update(__MODULE__, fn all -> Map.put(all, db, fun.(Map.get(all, db, empty()))) end)
  end

  defp update_get(db, fun) do
    Agent.get_and_update(__MODULE__, fn all ->
      {reply, next} = fun.(Map.get(all, db, empty()))
      {reply, Map.put(all, db, next)}
    end)
  end

  defp empty, do: %{issues: %{}, calls: [], crash: %{}, script: %{}, get_mode: :ok}
end
