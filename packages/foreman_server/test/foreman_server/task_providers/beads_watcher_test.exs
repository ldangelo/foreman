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

      case :persistent_term.get({__MODULE__, :sequence}, []) do
        [next | rest] ->
          :persistent_term.put({__MODULE__, :sequence}, rest)
          next

        [] ->
          :persistent_term.get({__MODULE__, :response}, {:ok, nil})
      end
    end

    def dispatch_system_approval(command, timeout), do: dispatch_system(command, timeout)
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

  # --- Cursor advance: terminal outcomes advance read_offset -----------

  describe "advance_one_line/2 with terminal outcomes" do
    setup do
      state = %BeadsWatcher{project_id: "proj-1", read_offset: 0, partial_line: ""}
      {:ok, state: state}
    end

    test "imported advances read_offset by line_bytes + 1", %{state: state} do
      FakeCommandGateway.stub_response({:ok, nil})
      line = ~s({"id":"bead-1","title":"hello","issue_type":"task","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported
      assert new_state.read_offset == byte_size(line) + 1
      assert new_state.partial_line == ""
    end

    test "skipped advances read_offset by line_bytes + 1", %{state: state} do
      line =
        ~s({"id":"bead-1","title":"foreman-owned","agent_context":{"foreman":{"task_id":"t1"}}})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :skipped
      assert new_state.read_offset == byte_size(line) + 1
    end

    test "reconciled advances read_offset by line_bytes + 1 when dedupe hits", %{state: state} do
      FakeProjectionStore.stub_external_id("bead-2", %{id: "task:beads:proj-1:bead-2"})
      line = ~s({"id":"bead-2","title":"already imported"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :reconciled
      assert new_state.read_offset == byte_size(line) + 1
      assert FakeCommandGateway.calls() == []
    end

    test "malformed advances read_offset by line_bytes + 1", %{state: state} do
      line = "{not json at all"

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :malformed
      assert new_state.read_offset == byte_size(line) + 1
      assert FakeCommandGateway.calls() == []
    end
  end

  # --- Cursor advance: transient hold preserves the read_offset --------

  describe "advance_one_line/2 with transient hold" do
    test "transient holds read_offset and stores the partial line" do
      FakeCommandGateway.stub_response({:error, :down})
      state = %BeadsWatcher{project_id: "proj-1", read_offset: 100, partial_line: ""}
      line = ~s({"id":"bead-3","title":"will retry","issue_type":"task","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :transient
      assert new_state.read_offset == 100
      assert new_state.partial_line == line
    end

    test "terminal_dispatch? {:error, {:already_exists, :task, _}} is :imported" do
      FakeCommandGateway.stub_response_sequence([
        {:error, {:already_exists, :task, "task:beads:proj-1:bead-4"}},
        {:ok, nil}
      ])

      state = %BeadsWatcher{project_id: "proj-1", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-4","title":"duplicate","issue_type":"task","status":"open"})

      {_new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported
    end

    test "{:exit, :killed} shape holds cursor (transient, not a crash)" do
      FakeCommandGateway.stub_response({:exit, :killed})
      state = %BeadsWatcher{project_id: "proj-1", read_offset: 250, partial_line: ""}
      line = ~s({"id":"bead-exit","title":"x","issue_type":"task","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :transient
      assert new_state.read_offset == 250
      assert new_state.partial_line == line
    end
  end

  describe "deterministic envelope" do
    test "command_id encodes project_id + bead_id (deterministic across retries)" do
      FakeCommandGateway.stub_response({:error, :down})
      state = %BeadsWatcher{project_id: "proj-det", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-det","title":"x","priority":1,"issue_type":"task","status":"open"})

      {state_after_1, _} = BeadsWatcher.advance_one_line(state, line)
      {state_after_2, _} = BeadsWatcher.advance_one_line(state_after_1, line)

      assert state_after_2.read_offset == state_after_1.read_offset,
             "transient retry MUST hold cursor at same offset"

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
      state = %BeadsWatcher{project_id: "proj-x", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-x","title":"x","issue_type":"task","status":"open"})

      BeadsWatcher.advance_one_line(state, line)

      [{_cmd, timeout}, _approve_call] = FakeCommandGateway.calls()
      assert is_integer(timeout) and timeout > 0
    end
  end

  # --- read_more: file-backed cursor mechanics -------------------------

  describe "read_more/1 file-backed cursor" do
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

    defp open_state(tmp, content) do
      path = Path.join(tmp, "issues.jsonl")
      File.write!(path, content)
      {:ok, handle} = :file.open(path, [:read, :binary, :raw])

      %BeadsWatcher{
        project_id: "proj-r",
        jsonl_path: path,
        database_path: Path.join(tmp, "beads.db"),
        file_handle: handle,
        read_offset: 0,
        partial_line: "",
        poll_ms: 1000
      }
    end

    test "processes all complete lines and leaves partial_line empty", %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      state =
        open_state(
          tmp,
          ~s({"id":"a","title":"a","issue_type":"task","status":"open"}\n{"id":"b","title":"b","issue_type":"task","status":"open"}\n)
        )

      {new_state, counters} = BeadsWatcher.read_more(state)

      assert new_state.read_offset ==
               byte_size(
                 ~s({"id":"a","title":"a","issue_type":"task","status":"open"}\n{"id":"b","title":"b","issue_type":"task","status":"open"}\n)
               )

      assert new_state.partial_line == ""
      assert counters.lines_processed == 2
      assert counters.lines_imported == 2
      assert counters.lines_suppressed == 0
    end

    test "preserves trailing fragment in partial_line when last line is unterminated", %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      body =
        ~s({"id":"a","title":"a","issue_type":"task","status":"open"}\n{"id":"b","title":"b-frag)

      state = open_state(tmp, body)
      {new_state, counters} = BeadsWatcher.read_more(state)

      assert new_state.partial_line == ~s({"id":"b","title":"b-frag)
      assert counters.lines_imported == 1
      assert counters.lines_processed == 1
    end

    test "subsequent read_more completes the fragment and dispatches the second bead", %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      body =
        ~s({"id":"a","title":"a","issue_type":"task","status":"open"}\n{"id":"b","title":"b-frag)

      state = open_state(tmp, body)

      {state, _} = BeadsWatcher.read_more(state)

      # Append the rest of line b + a terminator
      File.write!(state.jsonl_path, ~s(","issue_type":"task","status":"open"}\n), [:append])
      {state2, counters2} = BeadsWatcher.read_more(state)

      assert state2.partial_line == ""
      assert counters2.lines_imported == 1
      assert counters2.lines_processed == 1
      # Two beads imported across the two reads, each create+approve
      # pair producing two dispatch_system/2 calls.
      assert length(FakeCommandGateway.calls()) == 4
    end

    test "a transient line holds the retry cursor at its own start but does not block later lines in the same pass",
         %{tmp: tmp} do
      FakeCommandGateway.stub_response({:error, :down})

      body =
        ~s({"id":"transient","title":"t","issue_type":"task","status":"open"}\n{"id":"later","title":"l","issue_type":"task","status":"open"}\n)

      state = open_state(tmp, body)

      {state, counters} = BeadsWatcher.read_more(state)

      # Retry cursor holds at the FIRST transient line's start byte —
      # unchanged from before: a permanently-stuck bead's retry
      # position must still be exact so a fix to whatever is blocking
      # it (a workflow-catalog mapping, a transient dispatch failure)
      # is retried on the next poll. What changed: this no longer
      # halts the whole pass — "later" is still visited and dispatched
      # this same read (TRD-2026 follow-up: one permanently-unmapped
      # or transiently-failing early bead must not block every bead
      # appended after it forever).
      assert state.read_offset == 0

      assert state.partial_line ==
               ~s({"id":"transient","title":"t","issue_type":"task","status":"open"})

      # Both lines hit the same stubbed dispatch failure, so both are
      # independently transient this pass — proving "later" really was
      # attempted, not skipped.
      assert counters.lines_transient == 2
      assert counters.lines_processed == 2
      assert length(FakeCommandGateway.calls()) == 2
    end

    test "an unmapped early bead does not block a later bead whose type resolves to a real workflow",
         %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      FakeWorkflowCatalog.stub_response_for_type(
        "nonexistent_unmapped_type",
        {:error, :unmapped_type}
      )

      body =
        ~s({"id":"stuck","title":"s","issue_type":"nonexistent_unmapped_type","status":"open"}\n{"id":"routable","title":"r","issue_type":"task","status":"open"}\n)

      state = open_state(tmp, body)

      {state, counters} = BeadsWatcher.read_more(state)

      # "stuck" holds the retry cursor (its type never resolves to a
      # workflow), but "routable" — appended AFTER it — still gets
      # created and approved in the SAME pass. This is the exact
      # scenario that motivated the fix: a single unmapped-type open
      # bead anywhere in a project's history must not permanently
      # block every bead behind it.
      assert state.read_offset == 0

      assert state.partial_line ==
               ~s({"id":"stuck","title":"s","issue_type":"nonexistent_unmapped_type","status":"open"})

      assert counters.lines_transient == 1
      assert counters.lines_imported == 1
      assert counters.lines_processed == 2

      calls = FakeCommandGateway.calls()
      dispatched_ids = Enum.map(calls, fn {command, _timeout} -> command.aggregate_id end)
      assert Enum.any?(dispatched_ids, &String.contains?(&1, "routable"))
    end

    test "replay counter placement: [:watcher, :replay_completed] carries all four required counters",
         %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})

      body =
        ~s({"id":"a","title":"a","issue_type":"task","status":"open"}\n{"id":"b","title":"b","issue_type":"task","status":"open"}\n{"id":"c","title":"c","agent_context":{"foreman":{"task_id":"t"}}}\n)

      state = open_state(tmp, body)

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
      # JSONL lines exist by the time the watcher (re)starts and replays
      # from offset 0.
      body =
        ~s({"id":"bead-restart","title":"x","status":"draft"}\n) <>
          ~s({"id":"bead-restart","title":"x","issue_type":"task","status":"open"}\n)

      state = open_state(tmp, body)

      replayed = BeadsWatcher.boot_replay(state)

      assert replayed.read_offset == byte_size(body)
      assert replayed.partial_line == ""

      # draft line: status-gate skip, no dispatch. open line: not
      # deduped (the draft line never created a task) -> create+approve.
      [{create_cmd, _timeout}, {approve_cmd, _approve_timeout}] = FakeCommandGateway.calls()
      assert create_cmd.type == "task.create"
      assert create_cmd.payload.external_id == "bead-restart"
      assert approve_cmd.type == "task.approve"
      assert approve_cmd.aggregate_id == create_cmd.aggregate_id
    end

    test "boot_replay starts state at offset 0 with empty partial_line", %{tmp: tmp} do
      FakeCommandGateway.stub_response({:ok, nil})
      body = ~s({"id":"a","title":"a","issue_type":"task","status":"open"}\n)
      state = open_state(tmp, body)

      replayed = BeadsWatcher.boot_replay(state)

      assert replayed.read_offset == byte_size(body)
      assert replayed.partial_line == ""
    end

    test "boot_replay on empty file keeps read_offset at 0 with zero counters", %{tmp: tmp} do
      state = open_state(tmp, "")
      replayed = BeadsWatcher.boot_replay(state)

      assert replayed.read_offset == 0
      assert replayed.partial_line == ""
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

      state = %BeadsWatcher{project_id: "proj-r", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-r","title":"already-imported"})

      {_new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :reconciled
      assert FakeCommandGateway.calls() == []

      events = collected(table)
      assert [:foreman_server, :task_provider, :beads, :watcher, :reconciled] in events
    end

    test "task exists but status is still open retries approval directly, without a new task.create" do
      FakeProjectionStore.stub_external_id("bead-pending", %{
        id: "task:beads:proj-pending:bead-pending",
        status: "open"
      })

      FakeCommandGateway.stub_response({:ok, %{}})

      state = %BeadsWatcher{project_id: "proj-pending", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-pending","title":"stuck","issue_type":"task","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :imported
      assert new_state.read_offset == byte_size(line) + 1

      # Only the retried `task.approve` dispatches — no new `task.create`,
      # since the task already exists.
      assert [{cmd, _timeout}] = FakeCommandGateway.calls()
      assert cmd.type == "task.approve"
    end

    test "task exists but status is still open holds the cursor as transient when retried approval also fails" do
      FakeProjectionStore.stub_external_id("bead-stuck", %{
        id: "task:beads:proj-stuck:bead-stuck",
        status: "open"
      })

      FakeCommandGateway.stub_response({:error, :down})

      state = %BeadsWatcher{project_id: "proj-stuck", read_offset: 100, partial_line: ""}
      line = ~s({"id":"bead-stuck","title":"stuck","issue_type":"task","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :transient
      assert new_state.read_offset == 100
      assert new_state.partial_line == line

      assert [{cmd, _timeout}] = FakeCommandGateway.calls()
      assert cmd.type == "task.approve"
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

      state = %BeadsWatcher{project_id: "proj-s", read_offset: 0, partial_line: ""}
      line = ~s({"id":"bead-s","title":"x","agent_context":{"foreman":{"task_id":"t1"}}})

      {_new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :skipped
      assert FakeCommandGateway.calls() == []

      events = collected(table)
      assert [:foreman_server, :task_provider, :beads, :watcher, :skipped] in events
    end
  end

  # --- Malformed terminal advance --------------------------------------

  describe "malformed terminal advance" do
    test "non-JSON line returns :malformed and advances cursor (no infinite loop)" do
      table =
        attach_collector(
          "malformed",
          [:foreman_server, :task_provider, :beads, :watcher, :malformed]
        )

      state = %BeadsWatcher{project_id: "proj-m", read_offset: 0, partial_line: ""}
      line = "{not json"

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :malformed
      assert new_state.read_offset == byte_size(line) + 1
      assert FakeCommandGateway.calls() == []

      events = collected(table)
      assert [:foreman_server, :task_provider, :beads, :watcher, :malformed] in events
    end

    test "bead with no id field returns :malformed (terminal advance)" do
      state = %BeadsWatcher{project_id: "proj-n", read_offset: 0, partial_line: ""}
      line = ~s({"title":"no-id","issue_type":"task","status":"open"})

      {new_state, outcome} = BeadsWatcher.advance_one_line(state, line)

      assert outcome == :malformed
      assert new_state.read_offset == byte_size(line) + 1
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
