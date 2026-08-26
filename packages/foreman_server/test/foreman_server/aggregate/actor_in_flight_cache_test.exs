defmodule ForemanServer.ActorInFlightCacheTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Task, as: TaskAggregate
  alias ForemanServer.CommandRouter

  alias ForemanServer.TaskProvider
  alias ForemanServer.TestSupport.TestApplication

  setup do
    _registry_pid = TestApplication.reset_application_child!(TaskProvider.Registry)
    :ok
  end

  describe "AC-024-1 init: in_flight_beads default in init/1" do
    test "init/1 returns state with in_flight_beads: %{} and version 0" do
      task_id = "task-#{uuid()}"
      pid = start_task_actor(task_id)
      state = :sys.get_state(pid)

      assert state.in_flight_beads == %{}
      assert state.aggregate_id == "task:#{task_id}"
      assert state.aggregate_module == TaskAggregate
      assert state.version == 0
    end

    test "init/1 rehydrates version from the event store and keeps cache empty" do
      task_id = "task-#{uuid()}"
      warmup = build_task_create(task_id, project_id: "project-warm", title: "warm")

      assert {:ok, _} = CommandRouter.dispatch(warmup, 5_000)
      assert :sys.get_state(start_task_actor(task_id)).version == 1

      pid = start_task_actor(task_id)
      state = :sys.get_state(pid)

      assert state.in_flight_beads == %{}
      assert state.version == 1
    end
  end

  describe "AC-024-2 cleared after append confirmation" do
    test "do_commit removes only the current command_id; pre-existing entries survive" do
      task_id = "task-#{uuid()}"
      pid = start_task_actor(task_id)

      stale = %{"cmd-stale" => "bead-stale"}
      :sys.replace_state(pid, fn state -> %{state | in_flight_beads: stale} end)

      cmd = build_task_create(task_id, project_id: "project-#{uuid()}", title: "real")
      assert {:ok, _} = CommandRouter.dispatch(cmd, 5_000)

      assert :sys.get_state(pid).in_flight_beads == stale
    end

    test "no provider registered: legacy no-op leaves cache empty" do
      task_id = "task-#{uuid()}"
      pid = start_task_actor(task_id)

      cmd = build_task_create(task_id, project_id: "project-#{uuid()}", title: "noop")
      assert {:ok, _} = CommandRouter.dispatch(cmd, 5_000)

      assert :sys.get_state(pid).in_flight_beads == %{}
    end
  end

  describe "AC-024 reload_after_conflict preserves in_flight_beads" do
    test "sentinel survives reload_after_conflict + re-decision rejection" do
      task_id = "task-#{uuid()}"

      # 1. Seed the stream with a real TaskCreated event so the
      #    EventStore has version = 1.
      warmup = build_task_create(task_id, project_id: "project-warm", title: "warm")
      assert {:ok, _} = CommandRouter.dispatch(warmup, 5_000)

      pid = start_task_actor(task_id)
      assert :sys.get_state(pid).version == 1

      # 2. Reset the actor's in-memory state: pretend it has a stale
      #    version=0 with empty module_state, plus a sentinel cache
      #    entry that must survive the conflict round-trip.
      sentinel = %{"cmd-sentinel" => "bead-sentinel"}

      :sys.replace_state(pid, fn state ->
        %{
          state
          | version: 0,
            module_state: TaskAggregate.initial_state(),
            in_flight_beads: sentinel
        }
      end)

      assert :sys.get_state(pid).in_flight_beads == sentinel

      # 3. Dispatch the SAME task.create with a NEW command_id. The
      #    actor decides from stale state, sends the append with
      #    expected_version=0, the EventStore rejects with
      #    :wrong_expected_version, reload_after_conflict rehydrates
      #    module_state + version=1, then re-decision rejects via
      #    require_absent (the task is already on the stream).
      cmd = build_task_create(task_id, project_id: "project-warm", title: "warm")
      assert {:error, _reason} = CommandRouter.dispatch(cmd, 5_000)

      # 4. Sentinel survived reload_after_conflict; the rejection
      #    reply path does not call clear_cache_on_success.
      post_state = :sys.get_state(pid)

      assert post_state.in_flight_beads == sentinel,
             "reload_after_conflict must preserve in_flight_beads; " <>
               "got #{inspect(post_state.in_flight_beads)}"

      assert post_state.version == 1
    end
  end

  describe "AC-024-4 success path: cache populated mid-flight, cleared after append confirmation" do
    test "provider-backed dispatch emits :populated telemetry mid-flight and clears cache on commit" do
      task_id = "task-#{uuid()}"
      project_id = "project-#{uuid()}"
      command_id = "cmd-#{uuid()}"

      pid = start_task_actor(task_id)

      :ok =
        TaskProvider.Registry.register_for_project(
          project_id,
          ForemanServer.ActorInFlightCacheTest.StubProvider,
          %{database_path: "/tmp/actor-in-flight-cache-test.db"}
        )

      :ok = :sys.suspend(CommandRouter)
      on_exit(fn -> :sys.resume(CommandRouter) end)
      attach_telemetry_handler([:foreman_server, :aggregate, :in_flight_beads, :populated])

      cmd = %{
        type: "task.create",
        payload: %{
          task_id: task_id,
          project_id: project_id,
          title: "stage2-populated",
          description: "cache test",
          priority: 2,
          task_type: "feature",
          dedupe_key: "dedupe-#{task_id}"
        },
        aggregate_id: "task:#{task_id}",
        command_id: command_id
      }

      task = Task.async(fn -> CommandRouter.dispatch(cmd, 30_000) end)

      populated =
        Enum.reduce_while(1..300, nil, fn _, _ ->
          receive do
            {:telemetry_event, [:foreman_server, :aggregate, :in_flight_beads, :populated], _m,
             %{command_id: ^command_id} = meta} ->
              {:halt, meta}

            other ->
              send(self(), other)
              {:cont, nil}
          after
            10 ->
              Process.sleep(10)
              {:cont, nil}
          end
        end)

      assert populated, "expected :populated telemetry mid-flight"
      assert populated.bead_id == "bead-x"
      assert populated.aggregate_id == "task:#{task_id}"

      :sys.resume(CommandRouter)
      assert {:ok, _} = Task.await(task, 10_000)

      assert :sys.get_state(pid).in_flight_beads == %{}
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp start_task_actor(task_id) do
    {:ok, pid} = ForemanServer.Aggregator.start_aggregate(TaskAggregate, "task:#{task_id}")
    pid
  end

  defp build_task_create(task_id, opts) do
    %{
      type: "task.create",
      payload: %{
        task_id: task_id,
        project_id: Keyword.get(opts, :project_id, "project-#{uuid()}"),
        title: Keyword.get(opts, :title, "title-#{task_id}"),
        description: "desc",
        priority: 2,
        task_type: "feature",
        dedupe_key: "dedupe-#{task_id}-#{Keyword.get(opts, :command_id, uuid())}"
      },
      aggregate_id: "task:#{task_id}",
      command_id: Keyword.get(opts, :command_id, "cmd-#{uuid()}")
    }
  end

  defp attach_telemetry_handler(event_path) do
    handler_id = "cache-test-#{System.unique_integer([:positive, :monotonic])}"
    :telemetry.attach(handler_id, event_path, &__MODULE__.handle_telemetry/4, self())
    on_exit(fn -> :telemetry.detach(handler_id) end)
  end

  def handle_telemetry(event_path, measurements, metadata, config) do
    send(config, {:telemetry_event, event_path, measurements, metadata})
    :ok
  end
