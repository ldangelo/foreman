defmodule ForemanServer.Agents.OperatorQuestionDispatcherTest do
  @moduledoc """
  Tests for `ForemanServer.Agents.OperatorQuestionDispatcher` — the
  JSI-T007 dispatcher that hands operator signals off to
  `ForemanServer.Inbox.SharedInbox.ingest/2` (TRD-2026-4212be7e,
  JSI-T006 + JSI-T007).

  These tests use the Poller + DedupeTable that the application tree already
  runs (they are not started here), so the dispatcher is exercised end-to-end
  through to the inbox.
  """

  use ExUnit.Case, async: false

  alias ForemanServer.Agents.OperatorQuestionDispatcher
  alias ForemanServer.Agents.OperatorQuestionSource
  alias ForemanServer.Inbox.{DedupeTable, InboxItemStarted}
  alias ForemanServer.Agents.OperatorTimeout
  alias ForemanServer.Aggregates.OperatorQuestion
  alias ForemanServer.EventStore, as: Store
  alias ForemanServer.TestSupport.{Eventually, UniqueIds}
  alias ForemanServer.Workflow.{AssetCatalog, Catalog}
  alias ForemanServer.{Overview, ProjectionStore}

  # Meck helper — calls :meck.new/2 before :meck.expect so passthrough stubs
  # are established for all three modules before the test runs.
  defp meck_passthrough(module) do
    :meck.new(module, [:passthrough, :no_link])
  end

  defp meck_expect(module, fun, mock_fn) do
    :meck.expect(module, fun, mock_fn)
  end

  setup_all do
    {:ok, _} = Application.ensure_all_started(:jido_signal)
    {:ok, _} = Application.ensure_all_started(:meck)
    # DedupeTable, Poller and OperatorTimeout are in the application tree
    # (config/test.exs enables :operator_timeout); nothing to start here.
    :ok
  end

  # `SharedInbox` dedupes through one ETS table for the whole VM, and an entry lives for the
  # app-env `:inbox_dedupe_window_seconds` (300 s unset). Both are left behind by whichever test
  # ran before: a zero window (set by a test that does not restore it) expires every entry as it
  # is written, so the second `dispatch/1` of a question is `:started` instead of `:deduped`,
  # and an entry for a literal id such as "q-43" turns a first dispatch into `:deduped`. Every
  # test therefore starts from an empty cache and its own window.
  setup do
    DedupeTable.clear()
    previous_window = Application.get_env(:foreman_server, :inbox_dedupe_window_seconds)
    Application.put_env(:foreman_server, :inbox_dedupe_window_seconds, 60)
    on_exit(fn -> restore_env(:inbox_dedupe_window_seconds, previous_window) end)
    :ok
  end

  describe "dispatch/1 with a Jido.Signal" do
    test "calls SharedInbox.ingest/2 and returns {:ok, :started, _} for a new question" do
      signal =
        Jido.Signal.new!(%{
          id: "evt-op-1",
          source: "operator.ui",
          type: "com.foreman.operator.question",
          specversion: "1.0.2",
          data: %{
            "question_id" => "q-42",
            "question" => "what should I do?",
            "agent_id" => "agent-7"
          }
        })

      assert {:ok, :started, %InboxItemStarted{} = item} =
               OperatorQuestionDispatcher.dispatch(signal)

      assert item.correlation_id == "q-42"
      assert item.source == OperatorQuestionSource
    end

    test "returns {:ok, :deduped, _} for a repeated question" do
      signal =
        Jido.Signal.new!(%{
          id: "evt-op-2",
          source: "operator.ui",
          type: "com.foreman.operator.question",
          specversion: "1.0.2",
          data: %{
            "question_id" => "q-43",
            "question" => "another one",
            "agent_id" => "agent-8"
          }
        })

      assert {:ok, :started, _} = OperatorQuestionDispatcher.dispatch(signal)
      assert {:ok, :deduped, _} = OperatorQuestionDispatcher.dispatch(signal)
    end

    test "returns {:error, :no_correlation_id} for data without question_id or agent_id" do
      signal =
        Jido.Signal.new!(%{
          id: "evt-op-3",
          source: "operator.ui",
          type: "com.foreman.operator.question",
          specversion: "1.0.2",
          data: %{"foo" => "bar"}
        })

      assert {:error, :no_correlation_id} =
               OperatorQuestionDispatcher.dispatch(signal)
    end
  end

  describe "resolve_operator_timeout/1 — manifest-read path (TRD-027)" do
    setup do
      # Establish passthrough stubs so the real implementations remain callable
      # for any functions we don't explicitly mock (e.g. other ProjectionStore calls
      # in concurrently-running tests).
      meck_passthrough(ForemanServer.ProjectionStore)
      meck_passthrough(ForemanServer.Workflow.Catalog)
      meck_passthrough(ForemanServer.Agents.OperatorTimeout)

      # Mock ProjectionStore → returns a task whose workflow_snapshot names "implement"
      meck_expect(ForemanServer.ProjectionStore, :task_projection, fn "agent-manifest-123" ->
        %{workflow_snapshot: %{"workflow_name" => "implement"}}
      end)

      # Mock Catalog → returns a manifest declaring a 15-minute operator timeout
      meck_expect(ForemanServer.Workflow.Catalog, :load, fn "implement.yaml" ->
        {:ok, %{"name" => "implement", "operator_timeout_ms" => 900_000}}
      end)

      # Mock OperatorTimeout.schedule/3 → send captured timeout_ms to test process
      meck_expect(ForemanServer.Agents.OperatorTimeout, :schedule, fn
        question_id, agent_id, timeout_ms
        when question_id == "q-timeout-test" and agent_id == "agent-manifest-123" ->
          send(self(), {:captured_timeout_ms, timeout_ms})
          :ok
      end)

      on_exit(fn ->
        :meck.unload([
          ForemanServer.ProjectionStore,
          ForemanServer.Workflow.Catalog,
          ForemanServer.Agents.OperatorTimeout
        ])
      end)

      :ok
    end

    test "reads operator_timeout_ms from the workflow manifest and passes it to OperatorTimeout.schedule/3" do
      signal =
        Jido.Signal.new!(%{
          id: "evt-op-timeout",
          source: "operator.ui",
          type: "com.foreman.operator.question",
          specversion: "1.0.2",
          data: %{
            "question_id" => "q-timeout-test",
            "question" => "what should I do?",
            "agent_id" => "agent-manifest-123"
          }
        })

      assert {:ok, :started, _} = OperatorQuestionDispatcher.dispatch(signal)

      assert_receive {:captured_timeout_ms, 900_000},
                     1_000,
                     "OperatorTimeout.schedule/3 was not called with the manifest's operator_timeout_ms"
    end
  end

  # E8: a started question becomes first-class state (`question.open`): pending in the API and
  # the Overview, answerable, and expired from the timeout it was asked with.
  describe "dispatch/1 opens the question (question.open)" do
    setup do
      n = System.unique_integer([:positive])
      question_id = "q-open-#{n}"
      agent_id = "agent-open-#{n}"

      # dispatch/1 arms a real OperatorTimeout timer (five minutes by default): disarm it.
      on_exit(fn -> OperatorTimeout.cancel(question_id, agent_id) end)

      {:ok, n: n, question_id: question_id, agent_id: agent_id}
    end

    test "a question from an agent with no task opens under the global run, with the default timeout",
         %{question_id: question_id, agent_id: agent_id} do
      assert {:ok, :started, _item} =
               OperatorQuestionDispatcher.dispatch(
                 question_signal(question_id, agent_id, "which database should I use?")
               )

      assert [%{event_type: "QuestionOpened", data: data}] =
               question_events(OperatorQuestion.global_run(), question_id)

      assert %{
               run_id: "global",
               question_id: ^question_id,
               agent_id: ^agent_id,
               project_id: nil,
               text: "which database should I use?",
               timeout_ms: 300_000
             } = atomized(data)

      assert %{status: "open", text: "which database should I use?", timeout_ms: 300_000} =
               Eventually.await(fn -> ProjectionStore.question("global", question_id) end)
    end

    test "a question from an agent whose task has a run opens under that run and project, and its thread waits on the operator",
         %{n: n, question_id: question_id, agent_id: agent_id} do
      run_id = UniqueIds.unique_run_id("qopen")
      project_id = "p-qopen-#{n}"
      seed_task!(agent_id, project_id, run_id, %{})

      assert {:ok, :started, _item} =
               OperatorQuestionDispatcher.dispatch(
                 question_signal(question_id, agent_id, "may I rewrite the schema?")
               )

      assert [%{event_type: "QuestionOpened", data: data}] = question_events(run_id, question_id)

      assert %{
               run_id: ^run_id,
               question_id: ^question_id,
               agent_id: ^agent_id,
               project_id: ^project_id,
               text: "may I rewrite the schema?",
               timeout_ms: 300_000
             } = atomized(data)

      assert {:error, :stream_not_found} =
               Store.read_stream_forward(OperatorQuestion.stream_id("global", question_id), 0, 10)

      assert [%{question_id: ^question_id, run_id: ^run_id}] =
               Eventually.await(fn ->
                 case ProjectionStore.project_questions(project_id) do
                   [] -> nil
                   questions -> questions
                 end
               end)

      {:ok, overview} = Overview.build(project_id)
      expected_thread = "run:" <> run_id
      assert [%{thread_id: ^expected_thread, reason: :question}] = overview.groups.waiting_on_you
    end

    @tag :tmp_dir
    test "the workflow manifest's operator timeout is the timeout the question records",
         %{tmp_dir: tmp, n: n, question_id: question_id, agent_id: agent_id} do
      File.mkdir_p!(Path.join(tmp, "prompts"))

      File.write!(
        Path.join(tmp, "opq.yaml"),
        "name: opq\noperator_timeout_ms: 123456\nphases:\n  - name: p1\n    command: /skill:x\n"
      )

      use_isolated_catalog!(tmp, :"operator_question_catalog_#{n}")
      run_id = UniqueIds.unique_run_id("qtimeout")
      seed_task!(agent_id, "p-qtimeout-#{n}", run_id, %{"workflow_name" => "opq"})

      assert {:ok, :started, _item} =
               OperatorQuestionDispatcher.dispatch(
                 question_signal(question_id, agent_id, "how long may I wait?")
               )

      assert [%{event_type: "QuestionOpened", data: data}] = question_events(run_id, question_id)
      assert %{timeout_ms: 123_456} = atomized(data)

      assert %{timeout_ms: 123_456} =
               Eventually.await(fn -> ProjectionStore.question(run_id, question_id) end)
    end
  end

  defp question_signal(question_id, agent_id, text) do
    Jido.Signal.new!(%{
      id: "evt-" <> question_id,
      source: "operator.ui",
      type: "com.foreman.operator.question",
      specversion: "1.0.2",
      data: %{"question_id" => question_id, "question" => text, "agent_id" => agent_id}
    })
  end

  # The agent id the dispatcher is handed is the id of the task that is asking.
  defp seed_task!(task_id, project_id, run_id, workflow_snapshot) do
    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: task_id,
            project_id: project_id,
            title: "asks a question",
            status: "open",
            task_type: "task"
          }
        },
        %{
          event_type: "TaskApproved",
          payload: %{
            task_id: task_id,
            approval_id: "approval-" <> task_id,
            approved_by: "operator",
            approved_at: "2026-10-21T00:00:00Z",
            run_id: run_id,
            workflow_snapshot: workflow_snapshot
          }
        },
        %{
          event_type: "RunStarted",
          payload: %{run_id: run_id, task_id: task_id, project_id: project_id}
        }
      ])
  end

  defp use_isolated_catalog!(root, server_name) do
    previous_server = Application.get_env(:foreman_server, :workflow_catalog)
    previous_poll = Application.get_env(:foreman_server, :workflow_catalog_poll_ms)
    Application.put_env(:foreman_server, :workflow_catalog, server_name)
    Application.put_env(:foreman_server, :workflow_catalog_poll_ms, 600_000)

    on_exit(fn ->
      restore_env(:workflow_catalog, previous_server)
      restore_env(:workflow_catalog_poll_ms, previous_poll)
    end)

    start_supervised!({Catalog, name: server_name, catalog: AssetCatalog.new(root)},
      id: server_name
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:foreman_server, key)
  defp restore_env(key, value), do: Application.put_env(:foreman_server, key, value)

  defp question_events(run_id, question_id) do
    case Store.read_stream_forward(OperatorQuestion.stream_id(run_id, question_id), 0, 100) do
      {:ok, events} -> events
      {:error, _reason} = error -> error
    end
  end

  defp atomized(data) when is_struct(data), do: Map.from_struct(data)
  defp atomized(data), do: Map.new(data, fn {key, value} -> {to_atom_key(key), value} end)

  defp to_atom_key(key) when is_atom(key), do: key
  defp to_atom_key(key) when is_binary(key), do: String.to_existing_atom(key)

  describe "OperatorQuestionSource.correlation_id/1" do
    test "extracts question_id from the signal data" do
      assert "q-42" ==
               OperatorQuestionSource.correlation_id(%{
                 "question_id" => "q-42",
                 "agent_id" => "agent-7"
               })
    end

    test "falls back to agent_id when question_id is missing" do
      assert "agent-7" ==
               OperatorQuestionSource.correlation_id(%{
                 "agent_id" => "agent-7"
               })
    end

    test "returns nil for data without question_id or agent_id" do
      assert is_nil(OperatorQuestionSource.correlation_id(%{"foo" => "bar"}))
    end
  end
end
