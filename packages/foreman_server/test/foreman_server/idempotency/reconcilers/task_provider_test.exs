defmodule ForemanServer.Idempotency.Reconcilers.TaskProviderTest do
  @moduledoc """
  `Reconcilers.TaskProvider` (TRD-015): the task provider is the source of truth for
  whether a `claim`, `complete`, `fail` or `reopen` happened. The reconciler reads the
  issue with `provider.get/2` and answers `:done` for the status the call produces,
  `:not_done` for the one it starts from, and `:unknown` for everything else. The
  provider module and its config come from the key's `project_id` through
  `TaskProvider.Registry.project_config/1`.
  """

  use ExUnit.Case, async: false

  @moduletag :capture_log

  alias ForemanServer.Idempotency.{Effect, KeyStore, Reconciler}
  alias ForemanServer.Idempotency.Reconcilers.TaskProvider, as: TaskProviderEffect
  alias ForemanServer.TaskProvider.Registry
  alias ForemanServer.TestSupport.{FakeTaskProvider, KeyStoreReset, TestApplication}

  @issue "issue-1"

  setup do
    KeyStoreReset.reset!()

    previous = Application.get_env(:foreman_server, :task_provider, [])

    Application.put_env(
      :foreman_server,
      :task_provider,
      actor: nil,
      accepted_contract_versions: ["br.capabilities.v1"],
      providers: []
    )

    TestApplication.reset_application_child!(Registry)
    start_supervised!(FakeTaskProvider)

    on_exit(fn ->
      Application.put_env(:foreman_server, :task_provider, previous)
      KeyStoreReset.reset!()
    end)

    project_id = "project-tp-#{System.unique_integer([:positive])}"
    db = "/abs/task-provider/#{project_id}.db"
    :ok = Registry.register_for_project(project_id, FakeTaskProvider, %{"database_path" => db})

    {:ok, project_id: project_id, db: db}
  end

  # The metadata `Effect.run/4` stores for a task-provider call, as it reads back.
  defp metadata(project_id, op, extra \\ %{}) do
    Map.merge(
      %{
        "run_id" => "run-1",
        "effect_class" => "task_provider",
        "project_id" => project_id,
        "op" => op,
        "issue_id" => @issue
      },
      extra
    )
  end

  # {op, status before the call, status after it}
  @ops [
    {"claim", "open", "in_progress"},
    {"complete", "in_progress", "closed"},
    {"fail", "in_progress", "blocked"},
    {"reopen", "in_progress", "open"}
  ]

  describe "key/3 and intent/5" do
    test "the key names the run, the op and the issue" do
      assert TaskProviderEffect.key("run-1", :claim, @issue) ==
               "effect:task_provider:run-1:claim:#{@issue}"

      assert TaskProviderEffect.key("run-1", "reopen", @issue) ==
               "effect:task_provider:run-1:reopen:#{@issue}"

      refute TaskProviderEffect.key("run-1", :claim, @issue) ==
               TaskProviderEffect.key("run-1", :complete, @issue)
    end

    test "the intent carries run, project, op and issue, and an actor only when there is one" do
      assert TaskProviderEffect.intent("run-1", "p", :fail, @issue) ==
               %{run_id: "run-1", project_id: "p", op: "fail", issue_id: @issue}

      assert TaskProviderEffect.intent("run-1", "p", :claim, @issue, %{actor: "me"}) ==
               %{run_id: "run-1", project_id: "p", op: "claim", issue_id: @issue, actor: "me"}

      assert TaskProviderEffect.intent("run-1", "p", :claim, @issue, %{actor: nil}) ==
               %{run_id: "run-1", project_id: "p", op: "claim", issue_id: @issue}
    end

    test "a key written through run/6 reads back with run_id, project_id, op and issue_id",
         %{project_id: project_id} do
      key = TaskProviderEffect.key("run-1", :complete, @issue)

      assert :ok = TaskProviderEffect.run("run-1", project_id, :complete, @issue, fn -> :ok end)

      assert {:ok, %{status: :completed, metadata: stored}} = KeyStore.get(key)
      stored = Map.new(stored, fn {k, v} -> {to_string(k), v} end)

      assert %{
               "run_id" => "run-1",
               "project_id" => ^project_id,
               "op" => "complete",
               "issue_id" => @issue,
               "effect_class" => "task_provider"
             } = stored

      # Nothing about the provider module or its config is stored: it is resolved
      # from the project id when recovery needs it.
      refute Map.has_key?(stored, "provider_module")
      refute Map.has_key?(stored, "config")
    end
  end

  describe "reconcile/2: the three verdicts of each call" do
    for {op, from, to} <- @ops do
      test "#{op}: `#{to}` is :done, `#{from}` is :not_done, any other status is :unknown",
           %{project_id: project_id, db: db} do
        meta = metadata(project_id, unquote(op))

        FakeTaskProvider.put_issue(db, @issue, unquote(to))
        assert TaskProviderEffect.reconcile(meta) == :done

        FakeTaskProvider.put_issue(db, @issue, unquote(from))
        assert TaskProviderEffect.reconcile(meta) == :not_done

        for other <- ["blocked", "closed", "open", "in_progress", "deferred", "weird"],
            other not in [unquote(from), unquote(to)] do
          FakeTaskProvider.put_issue(db, @issue, other)

          assert TaskProviderEffect.reconcile(meta) == :unknown,
                 "#{unquote(op)} with the issue #{other} must be :unknown"
        end
      end
    end

    test "the verdict reaches the boot sweep through the configured registry",
         %{project_id: project_id, db: db} do
      FakeTaskProvider.put_issue(db, @issue, "closed")

      assert Reconciler.verdict("task_provider", metadata(project_id, "complete")) == :done
    end
  end

  describe "reconcile/2: a claim and its claimant" do
    test "in_progress for the claiming actor is :done", %{project_id: project_id, db: db} do
      FakeTaskProvider.put_issue(db, @issue, "in_progress", "runner-a")

      assert TaskProviderEffect.reconcile(metadata(project_id, "claim", %{"actor" => "runner-a"})) ==
               :done
    end

    test "in_progress for a different assignee is :unknown", %{project_id: project_id, db: db} do
      FakeTaskProvider.put_issue(db, @issue, "in_progress", "someone-else")

      assert TaskProviderEffect.reconcile(metadata(project_id, "claim", %{"actor" => "runner-a"})) ==
               :unknown
    end

    test "a provider that reports no assignee, or a claim with no actor, cannot contradict it",
         %{project_id: project_id, db: db} do
      FakeTaskProvider.put_issue(db, @issue, "in_progress", nil)

      assert TaskProviderEffect.reconcile(metadata(project_id, "claim", %{"actor" => "runner-a"})) ==
               :done

      FakeTaskProvider.put_issue(db, @issue, "in_progress", "anyone")
      assert TaskProviderEffect.reconcile(metadata(project_id, "claim")) == :done
    end
  end

  describe "reconcile/2: the answer cannot be established" do
    test "a provider that cannot be reached is :unknown, never :not_done",
         %{project_id: project_id, db: db} do
      FakeTaskProvider.put_issue(db, @issue, "open")

      for mode <- [
            {:error, FakeTaskProvider.error("br unreachable", true)},
            {:error, :econnrefused},
            :raise,
            :exit
          ] do
        FakeTaskProvider.get_mode(db, mode)

        for {op, _from, _to} <- @ops do
          assert TaskProviderEffect.reconcile(metadata(project_id, op)) == :unknown,
                 "#{op} with get/2 answering #{inspect(mode)} must be :unknown"
        end
      end
    end

    test "an issue the provider does not know is :unknown", %{project_id: project_id} do
      assert TaskProviderEffect.reconcile(metadata(project_id, "claim")) == :unknown
    end

    test "a provider that does not answer in time is :unknown", %{project_id: project_id, db: db} do
      FakeTaskProvider.put_issue(db, @issue, "open")
      FakeTaskProvider.get_mode(db, :hang)

      {micros, verdict} =
        :timer.tc(fn ->
          TaskProviderEffect.reconcile(metadata(project_id, "claim"), timeout_ms: 100)
        end)

      assert verdict == :unknown
      assert micros < 5_000_000
    end

    test "a project the registry cannot resolve is :unknown" do
      assert {:error, :task_provider_not_configured} = Registry.project_config("project-unknown")
      assert TaskProviderEffect.reconcile(metadata("project-unknown", "claim")) == :unknown
    end

    test "a project whose provider is unavailable is :unknown", %{project_id: project_id, db: db} do
      FakeTaskProvider.put_issue(db, @issue, "open")
      assert TaskProviderEffect.reconcile(metadata(project_id, "claim")) == :not_done

      :ok = Registry.unregister_for_project(project_id, :database_not_found)

      assert {:error, :provider_unavailable_for_project} = Registry.project_config(project_id)
      assert TaskProviderEffect.reconcile(metadata(project_id, "claim")) == :unknown
    end

    test "incomplete or malformed metadata is :unknown", %{project_id: project_id} do
      for broken <- [
            Map.delete(metadata(project_id, "claim"), "project_id"),
            Map.delete(metadata(project_id, "claim"), "issue_id"),
            Map.delete(metadata(project_id, "claim"), "op"),
            metadata(project_id, "annotate"),
            Map.put(metadata(project_id, "claim"), "issue_id", "")
          ] do
        assert TaskProviderEffect.reconcile(broken) == :unknown
      end
    end
  end

  describe "reconcile/2: the provider is resolved from project_id through the registry" do
    test "two projects with the same issue id get their own provider's answer",
         %{project_id: project_a, db: db_a} do
      project_b = "project-tp-b-#{System.unique_integer([:positive])}"
      db_b = "/abs/task-provider/#{project_b}.db"

      :ok =
        Registry.register_for_project(project_b, FakeTaskProvider, %{"database_path" => db_b})

      assert {:ok, %{config: %{"database_path" => ^db_a}, provider_module: FakeTaskProvider}} =
               Registry.project_config(project_a)

      FakeTaskProvider.put_issue(db_a, @issue, "open")
      FakeTaskProvider.put_issue(db_b, @issue, "in_progress", "x")

      assert TaskProviderEffect.reconcile(metadata(project_a, "claim")) == :not_done
      assert TaskProviderEffect.reconcile(metadata(project_b, "claim")) == :done
    end

    test "a provider module or config copied into the key is ignored", %{
      project_id: project_id,
      db: db
    } do
      FakeTaskProvider.put_issue(db, @issue, "open")

      forged =
        metadata(project_id, "claim", %{
          "provider_module" => "Elixir.DoesNotExist",
          "config" => %{"database_path" => "/abs/elsewhere.db"},
          "database_path" => "/abs/elsewhere.db"
        })

      assert TaskProviderEffect.reconcile(forged) == :not_done
    end

    test "the `task_provider` class is registered for the boot sweep" do
      assert Reconciler.classes()["task_provider"] == TaskProviderEffect
    end
  end

  describe "run/6 around the provider call" do
    test "the call's own result is returned and the key ends completed or failed",
         %{project_id: project_id} do
      assert {:ok, :issue} =
               TaskProviderEffect.run("run-1", project_id, :claim, @issue, fn -> {:ok, :issue} end)

      assert {:ok, :completed} = KeyStore.status(TaskProviderEffect.key("run-1", :claim, @issue))

      assert {:error, :nope} =
               TaskProviderEffect.run("run-1", project_id, :fail, @issue, fn ->
                 {:error, :nope}
               end)

      assert {:ok, :failed} = KeyStore.status(TaskProviderEffect.key("run-1", :fail, @issue))
    end

    test "an ambiguous key recovery marked unresolved refuses the call without running it",
         %{project_id: project_id} do
      key = TaskProviderEffect.key("run-1", :complete, @issue)

      :ok =
        KeyStore.mark_started(
          key,
          TaskProviderEffect.intent("run-1", project_id, :complete, @issue)
          |> Map.put(:effect_class, "task_provider")
        )

      :ok = KeyStore.mark_ambiguous(key, "orphaned_started_key")
      :ok = KeyStore.mark_unresolved(key, 3, "effect_already_done")

      test_pid = self()

      assert {:error, {:effect_unresolved, ^key}} =
               TaskProviderEffect.run("run-1", project_id, :complete, @issue, fn ->
                 send(test_pid, :provider_called)
                 {:ok, :closed}
               end)

      refute_received :provider_called
      assert {:ok, :ambiguous} = KeyStore.status(key)
      assert Effect.key(:task_provider, "run-1", "complete:#{@issue}") == key
    end
  end
end
