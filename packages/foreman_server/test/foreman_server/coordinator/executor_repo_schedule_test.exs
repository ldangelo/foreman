defmodule ForemanServer.Coordinator.ExecutorRepoScheduleTest do
  @moduledoc """
  The `add_repo` and `schedule` coordinator actions: operator-grade commands
  (`project.repo.add`, `schedule.create`) that run through the gateway's operator
  path, so the validation and limits of the CLI verbs apply, and only for an
  operator turn whose own words (`quote`) confirm them.
  """
  use ExUnit.Case, async: false

  @moduletag :tmp_dir

  alias ForemanServer.Coordinator.{Action, Commands, Executor, Tuning}
  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.Projects.RepoValidation

  alias ForemanServer.TestSupport.CoordinatorHelpers, as: H
  alias ForemanServer.TestSupport.CoordinatorHelpers.{FakeThreads, SpyGateway}

  @operator_text "Please register the checkout called web-app and run the dependency audit every weekday at 9 UTC."
  @repo_quote "register the checkout called web-app"
  @schedule_quote "run the dependency audit every weekday at 9 UTC"

  setup %{tmp_dir: dir} do
    project_id = H.register_project(git_repo(dir, "primary"))
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
            operator_texts: [@operator_text],
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
          {:ok, action} -> {:ok, action}
          {:error, {:invalid_action, reason}} -> {:invalid, raw, reason}
        end
      end)

    Executor.run(items, ctx)
  end

  defp git_repo(dir, name) do
    path = Path.join(dir, name)
    File.mkdir_p!(path)
    {_, 0} = System.cmd("git", ["init", "-q", path])
    path
  end

  defp add_repo(path, extra \\ %{}),
    do: Map.merge(%{"kind" => "add_repo", "path" => path, "quote" => @repo_quote}, extra)

  defp schedule(extra \\ %{}) do
    Map.merge(
      %{
        "kind" => "schedule",
        "spec" => "30m",
        "prompt" => "Audit the dependencies and report each outdated package.\nBe brief.",
        "workflow" => "implement",
        "quote" => @schedule_quote
      },
      extra
    )
  end

  # Every command of `type` the gateway saw, oldest first.
  defp spied(type), do: for({^type, command} <- SpyGateway.drain(), do: command)

  defp repo_ids(p), do: p |> ProjectionStore.project_repositories() |> Enum.map(& &1.id)

  describe "add_repo" do
    test "registers the checkout through the operator path, attributed to the coordinator", %{
      project_id: p,
      dir: dir
    } do
      repo = git_repo(dir, "Web App")
      {:ok, canonical} = RepoValidation.canonical_path(repo)

      assert [%{status: "executed", result_ref: %{"repo_id" => "web-app", "path" => ^repo}}] =
               run(p, [add_repo(repo, %{"name" => "web-app"})])

      added_by = "coordinator:" <> p

      assert %{id: "web-app", path: ^canonical, added_by: ^added_by} =
               ProjectionStore.project_repository(p, "web-app")

      assert [%{command_id: "coord:repo.add:" <> _, payload: %{repo_id: "web-app"}}] =
               spied("project.repo.add")
    end

    test "without a name the repository id is the directory name reduced to the id syntax", %{
      project_id: p,
      dir: dir
    } do
      repo = git_repo(dir, "My Web_App.git")

      assert [%{status: "executed", result_ref: %{"repo_id" => "my-web-app-git"}}] =
               run(p, [add_repo(repo)])

      assert repo_ids(p) == ["main", "my-web-app-git"]
    end

    test "needs the operator's own words: none or invented words add nothing", %{
      project_id: p,
      dir: dir
    } do
      repo = git_repo(dir, "api")

      for extra <- [%{"quote" => nil}, %{"quote" => "add everything under /srv"}] do
        assert [%{status: "rejected", reason: reason}] = run(p, [add_repo(repo, extra)])
        assert reason =~ "exact words"
      end

      assert repo_ids(p) == ["main"]
      assert spied("project.repo.add") == []
    end

    test "a machine turn cannot add a repository, whatever it quotes", %{project_id: p, dir: dir} do
      repo = git_repo(dir, "api")

      assert [%{status: "rejected", reason: reason}] =
               run(p, [add_repo(repo)], %{authority: :machine})

      assert reason =~ "operator message"
      assert repo_ids(p) == ["main"]
      assert spied("project.repo.add") == []
    end

    test "the checks of `foreman project repo add` apply: git work tree, absolute, not a member",
         %{project_id: p, dir: dir} do
      plain = Path.join(dir, "plain") |> tap(&File.mkdir_p!/1)
      primary = ProjectionStore.project(p).path

      refusals =
        for path <- [plain, Path.join(dir, "missing"), "relative/dir", primary] do
          assert [%{status: "rejected", reason: reason, result_ref: nil}] =
                   run(p, [add_repo(path)])

          reason
        end

      assert [not_git, not_found, not_absolute, duplicate] = refusals
      assert not_git =~ "repo_not_git_work_tree"
      assert not_found =~ "repo_path_not_found"
      assert not_absolute =~ "repo_path_not_absolute"
      assert duplicate =~ "repo_path_duplicate"
      assert repo_ids(p) == ["main"]
    end

    test "a second name for a registered checkout, or a taken id, is refused like on the CLI", %{
      project_id: p,
      dir: dir
    } do
      first = git_repo(dir, "api")
      second = git_repo(dir, "other")
      assert [%{status: "executed"}] = run(p, [add_repo(first, %{"name" => "api"})])

      assert [%{status: "rejected", reason: alias_reason}] =
               run(p, [add_repo(first, %{"name" => "api-two"})])

      assert alias_reason =~ "repo_path_duplicate"

      assert [%{status: "rejected", reason: taken}] =
               run(p, [add_repo(second, %{"name" => "api"})])

      assert taken =~ "repo_id_taken"

      assert [%{status: "rejected", reason: reserved}] =
               run(p, [add_repo(second, %{"name" => "main"})])

      assert reserved =~ "repo_id_taken"
      assert repo_ids(p) == ["main", "api"]
    end

    test "a name that reduces to no id is rejected before anything is dispatched", %{
      project_id: p,
      dir: dir
    } do
      repo = git_repo(dir, "api")

      assert [%{status: "rejected", reason: reason}] =
               run(p, [add_repo(repo, %{"name" => "!!!"})])

      assert reason =~ "cannot make a repository id"
      assert spied("project.repo.add") == []
    end

    test "re-running the action (a crash before it was recorded) registers nothing twice", %{
      project_id: p,
      dir: dir
    } do
      repo = git_repo(dir, "api")
      action = add_repo(repo, %{"name" => "api"})

      assert [%{status: "executed", result_ref: first}] = run(p, [action])
      assert [%{status: "executed", result_ref: second}] = run(p, [action])

      refute Map.has_key?(first, "already_registered")
      assert second == Map.put(first, "already_registered", true)
      assert repo_ids(p) == ["main", "api"]
      assert [%{command_id: command_id}] = spied("project.repo.add")
      assert command_id =~ "coord:repo.add:"
    end
  end

  describe "schedule" do
    test "creates the schedule through the operator path", %{project_id: p} do
      assert [%{status: "executed", result_ref: ref}] = run(p, [schedule()])
      assert %{"schedule_id" => "sch-" <> _ = id, "workflow" => "implement"} = ref
      assert ref["name"] == "Audit the dependencies and report each outdated package."

      assert [
               %{
                 schedule_id: ^id,
                 status: "active",
                 workflow: "implement",
                 auto_approve: true,
                 spec: %{"every" => "30m"},
                 name: "Audit the dependencies and report each outdated package.",
                 prompt: "Audit the dependencies and report each outdated package.\nBe brief."
               }
             ] = ProjectionStore.schedules(p)

      assert [%{command_id: "coord:schedule.create:" <> _, aggregate_id: aggregate_id}] =
               spied("schedule.create")

      assert aggregate_id == "schedule:#{p}:#{id}"
    end

    test "a cron expression and an explicit name are used as given", %{project_id: p} do
      extra = %{"spec" => "0 9 * * 1-5", "name" => "weekday audit"}
      assert [%{status: "executed"}] = run(p, [schedule(extra)])

      assert [%{name: "weekday audit", spec: %{"cron" => "0 9 * * 1-5"}}] =
               ProjectionStore.schedules(p)
    end

    test "a project that makes the coordinator propose never gets an unattended schedule", %{
      project_id: p
    } do
      tuning = %Tuning{propose_before_start: true}
      assert [%{status: "executed"}] = run(p, [schedule()], %{tuning: tuning})
      assert [%{auto_approve: false}] = ProjectionStore.schedules(p)
    end

    test "needs the operator's own words: none or invented words create nothing", %{
      project_id: p
    } do
      for extra <- [%{"quote" => nil}, %{"quote" => "every minute, whatever it costs"}] do
        assert [%{status: "rejected", reason: reason}] = run(p, [schedule(extra)])
        assert reason =~ "exact words"
      end

      assert ProjectionStore.schedules(p) == []
      assert spied("schedule.create") == []
    end

    test "a machine turn cannot create a schedule, whatever it quotes", %{project_id: p} do
      assert [%{status: "rejected", reason: reason}] =
               run(p, [schedule()], %{authority: :machine})

      assert reason =~ "operator message"
      assert ProjectionStore.schedules(p) == []
    end

    test "the limits of `foreman project schedule create` apply, with a reason the model can act on",
         %{project_id: p} do
      below_minimum = schedule(%{"spec" => "1m"})
      not_a_spec = schedule(%{"spec" => "0 9 * *"})
      outcomes = run(p, [below_minimum, not_a_spec])

      assert [%{status: "rejected", reason: r1}, %{status: "rejected", reason: r2}] = outcomes

      for reason <- [r1, r2] do
        assert reason =~ "schedule spec is not valid"
        assert reason =~ "30m, 6h or 1d"
      end

      assert r1 =~ "below_minimum"
      assert r2 =~ "wrong_field_count"
      assert ProjectionStore.schedules(p) == []
      assert Executor.notice(outcomes) =~ "I did not run schedule"
    end

    test "the workflow is chosen like for a thread: installed, else a task type, else an error",
         %{project_id: p} do
      assert [%{status: "rejected", reason: unknown}] =
               run(p, [schedule(%{"workflow" => "no-such"})])

      assert unknown =~ "unknown workflow" and unknown =~ "implement"

      without = Map.delete(schedule(), "workflow")
      assert [%{status: "rejected", reason: none}] = run(p, [without])
      assert none =~ "no workflow could be chosen"

      invalid = [%{name: "broken", reason: "bad manifest"}]

      assert [%{status: "rejected", reason: refused}] =
               run(p, [schedule(%{"workflow" => "broken"})], %{invalid_workflows: invalid})

      assert refused =~ "INVALID"
      assert ProjectionStore.schedules(p) == []
    end

    test "the per-project schedule cap applies", %{project_id: p} do
      previous = Application.get_env(:foreman_server, :schedule, [])
      Application.put_env(:foreman_server, :schedule, Keyword.put(previous, :max_per_project, 1))
      on_exit(fn -> Application.put_env(:foreman_server, :schedule, previous) end)

      assert [%{status: "executed"}] = run(p, [schedule()])

      assert [%{status: "rejected", reason: reason}] =
               run(p, [schedule(%{"prompt" => "A different brief."})])

      assert reason =~ "schedule_limit_reached"
      assert [_one] = ProjectionStore.schedules(p)
    end

    test "re-running the action (a crash before it was recorded) creates no second schedule", %{
      project_id: p
    } do
      assert [%{status: "executed", result_ref: first}] = run(p, [schedule()])
      assert [%{status: "executed", result_ref: second}] = run(p, [schedule()])

      assert first == second
      assert [%{schedule_id: id}] = ProjectionStore.schedules(p)
      assert id == first["schedule_id"]

      assert [%{command_id: same}, %{command_id: same}] = spied("schedule.create")
    end
  end
end
