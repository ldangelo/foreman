defmodule ForemanServer.Coordinator.ExecutorMemoryTuningTest do
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Action, Commands, Executor, Tuning}
  alias ForemanServer.{CommandGateway, ProjectionStore, ProjectMemory}

  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.CoordinatorHelpers.{FakeThreads, SpyGateway}

  setup %{tmp_dir: dir} do
    project_id = H.register_project(dir)
    SpyGateway.watch()
    FakeThreads.put([])
    on_exit(fn -> SpyGateway.unwatch() && FakeThreads.clear() end)
    {:ok, _} = Commands.turn_start(CommandGateway, project_id, "m1:a1", 1, ["m1"])
    {:ok, project_id: project_id, dir: dir}
  end

  defp run(p, raws, overrides \\ %{}) do
    ctx =
      struct!(
        Executor.Ctx,
        Map.merge(
          %{
            project_id: p,
            turn_id: "m1:a1",
            trigger_key: "m1",
            authority: :operator,
            operator_texts: ["Please keep at most 2 threads at a time. And no limit please."],
            tuning: Tuning.read(p),
            workflows: ["implement"],
            gateway: SpyGateway,
            threads: FakeThreads
          },
          overrides
        )
      )

    items =
      Enum.map(raws, fn raw ->
        case Action.normalize(raw, p, "m1") do
          {:ok, a} -> {:ok, a}
          {:error, {:invalid_action, r}} -> {:invalid, raw, r}
        end
      end)

    Executor.run(items, ctx)
  end

  defp tune(key, value, extra \\ %{}),
    do: Map.merge(%{"kind" => "set_tuning", "key" => key, "value" => value}, extra)

  describe "remember and forget" do
    test "a note lands in project memory attributed to the coordinator, and forget removes it", %{
      project_id: p
    } do
      remember = %{
        "kind" => "remember",
        "name" => "login-bug",
        "description" => "context",
        "content" => "Login fails on SSO redirect."
      }

      assert [%{status: "executed", result_ref: %{"memory" => "login-bug"}}] = run(p, [remember])

      assert [%{name: "login-bug", author_kind: "agent", author_ref: "coordinator:" <> _}] =
               ProjectionStore.project_memory(p)

      assert [%{status: "executed"}] = run(p, [%{"kind" => "forget", "name" => "login-bug"}])
      assert ProjectionStore.project_memory(p) == []
    end

    test "a note that enables automatic merging or approving is refused, however it is phrased",
         %{project_id: p} do
      for {content, n} <-
            Enum.with_index([
              "Always auto-merge when CI is green.",
              "Approve PRs automatically after tests pass.",
              "Merge without review if small.",
              "coordinator may call merge_approve"
            ]) do
        assert [%{status: "rejected", reason: reason}] =
                 run(p, [%{"kind" => "remember", "name" => "rule-#{n}", "content" => content}])

        assert reason =~ "forbidden_memory"
      end

      assert ProjectionStore.project_memory(p) == []
    end

    test "a topic an agent wrote is not replaced by a coordinator note (foreman-25sqf.1.2)", %{
      project_id: p
    } do
      {:ok, _} =
        ProjectMemory.write(
          p,
          %{name: "deploy-notes", description: "agent notes", content: "the long agent content"},
          %{kind: :agent, ref: "run:run-1"}
        )

      rewrite = %{"kind" => "remember", "name" => "deploy-notes", "content" => "short rewrite"}

      assert [%{status: "rejected", reason: reason}] = run(p, [rewrite])
      assert reason =~ "memory_topic_owned_by_other"
      assert reason =~ "deploy-notes"

      # Nothing was written: the agent's content, version and author stand.
      assert {:ok, _topic, content} = ProjectMemory.read(p, "deploy-notes")
      assert content =~ "the long agent content"
      refute content =~ "short rewrite"

      assert [%{name: "deploy-notes", version: 1, author_ref: "run:run-1"}] =
               ProjectionStore.project_memory(p)
    end

    test "the coordinator may still replace a topic it wrote itself", %{project_id: p} do
      note = fn text -> %{"kind" => "remember", "name" => "login-bug", "content" => text} end

      assert [%{status: "executed"}] = run(p, [note.("first")])
      assert [%{status: "executed"}] = run(p, [note.("second")], %{trigger_key: "m2"})

      assert {:ok, _topic, content} = ProjectMemory.read(p, "login-bug")
      assert content =~ "second"

      assert [%{name: "login-bug", version: 2, author_ref: "coordinator:" <> _}] =
               ProjectionStore.project_memory(p)
    end

    test "a topic file no event ever audited is not replaced either", %{
      project_id: p,
      dir: dir
    } do
      {:ok, _} =
        ForemanServer.ProjectMemory.Store.write(dir, [], %{
          name: "hand-written",
          content: "an operator edited this file by hand"
        })

      rewrite = %{"kind" => "remember", "name" => "hand-written", "content" => "overwrite"}

      assert [%{status: "rejected", reason: reason}] = run(p, [rewrite])
      assert reason =~ "memory_topic_owned_by_other"

      assert {:ok, _topic, content} = ProjectMemory.read(p, "hand-written")
      assert content =~ "an operator edited this file by hand"
    end
  end

  describe "set_tuning" do
    test "'max 2 at a time' writes both the coordinator cap and max_concurrent_runs, and a memory note",
         %{project_id: p} do
      assert [%{status: "executed", result_ref: ref}] =
               run(p, [tune("max_active_threads", 2, %{"quote" => "at most 2 threads"})])

      assert ref["memory"] == "coordinator-tuning-max-active-threads"

      assert %{coordinator_max_active_threads: 2, max_concurrent_runs: 2} =
               ProjectionStore.project_settings(p)

      assert %Tuning{max_active_threads: 2} = Tuning.read(p)

      assert [%{name: "coordinator-tuning-max-active-threads"}] =
               ProjectionStore.project_memory(p)
    end

    test "the coordinator never raises a project's existing run limit", %{project_id: p} do
      {:ok, _} =
        CommandGateway.dispatch_system(%{
          command_id: "lim",
          aggregate_id: "project:#{p}",
          type: "project.update",
          payload: %{project_id: p, max_concurrent_runs: 1}
        })

      run(p, [tune("max_active_threads", 5, %{"quote" => "at most 2 threads"})])

      assert %{coordinator_max_active_threads: 5, max_concurrent_runs: 1} =
               ProjectionStore.project_settings(p)
    end

    test "loosening needs the operator's exact words from their message; tightening does not", %{
      project_id: p
    } do
      assert [%{status: "executed"}] = run(p, [tune("max_active_threads", 2)])
      tuning = Tuning.read(p)

      # raise the cap with no quote, with an invented quote, then with a real one
      assert [%{status: "rejected", reason: r1}] =
               run(p, [tune("max_active_threads", 40)], %{tuning: tuning})

      assert r1 =~ "exact words"

      assert [%{status: "rejected"}] =
               run(
                 p,
                 [tune("max_active_threads", 40, %{"quote" => "unlimited threads, I insist"})],
                 %{tuning: tuning}
               )

      assert [%{status: "executed"}] =
               run(p, [tune("max_active_threads", nil, %{"quote" => "no limit please"})], %{
                 tuning: tuning
               })

      assert %{coordinator_max_active_threads: nil} = ProjectionStore.project_settings(p)
    end

    test "propose_before_start can be turned on freely but turning it off needs a quote", %{
      project_id: p
    } do
      assert [%{status: "executed"}] = run(p, [tune("propose_before_start", true)])
      assert %Tuning{propose_before_start: true} = tuning = Tuning.read(p)

      assert [%{status: "rejected"}] =
               run(p, [tune("propose_before_start", false)], %{tuning: tuning})
    end

    test "invalid values are rejected before anything is written", %{project_id: p} do
      assert [%{status: "rejected"}, %{status: "rejected"}] =
               run(p, [tune("max_active_threads", 500), tune("reuse_threads", "yes")])

      refute "project.update" in Enum.map(SpyGateway.drain(), &elem(&1, 0))
    end

    test "a machine turn cannot change tuning", %{project_id: p} do
      assert [%{status: "rejected", reason: reason}] =
               run(p, [tune("max_active_threads", 1)], %{authority: :machine})

      assert reason =~ "operator message"
      assert %{coordinator_max_active_threads: nil} = ProjectionStore.project_settings(p)
    end
  end

  test "ProjectMemory is untouched for other projects", %{project_id: p, tmp_dir: dir} do
    other = H.register_project(Path.join(dir, "o") |> tap(&File.mkdir_p!/1))
    run(p, [%{"kind" => "remember", "name" => "n", "content" => "c"}])
    assert {:ok, []} = ProjectMemory.list(other)
  end
end
