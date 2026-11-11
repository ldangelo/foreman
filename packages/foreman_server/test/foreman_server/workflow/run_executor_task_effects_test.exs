defmodule ForemanServer.Workflow.RunExecutorTaskEffectsTest do
  @moduledoc """
  The four task-provider state changes as keyed effects (TRD-015): `RunExecutor`'s
  `claim`, `complete` and attempt 1 of `fail`, and the boot scan's `reopen`.

  A crash is a process killed while it is inside the provider call
  (`FakeTaskProvider.crash/4` blocks the call, before or after it applied), so the
  key stays `started` exactly as a real crash leaves it. Recovery is then
  `BootReconciliation.do_reconcile_ambiguous_keys/2` with the configured registry
  (which also proves `task_provider` is registered).
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  import ExUnit.CaptureLog

  alias ForemanServer.Aggregate
  alias ForemanServer.Aggregates.Run
  alias ForemanServer.{CommandGateway, CommandRouter, EventStore, ProjectionStore, RunAdmission}
  alias ForemanServer.Idempotency.KeyStore
  alias ForemanServer.Idempotency.Reconcilers.TaskProvider, as: TaskProviderEffect
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.{FakeTaskProvider, KeyStoreReset, TestApplication}
  alias ForemanServer.Workflow.{BootReconciliation, RunExecutor}

  @terminal_event [:foreman_server, :workflow, :boot_reconciliation, :effect_on_terminal_run]
  @cache_name :foreman_server_json_schema_cache
  @actor "foreman-runner"

  # The phase worker of `Overwatch.start_phase/2`, mirroring the protocol
  # `RunExecutorTest.TestWorkerAdapter` follows: activate handshake, one result sent to the
  # recipient, exit. The result comes from the app env so a test chooses pass or fail.
  defmodule Worker do
    @moduledoc false
    use GenServer

    alias ForemanServer.Overwatch.WorkerProtocol

    def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

    @impl true
    def init(opts), do: {:ok, opts}

    @impl true
    def handle_info({:overwatch_activate, _worker_id, _run_id, parent}, state) do
      send(parent, {:overwatch_activated, self()})
      send(self(), :run)
      {:noreply, state}
    end

    def handle_info(:run, state) do
      result =
        Application.get_env(:foreman_server, :task_effects_worker_result, {:ok, "artifact"})

      _ =
        WorkerProtocol.emit(:worker_exited, %{
          worker_id: Keyword.fetch!(state, :worker_id),
          run_id: Keyword.fetch!(state, :run_id)
        })

      case Keyword.get(state, :result_recipient) do
        pid when is_pid(pid) -> send(pid, {:worker_result, result})
        _ -> :ok
      end

      {:stop, :normal, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  defmodule BackendAdapter do
    @moduledoc false
    @behaviour ForemanServer.AgentRuntime.BackendAdapter

    @impl true
    def name, do: :pi

    @impl true
    def capabilities,
      do: %{
        type: :cli,
        strengths: [:workflow_execution],
        weaknesses: [:none],
        supported_contexts: [:implement, :test]
      }

    @impl true
    def available?, do: true

    @impl true
    def execute(_request, _opts), do: {:ok, "artifact", %{}}
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    {:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
    {:ok, _} = Application.ensure_all_started(:eventstore)

    ensure_started({Phoenix.PubSub, name: ForemanServer.PubSub}, ForemanServer.PubSub)
    ensure_started(ForemanServerWeb.Presence, ForemanServerWeb.Presence)
    ensure_started(ForemanServer.EventStore, ForemanServer.EventStore)
    ensure_started(ForemanServer.ProjectionStore, ForemanServer.ProjectionStore)
    ensure_started(ForemanServer.Aggregator, ForemanServer.Aggregator)

    ensure_started(
      {Elixir.Registry, keys: :unique, name: ForemanServer.RunExecutorRegistry},
      ForemanServer.RunExecutorRegistry
    )

    ensure_started(ForemanServer.CommandRouter, ForemanServer.CommandRouter)

    ensure_started(
      ForemanServer.AgentRuntime.AdapterCatalog,
      ForemanServer.AgentRuntime.AdapterCatalog
    )

    ensure_started(
      ForemanServer.AgentRuntime.InvocationSupervisor,
      ForemanServer.AgentRuntime.InvocationSupervisor
    )

    ensure_started(ForemanServer.TaskProvider.Registry, ForemanServer.TaskProvider.Registry)
    ensure_started(ForemanServer.Agents.JidoShellRunner, ForemanServer.Agents.JidoShellRunner)
    ensure_started(ForemanServer.Overwatch, ForemanServer.Overwatch)

    previous = ForemanServer.AgentRuntime.AdapterCatalog.routing_snapshot()

    for %{adapter: module} <- previous do
      _ = ForemanServer.AgentRuntime.AdapterCatalog.unregister(module)
    end

    {:ok, _} = ForemanServer.AgentRuntime.register_adapter(BackendAdapter)

    on_exit(fn ->
      _ = ForemanServer.AgentRuntime.AdapterCatalog.unregister(BackendAdapter)

      for %{adapter: module} <- previous do
        _ = ForemanServer.AgentRuntime.register_adapter(module)
      end
    end)

    :ok
  end

  setup do
    previous_provider = Application.get_env(:foreman_server, :task_provider, [])
    previous_worker = Application.get_env(:foreman_server, :worker_adapter)

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: @actor,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    Application.put_env(:foreman_server, :worker_adapter, Worker)
    Application.put_env(:foreman_server, :task_effects_worker_result, {:ok, "artifact"})

    ForemanServer.TestSupport.RunSlotsReset.reset!()
    TestApplication.reset_application_child!(Registry)

    dispatcher = Process.whereis(ForemanServer.Workflow.Dispatcher)

    if dispatcher do
      :sys.suspend(dispatcher)
      on_exit(fn -> ForemanServer.TestSupport.DispatcherRestart.restart!() end)
    end

    KeyStoreReset.reset!()
    start_supervised!(FakeTaskProvider)

    {handler_id, ref} = Handler.attach_event_handlers(self(), [@terminal_event])

    on_exit(fn ->
      :telemetry.detach(handler_id)
      Application.put_env(:foreman_server, :task_provider, previous_provider)
      Application.delete_env(:foreman_server, :task_effects_worker_result)

      case previous_worker do
        nil -> Application.delete_env(:foreman_server, :worker_adapter)
        adapter -> Application.put_env(:foreman_server, :worker_adapter, adapter)
      end

      KeyStoreReset.reset!()
    end)

    {:ok, ref: ref}
  end

  # --- claim and complete, through RunExecutor.claim/4 and complete/4 ---

  describe "claim and complete are keyed effects" do
    test "a claim writes its key with run, project, op, issue and actor, and settles it" do
      %{project_id: project_id, db: db, task_id: task_id, run_id: run_id} = world("claim-key")
      FakeTaskProvider.put_issue(db, task_id, "open")

      assert {:ok, %{status: "in_progress"}} =
               RunExecutor.claim(project_id, task_id, @actor, run_id)

      key = "effect:task_provider:#{run_id}:claim:#{task_id}"
      assert key == TaskProviderEffect.key(run_id, :claim, task_id)
      assert {:ok, %{status: :completed, metadata: meta}} = KeyStore.get(key)

      assert %{
               "run_id" => ^run_id,
               "project_id" => ^project_id,
               "op" => "claim",
               "issue_id" => ^task_id,
               "actor" => @actor
             } = stringify(meta)
    end

    test "a complete writes its key with run, project, op and issue, and settles it" do
      %{project_id: project_id, db: db, task_id: task_id, run_id: run_id} = world("complete-key")
      FakeTaskProvider.put_issue(db, task_id, "in_progress", @actor)

      assert {:ok, %{status: "closed"}} =
               RunExecutor.complete(project_id, task_id, run_id, "/artifacts/a.md")

      assert {:ok, %{status: :completed, metadata: meta}} =
               KeyStore.get("effect:task_provider:#{run_id}:complete:#{task_id}")

      assert %{
               "run_id" => ^run_id,
               "project_id" => ^project_id,
               "op" => "complete",
               "issue_id" => ^task_id
             } = stringify(meta)
    end

    test "a provider error settles the key failed and is returned unchanged" do
      %{project_id: project_id, db: db, task_id: task_id, run_id: run_id} = world("claim-error")
      FakeTaskProvider.put_issue(db, task_id, "open")
      error = FakeTaskProvider.error("not claimable", false)
      FakeTaskProvider.script(db, :claim, [{:error, error}])

      assert {:error, ^error} = RunExecutor.claim(project_id, task_id, @actor, run_id)
      assert {:ok, :failed} = KeyStore.status(TaskProviderEffect.key(run_id, :claim, task_id))
    end
  end

  describe "a crash on each side of claim and complete" do
    # {op, status the issue starts in}
    for {op, start_status} <- [claim: "open", complete: "in_progress"] do
      test "#{op}: a crash after the provider call is :done, blocks the run, and the call is not repeated" do
        op = unquote(op)
        %{db: db, task_id: task_id, run_id: run_id} = w = world("#{op}-after")
        FakeTaskProvider.put_issue(db, task_id, unquote(start_status), @actor)

        crash_in_call(w, op, :after)
        key = TaskProviderEffect.key(run_id, op, task_id)
        assert {:ok, :started} = KeyStore.status(key)

        sweep()

        assert status(run_id) == "blocked"
        assert block_reason(run_id) == "effect_already_done"
        assert {:ok, :ambiguous} = KeyStore.status(key)

        # The key is unresolved, so the call is refused, not repeated.
        assert {:error, {:effect_unresolved, ^key}} = call(w, op)
        assert FakeTaskProvider.calls(db) == [{op, task_id}]
      end

      test "#{op}: a crash before the provider call is :not_done, is recorded, and nothing is issued" do
        op = unquote(op)
        %{db: db, task_id: task_id, run_id: run_id} = w = world("#{op}-before")
        FakeTaskProvider.put_issue(db, task_id, unquote(start_status), @actor)

        crash_in_call(w, op, :before)
        key = TaskProviderEffect.key(run_id, op, task_id)

        sweep()

        assert status(run_id) == "awaiting_worker"
        assert recovery_outcome(run_id, "effect_retried")
        assert FakeTaskProvider.status(db, task_id) == unquote(start_status)
        assert FakeTaskProvider.calls(db) == [{op, task_id}]
        assert {:ok, :ambiguous} = KeyStore.status(key)
      end

      test "#{op}: a provider that cannot be reached blocks the run `effect_outcome_ambiguous`" do
        op = unquote(op)
        %{db: db, task_id: task_id, run_id: run_id} = w = world("#{op}-down")
        FakeTaskProvider.put_issue(db, task_id, unquote(start_status), @actor)

        crash_in_call(w, op, :after)
        FakeTaskProvider.get_mode(db, {:error, FakeTaskProvider.error("br down", true)})

        sweep()

        assert status(run_id) == "blocked"
        assert block_reason(run_id) == "effect_outcome_ambiguous"
        assert FakeTaskProvider.calls(db) == [{op, task_id}]
      end
    end

    test "complete: a :not_done verdict lets the resumed run complete the issue" do
      %{db: db, task_id: task_id, run_id: run_id} = w = world("complete-resume")
      FakeTaskProvider.put_issue(db, task_id, "in_progress", @actor)

      crash_in_call(w, :complete, :before)
      sweep()
      assert status(run_id) == "awaiting_worker"

      FakeTaskProvider.clear_crash(db, :complete)
      assert {:ok, %{status: "closed"}} = call(w, :complete)

      assert FakeTaskProvider.calls(db) == [{:complete, task_id}, {:complete, task_id}]

      assert {:ok, :completed} =
               KeyStore.status(TaskProviderEffect.key(run_id, :complete, task_id))
    end

    test "claim: a claim in_progress for someone else is :unknown and blocks the run" do
      %{db: db, task_id: task_id, run_id: run_id} = w = world("claim-other")
      FakeTaskProvider.put_issue(db, task_id, "open")
      crash_in_call(w, :claim, :before)
      FakeTaskProvider.put_issue(db, task_id, "in_progress", "another-agent")

      sweep()

      assert status(run_id) == "blocked"
      assert block_reason(run_id) == "effect_outcome_ambiguous"
    end

    test "a project the registry cannot resolve is :unknown and blocks the run" do
      %{project_id: project_id, db: db, task_id: task_id, run_id: run_id} = w = world("unrouted")
      FakeTaskProvider.put_issue(db, task_id, "open", @actor)
      crash_in_call(w, :claim, :after)

      :ok = Registry.unregister_for_project(project_id, :database_not_found)
      sweep()

      assert status(run_id) == "blocked"
      assert block_reason(run_id) == "effect_outcome_ambiguous"
    end
  end

  # --- fail, attempt 1, through a real RunExecutor ---

  describe "fail is keyed on attempt 1 only" do
    setup do
      Application.put_env(:foreman_server, :task_effects_worker_result, {:error, :boom})
      :ok
    end

    test "attempt 1 writes the key and the run still fails" do
      %{db: db, task_id: task_id, run_id: run_id} = w = full_world("fail-key")
      FakeTaskProvider.put_issue(db, task_id, "open")

      start_executor!(w)
      await_status(run_id, "failed")

      key = TaskProviderEffect.key(run_id, :fail, task_id)
      assert {:ok, %{status: :completed, metadata: meta}} = KeyStore.get(key)

      assert %{
               "run_id" => ^run_id,
               "project_id" => _,
               "op" => "fail",
               "issue_id" => ^task_id
             } = stringify(meta)

      assert FakeTaskProvider.calls(db) == [{:claim, task_id}, {:fail, task_id}]
      assert FakeTaskProvider.status(db, task_id) == "blocked"
    end

    test "the detached retries 2 and 3 write no key: attempt 1's outcome is the key's last word" do
      %{db: db, task_id: task_id, run_id: run_id} = w = full_world("fail-retry")
      FakeTaskProvider.put_issue(db, task_id, "open")
      transient = FakeTaskProvider.error("br busy", true)
      # Attempt 1 (synchronous, keyed) answers a transient error; the retry is detached.
      FakeTaskProvider.script(db, :fail, [{:error, transient}])
      key = TaskProviderEffect.key(run_id, :fail, task_id)

      start_executor!(w)
      await_status(run_id, "failed")
      await_calls(db, :fail, 2)

      # Attempt 2 succeeded against the provider, yet the key still says attempt 1 failed:
      # a retry that went through `Effect.run` would have settled it `completed`.
      assert FakeTaskProvider.status(db, task_id) == "blocked"
      assert {:ok, :failed} = KeyStore.status(key)
      assert Enum.count(FakeTaskProvider.calls(db), &(&1 == {:fail, task_id})) == 2
    end

    test "a refused attempt 1 does not call the provider, and the run still fails" do
      %{db: db, task_id: task_id, run_id: run_id} = w = full_world("fail-refused")
      FakeTaskProvider.put_issue(db, task_id, "open")

      key = TaskProviderEffect.key(run_id, :fail, task_id)

      :ok =
        KeyStore.mark_started(
          key,
          Map.put(
            TaskProviderEffect.intent(run_id, w.project_id, :fail, task_id),
            :effect_class,
            "task_provider"
          )
        )

      :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")
      :ok = KeyStore.mark_unresolved(key, 1_000_000, "effect_already_done")

      log =
        capture_log([level: :error], fn ->
          start_executor!(w)
          await_status(run_id, "failed")

          await(fn ->
            if RunExecutor.pid_for(run_id) == nil, do: {:ok, :stopped}, else: :waiting
          end)
        end)

      refute {:fail, task_id} in FakeTaskProvider.calls(db)
      assert {:ok, :ambiguous} = KeyStore.status(key)

      # The log says the provider call was not attempted, not that `phase.fail` failed.
      assert log =~ "task-provider fail"
      assert log =~ "was not attempted"
      assert log =~ "effect_unresolved"
      refute log =~ "phase.fail dispatch"
    end

    test "a crash during attempt 1 after the provider call is :done and blocks the run" do
      assert_fail_crash_reconciled(:after)
    end

    test "a crash during attempt 1 before the provider call is :not_done and is recorded" do
      assert_fail_crash_reconciled(:before)
    end

    test "an unreachable provider blocks a run that crashed during attempt 1" do
      %{db: db, task_id: task_id, run_id: run_id} = w = full_world("fail-down")
      FakeTaskProvider.put_issue(db, task_id, "open")
      FakeTaskProvider.crash(db, :fail, :after, self())

      executor = start_unsupervised_executor(w)
      assert_receive {:in_call, :fail, :after}, 10_000
      kill_executor(executor, run_id)
      FakeTaskProvider.get_mode(db, {:error, FakeTaskProvider.error("br down", true)})

      sweep()

      assert status(run_id) == "blocked"
      assert block_reason(run_id) == "effect_outcome_ambiguous"
    end
  end

  describe "RunExecutor reaches the keyed calls on its production path" do
    test "a run that succeeds claims and completes through keys" do
      %{db: db, task_id: task_id, run_id: run_id} = w = full_world("happy")
      FakeTaskProvider.put_issue(db, task_id, "open")

      start_executor!(w)
      await_status(run_id, "completed")

      assert {:ok, :completed} = KeyStore.status(TaskProviderEffect.key(run_id, :claim, task_id))

      assert {:ok, :completed} =
               KeyStore.status(TaskProviderEffect.key(run_id, :complete, task_id))

      assert FakeTaskProvider.calls(db) == [{:claim, task_id}, {:complete, task_id}]
    end

    test "a resumed run issues no claim after a :not_done claim verdict" do
      %{db: db, task_id: task_id, run_id: run_id} = w = full_world("claim-resume")
      FakeTaskProvider.put_issue(db, task_id, "open")

      crash_in_call(w, :claim, :before)
      sweep()

      assert recovery_outcome(run_id, "effect_retried")
      assert FakeTaskProvider.calls(db) == [{:claim, task_id}]
      FakeTaskProvider.clear_crash(db, :claim)

      start_executor!(w, resume_from: 0)
      await_status(run_id, "completed")

      # Nothing re-issued the claim: the issue is still `open` as far as a claim goes,
      # and the resumed run went on to complete it.
      assert Enum.count(FakeTaskProvider.calls(db), &match?({:claim, _}, &1)) == 1
      assert {:ok, :ambiguous} = KeyStore.status(TaskProviderEffect.key(run_id, :claim, task_id))
    end
  end

  # --- boot reopen ---

  describe "boot reopen of an orphaned in_progress issue" do
    test "with a projected run the reopen is keyed and settles" do
      %{project_id: project_id, db: db, task_id: task_id} = w = world("reopen-keyed")
      older = w.run_id
      newer = start_run!(project_id, task_id, "newer")
      end_run!(older)
      Process.sleep(5)
      end_run!(newer)
      FakeTaskProvider.put_issue(db, task_id, "in_progress", @actor)
      ensure_cache_stub!()

      assert :ok = BootReconciliation.reconcile()

      assert FakeTaskProvider.status(db, task_id) == "open"
      assert FakeTaskProvider.calls(db) == [{:reopen, task_id}]

      # Attributed to the newest projected run of the task.
      assert {:ok, %{status: :completed, metadata: meta}} =
               KeyStore.get(TaskProviderEffect.key(newer, :reopen, task_id))

      assert %{"run_id" => ^newer, "project_id" => ^project_id, "op" => "reopen"} =
               stringify(meta)

      assert :not_found = KeyStore.status(TaskProviderEffect.key(older, :reopen, task_id))
    end

    test "with no projected run it is not keyed, warns naming the issue, and still reopens" do
      %{project_id: project_id, db: db} = world("reopen-unkeyed")
      issue_id = "orphan-no-run-#{System.unique_integer([:positive])}"
      FakeTaskProvider.put_issue(db, issue_id, "in_progress", @actor)
      ensure_cache_stub!()

      log = capture_log([level: :warning], fn -> assert :ok = BootReconciliation.reconcile() end)

      assert log =~ issue_id
      assert log =~ "without an effect key"
      assert log =~ project_id
      assert FakeTaskProvider.status(db, issue_id) == "open"
      assert task_provider_keys() == []
    end

    test "a crash during the reopen of a failed run: :done is logged and counted, never a block",
         %{ref: ref} do
      %{db: db, task_id: task_id, run_id: run_id} = world("reopen-failed")
      end_run!(run_id)
      FakeTaskProvider.put_issue(db, task_id, "in_progress", @actor)
      crash_in_reopen(db, :after)

      key = TaskProviderEffect.key(run_id, :reopen, task_id)
      assert {:ok, :started} = KeyStore.status(key)
      events_before = events(run_id)

      log = capture_log([level: :warning], fn -> sweep() end)

      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{run_id: ^run_id, effect_verdict: "done", status: "failed"} = metadata}

      assert metadata.effect_class == "task_provider"
      assert metadata.effect_key == key
      assert log =~ "cannot be blocked"
      assert log =~ key

      assert status(run_id) == "failed"
      assert events(run_id) == events_before
      assert {:ok, :ambiguous} = KeyStore.status(key)
    end

    test "a crash before the reopen of a failed run: :not_done is logged and counted, and the boot scan reopens again",
         %{ref: ref} do
      %{db: db, task_id: task_id, run_id: run_id} = world("reopen-failed-before")
      end_run!(run_id)
      FakeTaskProvider.put_issue(db, task_id, "in_progress", @actor)
      crash_in_reopen(db, :before)

      key = TaskProviderEffect.key(run_id, :reopen, task_id)
      events_before = events(run_id)

      log = capture_log([level: :warning], fn -> sweep() end)

      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{run_id: ^run_id, effect_verdict: "not_done"}}

      assert log =~ "did not happen"
      assert events(run_id) == events_before
      assert {:ok, :ambiguous} = KeyStore.status(key)
      assert FakeTaskProvider.status(db, task_id) == "in_progress"

      # The reopen is still needed, so the next boot scan issues it again.
      FakeTaskProvider.clear_crash(db, :reopen)
      assert :ok = BootReconciliation.reconcile()

      assert FakeTaskProvider.status(db, task_id) == "open"
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "an :unknown verdict on a failed run leaves the reopen key repeatable: the next boot reopens" do
      %{db: db, task_id: task_id, run_id: run_id} = world("reopen-unknown")
      end_run!(run_id)
      FakeTaskProvider.put_issue(db, task_id, "in_progress", @actor)
      crash_in_reopen(db, :before)
      FakeTaskProvider.get_mode(db, {:error, FakeTaskProvider.error("br down", true)})

      key = TaskProviderEffect.key(run_id, :reopen, task_id)
      sweep()

      assert status(run_id) == "failed"
      assert {:ok, %{status: :ambiguous, metadata: meta}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(stringify(meta)) == :none

      FakeTaskProvider.get_mode(db, :ok)
      FakeTaskProvider.clear_crash(db, :reopen)
      assert :ok = BootReconciliation.reconcile()

      assert FakeTaskProvider.status(db, task_id) == "open"
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "a :done verdict on a failed run leaves the reopen key repeatable: the next boot reopens" do
      %{db: db, task_id: task_id, run_id: run_id} = world("reopen-done-again")
      end_run!(run_id)
      FakeTaskProvider.put_issue(db, task_id, "in_progress", @actor)
      crash_in_reopen(db, :after)

      key = TaskProviderEffect.key(run_id, :reopen, task_id)
      sweep()

      assert {:ok, %{status: :ambiguous, metadata: meta}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(stringify(meta)) == :none

      # The issue is orphaned again (another claim that died with the same run's id).
      FakeTaskProvider.clear_crash(db, :reopen)
      FakeTaskProvider.put_issue(db, task_id, "in_progress", @actor)
      assert :ok = BootReconciliation.reconcile()

      assert FakeTaskProvider.status(db, task_id) == "open"
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "a crash during the reopen of a paused run: :done blocks it `effect_already_done`" do
      %{db: db, task_id: task_id, run_id: run_id} = world("reopen-paused")
      pause_run!(run_id)
      FakeTaskProvider.put_issue(db, task_id, "in_progress", @actor)
      crash_in_reopen(db, :after)

      sweep()

      assert status(run_id) == "blocked"
      assert block_reason(run_id) == "effect_already_done"
    end

    test "a provider that cannot be reached blocks a paused run `effect_outcome_ambiguous`" do
      %{db: db, task_id: task_id, run_id: run_id} = world("reopen-paused-down")
      pause_run!(run_id)
      FakeTaskProvider.put_issue(db, task_id, "in_progress", @actor)
      crash_in_reopen(db, :after)
      FakeTaskProvider.get_mode(db, {:error, FakeTaskProvider.error("br down", true)})

      sweep()

      assert status(run_id) == "blocked"
      assert block_reason(run_id) == "effect_outcome_ambiguous"
    end
  end

  # --- helpers ---

  defp sweep, do: BootReconciliation.do_reconcile_ambiguous_keys(fn _key -> true end)

  defp assert_fail_crash_reconciled(side) do
    %{db: db, task_id: task_id, run_id: run_id} = w = full_world("fail-crash-#{side}")
    FakeTaskProvider.put_issue(db, task_id, "open")
    FakeTaskProvider.crash(db, :fail, side, self())

    executor = start_unsupervised_executor(w)
    assert_receive {:in_call, :fail, ^side}, 10_000
    kill_executor(executor, run_id)

    assert {:ok, :started} = KeyStore.status(TaskProviderEffect.key(run_id, :fail, task_id))

    sweep()

    if side == :after do
      assert FakeTaskProvider.status(db, task_id) == "blocked"
      assert status(run_id) == "blocked"
      assert block_reason(run_id) == "effect_already_done"
    else
      assert FakeTaskProvider.status(db, task_id) == "in_progress"
      assert recovery_outcome(run_id, "effect_retried")
      refute status(run_id) == "blocked"
    end

    assert Enum.count(FakeTaskProvider.calls(db), &(&1 == {:fail, task_id})) == 1
  end

  defp stringify(meta), do: Map.new(meta, fn {k, v} -> {to_string(k), v} end)

  # A project registered with the fake provider (through the real `project.register`
  # command and the projector that feeds the registry) and a started run on it.
  defp world(label) do
    project_id = "project-#{label}-#{System.unique_integer([:positive])}"
    db = "/abs/task-effects/#{project_id}.db"
    register_project!(project_id, db)
    task_id = "task-#{label}-#{System.unique_integer([:positive])}"
    run_id = start_run!(project_id, task_id, "run")
    %{project_id: project_id, db: db, task_id: task_id, run_id: run_id}
  end

  defp register_project!(project_id, db) do
    dispatch_system!("project.register", "project:#{project_id}", %{
      project_id: project_id,
      name: project_id,
      path: System.tmp_dir!(),
      task_provider: %{
        provider: FakeTaskProvider.provider_ref(),
        config: %{"database_path" => db}
      }
    })

    # The projector that turns `task_provider` config into registry routing is not part of
    # this test's tree: register the same module and config it would.
    assert :ok =
             Registry.register_for_project(project_id, FakeTaskProvider, %{"database_path" => db})

    await(fn ->
      case ProjectionStore.project_projection(project_id) do
        %{} -> {:ok, :registered}
        other -> {:waiting, other}
      end
    end)
  end

  defp start_run!(project_id, task_id, label) do
    run_id = "#{label}-#{System.system_time(:nanosecond)}-#{System.unique_integer([:positive])}"

    {:ok, _} =
      CommandRouter.dispatch_run_start(project_id, %{
        run_id: run_id,
        task_id: task_id,
        workflow_snapshot: %{phases: [], attempt: 1}
      })

    run_id
  end

  # The world a RunExecutor needs: a task, its approval, a dispatch and an admitted run.
  defp full_world(label) do
    project_id = "project-#{label}-#{System.unique_integer([:positive])}"
    db = "/abs/task-effects/#{project_id}.db"
    register_project!(project_id, db)
    task_id = "task-#{label}-#{System.unique_integer([:positive])}"
    run_id = "run-#{label}-#{System.unique_integer([:positive])}"
    approval_id = "approval-#{run_id}"

    artifact_dir = Path.join(System.tmp_dir!(), "task-effects-#{run_id}")
    File.mkdir_p!(artifact_dir)
    on_exit(fn -> File.rm_rf(artifact_dir) end)

    snapshot = %{
      phases: [
        %{
          name: :implement,
          artifact_template: %{path: Path.join([artifact_dir, "{run_id}-{task_id}.md"])},
          context: %{"script_key" => run_id}
        }
      ],
      worktree: %{enabled: false}
    }

    dispatch_system!("task.create", "task:#{task_id}", %{
      task_id: task_id,
      project_id: project_id,
      task_type: "implement",
      title: "effects #{task_id}"
    })

    dispatch_system!("task.approve", "task:#{task_id}", %{
      task_id: task_id,
      approval_id: approval_id,
      approved_by: "task-effects-test",
      approved_at: "2026-08-06T00:00:00Z",
      run_id: run_id,
      workflow_snapshot: snapshot
    })

    dispatch_system!("task.dispatch", "task:#{task_id}", %{task_id: task_id})

    assert {:ok, result} =
             RunAdmission.start(project_id, %{
               run_id: run_id,
               task_id: task_id,
               project_id: project_id,
               approval_id: approval_id,
               workflow_snapshot: snapshot,
               phase_specs: snapshot.phases
             })

    refute result in [:slot_queued, :queued, nil], "the run was not admitted: #{inspect(result)}"

    %{project_id: project_id, db: db, task_id: task_id, run_id: run_id}
  end

  defp start_executor!(%{run_id: run_id, task_id: task_id}, opts \\ []) do
    task = ProjectionStore.task_projection(task_id)

    start_supervised!(%{
      id: {RunExecutor, run_id},
      start: {RunExecutor, :start_link, [run_id, task, opts]},
      restart: :temporary,
      shutdown: 5_000,
      type: :worker
    })
  end

  # An executor that nothing supervises, so killing it is a crash and nothing restarts it.
  defp start_unsupervised_executor(%{run_id: run_id, task_id: task_id}) do
    task = ProjectionStore.task_projection(task_id)
    test = self()

    spawn(fn ->
      {:ok, pid} = RunExecutor.start_link(run_id, task)
      send(test, {:executor, pid})
      Process.sleep(:infinity)
    end)

    assert_receive {:executor, pid}, 5_000
    pid
  end

  # The registry drops a dead executor asynchronously; recovery treats a run with a
  # registered executor as live, so wait for the entry to go like a restarted server would.
  defp kill_executor(executor, run_id) do
    monitor = Process.monitor(executor)
    Process.exit(executor, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^executor, :killed}, 5_000

    await(fn ->
      if RunExecutor.pid_for(run_id) == nil, do: {:ok, :gone}, else: :waiting
    end)
  end

  defp call(%{project_id: project_id, task_id: task_id, run_id: run_id}, :claim),
    do: RunExecutor.claim(project_id, task_id, @actor, run_id)

  defp call(%{project_id: project_id, task_id: task_id, run_id: run_id}, :complete),
    do: RunExecutor.complete(project_id, task_id, run_id, "/artifacts/a.md")

  # Run `op` in a process and kill it while it is inside the provider call.
  defp crash_in_call(%{db: db} = w, op, side) do
    FakeTaskProvider.crash(db, op, side, self())
    pid = spawn(fn -> call(w, op) end)
    assert_receive {:in_call, ^op, ^side}, 10_000
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    :ok
  end

  # The boot scan runs the reopen in a process that is killed inside the provider call.
  defp crash_in_reopen(db, side) do
    FakeTaskProvider.crash(db, :reopen, side, self())
    ensure_cache_stub!()
    pid = spawn(fn -> BootReconciliation.reconcile() end)
    assert_receive {:in_call, :reopen, ^side}, 10_000
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 5_000
    :ok
  end

  # `reopen` starts the schema cache before it calls the provider; these tests do not
  # exercise the Beads adapter, so a stand-in under the cache's name is enough.
  defp ensure_cache_stub! do
    if Process.whereis(@cache_name) == nil do
      start_supervised!(%{
        id: :schema_cache_stub,
        start: {Agent, :start_link, [fn -> :ok end, [name: @cache_name]]}
      })
    end

    :ok
  end

  defp task_provider_keys do
    for status <- [:started, :completed, :failed, :ambiguous],
        key <- KeyStore.list_by_status(status),
        String.starts_with?(key, "effect:task_provider:"),
        do: key
  end

  defp end_run!(run_id) do
    dispatch_system!("run.fail", "run:#{run_id}", %{run_id: run_id, reason: "test"})
  end

  defp pause_run!(run_id) do
    dispatch_system!("run.pause", "run:#{run_id}", %{run_id: run_id, reason: "test"})
  end

  defp dispatch_system!(type, aggregate_id, payload) do
    command_id = "#{type}:#{aggregate_id}:#{System.unique_integer([:positive])}"

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               command_id: command_id,
               aggregate_id: aggregate_id,
               type: type,
               payload: payload
             })
  end

  defp events(run_id) do
    {:ok, recorded} = EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
    for e <- recorded, do: {Aggregate.event_type(e), Aggregate.event_payload(e)}
  end

  defp recovery_outcome(run_id, outcome) do
    Enum.find(events(run_id), fn
      {"RunRecoveryAttempted", payload} -> Aggregate.get(payload, :outcome) == outcome
      _ -> false
    end)
  end

  defp block_reason(run_id) do
    case Enum.find(events(run_id), &match?({"RunBlocked", _}, &1)) do
      {"RunBlocked", payload} -> Aggregate.get(payload, :reason)
      nil -> nil
    end
  end

  defp status(run_id), do: Aggregate.load(Run, "run:#{run_id}") |> elem(0) |> Map.fetch!(:status)

  defp await_status(run_id, wanted) do
    await(fn ->
      if status(run_id) == wanted, do: {:ok, wanted}, else: {:waiting, status(run_id)}
    end)
  end

  defp await_calls(db, op, count) do
    await(fn ->
      if Enum.count(FakeTaskProvider.calls(db), &match?({^op, _}, &1)) >= count,
        do: {:ok, count},
        else: :waiting
    end)
  end

  defp await(fun, timeout_ms \\ 15_000) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await(fun, deadline)
  end

  defp do_await(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      other ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("timed out waiting (last: #{inspect(other)})")
        else
          Process.sleep(25)
          do_await(fun, deadline)
        end
    end
  end

  defp ensure_started(child_spec, name) do
    if Process.whereis(name) == nil, do: start_supervised!(child_spec)
    :ok
  end
end
