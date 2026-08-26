defmodule ForemanServer.ActorCompensationTest do
  @moduledoc """
  TRD-008-TEST — Compensation path coverage for AC-020-3.

  Validates the actor's three compensation triggers under the
  bounded-retry / append-conflict protocol:

  1. Transient retry recovery (AC-024-3) — actor's cache HIT skips
     Stage 2 on retry; no compensation fires.
  2. Bounded-retry exhaustion — after `@max_conflict_retries + 1`
     `:wrong_expected_version` returns, `compensate_for_conflict/3`
     closes the bead with reason
     `foreman-compensation:append-conflict-retry-exhausted`.
  3. Post-reload re-decision rejection — once `reload_after_conflict/1`
     catches a stream-version conflict, the rehydrated state may reject
     the original command; closes with
     `foreman-compensation:re-decision-rejected`.
  4. CLOSE-ONLY-ONCE invariant — a second dispatch of the same
     `command_id` does not trigger an additional close.
  5. `phase.complete` without `:command_id` — the compensation helper
     short-circuits (cache miss + nil command_id) and the error
     propagates unchanged.
  """

  use ExUnit.Case, async: false

  import Mox

  alias Elixir.EventStore.EventData
  alias ForemanServer.Aggregates.Phase, as: PhaseAggregate
  alias ForemanServer.Aggregates.Task, as: TaskAggregate
  alias ForemanServer.CommandRouter
  alias ForemanServer.EventStore, as: FServerStore
  alias ForemanServer.TaskProvider
  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ProviderError
  alias ForemanServer.TestSupport.TestApplication

  @max_conflict_retries Application.compile_env(
                          :foreman_server,
                          [:aggregate, :actor, :max_conflict_retries],
                          3
                        )

  setup_all do
    {:ok, _} = Application.ensure_all_started(:mox)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    previous_config = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    TestApplication.reset_application_child!(TaskProvider.Registry)

    stub(BrRunnerMock, :cmd, fn _request, _cfg, _opts ->
      flunk("unexpected BrRunnerMock.cmd/3 call")
    end)

    # Start JsonSchemaCache so BeadsAdapter.complete/3 can validate the
    # close response without crashing on the missing schema cache process.
    start_schema_cache!()

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous_config)
    end)

    :ok
  end

  describe "AC-024-3 transient retry recovery" do
    test "first append conflict is recovered via cache HIT, no compensation" do
      ids = new_ids()
      db_path = "/abs/path-#{uuid()}.db"
      stream_id = "task:#{ids.task_id}"
      register_stub_provider(ids.project_id, db_path)

      # StubProvider.create returns a hardcoded %Issue{} — it does NOT
      # route through BrRunnerMock. The fake CommandRouter script
      # supplies the conflict + the eventual success.
      install_fake_command_router([
        {:conflict, 1},
        {:ok, 1}
      ])

      attach_telemetry_handler([:foreman_server, :task_provider, :beads, :create, :compensated])

      # Pre-append a noise event so the actor's rehydrated stream
      # version is 1 (the default clause in Task.apply_event/2 leaves
      # exists? false, so the actor still views this task as missing).
      :ok =
        FServerStore.append_to_stream(stream_id, 0, [
          %EventData{event_type: "UnrecognizedNoise", data: %{}, metadata: %{}}
        ])

      pid = start_actor(TaskAggregate, stream_id)
      # Lie about the actor's local version so the next append conflicts.
      force_actor_version(pid, 0)

      cmd = task_create_command(ids)
      assert {:ok, _event_spec} = CommandRouter.dispatch(cmd, 10_000)

      # Cache cleared on terminal success.
      assert :sys.get_state(pid).in_flight_beads == %{}

      # The fake did not persist anything to the real stream — only the
      # original noise event remains.
      {:ok, events} = FServerStore.read_stream_forward(stream_id, 0, 10)
      assert length(events) == 1
      assert hd(events).event_type == "UnrecognizedNoise"

      # No compensation telemetry fired.
      assert drain_telemetry([:foreman_server, :task_provider, :beads, :create, :compensated]) ==
               []
    end
  end

  describe "bounded-retry exhaustion (AC-020-3 Trigger 1)" do
    test "@max_conflict_retries+1 conflicts → compensate with retry-exhausted" do
      ids = new_ids()
      db_path = "/abs/path-#{uuid()}.db"
      stream_id = "task:#{ids.task_id}"
      register_stub_provider(ids.project_id, db_path)

      expect(BrRunnerMock, :cmd, 1, fn
        {:close, %{id: "bead-x", reason: "foreman-compensation:append-conflict-retry-exhausted"}},
        %{database_path: ^db_path},
        _opts ->
          {:ok, stub_close_response("bead-x")}
      end)

      attach_telemetry_handler([:foreman_server, :task_provider, :beads, :create, :compensated])

      # 4 conflicts: actor starts with retries_left=3, decremented per
      # retry, exhausted at 0 (actor.ex lines 471-507).
      install_fake_command_router(
        Enum.map(1..(@max_conflict_retries + 1), fn _ -> {:conflict, 1} end)
      )

      pid = start_actor(TaskAggregate, stream_id)
      # The stream is empty, so the actor's rehydrated version is 0.
      # An empty stream is canonical for this scenario — every
      # reload-after-conflict returns exists?=false, so each re-decide
      # succeeds and the cache HIT pattern continues until retries
      # are exhausted.
      force_actor_version(pid, 0)

      cmd = task_create_command(ids)
      result = CommandRouter.dispatch(cmd, 10_000)

      # CommandRouter.finalize_dispatch unwraps the {:telemetry, ...}
      # tuple, returning {:error, {:wrong_expected_version, version}}.
      assert {:error, {:wrong_expected_version, _version}} = result

      # Cache cleared after compensation.
      assert :sys.get_state(pid).in_flight_beads == %{}

      # Compensation telemetry fired.
      assert telemetry_fired_for?([
               :foreman_server,
               :task_provider,
               :beads,
               :create,
               :compensated
             ])
    end
  end

  describe "post-reload re-decision rejection (AC-020-3 Trigger 2)" do
    test "rehydrated state rejects task.create → compensate with re-decision-rejected" do
      ids = new_ids()
      db_path = "/abs/path-#{uuid()}.db"
      stream_id = "task:#{ids.task_id}"
      register_stub_provider(ids.project_id, db_path)

      # StubProvider.create runs once on the first attempt; no
      # BrRunnerMock call for create. The compensation's close is the
      # only BrRunnerMock call.
      expect(BrRunnerMock, :cmd, 1, fn
        {:close, %{id: "bead-x", reason: "foreman-compensation:re-decision-rejected"}},
        %{database_path: ^db_path},
        _opts ->
          {:ok, stub_close_response("bead-x")}
      end)

      attach_telemetry_handler([:foreman_server, :task_provider, :beads, :create, :compensated])

      # 1 conflict is enough: after reload, re-decide rejects.
      install_fake_command_router([{:conflict, 1}])

      # Per the user's CLOSE-ONLY-ONCE advisory: start the actor while
      # the stream is empty (exists?=false), then externally append
      # TaskCreated. Appending TaskCreated before actor startup would
      # rehydrate exists?=true, and the initial task.create would be
      # rejected at retries_left=3 (no compensation).
      pid = start_actor(TaskAggregate, stream_id)

      # Externally append TaskCreated to simulate a concurrent writer.
      payload = %{
        task_id: ids.task_id,
        project_id: ids.project_id,
        title: "racing-writer",
        description: "desc",
        priority: 2,
        status: "open",
        task_type: "feature",
        dedupe_key: "dedupe-#{ids.task_id}"
      }

      :ok =
        FServerStore.append_to_stream(stream_id, 0, [
          %EventData{event_type: "TaskCreated", data: payload, metadata: %{}}
        ])

      # Force actor's local version to 0 so the first append conflicts.
      force_actor_version(pid, 0)

      cmd = task_create_command(ids)
      result = CommandRouter.dispatch(cmd, 10_000)

      # The re-decision rejects with :already_exists, propagated through
      # compensate_and_reply unchanged.
      assert {:error, {:already_exists, :task, _task_id}} = result

      # Cache cleared after compensation.
      assert :sys.get_state(pid).in_flight_beads == %{}

      # Compensation telemetry fired.
      assert telemetry_fired_for?([
               :foreman_server,
               :task_provider,
               :beads,
               :create,
               :compensated
             ])
    end
  end

  describe "CLOSE-ONLY-ONCE invariant" do
    test "second dispatch of the same command_id does not re-close" do
      ids = new_ids()
      db_path = "/abs/path-#{uuid()}.db"
      stream_id = "task:#{ids.task_id}"
      register_stub_provider(ids.project_id, db_path)

      expect(BrRunnerMock, :cmd, 1, fn
        {:close, %{id: "bead-x", reason: "foreman-compensation:re-decision-rejected"}},
        %{database_path: ^db_path},
        _opts ->
          {:ok, stub_close_response("bead-x")}
      end)

      attach_telemetry_handler([:foreman_server, :task_provider, :beads, :create, :compensated])

      install_fake_command_router([{:conflict, 1}])

      pid = start_actor(TaskAggregate, stream_id)

      payload = %{
        task_id: ids.task_id,
        project_id: ids.project_id,
        title: "racing-writer",
        description: "desc",
        priority: 2,
        status: "open",
        task_type: "feature",
        dedupe_key: "dedupe-#{ids.task_id}"
      }

      :ok =
        FServerStore.append_to_stream(stream_id, 0, [
          %EventData{event_type: "TaskCreated", data: payload, metadata: %{}}
        ])

      force_actor_version(pid, 0)

      cmd = task_create_command(ids)

      # First dispatch: triggers compensation.
      assert {:error, {:already_exists, :task, _}} = CommandRouter.dispatch(cmd, 10_000)
      assert :sys.get_state(pid).in_flight_beads == %{}

      # Second dispatch: same command_id. handle_command runs on the
      # rehydrated state (exists?=true from the externally appended
      # TaskCreated) and rejects immediately. retries_left=3 (not < 3)
      # so the outer branch returns the error without compensation.
      # Mox count remains 1.
      assert {:error, {:already_exists, :task, _}} = CommandRouter.dispatch(cmd, 10_000)
      assert :sys.get_state(pid).in_flight_beads == %{}
    end
  end

  describe "phase.complete without :command_id" do
    test "compensation helper short-circuits when cache miss + no command_id" do
      run_id = "run-#{uuid()}"
      phase_id = "phase-#{uuid()}"
      stream_id = "phase:#{run_id}:#{phase_id}"

      # Default BrRunnerMock stub (in setup) flunks if called.

      attach_telemetry_handler([:foreman_server, :task_provider, :beads, :create, :compensated])

      # 1 conflict is enough: after reload, re-decide hits reject_terminal.
      install_fake_command_router([{:conflict, 1}])

      # Per the user's scenario-5 advisory: PhaseStarted first, then
      # start the actor (so the actor's stale state is
      # started/nonterminal), then PhaseCompleted externally. This
      # ensures the initial dispatch reaches append (started +
      # nonterminal) and the reloaded state is terminal
      # (reject_terminal fires on re-decide).
      #
      # Use typed event structs with all required keys so global
      # replay via ProjectionStore.rebuild/1 stays valid (the codec
      # rejects unknown/omitted fields by design — see AGENTS.md).
      alias ForemanServer.Events.PhaseStarted
      alias ForemanServer.Events.PhaseCompleted

      started_event = %PhaseStarted{
        phase_id: phase_id,
        run_id: run_id,
        index: 1,
        name: "test-phase",
        attempt: 1,
        artifact_template: "{run.id}.md"
      }

      :ok =
        FServerStore.append_to_stream(stream_id, 0, [
          %EventData{event_type: "PhaseStarted", data: started_event, metadata: %{}}
        ])

      pid = start_actor(PhaseAggregate, stream_id)

      # Append PhaseCompleted externally — the actor's stale state
      # does not know about it yet.
      completed_event = %PhaseCompleted{
        phase_id: phase_id,
        run_id: run_id,
        index: 1,
        artifact_path: "/tmp/#{phase_id}.md",
        artifact_sha256: "deadbeef",
        artifact_bytes: 0
      }

      :ok =
        FServerStore.append_to_stream(stream_id, 1, [
          %EventData{event_type: "PhaseCompleted", data: completed_event, metadata: %{}}
        ])

      # Force actor's local version to 1 so the next append conflicts.
      # The actor's rehydrated version is 1 (PhaseStarted applied);
      # the stream is now at 2.
      force_actor_version(pid, 1)

      cmd = %{
        type: "phase.complete",
        payload: %{
          run_id: run_id,
          phase_id: phase_id,
          attempt: 1
        },
        aggregate_id: stream_id
      }

      result = CommandRouter.dispatch(cmd, 10_000)

      # Re-decision rejects with :phase_terminal, propagated through
      # compensate_and_reply unchanged.
      assert {:error, :phase_terminal} = result

      # Compensation helper short-circuited — no close was issued.
      # The cache is still empty (never populated: phase.complete
      # doesn't go through Stage 2 — task_create_event? is false),
      # and no compensation telemetry fires (re-decision rejected
      # before compensation ran).
      assert :sys.get_state(pid).in_flight_beads == %{}

      assert drain_telemetry([:foreman_server, :task_provider, :beads, :create, :compensated]) ==
               []
    end
  end

  # ===========================================================================
  # Helpers
  # ===========================================================================

  defp new_ids do
    %{
      project_id: "project-#{uuid()}",
      task_id: "task-#{uuid()}",
      command_id: "cmd-#{uuid()}"
    }
  end

  defp uuid, do: Elixir.EventStore.UUID.uuid4()

  defp start_actor(aggregate_module, aggregate_id) do
    {:ok, pid} = ForemanServer.Aggregator.start_aggregate(aggregate_module, aggregate_id)
    pid
  end

  defp force_actor_version(pid, version) do
    :sys.replace_state(pid, fn state -> %{state | version: version} end)
  end

  defp register_stub_provider(project_id, database_path) do
    :ok =
      TaskProvider.Registry.register_for_project(
        project_id,
        ForemanServer.ActorCompensationTest.StubProvider,
        %{database_path: database_path}
      )
  end

  defp task_create_command(ids) do
    %{
      type: "task.create",
      payload: %{
        task_id: ids.task_id,
        project_id: ids.project_id,
        title: "title-#{ids.task_id}",
        description: "desc",
        priority: 2,
        task_type: "feature",
        dedupe_key: "dedupe-#{ids.task_id}"
      },
      aggregate_id: "task:#{ids.task_id}",
      command_id: ids.command_id
    }
  end

  defp stub_close_response(bead_id) do
    %{
      stdout:
        Jason.encode!(%{
          "id" => bead_id,
          "status" => "closed",
          "title" => "stub task",
          "priority" => 2,
          "dependencies" => [],
          "assignee" => nil,
          "description" => "stub",
          "notes" => nil,
          "design" => nil,
          "labels" => [],
          "metadata" => %{"provider_id" => "stub", "source" => "br close"}
        }),
      stderr: "",
      exit_code: 0
    }
  end

  defp attach_telemetry_handler(event_path) do
    parent = self()
    handler_id = {__MODULE__, event_path, make_ref()}

    :ok =
      :telemetry.attach(
        handler_id,
        event_path,
        fn _name, _measurements, metadata, _config ->
          send(parent, {:telemetry_event, event_path, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler_id) end)
    handler_id
  end

  defp drain_telemetry(event_path, timeout_ms \\ 100) do
    Enum.reduce_while(1..max(1, div(timeout_ms, 10)), [], fn _, acc ->
      receive do
        {:telemetry_event, ^event_path, metadata} ->
          {:cont, [metadata | acc]}
      after
        10 -> {:halt, acc}
      end
    end)
  end

  defp telemetry_fired_for?(event_path, timeout_ms \\ 200) do
    drain_telemetry(event_path, timeout_ms) != []
  end

  # ---------------------------------------------------------------------------
  # JsonSchemaCache boot — BeadsAdapter.complete/3 calls into
  # JsonSchemaCache.validate/2 when it parses the br close response. The
  # application supervisor doesn't start the cache in test mode
  # (`start_json_schema_cache?: false` in config/test.exs), so each test
  # boots its own schema cache and stubs the four schema fetches.
  # ---------------------------------------------------------------------------

  defp start_schema_cache! do
    expect_schema_boot_fetches()
    start_supervised!(ForemanServer.TaskProviders.JsonSchemaCache)
  end

  defp expect_schema_boot_fetches do
    expect(BrRunnerMock, :cmd, 4, fn {:schema, %{schema: schema_name}}, %{}, [] ->
      {:ok, %{stdout: Jason.encode!(schema_document(schema_name)), stderr: "", exit_code: 0}}
    end)
  end

  defp schema_document("ready-issue") do
    %{
      "type" => "object",
      "required" => [
        "id",
        "title",
        "status",
        "priority",
        "dependencies",
        "assignee",
        "description",
        "notes",
        "design",
        "labels",
        "metadata"
      ],
      "properties" => %{
        "id" => %{"type" => "string"},
        "title" => %{"type" => "string"},
        "status" => %{"type" => "string"},
        "priority" => %{"type" => "integer"},
        "dependencies" => %{"type" => "array"},
        "assignee" => %{"type" => ["string", "null"]},
        "description" => %{"type" => ["string", "null"]},
        "notes" => %{"type" => ["string", "null"]},
        "design" => %{"type" => ["string", "null"]},
        "labels" => %{"type" => "array"},
        "metadata" => %{"type" => "object"}
      }
    }
  end

  defp schema_document("issue-details"), do: schema_document("ready-issue")
  defp schema_document("closed-issue"), do: schema_document("ready-issue")
  defp schema_document("claimed-issue"), do: schema_document("ready-issue")

  defp schema_document("error"), do: %{"type" => "object"}
  defp schema_document("commands"), do: %{"type" => "object"}

  # ---------------------------------------------------------------------------
  # Fake CommandRouter — replaces the supervised CommandRouter for the
  # duration of a single test. Stops the supervised child via
  # `Supervisor.terminate_child/2`, registers as `ForemanServer.CommandRouter`,
  # and restores the original via `Supervisor.restart_child/2` in cleanup.
  # ---------------------------------------------------------------------------

  defp install_fake_command_router(scripted_replies) do
    :ok = Supervisor.terminate_child(ForemanServer.Application, ForemanServer.CommandRouter)
    wait_for_name_unregistered(ForemanServer.CommandRouter, 1_000)

    {:ok, fake_pid} =
      ForemanServer.ActorCompensationTest.FakeCommandRouter.start_link(
        scripted_replies: scripted_replies,
        name: ForemanServer.CommandRouter
      )

    on_exit(fn -> cleanup_fake_command_router(fake_pid) end)
    fake_pid
  end

  defp wait_for_name_unregistered(name, timeout_ms) do
    Enum.reduce_while(1..max(1, div(timeout_ms, 10)), nil, fn _, _ ->
      if Process.whereis(name) == nil do
        {:halt, :ok}
      else
        Process.sleep(10)
        {:cont, nil}
      end
    end)

    if Process.whereis(name) != nil do
      flunk("name #{inspect(name)} still registered after terminate")
    end

    :ok
  end

  defp cleanup_fake_command_router(fake_pid) do
    try do
      if Process.alive?(fake_pid) do
        ref = Process.monitor(fake_pid)
        GenServer.stop(fake_pid, :normal, 5_000)

        receive do
          {:DOWN, ^ref, :process, ^fake_pid, _} -> :ok
        after
          5_000 -> :ok
        end
      end
    catch
      _kind, _reason -> :ok
    end

    case Supervisor.restart_child(ForemanServer.Application, ForemanServer.CommandRouter) do
      {:ok, _pid} ->
        :ok

      {:error, {:already_started, _pid}} ->
        :ok

      {:error, reason} ->
        IO.puts(
          :stderr,
          "[actor_compensation_test] could not restart CommandRouter: #{inspect(reason)}"
        )
    end
  end
end

# ---------------------------------------------------------------------------
# FakeCommandRouter — test double that replaces the supervised
# ForemanServer.CommandRouter for the duration of a single test.
# ---------------------------------------------------------------------------

defmodule ForemanServer.ActorCompensationTest.FakeCommandRouter do
  @moduledoc false
  use GenServer

  @impl true
  def init(opts) do
    state = %{
      scripted_replies: Keyword.get(opts, :scripted_replies, []),
      sent: []
    }

    {:ok, state}
  end

  @impl true
  def handle_info({:append, _aggregate_id, event_data_list, expected_version, ref, sender}, state) do
    sent_entry = {expected_version, ref, length(event_data_list)}
    {reply, new_script} = pop_reply(state.scripted_replies, ref, length(event_data_list))
    send(sender, reply)

    {:noreply, %{state | scripted_replies: new_script, sent: [sent_entry | state.sent]}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp pop_reply([{:conflict, latency} | rest], ref, _count) do
    {{:error, ref, :wrong_expected_version, latency}, rest}
  end

  defp pop_reply([{:ok, latency} | rest], ref, count) do
    {{:append_ok, ref, count, latency}, rest}
  end

  defp pop_reply([], ref, count) do
    {{:append_ok, ref, count, 0}, []}
  end

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end
end

# ---------------------------------------------------------------------------
# StubProvider — minimal TaskProvider for compensation tests.
# ---------------------------------------------------------------------------

defmodule ForemanServer.ActorCompensationTest.StubProvider do
  @moduledoc false
  @behaviour ForemanServer.TaskProvider

  alias ForemanServer.TaskProvider.Issue
  alias ForemanServer.TaskProviders.ProviderError

  @impl true
  def name, do: "stub_compensation"

  @impl true
  def capabilities do
    %{
      provider_id: :stub_compensation,
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
