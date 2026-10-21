defmodule ForemanServer.TestSupport.CoordinatorHelpers do
  @moduledoc """
  Shared fixtures for coordinator tests: a registered project, a spy gateway that
  forwards to the real `CommandGateway`, fake thread read/steer modules, and an
  event-driven `await_event/3` (no sleeps).
  """

  alias ForemanServer.{CommandRouter, ProjectionStore}
  alias ForemanServer.Threads.Thread

  def register_project(dir, opts \\ []) do
    project_id = Keyword.get(opts, :id, "co-#{System.unique_integer([:positive])}")
    config = Keyword.get(opts, :config, %{})

    {:ok, _} =
      CommandRouter.dispatch(%{
        type: "project.register",
        aggregate_id: "project:#{project_id}",
        payload: %{project_id: project_id, path: dir, config: config}
      })

    project_id
  end

  @doc "Subscribe the calling test process to projection events."
  def subscribe!, do: :ok = ProjectionStore.subscribe(replay_existing: false)

  @doc """
  Wait for a projection event of `type` whose decoded payload satisfies `pred`.
  Returns the payload. Fails the test (via `flunk/1`) after `timeout` ms.
  """
  def await_event(type, pred \\ fn _ -> true end, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_await(type, pred, deadline, [])
  end

  # Events that do not match are put back (in order) so a later await can still
  # see them: two awaits for the same type in one test must not steal each other's.
  defp do_await(type, pred, deadline, skipped) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {:projection_event, event} ->
        if field(event, :event_type) == type and pred.(payload(event)) do
          Enum.each(Enum.reverse(skipped), &send(self(), {:projection_event, &1}))
          payload(event)
        else
          do_await(type, pred, deadline, [event | skipped])
        end
    after
      remaining ->
        Enum.each(Enum.reverse(skipped), &send(self(), {:projection_event, &1}))
        ExUnit.Assertions.flunk("timed out waiting for #{type}")
    end
  end

  def payload(event) do
    data = field(event, :data) || field(event, :payload) || %{}
    Map.new(data, fn {k, v} -> {to_atom(k), v} end)
  end

  defp to_atom(k) when is_binary(k), do: String.to_atom(k)
  defp to_atom(k), do: k

  defp field(map, key) do
    case Map.fetch(map, key) do
      {:ok, v} -> v
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  def thread(project_id, n, status, opts \\ []) do
    %Thread{
      id: Keyword.get(opts, :id, "run:r#{n}"),
      door: :workflow,
      project_id: project_id,
      task_id: Keyword.get(opts, :task_id),
      title: "Thread #{n}",
      status: status,
      resolved: Keyword.get(opts, :resolved, false)
    }
  end

  defmodule SpyGateway do
    @moduledoc "Forwards to the real gateway and tells the test process every command."
    alias ForemanServer.CommandGateway

    def watch(pid \\ self()), do: :persistent_term.put({__MODULE__, :pid}, pid)
    def unwatch, do: :persistent_term.erase({__MODULE__, :pid})

    def dispatch_system(command) do
      note(command)
      CommandGateway.dispatch_system(command)
    end

    def dispatch_system_approval(command) do
      note(command)
      CommandGateway.dispatch_system_approval(command)
    end

    defp note(command) do
      case :persistent_term.get({__MODULE__, :pid}, nil) do
        nil -> :ok
        pid -> send(pid, {:gateway, command.type, command})
      end
    end

    @doc "Drain every spied command so far."
    def drain(acc \\ []) do
      receive do
        {:gateway, type, command} -> drain([{type, command} | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end
  end

  defmodule FakeThreads do
    @moduledoc "Thread read model backed by a persistent_term list (tests run sync)."
    def put(threads), do: :persistent_term.put({__MODULE__, :threads}, threads)
    def clear, do: :persistent_term.erase({__MODULE__, :threads})
    defp all, do: :persistent_term.get({__MODULE__, :threads}, [])

    def list(project_id, opts) do
      resolved = Keyword.get(opts, :resolved)

      Enum.filter(all(), fn t ->
        t.project_id == project_id and (is_nil(resolved) or t.resolved == resolved)
      end)
    end

    def get(id) do
      case Enum.find(all(), &(&1.id == id)) do
        nil -> {:error, :thread_not_found}
        thread -> {:ok, thread}
      end
    end
  end

  defmodule FakeThreadActions do
    @moduledoc "Records follow-ups; the result is `:persistent_term` configurable."
    def respond_with(result), do: :persistent_term.put({__MODULE__, :result}, result)
    def clear, do: :persistent_term.erase({__MODULE__, :result})

    def follow_up(thread_id, text, opts) do
      case :persistent_term.get({SpyGateway, :pid}, nil) do
        nil -> :ok
        pid -> send(pid, {:follow_up, thread_id, text, opts})
      end

      :persistent_term.get({__MODULE__, :result}, {:ok, %{message_id: Keyword.get(opts, :message_id), mode: :pause_resume}})
    end
  end

  def event_count(stream) do
    case ForemanServer.EventStore.read_stream_forward(stream, 0, 10_000) do
      {:ok, events} -> length(events)
      {:error, :stream_not_found} -> 0
    end
  end
end