end

# ---------------------------------------------------------------------------
# Stub provider for the AC-024-4 mid-flight cache test. Implements the
# TaskProvider behaviour with the canonical arity set so the registry
# accepts it via register_for_project/3.
# ---------------------------------------------------------------------------

defmodule ForemanServer.ActorInFlightCacheTest.StubProvider do
  @moduledoc false
  @behaviour ForemanServer.TaskProvider

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProviders.ProviderError

  @impl true
  def name, do: "stub_in_flight"

  @impl true
  def capabilities do
    %{
      provider_id: :stub_in_flight,
      contract_version: "br.capabilities.v1",
      id_format: "stub:%s",
      supports: [:create]
    }
  end

  @impl true
  def available?, do: true

  @impl true
  def create(_project_id, _attrs) do
    {:ok,
     %Issue{
       id: "bead-x",
       title: "stub task",
       status: "open",
       priority: 2,
       dependencies: [],
       dependents: [],
       assignee: nil,
       description: nil,
       notes: nil,
       design: nil,
       labels: [],
       metadata: %{}
     }}
  end

  @impl true
  def list_ready(_project_id, _opts), do: {:ok, []}

  @impl true
  def get(_project_id, _id) do
    {:error,
     %ProviderError{
       code: "STUB_NOT_IMPLEMENTED",
       message: "stub",
       hint: "",
       retryable?: false,
       context: %{}
     }}
  end

  @impl true
  def claim(_project_id, _id, _assignee), do: :ok
  @impl true
  def complete(_project_id, _id, _opts), do: :ok
  @impl true
  def fail(_project_id, _id, _opts), do: :ok
  @impl true
  def reopen(_project_id, _id, _opts), do: :ok
  @impl true
  def set_priority(_project_id, _id, _priority), do: :ok
  @impl true
  def add_dependency(_project_id, _id, _depends_on), do: :ok
end
