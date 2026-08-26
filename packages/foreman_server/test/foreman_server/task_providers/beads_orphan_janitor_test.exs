defmodule ForemanServer.TaskProviders.FakeJanitor.Projection do
  @moduledoc false
  def get_task(opts) do
    case Keyword.get(opts, :external_id) do
      nil -> nil
      bead_id -> lookup(bead_id)
    end
  end

  defp lookup(bead_id) do
    case :ets.lookup(:janitor_projection, bead_id) do
      [{^bead_id, value}] -> value
      [] -> nil
    end
  end
end

defmodule ForemanServer.TaskProviders.FakeJanitor.Adapter do
  @moduledoc false
  def complete(bead_id, %{transition_comment: tc}, _project_config) do
    send(self(), {:complete_called, bead_id, tc})
    {:ok, %{id: bead_id, status: "closed"}}
  end
end

defmodule ForemanServer.TaskProviders.FakeJanitor.FailingAdapter do
  @moduledoc false
  def complete(_bead_id, _payload, _project_config) do
    {:error, %{retryable?: true, message: "synthetic close failure"}}
  end
end

defmodule ForemanServer.TaskProviders.BeadsOrphanJanitorTest do
  use ExUnit.Case, async: false

  import Mox

  alias ForemanServer.TaskProviders.BeadsOrphanJanitor
  alias ForemanServer.TaskProviders.BrRunnerMock
  alias ForemanServer.TaskProviders.FakeJanitor, as: Fake

  @moduletag :tmp_dir

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    :ets.new(:janitor_projection, [:named_table, :public, :set])

    Application.put_env(:foreman_server, :projection_store_module, Fake.Projection)
    Application.put_env(:foreman_server, :beads_adapter_module, Fake.Adapter)

    on_exit(fn ->
      Application.delete_env(:foreman_server, :projection_store_module)
      Application.delete_env(:foreman_server, :beads_adapter_module)
      if :ets.info(:janitor_projection) != :undefined, do: :ets.delete(:janitor_projection)
    end)

    state = %BeadsOrphanJanitor{
      project_id: "test-project-#{System.unique_integer([:positive])}",
      database_path: Path.join(System.tmp_dir!(), "test-#{System.unique_integer([:positive])}"),
      jsonl_path:
        Path.join(System.tmp_dir!(), "janitor-test-#{System.unique_integer([:positive])}.jsonl"),
      grace_ms: 300_000,
      scan_interval_ms: 60_000
    }

    {:ok, %{state: state, now_ms: System.system_time(:millisecond)}}
  end

  describe "run_scan/2 — per-entry age gate (PRD REQ-023)" do
    test "untagged bead is skipped, never closed", %{state: state, now_ms: now_ms} do
      state = put_jsonl(state, [untagged_line("operator-1")])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_processed == 1
      assert counters.lines_untagged == 1
      assert counters.lines_tagged == 0
      assert counters.lines_closed == 0
      assert counters.lines_retained == 0
      refute_received {:complete_called, _, _}
    end

    test "foreman-tagged with young linked_at is retained (age_young)", %{
      state: state,
      now_ms: now_ms
    } do
      state = put_jsonl(state, [foreman_line("foreman-young", now_ms - 5_000)])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_processed == 1
      assert counters.lines_tagged == 1
      assert counters.lines_retained == 1
      assert counters.lines_age_young == 1
      assert counters.lines_closed == 0
      refute_received {:complete_called, _, _}
    end

    test "foreman-tagged with missing linked_at is retained (no_linked_at)", %{
      state: state,
      now_ms: now_ms
    } do
      state = put_jsonl(state, [foreman_line_no_linked_at("foreman-no-linked-at")])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_tagged == 1
      assert counters.lines_retained == 1
      assert counters.lines_no_linked_at == 1
      assert counters.lines_closed == 0
    end

    test "foreman-tagged with malformed linked_at is retained (no_linked_at)", %{
      state: state,
      now_ms: now_ms
    } do
      state = put_jsonl(state, [foreman_line_raw("foreman-malformed", "not-a-date")])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_retained == 1
      assert counters.lines_no_linked_at == 1
      assert counters.lines_closed == 0
    end

    test "foreman-tagged with old linked_at + no task closes with no-task reason", %{
      state: state,
      now_ms: now_ms
    } do
      bead_id = "foreman-orphan"
      state = put_jsonl(state, [foreman_line(bead_id, now_ms - 600_000)])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_tagged == 1
      assert counters.lines_closed == 1
      assert_received {:complete_called, ^bead_id, "foreman-orphan:no-task"}
    end

    test "foreman-tagged with terminal task closes with terminal-task reason", %{
      state: state,
      now_ms: now_ms
    } do
      bead_id = "foreman-terminal"
      :ets.insert(:janitor_projection, {bead_id, %{id: bead_id, status: "closed"}})
      state = put_jsonl(state, [foreman_line(bead_id, now_ms - 600_000)])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_tagged == 1
      assert counters.lines_closed == 1
      assert_received {:complete_called, ^bead_id, "foreman-orphan:terminal-task"}
    end

    test "foreman-tagged with active task is retained (active_task)", %{
      state: state,
      now_ms: now_ms
    } do
      bead_id = "foreman-active"
      :ets.insert(:janitor_projection, {bead_id, %{id: bead_id, status: "in_progress"}})
      state = put_jsonl(state, [foreman_line(bead_id, now_ms - 600_000)])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_tagged == 1
      assert counters.lines_retained == 1
      assert counters.lines_closed == 0
      refute_received {:complete_called, _, _}
    end

    test "foreman-tagged with failed task closes with terminal-task reason", %{
      state: state,
      now_ms: now_ms
    } do
      bead_id = "foreman-failed"
      :ets.insert(:janitor_projection, {bead_id, %{id: bead_id, status: "failed"}})
      state = put_jsonl(state, [foreman_line(bead_id, now_ms - 600_000)])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_closed == 1
      assert_received {:complete_called, ^bead_id, "foreman-orphan:terminal-task"}
    end

    test "non-foreman-tagged bead is NEVER touched across all status combos", %{
      state: state,
      now_ms: now_ms
    } do
      state =
        put_jsonl(state, [
          untagged_line("operator-1"),
          untagged_line("operator-2"),
          untagged_line("operator-3")
        ])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_processed == 3
      assert counters.lines_untagged == 3
      assert counters.lines_tagged == 0
      assert counters.lines_closed == 0
      refute_received {:complete_called, _, _}
    end

    test "malformed JSON line is counted, never closed", %{state: state, now_ms: now_ms} do
      state =
        put_jsonl(state, [
          "{not valid json",
          foreman_line("foreman-good", now_ms - 600_000)
        ])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_processed == 2
      assert counters.lines_malformed == 1
      assert counters.lines_tagged == 1
      assert counters.lines_closed == 1
    end

    test "end-to-end six-line fixture covers all paths", %{state: state, now_ms: now_ms} do
      :ets.insert(
        :janitor_projection,
        {"foreman-terminal", %{id: "foreman-terminal", status: "closed"}}
      )

      :ets.insert(
        :janitor_projection,
        {"foreman-active", %{id: "foreman-active", status: "in_progress"}}
      )

      state =
        put_jsonl(state, [
          untagged_line("operator-1"),
          foreman_line("foreman-young", now_ms - 5_000),
          foreman_line_no_linked_at("foreman-no-linked-at"),
          foreman_line("foreman-orphan", now_ms - 600_000),
          foreman_line("foreman-terminal", now_ms - 600_000),
          foreman_line("foreman-active", now_ms - 600_000)
        ])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_processed == 6
      assert counters.lines_untagged == 1
      assert counters.lines_tagged == 5
      assert counters.lines_retained == 3
      assert counters.lines_age_young == 1
      assert counters.lines_no_linked_at == 1
      assert counters.lines_closed == 2
      assert_received {:complete_called, "foreman-orphan", "foreman-orphan:no-task"}
      assert_received {:complete_called, "foreman-terminal", "foreman-orphan:terminal-task"}
    end
  end

  describe "get_counters/1 — CQRS read path (state.last_counters cache)" do
    setup :set_mox_global
    setup :verify_on_exit!

    setup %{state: state} do
      jsonl_path = state.database_path <> ".jsonl"
      File.write!(jsonl_path, "")
      on_exit(fn -> File.rm(jsonl_path) end)

      expect(BrRunnerMock, :cmd, fn {:where, %{database_path: db_path}}, _config, _opts ->
        {:ok, %{stdout: Jason.encode!(%{"jsonl_path" => db_path <> ".jsonl"})}}
      end)

      :ok
    end

    test "returns nil before any scan has completed", %{state: state} do
      {:ok, pid} =
        start_supervised(
          {BeadsOrphanJanitor,
           project_id: state.project_id,
           database_path: state.database_path,
           grace_ms: 60_000,
           scan_interval_ms: 60_000,
           name: :"janitor-counters-pre-#{state.project_id}"}
        )

      # grace_ms is 60s, so no scan has fired yet; last_counters is nil.
      assert BeadsOrphanJanitor.get_counters(pid) == nil
    end

    test "returns cached counters after state.last_counters is populated", %{
      state: state,
      now_ms: now_ms
    } do
      jsonl_path = state.database_path <> ".jsonl"
      File.write!(jsonl_path, foreman_line("foreman-young", now_ms - 5_000))

      {:ok, pid} =
        start_supervised(
          {BeadsOrphanJanitor,
           project_id: state.project_id,
           database_path: state.database_path,
           grace_ms: 60_000,
           scan_interval_ms: 60_000,
           name: :"janitor-counters-post-#{state.project_id}"}
        )

      # Inject the cache write directly to simulate handle_info(:scan, state)
      # having completed without waiting for grace_ms.
      :sys.replace_state(pid, fn s ->
        %{s | last_counters: BeadsOrphanJanitor.run_scan(s, now_ms: now_ms)}
      end)

      assert %BeadsOrphanJanitor.Counters{lines_processed: 1, lines_retained: 1} =
               BeadsOrphanJanitor.get_counters(pid)
    end

    test "counter cache is NOT recomputed on successive reads", %{state: state} do
      {:ok, pid} =
        start_supervised(
          {BeadsOrphanJanitor,
           project_id: state.project_id,
           database_path: state.database_path,
           grace_ms: 60_000,
           scan_interval_ms: 60_000,
           name: :"janitor-counters-cache-#{state.project_id}"}
        )

      # Three reads in a row; if get_counters/1 were to invoke run_scan/2,
      # line counts would tick. They must stay nil (no scan yet).
      Enum.each(1..3, fn _ ->
        assert BeadsOrphanJanitor.get_counters(pid) == nil
      end)

      assert :sys.get_state(pid).last_counters == nil
    end
  end

  describe "telemetry events" do
    test "closed event carries bead_id, project_id, transition_comment, elapsed_ms", %{
      state: state,
      now_ms: now_ms
    } do
      test_pid = self()
      handler_id = "janitor-closed-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:foreman_server, :task_provider, :beads, :orphan, :janitor, :closed],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:closed_event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      linked_at_ms = now_ms - 600_000

      state =
        put_jsonl(state, [
          foreman_line_raw(
            "foreman-telemetry-closed",
            DateTime.from_unix!(linked_at_ms, :millisecond) |> DateTime.to_iso8601()
          )
        ])

      _ = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert_received {:closed_event, metadata}
      assert metadata.bead_id == "foreman-telemetry-closed"
      assert metadata.project_id == state.project_id
      assert metadata.transition_comment == "foreman-orphan:no-task"
      assert is_integer(metadata.elapsed_ms)
      assert metadata.elapsed_ms >= 600_000
    end

    test "retained event carries bead_id and reason string", %{state: state, now_ms: now_ms} do
      test_pid = self()
      handler_id = "janitor-retained-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:foreman_server, :task_provider, :beads, :orphan, :janitor, :retained],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:retained_event, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # linked_at 5_000ms in the past; grace_ms is 300_000ms → must retain
      state = put_jsonl(state, [foreman_line("foreman-telemetry-retained", now_ms - 5_000)])

      _ = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert_received {:retained_event, metadata}
      assert metadata.bead_id == "foreman-telemetry-retained"
      assert metadata.reason == "age_young"
    end
  end

  describe "close failure path" do
    test "adapter error retains the bead, increments lines_retained", %{
      state: state,
      now_ms: now_ms
    } do
      Application.put_env(:foreman_server, :beads_adapter_module, Fake.FailingAdapter)
      on_exit(fn -> Application.put_env(:foreman_server, :beads_adapter_module, Fake.Adapter) end)

      state = put_jsonl(state, [foreman_line("foreman-fail", now_ms - 600_000)])

      counters = BeadsOrphanJanitor.run_scan(state, now_ms: now_ms)

      assert counters.lines_tagged == 1
      assert counters.lines_retained == 1
      assert counters.lines_closed == 0
    end
  end

  describe "init/1 — grace-window semantics (PRD AC-023-1)" do
    test "no scan fires before grace_ms elapses", %{state: state} do
      test_pid = self()
      handler_id = "janitor-scan-pre-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:foreman_server, :task_provider, :beads, :orphan, :janitor, :scan_started],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:scan_started, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      # The mocked `br where` resolves `jsonl_path` to `<database_path>.jsonl`.
      # Pre-writing an empty file ensures the eventual scan (after grace) reads
      # zero lines instead of emitting `[:jsonl_read_failed, ...]` telemetry.
      jsonl_path = state.database_path <> ".jsonl"
      File.write!(jsonl_path, "")

      expect(BrRunnerMock, :cmd, fn {:where, %{database_path: db_path}}, _config, _opts ->
        {:ok, %{stdout: Jason.encode!(%{"jsonl_path" => db_path <> ".jsonl"})}}
      end)

      {:ok, _pid} =
        start_supervised(
          {BeadsOrphanJanitor,
           project_id: state.project_id,
           database_path: state.database_path,
           grace_ms: 200,
           scan_interval_ms: 60_000,
           name: :"janitor-grace-pre-#{state.project_id}"}
        )

      # Sleep well below grace_ms (200ms) — no scan should have fired.
      Process.sleep(50)
      refute_received {:scan_started, _}
    end

    test "scan fires after grace_ms elapses", %{state: state} do
      test_pid = self()
      handler_id = "janitor-scan-post-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler_id,
        [:foreman_server, :task_provider, :beads, :orphan, :janitor, :scan_started],
        fn _event, _measurements, metadata, _config ->
          send(test_pid, {:scan_started, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      jsonl_path = state.database_path <> ".jsonl"
      File.write!(jsonl_path, "")

      expect(BrRunnerMock, :cmd, fn {:where, %{database_path: db_path}}, _config, _opts ->
        {:ok, %{stdout: Jason.encode!(%{"jsonl_path" => db_path <> ".jsonl"})}}
      end)

      {:ok, _pid} =
        start_supervised(
          {BeadsOrphanJanitor,
           project_id: state.project_id,
           database_path: state.database_path,
           grace_ms: 100,
           scan_interval_ms: 60_000,
           name: :"janitor-grace-post-#{state.project_id}"}
        )

      # Sleep well above grace_ms (100ms) so the deferred :scan has fired.
      Process.sleep(250)
      assert_received {:scan_started, _}
    end
  end

  # ---------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------

  defp put_jsonl(state, lines) do
    content = Enum.join(lines, "\n") <> "\n"
    File.write!(state.jsonl_path, content)
    state
  end

  defp untagged_line(id) do
    Jason.encode!(%{id: id, title: "operator-managed"})
  end

  # `foreman_line(id, linked_at_ms)` — emits a foreman-tagged bead whose
  # `linked_at` is the absolute wall-clock instant the bead was linked.
  # The age check is `now_ms - linked_at_ms`; pass a value within
  # `grace_ms` of `now_ms` for young, well past `grace_ms` for old.
  defp foreman_line(id, linked_at_ms) do
    linked_at_iso = DateTime.from_unix!(linked_at_ms, :millisecond) |> DateTime.to_iso8601()
    foreman_line_raw(id, linked_at_iso)
  end

  defp foreman_line_raw(id, linked_at) do
    Jason.encode!(%{
      id: id,
      title: "foreman-tagged",
      agent_context: %{
        foreman: %{
          task_id: "task-#{id}",
          command_id: "cmd-#{id}",
          origin: "foreman",
          linked_at: linked_at
        }
      }
    })
  end

  defp foreman_line_no_linked_at(id) do
    Jason.encode!(%{
      id: id,
      title: "foreman-tagged-no-linked-at",
      agent_context: %{
        foreman: %{
          task_id: "task-#{id}",
          command_id: "cmd-#{id}",
          origin: "foreman"
        }
      }
    })
  end
end
