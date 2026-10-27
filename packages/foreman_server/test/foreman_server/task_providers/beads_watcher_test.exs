defmodule ForemanServer.TaskProviders.BeadsWatcherTest do
  use ExUnit.Case, async: false

  alias ForemanServer.TaskProviders.BeadsWatcher

  # --- Fake side-effect modules -----------------------------------------
  #
  # These fakes replace the real CommandGateway and ProjectionStore at
  # runtime via Application env. They record every call so tests can
  # assert on the deterministic envelopes and dedupe ordering without
  # booting the real GenServers. Only the explicit dispatch_system/2
  # and get_task/1 arities exist on the fakes — boundary drift at the
  # watcher would fail to compile, not silently misbehave.

  defmodule FakeCommandGateway do
    @moduledoc false
    def reset do
      :persistent_term.put({__MODULE__, :calls}, [])
      :persistent_term.put({__MODULE__, :sequence}, [])
    end

    def calls, do: :persistent_term.get({__MODULE__, :calls}, [])
    def stub_response(response), do: :persistent_term.put({__MODULE__, :response}, response)
    def stubbed_response, do: :persistent_term.get({__MODULE__, :response}, {:ok, nil})

    # Queues distinct responses for successive `dispatch_system/2` calls
    # (e.g. `task.create` then its immediate auto-`task.approve`) — used
    # when a test needs those two calls to disagree, unlike
    # `stub_response/1`'s single fixed reply for every call.
    def stub_response_sequence(responses) when is_list(responses),
      do: :persistent_term.put({__MODULE__, :sequence}, responses)

    def dispatch_system(command, timeout) do
      prev = :persistent_term.get({__MODULE__, :calls}, [])
      :persistent_term.put({__MODULE__, :calls}, prev ++ [{command, timeout}])

      result =
        case :persistent_term.get({__MODULE__, :sequence}, []) do
          [next | rest] ->
            :persistent_term.put({__MODULE__, :sequence}, rest)
            next

          [] ->
            :persistent_term.get({__MODULE__, :response}, {:ok, nil})
        end

      # Mirrors production's read model: a successful (or idempotent
      # already-exists) `task.create` makes the task visible to the NEXT
      # `ProjectionStore.get_task/1` dedupe check. Without this, these
      # fakes don't agree with each other the way the real
      # CommandGateway/ProjectionStore pair does, and a test asserting
      # idempotency across two `rescan/2` passes would be exercising an
      # impossible-in-production state (a "created" task the store has
      # never heard of).
      case {command.type, result} do
        {"task.create", {:ok, _}} ->
          ForemanServer.TaskProviders.BeadsWatcherTest.FakeProjectionStore.stub_external_id(
            command.payload.external_id,
            %{id: command.aggregate_id, status: "ready"}
          )

        {"task.create", {:error, {:already_exists, :task, _}}} ->
          ForemanServer.TaskProviders.BeadsWatcherTest.FakeProjectionStore.stub_external_id(
            command.payload.external_id,
            %{id: command.aggregate_id, status: "ready"}
          )

        _ ->
          :ok
      end

      result
    end

    def dispatch_system_approval(command, timeout), do: dispatch_system(command, timeout)
    def dispatch_system_retry(command, timeout), do: dispatch_system(command, timeout)
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
    def reset do
      :persistent_term.put({__MODULE__, :response}, {:ok, "generic"})
      :persistent_term.put({__MODULE__, :by_type}, %{})
    end

    def stub_response(response), do: :persistent_term.put({__MODULE__, :response}, response)

    # Per-`issue_type` override, checked before the blanket `stub_response/1`
    # reply — lets one test mix a type that resolves with one that doesn't.
    def stub_response_for_type(issue_type, response) do
      by_type = :persistent_term.get({__MODULE__, :by_type}, %{})
      :persistent_term.put({__MODULE__, :by_type}, Map.put(by_type, issue_type, response))
    end

    def type_to_workflow(issue_type) do
      by_type = :persistent_term.get({__MODULE__, :by_type}, %{})

      case Map.fetch(by_type, issue_type) do
        {:ok, response} -> response
        :error -> :persistent_term.get({__MODULE__, :response}, {:ok, "generic"})
      end
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
    FakeCommandGateway.stub_response({:ok, nil})
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

  # --- Pure split helper -----------------------------------------------

  describe "split_complete_lines/1" do
    test "returns trailing fragment when input has no terminator" do
      assert BeadsWatcher.split_complete_lines("no newline here") == {[], "no newline here"}
    end

    test "returns single complete line when input ends on \\n" do
      assert BeadsWatcher.split_complete_lines("a\n") == {["a"], ""}
    end

    test "splits multiple complete lines and preserves on-disk order" do
      assert BeadsWatcher.split_complete_lines("a\nb\nc\n") == {["a", "b", "c"], ""}
    end

    test "preserves trailing fragment when last line is unterminated" do
      assert BeadsWatcher.split_complete_lines("a\nb\nfrag") == {["a", "b"], "frag"}
    end

    test "handles empty input as zero complete lines and empty fragment" do
      assert BeadsWatcher.split_complete_lines("") == {[], ""}
    end

    test "treats every \\n as a separator (including consecutive newlines)" do
      assert BeadsWatcher.split_complete_lines("a\n\nb\n") == {["a", "", "b"], ""}
    end
  end

  # --- process_line/2: terminal and transient outcomes ------------------

  describe "process_line/2 outcomes" do
    setup do
      {:ok, state: %BeadsWatcher{project_id: "proj-1"}}
    end

    test "imported bead returns :imported", %{state: state} do
      FakeCommandGateway.stub_response({:ok, nil})

      line =
        ~s({"id":"bead-1","title":"hello","issue_type":"task","status":"open","labels":["foreman-exec"]})

      assert BeadsWatcher.process_line(state, line) == :imported
    end

    test "foreman-owned bead returns :skipped without dispatching", %{state: state} do
      line =
        ~s({"id":"bead-1","title":"foreman-owned","agent_context":{"foreman":{"task_id":"t1"}}})

      assert BeadsWatcher.process_line(state, line) == :skipped
      assert FakeCommandGateway.calls() == []
    end

    test "already-imported bead (dedupe hit) returns :reconciled", %{state: state} do
      FakeProjectionStore.stub_external_id("bead-2", %{id: "task:beads:proj-1:bead-2"})
      line = ~s({"id":"bead-2","title":"already imported"})

      assert BeadsWatcher.process_line(state, line) == :reconciled
      assert FakeCommandGateway.calls() == []
    end

    test "non-JSON line returns :malformed without dispatching", %{state: state} do
      line = "{not json at all"

      assert BeadsWatcher.process_line(state, line) == :malformed
      assert FakeCommandGateway.calls() == []
    end

    test "transient dispatch failure returns :transient", %{state: state} do
      FakeCommandGateway.stub_response({:error, :down})

      line =
        ~s({"id":"bead-3","title":"will retry","issue_type":"task","status":"open","labels":["foreman-exec"]})

      assert BeadsWatcher.process_line(state, line) == :transient
    end

    test "{:error, {:already_exists, :task, _}} on task.create is :imported (idempotent retry)",
         %{
           state: state
         } do
      FakeCommandGateway.stub_response_sequence([
        {:error, {:already_exists, :task, "task:beads:proj-1:bead-4"}},
        {:ok, nil}
      ])

      line =
        ~s({"id":"bead-4","title":"duplicate","issue_type":"task","status":"open","labels":["foreman-exec"]})

      assert BeadsWatcher.process_line(state, line) == :imported
    end

    test "{:exit, :killed} shape is :transient, not a crash", %{state: state} do
      FakeCommandGateway.stub_response({:exit, :killed})

      line =
        ~s({"id":"bead-exit","title":"x","issue_type":"task","status":"open","labels":["foreman-exec"]})

      assert BeadsWatcher.process_line(state, line) == :transient
    end
  end

  describe "deterministic envelope" do
    test "command_id encodes project_id + bead_id (deterministic across retries)" do
      FakeCommandGateway.stub_response({:error, :down})
      state = %BeadsWatcher{project_id: "proj-det"}

      line =
        ~s({"id":"bead-det","title":"x","priority":1,"issue_type":"task","status":"open","labels":["foreman-exec"]})

      BeadsWatcher.process_line(state, line)
      BeadsWatcher.process_line(state, line)

      calls = FakeCommandGateway.calls()
      assert length(calls) == 2
      assert {cmd1, _} = hd(calls)
      assert {cmd2, _} = Enum.at(calls, 1)
      assert cmd1.command_id == cmd2.command_id
      assert cmd1.command_id == "beads-cmd:proj-det:bead-det"
      assert cmd1.aggregate_id == "task:beads:proj-det:bead-det"
      assert cmd1.type == "task.create"
      assert cmd1.payload.task_id == "beads:proj-det:bead-det"
      assert cmd1.payload.external_id == "bead-det"
      assert cmd1.payload.project_id == "proj-det"
      assert cmd1.payload.priority == 1
      assert cmd1.payload.task_type == "task"
    end

    test "dispatches with explicit timeout argument (boundary drift guard)" do
      FakeCommandGateway.stub_response({:ok, nil})
      state = %BeadsWatcher{project_id: "proj-x"}

      line =
        ~s({"id":"bead-x","title":"x","issue_type":"task","status":"open","labels":["foreman-exec"]})

      BeadsWatcher.process_line(state, line)

      [{_cmd, timeout}, _approve_call] = FakeCommandGateway.calls()
      assert is_integer(timeout) and timeout > 0
    end
  end

  # --- rescan/2: stateless full-file rescan (foreman-fo3k) --------------
  #
  # Every trigger reads the CURRENT file fresh by path — no held file
  # descriptor, no byte-offset cursor. These tests exercise that
  # directly via real files on disk, including the regression case for
  # foreman-fo3k (the file being replaced out from under an open
  # descriptor must not stop new content from being seen).

  describe "rescan/2 stateless full-file read" do
    setup do
      tmp =
        Path.join(
          System.tmp_dir!(),
          "beads_watcher_test_#{System.unique_integer([:positive, :monotonic])}"
        )

      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf!(tmp) end)
      {:ok, tmp: tmp}
    end

    defp state_for(tmp, content) do
      path = Path.join(tmp, "issues.jsonl")
      File.write!(path, content)

      %BeadsWatcher{
        project_id: "proj-r",
        jsonl_path: path,
        database_path: Path.join(tmp, "beads.db"),
        poll_ms: 1000
      }
    end

    test "processes every complete line", %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      state =
        state_for(
          tmp,
          ~s({"id":"a","title":"a","issue_type":"task","status":"open","labels":["foreman-exec"]}\n{"id":"b","title":"b","issue_type":"task","status":"open","labels":["foreman-exec"]}\n)
        )

      {_state, counters} = BeadsWatcher.rescan(state)

      assert counters.lines_processed == 2
      assert counters.lines_imported == 2
      assert counters.lines_suppressed == 0
    end

    test "ignores an unterminated trailing fragment for this pass", %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      body =
        ~s({"id":"a","title":"a","issue_type":"task","status":"open","labels":["foreman-exec"]}\n{"id":"b","title":"b-frag)

      state = state_for(tmp, body)
      {_state, counters} = BeadsWatcher.rescan(state)

      assert counters.lines_imported == 1
      assert counters.lines_processed == 1
    end

    test "a later rescan sees a completed fragment once the file is finished", %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      body =
        ~s({"id":"a","title":"a","issue_type":"task","status":"open","labels":["foreman-exec"]}\n{"id":"b","title":"b-frag)

      state = state_for(tmp, body)
      BeadsWatcher.rescan(state)

      File.write!(
        state.jsonl_path,
        ~s(","issue_type":"task","status":"open","labels":["foreman-exec"]}\n),
        [:append]
      )

      {_state, counters2} = BeadsWatcher.rescan(state)

      # Full rescan reprocesses everything: "a" is now deduped
      # (:reconciled, it already has a task from the first rescan) and
      # "b" is newly complete (:imported) — two lines processed, one
      # newly imported.
      assert counters2.lines_processed == 2
      assert counters2.lines_imported == 1
      # Two beads imported across the two reads, each create+approve
      # pair producing two dispatch_system/2 calls.
      assert length(FakeCommandGateway.calls()) == 4
    end

    test "regression (foreman-fo3k): a full file replacement (inode rotation) is still seen", %{
      tmp: tmp
    } do
      FakeCommandGateway.stub_response({:ok, nil})

      state =
        state_for(
          tmp,
          ~s({"id":"a","title":"a","issue_type":"task","status":"open","labels":["foreman-exec"]}\n)
        )

      {_state, counters1} = BeadsWatcher.rescan(state)
      assert counters1.lines_imported == 1

      # Simulate `br`'s atomic write-temp-then-rename export: write a
      # NEW file at a temp path and rename it over the original,
      # rotating the inode the old bug's persistent file handle would
      # have kept pointing at.
      tmp_path = state.jsonl_path <> ".tmp"

      File.write!(
        tmp_path,
        ~s({"id":"a","title":"a","issue_type":"task","status":"open","labels":["foreman-exec"]}\n) <>
          ~s({"id":"b","title":"b","issue_type":"task","status":"open","labels":["foreman-exec"]}\n)
      )

      File.rename!(tmp_path, state.jsonl_path)

      {_state, counters2} = BeadsWatcher.rescan(state)

      # "a" is deduped (already has a task from the first rescan);
      # "b" is new and gets imported. Both are still visible after the
      # rename — this is what the pre-fix design could never do again
      # after the first mutation.
      assert counters2.lines_processed == 2
      assert counters2.lines_imported == 1
    end

    test "an unmapped early bead does not block a later bead whose type resolves to a real workflow",
         %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      FakeWorkflowCatalog.stub_response_for_type(
        "nonexistent_unmapped_type",
        {:error, :unmapped_type}
      )

      body =
        ~s({"id":"stuck","title":"s","issue_type":"nonexistent_unmapped_type","status":"open","labels":["foreman-exec"]}\n{"id":"routable","title":"r","issue_type":"task","status":"open","labels":["foreman-exec"]}\n)

      state = state_for(tmp, body)

      {_state, counters} = BeadsWatcher.rescan(state)

      assert counters.lines_unmapped == 1
      assert counters.lines_transient == 0
      assert counters.lines_imported == 1
      assert counters.lines_processed == 2

      calls = FakeCommandGateway.calls()
      dispatched_ids = Enum.map(calls, fn {command, _timeout} -> command.aggregate_id end)
      assert Enum.any?(dispatched_ids, &String.contains?(&1, "routable"))
    end

    # TRD-008-TEST (REQ-002, AC-001-2): the replay counters separate a bead that is
    # inert until a manifest declares its type (`lines_unmapped`) from one whose
    # dispatch failed and is simply retried (`lines_transient`), so an operator
    # sizing the boot-replay storm can tell "waiting for a mapping" from "failing".
    test "boot replay counts an unmapped bead under lines_unmapped, never lines_transient",
         %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      FakeWorkflowCatalog.stub_response_for_type(
        "nonexistent_unmapped_type",
        {:error, :unmapped_type}
      )

      body =
        ~s({"id":"stuck","title":"s","issue_type":"nonexistent_unmapped_type","status":"open","labels":["foreman-exec"]}\n{"id":"routable","title":"r","issue_type":"task","status":"open","labels":["foreman-exec"]}\n)

      state = state_for(tmp, body)
      parent = self()
      handler_id = unique_handler("replay-unmapped")

      :telemetry.attach(
        handler_id,
        [:foreman_server, :task_provider, :beads, :watcher, :replay_completed],
        fn _event, _measurements, metadata, _config ->
          send(parent, {:replay_completed, metadata})
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

      BeadsWatcher.boot_replay(state)

      assert_receive {:replay_completed, metadata}, 500
      assert metadata.lines_unmapped == 1
      assert metadata.lines_transient == 0
      assert metadata.lines_imported == 1
      assert metadata.lines_processed == 2
    end

    test "replay counter placement: [:watcher, :replay_completed] carries all four required counters",
         %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      body =
        ~s({"id":"a","title":"a","issue_type":"task","status":"open","labels":["foreman-exec"]}\n{"id":"b","title":"b","issue_type":"task","status":"open","labels":["foreman-exec"]}\n{"id":"c","title":"c","agent_context":{"foreman":{"task_id":"t"}}}\n)

      state = state_for(tmp, body)

      table =
        attach_collector(
          "replay_completed",
          [:foreman_server, :task_provider, :beads, :watcher, :replay_completed]
        )

      BeadsWatcher.boot_replay(state)

      events = collected(table)

      assert [
               :foreman_server,
               :task_provider,
               :beads,
               :watcher,
               :replay_completed
             ] in events
    end

    test "boot replay imports and approves a bead that transitioned draft -> open while stopped",
         %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      # The bead was created while the watcher was offline (draft — no
      # dispatch), then transitioned to open — also while offline. Both
      # JSONL lines exist by the time the watcher (re)starts and replays.
      body =
        ~s({"id":"bead-restart","title":"x","status":"draft"}\n) <>
          ~s({"id":"bead-restart","title":"x","issue_type":"task","status":"open","labels":["foreman-exec"]}\n)

      state = state_for(tmp, body)

      BeadsWatcher.boot_replay(state)

      # draft line: status-gate skip, no dispatch. open line: not
      # deduped (the draft line never created a task) -> create+approve.
      [{create_cmd, _timeout}, {approve_cmd, _approve_timeout}] = FakeCommandGateway.calls()
      assert create_cmd.type == "task.create"
      assert create_cmd.payload.external_id == "bead-restart"
      assert approve_cmd.type == "task.approve"
      assert approve_cmd.aggregate_id == create_cmd.aggregate_id
    end

    test "boot_replay on empty file produces zero counters", %{tmp: tmp} do
      state = state_for(tmp, "")
      {_state, counters} = BeadsWatcher.rescan(state)
      assert counters.lines_processed == 0
    end
  end

  # --- Dedupe path: ProjectionStore hit produces :reconciled ----------

  describe "dedupe path (ProjectionStore.get_task/1 hit)" do
    test "reconciled outcome emits [:watcher, :reconciled] and skips dispatch" do
      FakeProjectionStore.stub_external_id("bead-r", %{id: "task:beads:proj-r:bead-r"})

      table =
        attach_collector(
          "reconciled",
          [:foreman_server, :task_provider, :beads, :watcher, :reconciled]
        )

      state = %BeadsWatcher{project_id: "proj-r"}
      line = ~s({"id":"bead-r","title":"already-imported"})

      assert BeadsWatcher.process_line(state, line) == :reconciled
      assert FakeCommandGateway.calls() == []

      events = collected(table)
      assert [:foreman_server, :task_provider, :beads, :watcher, :reconciled] in events
    end

    test "task exists but status is still open retries approval directly, without a new task.create" do
      FakeProjectionStore.stub_external_id("bead-pending", %{
        id: "task:beads:proj-pending:bead-pending",
        status: "open",
        retry_count: 0
      })

      FakeCommandGateway.stub_response({:ok, %{}})

      state = %BeadsWatcher{project_id: "proj-pending"}

      line =
        ~s({"id":"bead-pending","title":"stuck","issue_type":"task","status":"open","labels":["foreman-exec"]})

      assert BeadsWatcher.process_line(state, line) == :imported

      # Only the retried `task.approve` dispatches — no new `task.create`,
      # since the task already exists. A task no `task.retry` has reset keeps
      # the deterministic approval id its first approval would have had.
      assert [{cmd, _timeout}] = FakeCommandGateway.calls()
      assert cmd.type == "task.approve"
      assert cmd.command_id == "beads-cmd:proj-pending:bead-pending:auto-approve"
    end

    test "task exists but status is still open reports :transient when retried approval also fails" do
      FakeProjectionStore.stub_external_id("bead-stuck", %{
        id: "task:beads:proj-stuck:bead-stuck",
        status: "open",
        retry_count: 0
      })

      FakeCommandGateway.stub_response({:error, :down})

      state = %BeadsWatcher{project_id: "proj-stuck"}

      line =
        ~s({"id":"bead-stuck","title":"stuck","issue_type":"task","status":"open","labels":["foreman-exec"]})

      assert BeadsWatcher.process_line(state, line) == :transient

      assert [{cmd, _timeout}] = FakeCommandGateway.calls()
      assert cmd.type == "task.approve"
    end

    # foreman-nfizr: `task.retry` returns a task to `open` so it can be approved
    # again, and an approval's identity IS its command_id. Re-sending the
    # original id replays the failed run's approval and the task stays `open`.
    test "a task the operator retried is re-approved under an id scoped to its retry count" do
      state = %BeadsWatcher{project_id: "proj-retried"}

      line =
        ~s({"id":"bead-retried","title":"again","issue_type":"task","status":"open","labels":["foreman-exec"]})

      for retry_count <- 1..3 do
        FakeProjectionStore.stub_external_id("bead-retried", %{
          id: "task:beads:proj-retried:bead-retried",
          status: "open",
          retry_count: retry_count
        })

        assert BeadsWatcher.process_line(state, line) == :imported
      end

      first = "beads-cmd:proj-retried:bead-retried:auto-approve"

      assert [first <> ":retry-1", first <> ":retry-2", first <> ":retry-3"] ==
               for(
                 {%{type: "task.approve"} = cmd, _timeout} <- FakeCommandGateway.calls(),
                 do: cmd.command_id
               )
    end

    test "the same retry delivered twice is the same approval command" do
      FakeProjectionStore.stub_external_id("bead-twice", %{
        id: "task:beads:proj-twice:bead-twice",
        status: "open",
        retry_count: 2
      })

      state = %BeadsWatcher{project_id: "proj-twice"}

      line =
        ~s({"id":"bead-twice","title":"again","issue_type":"task","status":"open","labels":["foreman-exec"]})

      assert BeadsWatcher.process_line(state, line) == :imported
      assert BeadsWatcher.process_line(state, line) == :imported

      assert [{first, _}, {second, _}] = FakeCommandGateway.calls()
      assert first == second
    end

    # foreman-pfta.1: re-opening a bead whose run failed retries the task.
    # The reopen guard compares the bead's `updated_at` with the task's last event.
    @last_event_ms 1_800_000_000_000
    @after_event "2027-01-15T08:00:01Z"
    @before_event "2027-01-15T08:00:00Z"

    defp reopen_line(bead_id, updated_at) do
      Jason.encode!(%{
        "id" => bead_id,
        "title" => "again",
        "issue_type" => "task",
        "status" => "open",
        "labels" => ["foreman-exec"],
        "updated_at" => updated_at
      })
    end

    defp stub_task(bead_id, project, status, retry_count) do
      FakeProjectionStore.stub_external_id(bead_id, %{
        id: "task:beads:#{project}:#{bead_id}",
        status: status,
        retry_count: retry_count,
        last_event_at_ms: @last_event_ms
      })
    end

    test "a failed task whose bead is re-opened after the failure is retried, then re-approved fresh" do
      assert DateTime.to_unix(elem(DateTime.from_iso8601(@after_event), 1), :millisecond) ==
               @last_event_ms + 1_000

      stub_task("bead-reopen", "proj-reopen", "failed", 1)
      state = %BeadsWatcher{project_id: "proj-reopen"}

      assert BeadsWatcher.process_line(state, reopen_line("bead-reopen", @after_event)) ==
               :imported

      assert [{retry, _}, {approve, _}] = FakeCommandGateway.calls()
      assert retry.type == "task.retry"
      assert retry.aggregate_id == "task:beads:proj-reopen:bead-reopen"
      assert retry.command_id == "beads-cmd:proj-reopen:bead-reopen:retry-2"
      assert approve.type == "task.approve"
      assert approve.command_id == "beads-cmd:proj-reopen:bead-reopen:auto-approve:retry-2"
    end

    test "a bead line not newer than the failure is not a reopen (no hot loop)" do
      stub_task("bead-stale", "proj-stale", "failed", 0)
      state = %BeadsWatcher{project_id: "proj-stale"}

      for updated_at <- [@before_event, "2027-01-15T07:59:59.500Z", nil, "garbage"] do
        assert BeadsWatcher.process_line(state, reopen_line("bead-stale", updated_at)) ==
                 :reconciled
      end

      assert FakeCommandGateway.calls() == []
    end

    test "an active or finished task is never retried by a reopen" do
      for {status, n} <- [{"ready", 1}, {"in_progress", 2}, {"closed", 3}, {"merged", 4}] do
        bead = "bead-#{status}"
        stub_task(bead, "proj-active", status, 0)
        state = %BeadsWatcher{project_id: "proj-active"}

        assert BeadsWatcher.process_line(state, reopen_line(bead, @after_event)) == :reconciled,
               "#{status} (#{n})"
      end

      assert FakeCommandGateway.calls() == []
    end

    test "a bead that is not open is not a reopen" do
      stub_task("bead-closed-bead", "proj-cb", "failed", 0)
      state = %BeadsWatcher{project_id: "proj-cb"}

      line =
        Jason.encode!(%{
          "id" => "bead-closed-bead",
          "title" => "x",
          "issue_type" => "task",
          "status" => "closed",
          "labels" => ["foreman-exec"],
          "updated_at" => @after_event
        })

      assert BeadsWatcher.process_line(state, line) == :reconciled
      assert FakeCommandGateway.calls() == []
    end

    test "a failed retry is :transient and approves nothing" do
      stub_task("bead-retry-fails", "proj-rf", "failed", 0)
      FakeCommandGateway.stub_response({:error, {:run_not_terminal, "in_progress"}})
      state = %BeadsWatcher{project_id: "proj-rf"}

      assert BeadsWatcher.process_line(state, reopen_line("bead-retry-fails", @after_event)) ==
               :transient

      assert [{%{type: "task.retry"}, _}] = FakeCommandGateway.calls()
    end

    test "an open task whose projection carries no retry_count fails loudly instead of reconciling" do
      FakeProjectionStore.stub_external_id("bead-shapeless", %{
        id: "task:beads:proj-shapeless:bead-shapeless",
        status: "open"
      })

      state = %BeadsWatcher{project_id: "proj-shapeless"}

      line =
        ~s({"id":"bead-shapeless","title":"x","issue_type":"task","status":"open","labels":["foreman-exec"]})

      assert_raise KeyError, ~r/:retry_count/, fn -> BeadsWatcher.process_line(state, line) end
      assert FakeCommandGateway.calls() == []
    end
  end

  # --- Foreman-tag suppression (AC-022-3) ------------------------------

  describe "foreman-tag suppression" do
    test "bead with agent_context.foreman returns :skipped without dispatching" do
      table =
        attach_collector(
          "skipped",
          [:foreman_server, :task_provider, :beads, :watcher, :skipped]
        )

      state = %BeadsWatcher{project_id: "proj-s"}
      line = ~s({"id":"bead-s","title":"x","agent_context":{"foreman":{"task_id":"t1"}}})

      assert BeadsWatcher.process_line(state, line) == :skipped
      assert FakeCommandGateway.calls() == []

      events = collected(table)
      assert [:foreman_server, :task_provider, :beads, :watcher, :skipped] in events
    end
  end

  # --- Malformed terminal advance --------------------------------------

  describe "malformed terminal advance" do
    test "non-JSON line returns :malformed (no infinite loop possible: stateless)" do
      table =
        attach_collector(
          "malformed",
          [:foreman_server, :task_provider, :beads, :watcher, :malformed]
        )

      state = %BeadsWatcher{project_id: "proj-m"}
      line = "{not json"

      assert BeadsWatcher.process_line(state, line) == :malformed
      assert FakeCommandGateway.calls() == []

      events = collected(table)
      assert [:foreman_server, :task_provider, :beads, :watcher, :malformed] in events
    end

    test "bead with no id field returns :malformed" do
      state = %BeadsWatcher{project_id: "proj-n"}
      line = ~s({"title":"no-id","issue_type":"task","status":"open","labels":["foreman-exec"]})

      assert BeadsWatcher.process_line(state, line) == :malformed
      assert FakeCommandGateway.calls() == []
    end
  end

  # --- Helpers --------------------------------------------------------

  defp unique_handler(label) do
    "#{__MODULE__}.#{label}.#{System.unique_integer([:positive, :monotonic])}"
  end

  defp attach_collector(label, event_path) do
    handler_id = unique_handler(label)
    table = :ets.new(:bw_collector, [:public])
    :ets.insert(table, {:events, []})
    :telemetry.attach(handler_id, event_path, &__MODULE__.collect/4, table)

    on_exit(fn ->
      try do
        :telemetry.detach(handler_id)
      rescue
        _ -> :ok
      end
    end)

    table
  end

  defp collected(table), do: Keyword.get(:ets.lookup(table, :events), :events, [])

  @doc false
  def collect(event, _measurements, _metadata, config) do
    prev = Keyword.get(:ets.lookup(config, :events), :events, [])
    :ets.insert(config, {:events, [event | prev]})
  end
end
