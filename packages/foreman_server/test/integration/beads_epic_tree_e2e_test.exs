defmodule ForemanServer.Integration.BeadsEpicTreeE2ETest do
  @moduledoc """
  TRD-006b / TRD-006b-TEST (TRD-2026-72f477ca, PRD AC-011-1): the whole
  epic-execution chain, driven end to end against the TRD-006a fixture
  (`ForemanServer.TestSupport.BeadsTreeFixture`: a real `br` database holding an
  epic and two tasks, one depending on the other):

      issues.jsonl line (as `br` exported it)
        -> BeadsWatcher.process_line/2          (label gate, trd_path gate, task.create + task.approve)
        -> real CommandGateway / Dispatcher     (TaskApproved -> TaskDispatched -> run admission)
        -> real RunExecutor + Overwatch         (worktree, the rendered `command:` phase)
        -> stand-in agent                       (the only fake: see below)
        -> JobsiteObserver -> RunExecutor.verify_run_outcome/2 -> Workflow.BeadsTreeCompletion
        -> RunCompleted | RunFailed, and the epic bead closed | blocked

  `br` itself is real: `BrRunnerMock` is stubbed to delegate every call to
  `SystemBrRunner`, so claim, the tree reads of `BeadsTreeCompletion`, and the
  closing/blocking of the epic all hit the fixture's SQLite database.

  ## What the stand-in agent is, and what it proves

  The worker adapter (`StandInAgent`) replaces the LLM agent. It receives the
  prompt the run rendered and, instead of reasoning, runs `br close` on the beads
  its scenario says it finishes. So this test PROVES the Foreman side: a tagged
  epic read from `br`'s own export is dispatched, the phase command names the
  epic with `--foreman`, and the run's outcome is decided by the state of the bead
  tree afterwards, never by the agent's clean exit (both scenarios end the agent's
  turn cleanly). It does NOT prove that the real `/skill:ensemble-beads-build`
  accepts `--foreman`, reads this tree, or closes its beads; nor that an LLM
  follows the command. See docs/user-guide.md ("Epic execution with
  ensemble-beads-build") and the live-run finding on foreman-2e5m.
  """

  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.TaskProvider.Registry, as: TaskProviderRegistry

  alias ForemanServer.TaskProviders.{
    BeadsAdapter,
    BeadsWatcher,
    BrRunnerMock,
    JsonSchemaCache,
    SystemBrRunner
  }

  alias ForemanServer.TestSupport.{BeadsTreeFixture, Eventually, RunSlotsReset}
  alias ForemanServer.TestSupport.ProjectionStoreReset
  alias ForemanServer.Workflow.{AssetCatalog, Catalog}

  @moduletag :tmp_dir
  @moduletag timeout: 120_000
  @terminal_timeout_ms 60_000

  defmodule StandInAgent do
    @moduledoc false
    # Overwatch worker (same protocol as JidoHarnessWorker): handshake, run the
    # phase, report `{:worker_result, {:ok, _}}` - a CLEAN finish - and stop.
    use GenServer

    alias ForemanServer.Overwatch.WorkerProtocol
    alias ForemanServer.TestSupport.BeadsTreeFixture

    def configure(config), do: :persistent_term.put({__MODULE__, :config}, config)
    def clear, do: :persistent_term.erase({__MODULE__, :config})

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
      %{test_pid: test_pid, fixture: fixture, closes: closes} =
        :persistent_term.get({__MODULE__, :config})

      send(test_pid, {:stand_in_prompt, Keyword.fetch!(state, :prompt)})
      :ok = BeadsTreeFixture.close!(fixture, closes)

      _ =
        WorkerProtocol.emit(:worker_exited, %{
          worker_id: Keyword.fetch!(state, :worker_id),
          run_id: Keyword.fetch!(state, :run_id)
        })

      case Keyword.get(state, :result_recipient) do
        pid when is_pid(pid) -> send(pid, {:worker_result, {:ok, "stand-in agent finished"}})
        _ -> :ok
      end

      {:stop, :normal, state}
    end

    def handle_info(_msg, state), do: {:noreply, state}
  end

  setup_all do
    unless BeadsTreeFixture.br_available?(),
      do: raise("the beads e2e test needs a `br` binary on the PATH")

    ensure_started(ForemanServer.Overwatch)
    :ok
  end

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{tmp_dir: tmp_dir} do
    ProjectionStoreReset.reset!()
    RunSlotsReset.reset!()

    # Every `br` call the server makes - claim, tree reads, closing/blocking the
    # epic, the schema fetches - runs against the fixture's real database.
    stub(BrRunnerMock, :cmd, &SystemBrRunner.cmd/3)

    previous_worker = Application.get_env(:foreman_server, :worker_adapter)
    Application.put_env(:foreman_server, :worker_adapter, StandInAgent)

    previous_provider = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(:foreman_server, :task_provider,
      actor: "foreman-runner",
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    stop_schema_cache()
    ForemanServer.TestSupport.TestApplication.reset_application_child!(TaskProviderRegistry)

    # The REAL Catalog over the bundled manifests (an empty root is filled from
    # `priv/defaults/workflows` on boot), isolated from the app-wide one, so the
    # workflow under test is the shipped `implement-trd-beads.yaml`.
    prev_server = Application.get_env(:foreman_server, :workflow_catalog)
    prev_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
    server_name = :"beads_e2e_catalog_#{System.unique_integer([:positive])}"
    Application.put_env(:foreman_server, :workflow_catalog, server_name)
    Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 60_000)

    start_supervised!(
      {Catalog,
       name: server_name,
       catalog: AssetCatalog.new(Path.join(tmp_dir, "workflows")),
       skills_target_dir: Path.join(tmp_dir, "skills")}
    )

    assert {:ok, "implement-trd-beads"} = Catalog.type_to_workflow("implement_trd_beads")

    # The schema cache the claim validates `br`'s answer against, filled from the
    # real `br schema` (the stub above delegates).
    start_supervised!(JsonSchemaCache)

    fixture = BeadsTreeFixture.build!(tmp_dir)
    project_id = "proj-beads-e2e-#{System.unique_integer([:positive])}"
    register_project!(project_id, fixture)

    on_exit(fn ->
      StandInAgent.clear()

      case previous_worker do
        nil -> Application.delete_env(:foreman_server, :worker_adapter)
        adapter -> Application.put_env(:foreman_server, :worker_adapter, adapter)
      end

      Application.put_env(:foreman_server, :task_provider, previous_provider)

      if prev_server,
        do: Application.put_env(:foreman_server, :workflow_catalog, prev_server),
        else: Application.delete_env(:foreman_server, :workflow_catalog)

      if prev_poll,
        do: Application.put_env(:foreman_server, :workflow_catalog_poll_ms, prev_poll),
        else: Application.delete_env(:foreman_server, :workflow_catalog_poll_ms)

      stop_schema_cache()
      ForemanServer.TestSupport.RunDrain.drain!()
      File.rm_rf(Path.join([System.user_home!(), ".foreman/worktrees", project_id]))
    end)

    watcher = %BeadsWatcher{
      project_id: project_id,
      database_path: fixture.database_path,
      jsonl_path: fixture.jsonl_path,
      poll_ms: 60_000
    }

    %{fixture: fixture, project_id: project_id, watcher: watcher}
  end

  test "the fixture is the tree the TRD describes: epic + two tasks, B blocked by A", %{
    fixture: fixture
  } do
    assert [task_a, task_b] = fixture.task_ids

    assert %{fixture.epic_id => "open", task_a => "open", task_b => "open"} ==
             BeadsTreeFixture.statuses!(fixture)

    line = BeadsTreeFixture.epic_line!(fixture) |> Jason.decode!()
    assert line["issue_type"] == "implement_trd_beads"
    assert line["labels"] == ["foreman-exec"]
  end

  for shape <- [:as_exported, :object] do
    test "AC-011-1: every bead of the tree closed -> the run completes with no manual step (agent_context #{shape})",
         ctx do
      %{fixture: fixture} = ctx
      StandInAgent.configure(%{test_pid: self(), fixture: fixture, closes: fixture.task_ids})

      {task_id, run_id} = dispatch_epic!(ctx, unquote(shape))

      assert_receive {:stand_in_prompt, prompt}, @terminal_timeout_ms
      assert prompt == "/skill:ensemble-beads-build #{fixture.epic_id} --foreman"

      assert %{status: "completed"} = await_terminal_run!(run_id)

      assert %{status: "closed"} =
               Eventually.await(
                 fn ->
                   case ProjectionStore.task_projection(task_id) do
                     %{status: "closed"} = task -> task
                     _ -> nil
                   end
                 end,
                 message: "task #{task_id} closed after the completed run"
               )

      statuses = BeadsTreeFixture.statuses!(fixture)
      assert Enum.all?(fixture.task_ids, &(statuses[&1] == "closed"))
      # The task provider, not the agent, closes the epic bead once the run completed.
      assert statuses[fixture.epic_id] == "closed"
    end
  end

  test "a tagged epic whose agent_context is not valid JSON is blocked for its missing trd_path",
       %{fixture: fixture, watcher: watcher} do
    line =
      fixture
      |> BeadsTreeFixture.epic_line!()
      |> Jason.decode!()
      |> Map.put("agent_context", "{\"trd_path\": ")
      |> Jason.encode!()

    assert :skipped = BeadsWatcher.process_line(watcher, line)
    assert BeadsTreeFixture.statuses!(fixture)[fixture.epic_id] == "blocked"
  end

  test "AC-008-1: a task left open fails the run although the agent finished cleanly", ctx do
    %{fixture: fixture} = ctx
    [task_a, task_b] = fixture.task_ids
    StandInAgent.configure(%{test_pid: self(), fixture: fixture, closes: [task_a]})

    {task_id, run_id} = dispatch_epic!(ctx)

    assert_receive {:stand_in_prompt, _prompt}, @terminal_timeout_ms

    assert %{status: "failed"} = await_terminal_run!(run_id)

    assert %{status: "failed"} =
             Eventually.await(
               fn ->
                 case ProjectionStore.task_projection(task_id) do
                   %{status: "failed"} = task -> task
                   _ -> nil
                 end
               end,
               message: "task #{task_id} failed after the run"
             )

    statuses = BeadsTreeFixture.statuses!(fixture)
    assert statuses[task_a] == "closed"
    assert statuses[task_b] != "closed"
    # The epic is handed back as blocked, never closed: its tree is not finished.
    assert statuses[fixture.epic_id] == "blocked"

    phase_reason = failed_phase_reason!(run_id)
    assert phase_reason =~ "incomplete_children"
    assert phase_reason =~ task_b
    refute phase_reason =~ task_a
  end

  # foreman-echpv. The provider's `fail` (the `br update <epic> --status blocked`) takes
  # the epic DB's `BeadsDbLease`; the Dispatcher's reaction to `RunFailed` releases that
  # run's lease. If `run.fail` is dispatched first, the two race and a release landing
  # after the provider's acquire strands it (`:lease_timeout`: epic never handed back,
  # task stuck `in_progress`). So the ordering is the contract: the provider's `fail`
  # completes BEFORE the run is failed. The blocked `br update` is held open here and
  # the run's event stream is read while it is: no `RunFailed` may exist yet. Nothing
  # is suspended: the real Dispatcher is live.
  test "echpv: the epic is handed back to the tracker before the run is failed", ctx do
    %{fixture: fixture} = ctx
    [task_a, _task_b] = fixture.task_ids
    StandInAgent.configure(%{test_pid: self(), fixture: fixture, closes: [task_a]})

    test_pid = self()
    gate = spawn(fn -> receive(do: (:open -> :ok)) end)

    stub(BrRunnerMock, :cmd, fn
      {:update, %{flags: flags}} = request, config, opts ->
        if "blocked" in flags do
          ref = Process.monitor(gate)
          send(test_pid, {:handing_back, self()})

          receive do
            {:DOWN, ^ref, :process, _pid, _reason} -> :ok
          end
        end

        SystemBrRunner.cmd(request, config, opts)

      request, config, opts ->
        SystemBrRunner.cmd(request, config, opts)
    end)

    {task_id, run_id} = dispatch_epic!(ctx)

    assert_receive {:handing_back, _executor}, @terminal_timeout_ms
    {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:" <> run_id)

    refute Enum.any?(events, &(&1.event_type == "RunFailed")),
           "the run was failed before the provider's fail ran"

    send(gate, :open)

    assert %{status: "failed"} = await_terminal_run!(run_id)

    assert %{status: "failed"} =
             Eventually.await(
               fn ->
                 case ProjectionStore.task_projection(task_id) do
                   %{status: "failed"} = task -> task
                   _ -> nil
                 end
               end,
               message: "task #{task_id} failed after the run"
             )

    assert BeadsTreeFixture.statuses!(fixture)[fixture.epic_id] == "blocked"
  end

  # --- driving the chain ---------------------------------------------------

  # Feeds the epic's own `br` export line to the real watcher and returns the
  # task id and the run id the real Dispatcher started for it.
  defp dispatch_epic!(
         %{fixture: fixture, watcher: watcher, project_id: project_id},
         shape \\ :as_exported
       ) do
    line = BeadsTreeFixture.epic_line!(fixture, agent_context: shape)
    assert :imported = BeadsWatcher.process_line(watcher, line)

    task_id = "beads:#{project_id}:#{fixture.epic_id}"

    run_id =
      Eventually.await(
        fn ->
          case ProjectionStore.task_projection(task_id) do
            %{run_id: run_id} when is_binary(run_id) and run_id != "" -> run_id
            _ -> nil
          end
        end,
        timeout: 30_000,
        message: "the Dispatcher starts a run for #{task_id}"
      )

    {task_id, run_id}
  end

  defp await_terminal_run!(run_id) do
    Eventually.await(
      fn ->
        case ProjectionStore.run(run_id) do
          %{status: status} = run when status in ["completed", "failed"] -> run
          _ -> nil
        end
      end,
      timeout: @terminal_timeout_ms,
      message: "run #{run_id} reaches a terminal status"
    )
  end

  defp failed_phase_reason!(run_id) do
    phase_id = ForemanServer.Identity.phase_id(run_id, 1)

    Eventually.await(
      fn ->
        case ProjectionStore.phase_projection(phase_id) do
          %{status: "failed"} = phase -> inspect(phase)
          _ -> nil
        end
      end,
      message: "phase #{phase_id} projected as failed"
    )
  end

  defp register_project!(project_id, fixture) do
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "project.register",
        command_id: "project.register:#{project_id}",
        aggregate_id: "project:#{project_id}",
        payload: %{
          project_id: project_id,
          path: fixture.project_root,
          name: "Beads e2e #{project_id}",
          task_provider: %{
            "provider" => "beads",
            "config" => %{"database_path" => fixture.database_path}
          }
        }
      })

    :ok =
      TaskProviderRegistry.register_for_project(project_id, BeadsAdapter, %{
        "database_path" => fixture.database_path
      })
  end

  defp stop_schema_cache do
    case Process.whereis(:foreman_server_json_schema_cache) do
      nil -> :ok
      pid -> GenServer.stop(pid)
    end
  end

  defp ensure_started(module) do
    if Process.whereis(module), do: :ok, else: start_supervised!(module) && :ok
  end
end
