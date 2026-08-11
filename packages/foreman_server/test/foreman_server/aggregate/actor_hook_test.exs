defmodule ForemanServer.ActorHookTest do
  @moduledoc """
  TRD-007-TEST — comprehensive coverage of the per-project synchronous
  bead-creation hook (`ForemanServer.Aggregate.Actor.resolve_enriched_event_spec/3`).

  Validates:
    AC-020-1 happy path          (scenario 1)
    AC-020-4 non-Beads project   (scenario 2)
    AC-020-5 failure-as-error    (scenario 3)
    AC-020-6 watcher-import      (scenario 4)
    AC-024-1 cache populated     (scenario 5)
    AC-024-2 cache reused on hit (scenario 6)
    AC-024-4 concurrent cmd ids  (scenario 7)

  Harness design:
    * `ForemanServer.ActorHookTest.StubProvider` is a `@behaviour TaskProvider` module
      backed by a per-test Agent so each test starts with a clean
      capability map, response queue, and call counter.
    * Persistence scenarios (AC-020-1/4/5/6, AC-024-4's tail) drive the
      command through `CommandRouter.dispatch/1` and assert against the
      real EventStore — no synthetic ACKs.
    * In-flight cache observation (AC-024-1/2) suspends CommandRouter,
      inspects the mailbox to read the in-flight `{:append, ...}` and the
      actor's `in_flight_beads`, then resumes so the dispatch completes
      naturally against the real store.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.{Aggregate, CommandRouter, TaskProvider}
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TestSupport.TestApplication
  alias ForemanServer.Aggregates.Task, as: TaskAggregate
  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp fresh_ids do
    %{
      project_id: "project-#{uuid()}",
      task_id: "task-#{uuid()}",
      command_id: "cmd-#{uuid()}"
    }
  end

  defp task_create_command(
         %{project_id: project_id, task_id: task_id, command_id: command_id},
         overrides \\ %{}
       ) do
    base = %{
      type: "task.create",
      payload: %{
        task_id: task_id,
        project_id: project_id,
        title: "title-#{task_id}",
        description: "desc",
        priority: 2,
        task_type: "feature",
        dedupe_key: "dedupe-#{task_id}"
      },
      aggregate_id: "task:#{task_id}",
      command_id: command_id
    }

    update_in(base, [Access.key!(:payload)], &Map.merge(&1, Map.new(overrides)))
  end

  defp stream_id_for_task(task_id), do: "task:#{task_id}"

  defp start_task_actor(task_id) do
    {:ok, pid} =
      ForemanServer.Aggregator.start_aggregate(TaskAggregate, stream_id_for_task(task_id))

    pid
  end

  defp suspend_command_router do
    :ok = :sys.suspend(CommandRouter)

    ExUnit.Callbacks.on_exit({:suspend_command_router, make_ref()}, fn ->
      try do
        :sys.resume(CommandRouter)
      catch
        _, _ -> :ok
      end
    end)

    :ok
  end

  defp actor_in_flight_beads(actor_pid) do
    :sys.get_state(actor_pid).in_flight_beads
  end

  defp pre_populate_cache(actor_pid, command_id, bead_id) do
    :sys.replace_state(actor_pid, fn state ->
      %{
        state
        | in_flight_beads: Map.put(state.in_flight_beads, command_id, bead_id)
      }
    end)
  end

  defp take_append_message do
    pid = Process.whereis(CommandRouter)
    {:messages, mailbox} = :erlang.process_info(pid, :messages)

    Enum.find(mailbox, fn
      {:append, _, _, _, _, _} -> true
      _ -> false
    end)
  end

  defp extract_event_data({:append, _agg_id, [event_data], _expected_version, _ref, _sender}) do
    event_data
  end

  defp read_task_created_event(task_id) do
    stream = stream_id_for_task(task_id)

    case Store.read_stream_forward(stream, 0, 10) do
      {:ok, events} ->
        Enum.find(events, fn ev -> ev.event_type == "TaskCreated" end)

      {:error, :stream_not_found} ->
        nil
    end
  end

  defp issue(id, title \\ "stub task") do
    %Issue{
      id: id,
      title: title,
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
    }
  end

  defp attach_telemetry(event_path, recipient \\ self()) do
    handler_id = "actor-hook-test-#{inspect(make_ref())}"

    :telemetry.attach(
      handler_id,
      event_path,
      fn name, measurements, metadata, _config ->
        send(recipient, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    ExUnit.Callbacks.on_exit({:telemetry_detach, handler_id}, fn ->
      :telemetry.detach(handler_id)
    end)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Setup
  # ---------------------------------------------------------------------------

  setup do
    Application.put_env(:foreman_server, :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    TestApplication.reset_application_child!(TaskProvider.Registry)

    {:ok, _} = start_supervised(ForemanServer.ActorHookTest.StubProvider)

    :ok
  end

  # ===========================================================================
  # AC-020-1 — Happy path
  # ===========================================================================

  describe "AC-020-1 happy path (scenario 1)" do
    test "provider.create returns bead_id; persisted TaskCreated has external_id" do
      ids = fresh_ids()

      ForemanServer.ActorHookTest.StubProvider.set_create_response(
        {:ok, issue("foreman-abc", ids.task_id)}
      )

      ForemanServer.ActorHookTest.StubProvider.set_capabilities(supports_with(:create))

      TaskProvider.Registry.register_for_project(
        ids.project_id,
        ForemanServer.ActorHookTest.StubProvider,
        %{database_path: "/tmp/not-used.db"}
      )

      _actor = start_task_actor(ids.task_id)
      cmd = task_create_command(ids)

      assert {:ok, _event_spec} =
               CommandRouter.dispatch(cmd, 10_000)

      recorded = read_task_created_event(ids.task_id)
      assert recorded != nil, "TaskCreated event must be persisted"
      assert recorded.event_type == "TaskCreated"
      assert get_in(recorded.data, [:external_id]) == "foreman-abc"

      assert ForemanServer.ActorHookTest.StubProvider.get_create_call_count() == 1
    end
  end

  # ===========================================================================
  # AC-020-4 — Non-Beads project: hook is no-op when :create missing
  # ===========================================================================

  describe "AC-020-4 non-Beads project (scenario 2)" do
    test "capability list without :create skips hook; external_id remains nil" do
      ids = fresh_ids()
      ForemanServer.ActorHookTest.StubProvider.set_capabilities(supports_without(:create))

      TaskProvider.Registry.register_for_project(
        ids.project_id,
        ForemanServer.ActorHookTest.StubProvider,
        %{}
      )

      _actor = start_task_actor(ids.task_id)
      cmd = task_create_command(ids)

      assert {:ok, _event_spec} =
               CommandRouter.dispatch(cmd, 10_000)

      recorded = read_task_created_event(ids.task_id)
      assert recorded != nil
      assert get_in(recorded.data, [:external_id]) == nil
      assert ForemanServer.ActorHookTest.StubProvider.get_create_call_count() == 0
    end
  end

  # ===========================================================================
  # AC-020-5 — Failure: hook returns error; actor emits telemetry; NO event
  # ===========================================================================

  describe "AC-020-5 failure-as-error (scenario 3)" do
    test "provider.create returns ProviderError; telemetry fires; no event persisted" do
      ids = fresh_ids()

      failure = %ProviderError{
        code: "INVALID_TITLE",
        message: "title is required",
        hint: "pass non-empty title",
        retryable?: false,
        context: %{}
      }

      ForemanServer.ActorHookTest.StubProvider.set_create_response({:error, failure})
      ForemanServer.ActorHookTest.StubProvider.set_capabilities(supports_with(:create))

      TaskProvider.Registry.register_for_project(
        ids.project_id,
        ForemanServer.ActorHookTest.StubProvider,
        %{database_path: "/tmp/not-used.db"}
      )

      attach_telemetry([:foreman_server, :task_provider, :beads, :create, :failure])

      _actor = start_task_actor(ids.task_id)
      cmd = task_create_command(ids)

      assert {:error, %ProviderError{code: "INVALID_TITLE"} = _err} =
               CommandRouter.dispatch(cmd, 10_000)

      assert read_task_created_event(ids.task_id) == nil,
             "no event must be persisted on stage-2 failure"

      assert_receive {:telemetry_event,
                      [:foreman_server, :task_provider, :beads, :create, :failure], _m, metadata}

      assert metadata.command_id == ids.command_id
      assert metadata.code == "INVALID_TITLE"
      assert metadata.retryable? == false
      assert metadata.task_id == ids.task_id
      assert metadata.project_id == ids.project_id

      assert ForemanServer.ActorHookTest.StubProvider.get_create_call_count() == 1
    end
  end

  # ===========================================================================
  # AC-020-6 — Watcher-import: pre-populated external_id is preserved
  # ===========================================================================

  describe "AC-020-6 watcher-import (scenario 4)" do
    test "payload.external_id present skips create; bead_id preserved in event" do
      ids = fresh_ids()
      ForemanServer.ActorHookTest.StubProvider.set_capabilities(supports_with(:create))

      TaskProvider.Registry.register_for_project(
        ids.project_id,
        ForemanServer.ActorHookTest.StubProvider,
        %{database_path: "/tmp/not-used.db"}
      )

      attach_telemetry([
        :foreman_server,
        :task_provider,
        :beads,
        :create,
        :skipped_watcher_import
      ])

      _actor = start_task_actor(ids.task_id)

      cmd =
        task_create_command(ids, %{
          external_id: "foreman-imported",
          external_link: "https://example.test/foreman-imported"
        })

      assert {:ok, _event_spec} =
               CommandRouter.dispatch(cmd, 10_000)

      recorded = read_task_created_event(ids.task_id)
      assert recorded != nil
      assert get_in(recorded.data, [:external_id]) == "foreman-imported"

      assert ForemanServer.ActorHookTest.StubProvider.get_create_call_count() == 0,
             "BeadsAdapter.create must NOT be invoked when external_id is pre-populated"

      assert_receive {:telemetry_event,
                      [:foreman_server, :task_provider, :beads, :create, :skipped_watcher_import],
                      _m, metadata}

      assert metadata.command_id == ids.command_id
      assert metadata.bead_id == "foreman-imported"
      assert metadata.task_id == ids.task_id
      assert metadata.project_id == ids.project_id
    end
  end

  # ===========================================================================
  # AC-024-1 — Cache populated on stage-2 success (mid-flight inspection)
  # ===========================================================================

  describe "AC-024-1 cache populated (scenario 5)" do
    test "after stage 2, in_flight_beads carries {command_id => bead_id} before append ack" do
      ids = fresh_ids()

      ForemanServer.ActorHookTest.StubProvider.set_create_response(
        {:ok, issue("bead-x", ids.task_id)}
      )

      ForemanServer.ActorHookTest.StubProvider.set_capabilities(supports_with(:create))

      TaskProvider.Registry.register_for_project(
        ids.project_id,
        ForemanServer.ActorHookTest.StubProvider,
        %{database_path: "/tmp/not-used.db"}
      )

      actor_pid = start_task_actor(ids.task_id)
      cmd = task_create_command(ids)

      # Attach telemetry handler for the in-flight cache populated event.
      attach_telemetry([:foreman_server, :aggregate, :in_flight_beads, :populated])

      # Mid-flight inspection requires suspending CommandRouter so the actor
      # parks in its `receive` after sending {:append, ...} but before
      # receiving {:append_ok, ...}. Mailbox inspection must happen BEFORE
      # resume; persistence assertions happen AFTER.
      suspend_command_router()

      task =
        Task.async(fn ->
          CommandRouter.dispatch(cmd, 30_000)
        end)

      # Wait until the actor observed the cache populated telemetry event.
      cmd_id = ids.command_id

      event =
        Enum.reduce_while(1..200, nil, fn _, _ ->
          receive do
            {:telemetry_event, [:foreman_server, :aggregate, :in_flight_beads, :populated], _,
             %{command_id: ^cmd_id, bead_id: "bead-x"} = meta} ->
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

      assert event != nil, "expected [:aggregate, :in_flight_beads, :populated] before resume"
      assert event.aggregate_id == stream_id_for_task(ids.task_id)

      # Wait until CommandRouter has the queued {:append, ...} from the actor.
      append_msg =
        Enum.reduce_while(1..200, nil, fn _, _ ->
          case take_append_message() do
            nil ->
              Process.sleep(10)
              {:cont, nil}

            msg ->
              {:halt, msg}
          end
        end)

      assert append_msg != nil,
             "expected {:append, ...} in CommandRouter mailbox before resume"

      {event_data, _ref, _sender} = extract_append_components(append_msg)
      assert event_data.event_type == "TaskCreated"
      assert get_in(event_data, [:data, :external_id]) == "bead-x"

      :sys.resume(CommandRouter)

      assert {:ok, _event_spec} = Task.await(task, 10_000)

      recorded = read_task_created_event(ids.task_id)
      assert recorded != nil
      assert get_in(recorded.data, [:external_id]) == "bead-x"

      # After terminal success, the cache entry for this command_id is cleared.
      assert actor_in_flight_beads(actor_pid) == %{}
    end
  end

  # ===========================================================================
  # AC-024-2 — Cache reused on hit
  # ===========================================================================

  describe "AC-024-2 cache reused on hit (scenario 6)" do
    test "pre-populated cache causes stage-2 to be skipped; event_data carries cached bead_id" do
      ids = fresh_ids()
      ForemanServer.ActorHookTest.StubProvider.set_capabilities(supports_with(:create))

      TaskProvider.Registry.register_for_project(
        ids.project_id,
        ForemanServer.ActorHookTest.StubProvider,
        %{database_path: "/tmp/not-used.db"}
      )

      actor_pid = start_task_actor(ids.task_id)
      cmd = task_create_command(ids)

      pre_populate_cache(actor_pid, ids.command_id, "bead-cached")

      suspend_command_router()

      task =
        Task.async(fn ->
          CommandRouter.dispatch(cmd, 30_000)
        end)

      append_msg =
        Enum.reduce_while(1..200, nil, fn _, _ ->
          case take_append_message() do
            nil ->
              Process.sleep(10)
              {:cont, nil}

            msg ->
              {:halt, msg}
          end
        end)

      assert append_msg != nil
      {event_data, _ref, _sender} = extract_append_components(append_msg)

      assert event_data.event_type == "TaskCreated"
      assert get_in(event_data, [:data, :external_id]) == "bead-cached"

      # Cache hit: provider.create is NOT invoked.
      assert ForemanServer.ActorHookTest.StubProvider.get_create_call_count() == 0,
             "cache hit must skip stage 2 (provider.create)"

      :sys.resume(CommandRouter)

      assert {:ok, _event_spec} = Task.await(task, 10_000)

      recorded = read_task_created_event(ids.task_id)
      assert recorded != nil
      assert get_in(recorded.data, [:external_id]) == "bead-cached"

      # Cache cleared after terminal success.
      assert actor_in_flight_beads(actor_pid) == %{}
    end
  end

  # ===========================================================================
  # AC-024-4 — Concurrent command_ids yield distinct cache entries
  # ===========================================================================

  describe "AC-024-4 concurrent command_ids (scenario 7)" do
    test "two concurrent dispatches produce distinct cache entries and distinct external_ids" do
      base_project = "project-#{uuid()}"
      ForemanServer.ActorHookTest.StubProvider.set_capabilities(supports_with(:create))

      TaskProvider.Registry.register_for_project(
        base_project,
        ForemanServer.ActorHookTest.StubProvider,
        %{database_path: "/tmp/not-used.db"}
      )

      ids1 = fresh_ids() |> Map.put(:project_id, base_project)
      ids2 = fresh_ids() |> Map.put(:project_id, base_project)
      actor1 = start_task_actor(ids1.task_id)
      actor2 = start_task_actor(ids2.task_id)

      cmd1 = task_create_command(ids1)
      cmd2 = task_create_command(ids2)

      attach_telemetry([:foreman_server, :aggregate, :in_flight_beads, :populated])

      suspend_command_router()

      # Stage 2 must produce a distinct bead_id per call. We use a per-call
      # counter via the stub's response function so each invocation yields
      # a unique bead_id derived from the call count.
      ForemanServer.ActorHookTest.StubProvider.set_create_response(fn count ->
        {:ok, issue("bead-concurrent-#{count}", "concurrent")}
      end)

      task1 = Task.async(fn -> CommandRouter.dispatch(cmd1, 30_000) end)
      task2 = Task.async(fn -> CommandRouter.dispatch(cmd2, 30_000) end)

      # Wait for both `:populated` telemetry events (one per command_id).
      events =
        wait_for_n_telemetry([:foreman_server, :aggregate, :in_flight_beads, :populated], 2)

      populated =
        Enum.filter(events, fn meta ->
          meta.command_id == ids1.command_id or meta.command_id == ids2.command_id
        end)

      assert length(populated) == 2,
             "expected 2 populated telemetry events (one per concurrent command_id)"

      populated1 = Enum.find(populated, &(&1.command_id == ids1.command_id))
      populated2 = Enum.find(populated, &(&1.command_id == ids2.command_id))
      assert populated1.bead_id != populated2.bead_id

      # Wait for BOTH {:append, ...} messages in CommandRouter mailbox.
      router_pid = Process.whereis(CommandRouter)

      appends =
        Enum.reduce_while(1..300, [], fn _, acc ->
          {:messages, mailbox} = :erlang.process_info(router_pid, :messages)

          found =
            Enum.filter(mailbox, fn
              {:append, _, _, _, _, _} -> true
              _ -> false
            end)

          if length(found) >= 2 do
            {:halt, found}
          else
            Process.sleep(10)
            {:cont, acc}
          end
        end)

      assert length(appends) == 2,
             "expected 2 concurrent {:append, ...} messages queued in CommandRouter mailbox"

      external_ids =
        Enum.map(appends, fn msg ->
          {event_data, _ref, _sender} = extract_append_components(msg)
          get_in(event_data, [:data, :external_id])
        end)

      assert length(Enum.uniq(external_ids)) == 2,
             "concurrent dispatches must yield distinct external_ids; got #{inspect(external_ids)}"

      :sys.resume(CommandRouter)

      assert {:ok, _} = Task.await(task1, 10_000)
      assert {:ok, _} = Task.await(task2, 10_000)

      rec1 = read_task_created_event(ids1.task_id)
      rec2 = read_task_created_event(ids2.task_id)

      assert rec1 != nil
      assert rec2 != nil
      assert get_in(rec1.data, [:external_id]) != get_in(rec2.data, [:external_id])

      # Both caches cleared after terminal success.
      assert actor_in_flight_beads(actor1) == %{}
      assert actor_in_flight_beads(actor2) == %{}

      # Provider.create was called exactly twice (once per dispatch).
      assert ForemanServer.ActorHookTest.StubProvider.get_create_call_count() == 2
    end
  end

  # ===========================================================================
  # Helpers
  # Consume `:telemetry_event` messages matching `event_path` until we have
  # ≥ `n` of them, or 300 iterations of 10ms elapse. Each `receive` call
  # actually pulls a message off the mailbox (no re-snapshotting).
  defp wait_for_n_telemetry(event_path, n) do
    Enum.reduce_while(1..300, [], fn _, acc ->
      if length(acc) >= n do
        {:halt, acc}
      else
        receive do
          {:telemetry_event, ^event_path, _measurements, metadata} ->
            {:cont, [metadata | acc]}
        after
          10 ->
            Process.sleep(10)
            {:cont, acc}
        end
      end
    end)
  end

  defp supports_with(cap), do: default_capabilities([cap | without_create()])

  defp supports_without(cap), do: default_capabilities(List.delete(without_create(), cap))

  defp without_create, do: [:claim, :close, :reopen, :annotate, :set_priority, :set_assignee]

  defp default_capabilities(supports) do
    %{
      provider_id: :stub_actor_hook,
      contract_version: "br.capabilities.v1",
      id_format: "stub:%s",
      supports: supports
    }
  end

  defp extract_append_components({:append, _agg, [event_data], _expected_version, ref, sender}) do
    {event_data, ref, sender}
  end
end

# ---------------------------------------------------------------------------
# Test stub provider — Agent-backed TaskProvider behaviour module.
#
# Global module name so `Registry.route/2` can resolve it polymorphically.
# Per-test state is held in an Agent started under `start_supervised` in setup.
# ---------------------------------------------------------------------------

defmodule ForemanServer.ActorHookTest.StubProvider do
  @moduledoc false
  @behaviour ForemanServer.TaskProvider

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProviders.ProviderError

  @agent __MODULE__.Agent

  def start_link(_opts \\ []) do
    initial = %{
      create_response: {:ok, default_issue()},
      capabilities: default_capabilities([:create, :claim, :close]),
      create_call_count: 0,
      captured_args: []
    }

    Agent.start_link(fn -> initial end, name: @agent)
  end

  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  def set_create_response(response_or_fn) do
    Agent.update(@agent, &Map.put(&1, :create_response, response_or_fn))
  end

  def set_capabilities(capabilities) do
    Agent.update(@agent, &Map.put(&1, :capabilities, capabilities))
  end

  def get_create_call_count, do: Agent.get(@agent, & &1.create_call_count)

  def get_captured_create_args, do: Agent.get(@agent, & &1.captured_args)

  # ---------------------------------------------------------------------------
  # TaskProvider behaviour callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def name, do: "stub_actor_hook"

  @impl true
  def capabilities do
    Agent.get(@agent, & &1.capabilities)
  end

  @impl true
  def available?, do: true

  @impl true
  def create(project_id, attrs) do
    Agent.get_and_update(@agent, fn state ->
      new_count = state.create_call_count + 1

      new_state = %{
        state
        | create_call_count: new_count,
          captured_args: [{project_id, attrs} | state.captured_args]
      }

      response =
        case state.create_response do
          fun when is_function(fun, 0) -> fun.()
          fun when is_function(fun, 1) -> fun.(new_count)
          fun when is_function(fun, 2) -> fun.(project_id, attrs)
          other -> other
        end

      {response, new_state}
    end)
  end

  @impl true
  def list_ready(_project_id, _opts), do: {:ok, []}

  @impl true
  def get(_project_id, _task_id) do
    {:error,
     %ProviderError{
       code: "STUB_NOT_IMPLEMENTED",
       message: "stub",
       hint: "stub",
       retryable?: false,
       context: %{}
     }}
  end

  @impl true
  def claim(_project_id, _task_id, _assignee), do: :ok
  @impl true
  def complete(_project_id, _task_id, _opts), do: :ok
  @impl true
  def fail(_project_id, _task_id, _opts), do: :ok
  @impl true
  def reopen(_project_id, _task_id, _opts), do: :ok
  @impl true
  def set_priority(_project_id, _task_id, _priority), do: :ok
  @impl true
  def annotate(_project_id, _task_id, _note), do: :ok
  @impl true
  def set_assignee(_project_id, _task_id, _assignee), do: :ok
  @impl true
  def add_dependency(_project_id, _task_id, _depends_on), do: :ok

  defp default_issue do
    %Issue{
      id: "stub-default",
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
    }
  end

  defp default_capabilities(supports) do
    %{
      provider_id: :stub_actor_hook,
      contract_version: "br.capabilities.v1",
      id_format: "stub:%s",
      supports: supports
    }
  end
end
