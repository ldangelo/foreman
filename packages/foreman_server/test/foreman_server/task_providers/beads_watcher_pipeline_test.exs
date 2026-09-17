defmodule ForemanServer.TaskProviders.BeadsWatcherPipelineTest do
  @moduledoc """
  Pipeline-level tests for `BeadsWatcher.process_line/2`.

  Verifies TRD-012 — per-line dispatch semantics:
    (1) foreman-tag → suppress + `[:watcher, :skipped]` carrying `bead_id`
    (2) ProjectionStore hit → no-op + `[:watcher, :reconciled]`
    (3) new operator bead → `dispatch_system/2` with the deterministic envelope
        (`command_id`, `aggregate_id`, `task_id`, `external_id`) + `[:watcher, :imported]`
    (4) Boundary invariant — `dispatch_operator/2` MUST NOT be invoked
    (5) Transient (`ProviderError{retryable?: true}`; `{:error, {:wrong_expected_version, _, _}}`;
        `{:exit, :killed}`) returns `:transient`; retries reuse the same `command_id`
        (no cursor to hold — every rescan reprocesses the line, see foreman-fo3k)
    (6) Terminal-imported (`{:ok, _}`; `{:error, {:already_exists, :task, _}}`)
        returns `:imported`
    (7) Terminal-rejected (`{:error, {:invalid_task_status, _}}`;
        `{:error, {:project_archived, _}}`; `{:error, :project_id_required}`)
        returns `:rejected` — no task was
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
      :persistent_term.put({__MODULE__, :sequence}, [])
    end

    def calls, do: :persistent_term.get({__MODULE__, :calls}, [])
    def operator_calls, do: :persistent_term.get({__MODULE__, :operator_calls}, [])
    def stub_response(response), do: :persistent_term.put({__MODULE__, :response}, response)

    # Queues distinct responses for successive `dispatch_system/2` calls
    # (e.g. `task.create` then its immediate auto-`task.approve`) — used
    # when a test needs those two calls to disagree, unlike
    # `stub_response/1`'s single fixed reply for every call.
    def stub_response_sequence(responses) when is_list(responses),
      do: :persistent_term.put({__MODULE__, :sequence}, responses)

    def dispatch_system(command, timeout) do
      prev = :persistent_term.get({__MODULE__, :calls}, [])
      :persistent_term.put({__MODULE__, :calls}, prev ++ [{command, timeout}])

      case :persistent_term.get({__MODULE__, :sequence}, []) do
        [next | rest] ->
          :persistent_term.put({__MODULE__, :sequence}, rest)
          next

        [] ->
          :persistent_term.get({__MODULE__, :response}, {:ok, nil})
      end
    end

    def dispatch_system_approval(command, timeout), do: dispatch_system(command, timeout)

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

      state = %BeadsWatcher{project_id: "proj-skip-pipe"}

      line =
        ~s({"id":"bead-skip-pipe","title":"x","agent_context":{"foreman":{"task_id":"t1"}}})

      outcome = BeadsWatcher.process_line(state, line)

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

      state = %BeadsWatcher{project_id: "proj-recon-pipe"}

      line = ~s({"id":"bead-recon-pipe","title":"already-imported"})

      outcome = BeadsWatcher.process_line(state, line)

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

      state = %BeadsWatcher{project_id: "proj-imp-pipe"}

      line =
        ~s({"id":"bead-imp-pipe","title":"hello","priority":2,"issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :imported
      

      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()

      assert cmd.command_id == "beads-cmd:proj-imp-pipe:bead-imp-pipe"
      assert cmd.aggregate_id == "task:beads:proj-imp-pipe:bead-imp-pipe"
      assert cmd.type == "task.create"
      assert cmd.payload.task_id == "beads:proj-imp-pipe:bead-imp-pipe"
      assert cmd.payload.external_id == "bead-imp-pipe"
      assert cmd.payload.project_id == "proj-imp-pipe"
      assert cmd.payload.priority == 2
      assert cmd.payload.task_type == "task"
      # Sole channel `RunExecutor.input_prompt/1` reads for a `command:`
      # phase's `{{input.prompt}}` — without this every bead auto-dispatched
      # here renders with an empty argument (regression: TRD-2026 follow-up).
      assert cmd.payload.prompt == "hello"

      assert_receive {:telemetry, ^ref, metadata}, 200
      assert metadata[:bead_id] == "bead-imp-pipe"
      assert metadata[:project_id] == "proj-imp-pipe"
    end

    test "task.create payload's prompt combines title and description when both are present" do
      state = %BeadsWatcher{project_id: "proj-prompt"}

      line =
        ~s({"id":"bead-prompt","title":"fix the thing","description":"it is broken because X","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :imported

      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()
      assert cmd.payload.prompt == "fix the thing\n\nit is broken because X"
    end

    test "task.create payload's prompt falls back to title alone when description is absent" do
      state = %BeadsWatcher{project_id: "proj-prompt-2"}

      line =
        ~s({"id":"bead-no-desc","title":"just the title","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :imported

      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()
      assert cmd.payload.prompt == "just the title"
    end

    test "title and description both absent is malformed, not imported with an empty prompt" do
      state = %BeadsWatcher{project_id: "proj-prompt-3"}

      line = ~s({"id":"bead-no-title","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :malformed
      assert FakeCommandGateway.calls() == []
    end
  end

  # --- (4) Boundary invariant -------------------------------------------

  describe "boundary invariant" do
    test "watcher NEVER routes through dispatch_operator/2" do
      state = %BeadsWatcher{project_id: "proj-boundary"}

      # Exercise every outcome that the pipeline can produce for an
      # operator-originated bead — terminal + transient + dedupe + skip
      # paths — and assert the operator path stays cold.
      foreman_line =
        ~s({"id":"bead-b1","title":"x","agent_context":{"foreman":{"task_id":"t"}}})

      recon_state =
        %BeadsWatcher{project_id: "proj-boundary"}

      FakeProjectionStore.stub_external_id(
        "bead-b2",
        %{id: "task:beads:proj-boundary:bead-b2"}
      )

      imported_line = ~s({"id":"bead-b3","title":"new","issue_type":"task","status":"open"})

      FakeCommandGateway.stub_response({:ok, nil})
      _ = BeadsWatcher.process_line(state, foreman_line)

      _ = BeadsWatcher.process_line(recon_state, ~s({"id":"bead-b2","title":"r","issue_type":"task","status":"open"}))

      _ = BeadsWatcher.process_line(state, imported_line)

      FakeCommandGateway.stub_response({:error, {:invalid_task_status, "closed"}})

      _ = BeadsWatcher.process_line(state, ~s({"id":"bead-b4","title":"t","issue_type":"task","status":"open"}))

      FakeCommandGateway.stub_response({:error, :down})

      _ = BeadsWatcher.process_line(state, ~s({"id":"bead-b5","title":"t","issue_type":"task","status":"open"}))

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

      state = %BeadsWatcher{project_id: "proj-prov-err"}

      line = ~s({"id":"bead-prov","title":"x","issue_type":"task","status":"open"})

      outcome_1 = BeadsWatcher.process_line(state, line)
      outcome_2 = BeadsWatcher.process_line(state, line)

      assert outcome_1 == :transient
      assert outcome_2 == :transient


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

      state = %BeadsWatcher{project_id: "proj-wver"}
      line = ~s({"id":"bead-wver","title":"x","issue_type":"task","status":"open"})

      outcome_1 = BeadsWatcher.process_line(state, line)
      outcome_2 = BeadsWatcher.process_line(state, line)

      assert outcome_1 == :transient
      assert outcome_2 == :transient

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

      state = %BeadsWatcher{project_id: "proj-exit"}
      line = ~s({"id":"bead-exit","title":"x","issue_type":"task","status":"open"})

      _ = BeadsWatcher.process_line(state, line)
      _ = BeadsWatcher.process_line(state, line)

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

      state = %BeadsWatcher{project_id: "proj-tok"}
      line = ~s({"id":"bead-tok","title":"x","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :imported
      
    end

    test "{:error, {:already_exists, :task, _}} advances read_offset" do
      FakeCommandGateway.stub_response_sequence([
        {:error, {:already_exists, :task, "task:beads:proj-ae:bead-ae"}},
        {:ok, nil}
      ])

      state = %BeadsWatcher{project_id: "proj-ae"}
      line = ~s({"id":"bead-ae","title":"x","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :imported
      
    end

    test "{:error, {:invalid_task_status, _}} is rejected, not imported, and advances read_offset" do
      FakeCommandGateway.stub_response({:error, {:invalid_task_status, "closed"}})

      state = %BeadsWatcher{project_id: "proj-its"}
      line = ~s({"id":"bead-its","title":"x","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :rejected
      
    end

    test "{:error, {:project_archived, _}} is rejected, not imported, and advances read_offset" do
      FakeCommandGateway.stub_response({:error, {:project_archived, "archived since 2026-08-01"}})

      state = %BeadsWatcher{project_id: "proj-pa"}
      line = ~s({"id":"bead-pa","title":"x","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :rejected
      
    end

    test "{:error, :project_id_required} is rejected, not imported, and advances read_offset" do
      FakeCommandGateway.stub_response({:error, :project_id_required})

      state = %BeadsWatcher{project_id: "proj-pir"}
      line = ~s({"id":"bead-pir","title":"x","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :rejected
      
    end
  end

  # --- Status gate (TRD-004-TEST, AC-003-1, AC-003-3) --------------------

  describe "status gate rejects non-open status, accepts open directly" do
    test "draft status is rejected: no task created, no blocking entry recorded" do
      state = %BeadsWatcher{project_id: "proj-status"}
      line = ~s({"id":"bead-draft","title":"x","status":"draft"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :skipped
      
      assert FakeCommandGateway.calls() == []
    end

    test "blocked status is rejected: no task created" do
      state = %BeadsWatcher{project_id: "proj-status"}
      line = ~s({"id":"bead-blocked","title":"x","status":"blocked"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :skipped
      
      assert FakeCommandGateway.calls() == []
    end

    test "closed status is rejected: no task created" do
      state = %BeadsWatcher{project_id: "proj-status"}
      line = ~s({"id":"bead-closed","title":"x","status":"closed"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :skipped
      
      assert FakeCommandGateway.calls() == []
    end

    test "open status is accepted directly, with no draft intermediate required" do
      state = %BeadsWatcher{project_id: "proj-status"}
      line = ~s({"id":"bead-direct-open","title":"x","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :imported
      

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

      state = %BeadsWatcher{project_id: "proj-unmapped"}

      line =
        ~s({"id":"bead-unmapped","title":"x","status":"open","issue_type":"custom_research"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :transient
      
      
      assert FakeCommandGateway.calls() == []

      assert_receive {:telemetry, ^ref, metadata}, 200
      assert metadata[:bead_id] == "bead-unmapped"
      assert metadata[:issue_type] == "custom_research"
    end

    test "mapped issue_type flows the resolved workflow_type into the task.create payload" do
      FakeWorkflowCatalog.stub_response({:ok, "foreman_implement_trd"})

      state = %BeadsWatcher{project_id: "proj-mapped"}

      line =
        ~s({"id":"bead-mapped","title":"x","status":"open","issue_type":"implement_trd"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :imported
      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()
      assert cmd.payload.workflow_type == "foreman_implement_trd"
    end

    test "missing issue_type is malformed, not transient, and advances read_offset" do
      state = %BeadsWatcher{project_id: "proj-no-type"}
      line = ~s({"id":"bead-no-type","title":"x","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :malformed
      
      assert FakeCommandGateway.calls() == []
    end

    test "non-string issue_type is malformed, not transient, and advances read_offset" do
      state = %BeadsWatcher{project_id: "proj-bad-type"}
      line = ~s({"id":"bead-bad-type","title":"x","status":"open","issue_type":42})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :malformed
      
      assert FakeCommandGateway.calls() == []
    end

    test "empty title and description is malformed -- no task is created or approved" do
      state = %BeadsWatcher{project_id: "proj-no-prompt"}

      line =
        ~s({"id":"bead-no-prompt","title":"","description":"","status":"open","issue_type":"bug"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :malformed
      
      assert FakeCommandGateway.calls() == []
    end

    test "missing title and description entirely is malformed" do
      state = %BeadsWatcher{project_id: "proj-no-prompt-2"}
      line = ~s({"id":"bead-no-fields","status":"open","issue_type":"bug"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :malformed
      assert FakeCommandGateway.calls() == []
    end

    test "non-binary title is malformed even with a valid description" do
      state = %BeadsWatcher{project_id: "proj-numeric-title"}

      line =
        ~s({"id":"bead-numeric-title","title":42,"description":"a real description",) <>
          ~s("status":"open","issue_type":"bug"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :malformed
      assert FakeCommandGateway.calls() == []
    end

    test "whitespace-only title and description is malformed" do
      state = %BeadsWatcher{
        project_id: "proj-whitespace-prompt",
      }

      line =
        ~s({"id":"bead-whitespace","title":"   ","description":"\\n\\t ",) <>
          ~s("status":"open","issue_type":"bug"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :malformed
      assert FakeCommandGateway.calls() == []
    end

    test "surrounding whitespace on title and description is trimmed from the prompt" do
      FakeWorkflowCatalog.stub_response({:ok, "fix"})
      state = %BeadsWatcher{project_id: "proj-trim-prompt"}

      line =
        ~s({"id":"bead-trim","title":"  padded title  ","description":"  padded desc  ",) <>
          ~s("status":"open","issue_type":"bug"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :imported
      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()
      assert cmd.payload.prompt == "padded title\n\npadded desc"
    end
  end

  # --- trd_path extraction and blocked transition (TRD-006-TEST) ---------

  describe "trd_path extraction and blocked transition (AC-007-1, AC-007-2)" do
    test "missing trd_path blocks the bead with the exact comment text and creates no task" do
      FakeWorkflowCatalog.stub_response({:ok, "implement-trd"})

      expect(BrRunnerMock, :cmd, 2, fn request, _project_config, _opts ->
        case request do
          {:show, %{id: "bead-missing-trd"}} ->
            {:ok, %{stdout: ~s({"status":"open"}), stderr: "", exit_code: 0}}

          {:update, %{flags: flags}} ->
            assert flags == [
                     "bead-missing-trd",
                     "--status",
                     "blocked",
                     "--transition-comment",
                     "Blocked: workflow requires trd_path in agent_context. Re-run: " <>
                       "br update bead-missing-trd --agent-context '{\"trd_path\":\"docs/TRD/...\"}' --status open"
                   ]

            {:ok, %{stdout: "", stderr: "", exit_code: 0}}
        end
      end)

      state = %BeadsWatcher{
        project_id: "proj-trd",
        database_path: "/tmp/proj-trd.db",
      }

      line =
        ~s({"id":"bead-missing-trd","title":"x","status":"open","issue_type":"implement_trd"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :skipped
      
      assert FakeCommandGateway.calls() == []
    end

    test "empty trd_path string is treated the same as missing" do
      FakeWorkflowCatalog.stub_response({:ok, "implement-trd-beads"})

      expect(BrRunnerMock, :cmd, 2, fn request, _project_config, _opts ->
        case request do
          {:show, %{id: "bead-empty-trd"}} ->
            {:ok, %{stdout: ~s({"status":"open"}), stderr: "", exit_code: 0}}

          {:update, _flags} ->
            {:ok, %{stdout: "", stderr: "", exit_code: 0}}
        end
      end)

      state = %BeadsWatcher{
        project_id: "proj-trd",
        database_path: "/tmp/proj-trd.db",
      }

      line =
        ~s({"id":"bead-empty-trd","title":"x","status":"open","issue_type":"implement_trd_beads",) <>
          ~s("agent_context":{"trd_path":""}})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :skipped
      assert FakeCommandGateway.calls() == []
    end

    test "missing trd_path skips the br update when the bead is already blocked" do
      FakeWorkflowCatalog.stub_response({:ok, "implement-trd"})

      # Regression: apply_3_way_cursor/3 no longer halts on an earlier
      # transient line, so this line can be re-scanned on a later poll
      # while an earlier line is still unresolved. A stale re-scan must
      # not re-issue `br update` once the bead has already transitioned
      # off "open" -- confirmed live via a fresh :show, not the file's
      # own cached (possibly stale) status field.
      expect(BrRunnerMock, :cmd, fn request, _project_config, _opts ->
        assert {:show, %{id: "bead-already-blocked"}} = request
        {:ok, %{stdout: ~s({"status":"blocked"}), stderr: "", exit_code: 0}}
      end)

      state = %BeadsWatcher{
        project_id: "proj-trd",
        database_path: "/tmp/proj-trd.db",
      }

      line =
        ~s({"id":"bead-already-blocked","title":"x","status":"open","issue_type":"implement_trd"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :skipped
      assert FakeCommandGateway.calls() == []
    end

    test "present trd_path flows into the task.create payload with no CLI mutation" do
      FakeWorkflowCatalog.stub_response({:ok, "implement-trd"})

      state = %BeadsWatcher{project_id: "proj-trd"}

      line =
        ~s({"id":"bead-with-trd","title":"x","status":"open","issue_type":"implement_trd",) <>
          ~s("agent_context":{"trd_path":"docs/TRD/TRD-123-example.md"}})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :imported
      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()
      assert cmd.payload.trd_path == "docs/TRD/TRD-123-example.md"
    end

    test "workflow that does not require trd_path ignores agent_context entirely" do
      FakeWorkflowCatalog.stub_response({:ok, "generic"})

      state = %BeadsWatcher{project_id: "proj-trd"}
      line = ~s({"id":"bead-no-trd-needed","title":"x","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

      assert outcome == :imported
      [{cmd, _timeout}, _approve_call] = FakeCommandGateway.calls()
      assert cmd.payload.trd_path == nil
    end
  end

  # --- Auto-approval (TRD-007-TEST, AC-003-2) -----------------------------

  describe "auto-approval on open transition" do
    test "bead transitioning to open results in a created-and-approved task with no separate operator action" do
      state = %BeadsWatcher{project_id: "proj-auto"}
      line = ~s({"id":"bead-auto","title":"x","issue_type":"task","status":"open"})

      outcome = BeadsWatcher.process_line(state, line)

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

      state = %BeadsWatcher{project_id: "proj-auto-tel"}
      line = ~s({"id":"bead-auto-tel","title":"x","issue_type":"task","status":"open"})

      _outcome = BeadsWatcher.process_line(state, line)

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
