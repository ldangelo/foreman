defmodule ForemanServer.TaskProviders.BeadsWatcherPipelineTest do
  @moduledoc """
  Pipeline-level tests for `BeadsWatcher.advance_one_line/2`.

  Verifies TRD-012 — per-line dispatch semantics:
    (1) foreman-tag → suppress + `[:watcher, :skipped]` carrying `bead_id`
    (2) ProjectionStore hit → no-op + `[:watcher, :reconciled]`
    (3) new operator bead → `dispatch_system/2` with the deterministic envelope
        (`command_id`, `aggregate_id`, `task_id`, `external_id`) + `[:watcher, :imported]`
    (4) Boundary invariant — `dispatch_operator/2` MUST NOT be invoked
    (5) Transient (`ProviderError{retryable?: true}`; `{:error, {:wrong_expected_version, _, _}}`;
        `{:exit, :killed}`) holds `read_offset`; retries reuse the same `command_id`
    (6) Terminal-imported (`{:ok, _}`; `{:error, {:already_exists, :task, _}}`)
        advances `read_offset` and returns `:imported`
    (7) Terminal-rejected (`{:error, {:invalid_task_status, _}}`;
        `{:error, {:project_archived, _}}`; `{:error, :project_id_required}`)
        advances `read_offset` but returns `:rejected` — no task was
        created, so this must never be counted as an import
  """
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProviders.BeadsWatcher
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.ProviderError

  setup :verify_on_exit!

  # --- Fake side-effect modules -----------------------------------------
  #
  # The fakes match the arities exposed by the real `ForemanServer.CommandGateway`
  # and `ForemanServer.ProjectionStore`. Both `dispatch_system/2` AND
  # `dispatch_operator/2` exist on the fake so the boundary invariant test
  # can assert that the watcher never reaches the operator path.

  defmodule FakeCommandGateway do
    @moduledoc false
    def reset do
      :persistent_term.put({__MODULE__, :calls}, [])
      :persistent_term.put({__MODULE__, :operator_calls}, [])
      :persistent_term.put({__MODULE__, :response}, {:ok, nil})
    end

    def calls, do: :persistent_term.get({__MODULE__, :calls}, [])
    def operator_calls, do: :persistent_term.get({__MODULE__, :operator_calls}, [])
    def stub_response(response), do: :persistent_term.put({__MODULE__, :response}, response)

    def dispatch_system(command, timeout) do
      prev = :persistent_term.get({__MODULE__, :calls}, [])
      :persistent_term.put({__MODULE__, :calls}, prev ++ [{command, timeout}])
      :persistent_term.get({__MODULE__, :response}, {:ok, nil})
    end

    def dispatch_operator(_command, _timeout) do
      prev = :persistent_term.get({__MODULE__, :operator_calls}, [])
      :persistent_term.put({__MODULE__, :operator_calls}, prev ++ [:invoked])
      {:error, :dispatch_operator_must_not_be_used_by_watcher}
    end
  end

  defmodule FakeProjectionStore do
    @moduledoc false
    def reset, do: :persistent_term.put({__MODULE__, :existing}, %{})

    def stub_external_id(bead_id, task_map),
      do:
        :persistent_term.put(
          {__MODULE__, :existing},
          Map.put(:persistent_term.get({__MODULE__, :existing}, %{}), bead_id, task_map)
        )

    def get_task(opts) do
      case opts do
        [external_id: bead_id] when is_binary(bead_id) ->
          Map.get(:persistent_term.get({__MODULE__, :existing}, %{}), bead_id)

        _ ->
          nil
      end
    end
  end

  defmodule FakeWorkflowCatalog do
    @moduledoc false
    def reset, do: :persistent_term.put({__MODULE__, :response}, {:ok, "generic"})
    def stub_response(response), do: :persistent_term.put({__MODULE__, :response}, response)

    def type_to_workflow(_issue_type) do
      :persistent_term.get({__MODULE__, :response}, {:ok, "generic"})
    end
  end

  setup do
    original_cg =
      Application.get_env(:foreman_server, :command_gateway_module, ForemanServer.CommandGateway)

    original_ps =
      Application.get_env(
        :foreman_server,
        :projection_store_module,
        ForemanServer.ProjectionStore
      )

    original_wc =
      Application.get_env(
        :foreman_server,
        :workflow_catalog_module,
        ForemanServer.Workflow.Catalog
      )

    Application.put_env(:foreman_server, :command_gateway_module, FakeCommandGateway)
    Application.put_env(:foreman_server, :projection_store_module, FakeProjectionStore)
    Application.put_env(:foreman_server, :workflow_catalog_module, FakeWorkflowCatalog)
    FakeCommandGateway.reset()
    FakeProjectionStore.reset()
    FakeWorkflowCatalog.reset()

    on_exit(fn ->
      Application.put_env(:foreman_server, :command_gateway_module, original_cg)
      Application.put_env(:foreman_server, :projection_store_module, original_ps)
      Application.put_env(:foreman_server, :workflow_catalog_module, original_wc)
      FakeCommandGateway.reset()
      FakeProjectionStore.reset()
      FakeWorkflowCatalog.reset()
    end)

    :ok
  end

  # --- (1) Foreman-tag suppression + telemetry bead_id -------------------

  describe "foreman-tag suppression telemetry" do
    test "[:watcher, :skipped] metadata carries the bead_id" do
      handler_id = unique_handler("skipped-pipe")
      ref = make_ref()

      :telemetry.attach(
        handler_id,
        [:foreman_server, :task_provider, :beads, :watcher, :skipped],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      on_exit(fn ->
        try do
          :telemetry.detach(handler_id)
        rescue
          _ -> :ok
        end
      end)

      state = %BeadsWatcher{project_id: "proj-skip-pipe", read_offset: 0, partial_line: ""}

      line =
        ~s({"id":"bead-skip-pipe","title":"x","agent_context":{"foreman":{"task_id":"t1"}}})

      {_new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :skipped
      assert FakeCommandGateway.calls() == []

      assert_receive {:telemetry, ^ref, metadata}, 200
      assert metadata[:bead_id] == "bead-skip-pipe"
      assert metadata[:project_id] == "proj-skip-pipe"
    end
  end

  # --- (2) Dedupe hit telemetry -----------------------------------------

  describe "dedupe hit telemetry" do
    test "[:watcher, :reconciled] metadata carries the bead_id" do
      handler_id = unique_handler("recon-pipe")
      ref = make_ref()

      :telemetry.attach(
        handler_id,
        [:foreman_server, :task_provider, :beads, :watcher, :reconciled],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      on_exit(fn ->
        try do
          :telemetry.detach(handler_id)
        rescue
          _ -> :ok
        end
      end)

      FakeProjectionStore.stub_external_id(
        "bead-recon-pipe",
        %{id: "task:beads:proj-recon-pipe:bead-recon-pipe"}
      )

      state = %BeadsWatcher{project_id: "proj-recon-pipe", read_offset: 0, partial_line: ""}

      line = ~s({"id":"bead-recon-pipe","title":"already-imported"})

      {_new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :reconciled
      assert FakeCommandGateway.calls() == []

      assert_receive {:telemetry, ^ref, metadata}, 200
      assert metadata[:bead_id] == "bead-recon-pipe"
      assert metadata[:project_id] == "proj-recon-pipe"
    end
  end

  # --- (3) Deterministic envelope for new operator beads ----------------

  describe "new operator bead dispatch envelope" do
    test "[:watcher, :imported] metadata carries the bead_id" do
      handler_id = unique_handler("imp-pipe")
      ref = make_ref()

      :telemetry.attach(
        handler_id,
        [:foreman_server, :task_provider, :beads, :watcher, :imported],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      on_exit(fn ->
        try do
          :telemetry.detach(handler_id)
        rescue
          _ -> :ok
        end
      end)

      state = %BeadsWatcher{project_id: "proj-imp-pipe", read_offset: 0, partial_line: ""}

      line =
        ~s({"id":"bead-imp-pipe","title":"hello","priority":2,"issue_type":"task","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported
      assert new_state.read_offset == byte_size(line) + 1

      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()

      assert cmd.command_id == "beads-cmd:proj-imp-pipe:bead-imp-pipe"
      assert cmd.aggregate_id == "task:beads:proj-imp-pipe:bead-imp-pipe"
      assert cmd.type == "task.create"
      assert cmd.payload.task_id == "beads:proj-imp-pipe:bead-imp-pipe"
      assert cmd.payload.external_id == "bead-imp-pipe"
      assert cmd.payload.project_id == "proj-imp-pipe"
      assert cmd.payload.priority == 2
      assert cmd.payload.task_type == "task"

      assert_receive {:telemetry, ^ref, metadata}, 200
      assert metadata[:bead_id] == "bead-imp-pipe"
      assert metadata[:project_id] == "proj-imp-pipe"
    end
  end

  # --- (4) Boundary invariant -------------------------------------------

  describe "boundary invariant" do
    test "watcher NEVER routes through dispatch_operator/2" do
      state = %BeadsWatcher{project_id: "proj-boundary", read_offset: 0, partial_line: ""}

      # Exercise every outcome that the pipeline can produce for an
      # operator-originated bead — terminal + transient + dedupe + skip
      # paths — and assert the operator path stays cold.
      foreman_line =
        ~s({"id":"bead-b1","title":"x","agent_context":{"foreman":{"task_id":"t"}}})

      recon_state =
        %BeadsWatcher{project_id: "proj-boundary", read_offset: 10, partial_line: ""}

      FakeProjectionStore.stub_external_id(
        "bead-b2",
        %{id: "task:beads:proj-boundary:bead-b2"}
      )

      imported_line = ~s({"id":"bead-b3","title":"new","status":"open"})

      FakeCommandGateway.stub_response({:ok, nil})
      {_, _} = BeadsWatcher.advance_one_line(state, foreman_line)

      {_, _} =
        BeadsWatcher.advance_one_line(
          recon_state,
          ~s({"id":"bead-b2","title":"r","status":"open"})
        )

      {_, _} = BeadsWatcher.advance_one_line(state, imported_line)

      FakeCommandGateway.stub_response({:error, {:invalid_task_status, "closed"}})

      {_, _} =
        BeadsWatcher.advance_one_line(state, ~s({"id":"bead-b4","title":"t","status":"open"}))

      FakeCommandGateway.stub_response({:error, :down})

      {_, _} =
        BeadsWatcher.advance_one_line(state, ~s({"id":"bead-b5","title":"t","status":"open"}))

      assert FakeCommandGateway.operator_calls() == [],
             "watcher MUST NOT route through dispatch_operator/2 — " <>
               "every system-originated dispatch must use dispatch_system/2"
    end
  end

  # --- (5) Transient classification -------------------------------------

  describe "transient classification" do
    test "ProviderError{retryable?: true} holds cursor and retries with same command_id" do
      err =
        ProviderError.new(
          "BR_TRANSIENT",
          "synthetic retryable failure",
          hint: "retry",
          retryable?: true,
          context: %{}
        )

      FakeCommandGateway.stub_response({:error, err})

      state = %BeadsWatcher{
        project_id: "proj-prov-err",
        read_offset: 42,
        partial_line: ""
      }

      line = ~s({"id":"bead-prov","title":"x","status":"open"})

      {state_after_1, outcome_1} = BeadsWatcher.advance_one_line(state, line)
      {state_after_2, outcome_2} = BeadsWatcher.advance_one_line(state_after_1, line)

      assert outcome_1 == :transient
      assert outcome_2 == :transient

      # Cursor MUST hold at the transient-line start offset (NOT advance).
      assert state_after_1.read_offset == 42
      assert state_after_2.read_offset == 42

      # Same command_id across retries — the retry uses the deterministic
      # envelope so the Actor's expected_stream_version logic doesn't
      # misfire.
      calls = FakeCommandGateway.calls()
      assert length(calls) == 2
      [{cmd1, _}, {cmd2, _}] = calls
      assert cmd1.command_id == cmd2.command_id
      assert cmd1.command_id == "beads-cmd:proj-prov-err:bead-prov"
    end

    test "{:error, {:wrong_expected_version, 5, 6}} holds cursor and retries with same command_id" do
      FakeCommandGateway.stub_response({:error, {:wrong_expected_version, 5, 6}})

      state = %BeadsWatcher{project_id: "proj-wver", read_offset: 100, partial_line: ""}

      line = ~s({"id":"bead-wver","title":"x","status":"open"})

      {state_after_1, outcome_1} = BeadsWatcher.advance_one_line(state, line)
      {state_after_2, outcome_2} = BeadsWatcher.advance_one_line(state_after_1, line)

      assert outcome_1 == :transient
      assert outcome_2 == :transient

      # Cursor MUST hold at the transient-line start offset (NOT advance).
      assert state_after_1.read_offset == 100
      assert state_after_2.read_offset == 100

      # Same command_id across retries — the retry reuses the deterministic
      # envelope so the Actor's expected_stream_version logic can re-decide.
      calls = FakeCommandGateway.calls()
      assert length(calls) == 2
      [{cmd1, _}, {cmd2, _}] = calls
      assert cmd1.command_id == cmd2.command_id
      assert cmd1.command_id == "beads-cmd:proj-wver:bead-wver"
    end

    test "{:exit, :killed} holds cursor and retries with same command_id" do
      FakeCommandGateway.stub_response({:exit, :killed})

      state = %BeadsWatcher{project_id: "proj-exit", read_offset: 7, partial_line: ""}

      line = ~s({"id":"bead-exit","title":"x","status":"open"})

      {state_after_1, _} = BeadsWatcher.advance_one_line(state, line)
      {state_after_2, _} = BeadsWatcher.advance_one_line(state_after_1, line)

      assert state_after_1.read_offset == 7
      assert state_after_2.read_offset == 7

      calls = FakeCommandGateway.calls()
      assert length(calls) == 2
      [{cmd1, _}, {cmd2, _}] = calls
      assert cmd1.command_id == cmd2.command_id
    end
  end

  # --- (6) Terminal classification --------------------------------------

  describe "terminal classification advances read_offset" do
    test "{:ok, _} advances read_offset" do
      FakeCommandGateway.stub_response({:ok, :imported_ok})

      state = %BeadsWatcher{project_id: "proj-tok", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-tok","title":"x","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported
      assert new_state.read_offset == byte_size(line) + 1
    end

    test "{:error, {:already_exists, :task, _}} advances read_offset" do
      FakeCommandGateway.stub_response(
        {:error, {:already_exists, :task, "task:beads:proj-ae:bead-ae"}}
      )

      state = %BeadsWatcher{project_id: "proj-ae", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-ae","title":"x","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported
      assert new_state.read_offset == byte_size(line) + 1
    end

    test "{:error, {:invalid_task_status, _}} is rejected, not imported, and advances read_offset" do
      FakeCommandGateway.stub_response({:error, {:invalid_task_status, "closed"}})

      state = %BeadsWatcher{project_id: "proj-its", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-its","title":"x","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :rejected
      assert new_state.read_offset == byte_size(line) + 1
    end

    test "{:error, {:project_archived, _}} is rejected, not imported, and advances read_offset" do
      FakeCommandGateway.stub_response({:error, {:project_archived, "archived since 2026-08-01"}})

      state = %BeadsWatcher{project_id: "proj-pa", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-pa","title":"x","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :rejected
      assert new_state.read_offset == byte_size(line) + 1
    end

    test "{:error, :project_id_required} is rejected, not imported, and advances read_offset" do
      FakeCommandGateway.stub_response({:error, :project_id_required})

      state = %BeadsWatcher{project_id: "proj-pir", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-pir","title":"x","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :rejected
      assert new_state.read_offset == byte_size(line) + 1
    end
  end

  # --- Status gate (TRD-004-TEST, AC-003-1, AC-003-3) --------------------

  describe "status gate rejects non-open status, accepts open directly" do
    test "draft status is rejected: no task created, no blocking entry recorded" do
      state = %BeadsWatcher{project_id: "proj-status", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-draft","title":"x","status":"draft"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :skipped
      assert new_state.read_offset == byte_size(line) + 1
      assert FakeCommandGateway.calls() == []
    end

    test "blocked status is rejected: no task created" do
      state = %BeadsWatcher{project_id: "proj-status", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-blocked","title":"x","status":"blocked"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :skipped
      assert new_state.read_offset == byte_size(line) + 1
      assert FakeCommandGateway.calls() == []
    end

    test "closed status is rejected: no task created" do
      state = %BeadsWatcher{project_id: "proj-status", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-closed","title":"x","status":"closed"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :skipped
      assert new_state.read_offset == byte_size(line) + 1
      assert FakeCommandGateway.calls() == []
    end

    test "open status is accepted directly, with no draft intermediate required" do
      state = %BeadsWatcher{project_id: "proj-status", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-direct-open","title":"x","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported
      assert new_state.read_offset == byte_size(line) + 1

      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()
      assert cmd.payload.external_id == "bead-direct-open"
    end
  end

  # --- Workflow selection (TRD-005-TEST, REQ-001) -------------------------

  describe "workflow selection holds transient on unmapped type" do
    test "unmapped issue_type holds transient, emits telemetry, and never dispatches" do
      FakeWorkflowCatalog.stub_response({:error, :unmapped_type})

      handler_id = unique_handler("unmapped")
      ref = make_ref()

      :telemetry.attach(
        handler_id,
        [
          :foreman_server,
          :task_provider,
          :beads,
          :watcher,
          :status_gate,
          :skipped,
          :unmapped_type
        ],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      on_exit(fn ->
        try do
          :telemetry.detach(handler_id)
        rescue
          _ -> :ok
        end
      end)

      state = %BeadsWatcher{project_id: "proj-unmapped", read_offset: 55, partial_line: ""}

      line =
        ~s({"id":"bead-unmapped","title":"x","status":"open","issue_type":"custom_research"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :transient
      assert new_state.read_offset == 55
      assert new_state.partial_line == line
      assert FakeCommandGateway.calls() == []

      assert_receive {:telemetry, ^ref, metadata}, 200
      assert metadata[:bead_id] == "bead-unmapped"
      assert metadata[:issue_type] == "custom_research"
    end

    test "mapped issue_type flows the resolved workflow_type into the task.create payload" do
      FakeWorkflowCatalog.stub_response({:ok, "foreman_implement_trd"})

      state = %BeadsWatcher{project_id: "proj-mapped", read_offset: 0, partial_line: ""}

      line =
        ~s({"id":"bead-mapped","title":"x","status":"open","issue_type":"implement_trd"})

      {_new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported
      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()
      assert cmd.payload.workflow_type == "foreman_implement_trd"
    end
  end

  # --- trd_path extraction and blocked transition (TRD-006-TEST) ---------

  describe "trd_path extraction and blocked transition (AC-007-1, AC-007-2)" do
    test "missing trd_path blocks the bead with the exact comment text and creates no task" do
      FakeWorkflowCatalog.stub_response({:ok, "implement-trd"})

      expect(BrRunnerMock, :cmd, fn request, _project_config, _opts ->
        assert {:update,
                %{
                  flags: [
                    "bead-missing-trd",
                    "--status",
                    "blocked",
                    "--transition-comment",
                    comment
                  ]
                }} = request

        assert comment ==
                 "Blocked: workflow requires trd_path in agent_context. Re-run: " <>
                   "br update bead-missing-trd --agent-context '{\"trd_path\":\"docs/TRD/...\"}' --status open"

        {:ok, %{stdout: "", stderr: "", exit_code: 0}}
      end)

      state = %BeadsWatcher{
        project_id: "proj-trd",
        database_path: "/tmp/proj-trd.db",
        read_offset: 0,
        partial_line: ""
      }

      line =
        ~s({"id":"bead-missing-trd","title":"x","status":"open","issue_type":"implement_trd"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :skipped
      assert new_state.read_offset == byte_size(line) + 1
      assert FakeCommandGateway.calls() == []
    end

    test "empty trd_path string is treated the same as missing" do
      FakeWorkflowCatalog.stub_response({:ok, "implement-trd-beads"})

      expect(BrRunnerMock, :cmd, fn _request, _project_config, _opts ->
        {:ok, %{stdout: "", stderr: "", exit_code: 0}}
      end)

      state = %BeadsWatcher{
        project_id: "proj-trd",
        database_path: "/tmp/proj-trd.db",
        read_offset: 0,
        partial_line: ""
      }

      line =
        ~s({"id":"bead-empty-trd","title":"x","status":"open","issue_type":"implement_trd_beads",) <>
          ~s("agent_context":{"trd_path":""}})

      {_new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :skipped
      assert FakeCommandGateway.calls() == []
    end

    test "present trd_path flows into the task.create payload with no CLI mutation" do
      FakeWorkflowCatalog.stub_response({:ok, "implement-trd"})

      state = %BeadsWatcher{project_id: "proj-trd", read_offset: 0, partial_line: ""}

      line =
        ~s({"id":"bead-with-trd","title":"x","status":"open","issue_type":"implement_trd",) <>
          ~s("agent_context":{"trd_path":"docs/TRD/TRD-123-example.md"}})

      {_new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported
      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()
      assert cmd.payload.trd_path == "docs/TRD/TRD-123-example.md"
    end

    test "workflow that does not require trd_path ignores agent_context entirely" do
      FakeWorkflowCatalog.stub_response({:ok, "generic"})

      state = %BeadsWatcher{project_id: "proj-trd", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-no-trd-needed","title":"x","status":"open"})

      {_new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported
      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()
      assert cmd.payload.trd_path == nil
    end
  end

  # --- Auto-approval (TRD-007-TEST, AC-003-2) -----------------------------

  describe "auto-approval on open transition" do
    test "bead transitioning to open results in a created-and-approved task with no separate operator action" do
      state = %BeadsWatcher{project_id: "proj-auto", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-auto","title":"x","status":"open"})

      {_new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported

      [{create_cmd, _timeout}, {approve_cmd, _approve_timeout}] = FakeCommandGateway.calls()

      assert create_cmd.type == "task.create"
      assert create_cmd.payload.task_id == "beads:proj-auto:bead-auto"

      assert approve_cmd.type == "task.approve"
      assert approve_cmd.aggregate_id == create_cmd.aggregate_id
      assert approve_cmd.payload.task_id == create_cmd.payload.task_id
      assert approve_cmd.command_id == create_cmd.command_id <> ":auto-approve"

      # Neither step is a separate operator action — both are trusted
      # system dispatches, so no operator path was ever exercised.
      assert FakeCommandGateway.operator_calls() == []
    end

    test "[:watcher, :dispatch_and_approve] telemetry carries the bead_id and task_id" do
      handler_id = unique_handler("auto-approve")
      ref = make_ref()

      :telemetry.attach(
        handler_id,
        [:foreman_server, :task_provider, :beads, :watcher, :dispatch_and_approve],
        fn _event, _measurements, metadata, _config ->
          send(self(), {:telemetry, ref, metadata})
        end,
        nil
      )

      on_exit(fn ->
        try do
          :telemetry.detach(handler_id)
        rescue
          _ -> :ok
        end
      end)

      state = %BeadsWatcher{project_id: "proj-auto-tel", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-auto-tel","title":"x","status":"open"})

      {_new_state, _outcome} = BeadsWatcher.advance_one_line(state, line)

      assert_receive {:telemetry, ^ref, metadata}, 200
      assert metadata[:bead_id] == "bead-auto-tel"
      assert metadata[:task_id] == "beads:proj-auto-tel:bead-auto-tel"
    end
  end

  # --- Helpers --------------------------------------------------------

  defp unique_handler(label) do
    "#{__MODULE__}.#{label}.#{System.unique_integer([:positive, :monotonic])}"
  end
end
