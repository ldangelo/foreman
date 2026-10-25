defmodule ForemanServerWeb.AdoptionControllerTest do
  # POST /api/project-adoptions end to end: the real router + auth pipeline, the real
  # AdoptionService, command gateway and event store, the shared ProjectionStore.
  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest
  import ForemanServer.TestSupport.AdoptionFixtures

  alias ForemanServer.ProjectionStore

  @endpoint ForemanServerWeb.Endpoint
  @token "adoption-controller-token"
  @moduletag :tmp_dir

  @dto_keys ~w(adopted archive_updates from_project_id minted_project_id mode moved new_task_id
               project_id subject_id subject_kind)

  setup %{tmp_dir: tmp} do
    previous = Application.get_env(:foreman_server, :api_bearer_token)
    Application.put_env(:foreman_server, :api_bearer_token, @token)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:foreman_server, :api_bearer_token),
        else: Application.put_env(:foreman_server, :api_bearer_token, previous)
    end)

    id = uid()
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))

    a = "a-#{id}"
    b = "b-#{id}"
    register!(a, repo)
    register!(b, repo)

    %{a: a, b: b, repo: repo, run: "run-#{id}", task: "task-#{id}", id: id}
  end

  defp post_adoption(body, status) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> @token)
    |> post("/api/project-adoptions", body)
    |> json_response(status)
  end

  defp seed_terminal!(ctx, repo \\ nil) do
    seed_run!(%{
      project: ctx.a,
      run: ctx.run,
      task: ctx.task,
      repo: repo || ctx.repo,
      terminal?: true
    })
  end

  describe "201" do
    test "move re-homes the session and answers with exactly the whitelisted projection", ctx do
      seed_terminal!(ctx)
      dir = archive!(ctx.repo, ctx.run, ctx.a)

      body =
        post_adoption(
          %{"subject_kind" => "run", "subject_id" => ctx.run, "target_project_id" => ctx.b},
          201
        )

      assert Map.keys(body) == ["adoption"]
      adoption = body["adoption"]
      assert Map.keys(adoption) |> Enum.sort() == @dto_keys

      assert adoption == %{
               "mode" => "move",
               "subject_kind" => "run",
               "subject_id" => ctx.run,
               "project_id" => ctx.b,
               "from_project_id" => ctx.a,
               "adopted" => true,
               "new_task_id" => nil,
               "minted_project_id" => nil,
               "moved" => %{"task_ids" => [ctx.task], "run_ids" => [ctx.run], "jobsite_ids" => []},
               "archive_updates" => [%{"path" => dir, "status" => "updated"}]
             }

      assert %{project_id: moved_to} = ProjectionStore.run(ctx.run)
      assert moved_to == ctx.b
    end

    test "move accepts an explicit mode and moves a finished jobsite", ctx do
      js = "js-#{ctx.id}"
      seed_jobsite!(%{project: ctx.a, jobsite: js, repo: ctx.repo, terminal?: true})
      dir = archive!(:jobsite, ctx.repo, js, ctx.a)

      %{"adoption" => adoption} =
        post_adoption(
          %{
            "mode" => "move",
            "subject_kind" => "jobsite",
            "subject_id" => js,
            "target_project_id" => ctx.b
          },
          201
        )

      assert %{
               "subject_kind" => "jobsite",
               "from_project_id" => from,
               "project_id" => target,
               "moved" => %{"task_ids" => [], "run_ids" => [], "jobsite_ids" => [^js]},
               "archive_updates" => [%{"path" => ^dir, "status" => "updated"}]
             } = adoption

      assert {from, target} == {ctx.a, ctx.b}
      assert %{project_id: moved_to} = ProjectionStore.jobsite(js)
      assert moved_to == ctx.b
    end

    test "mint creates the project named in new_project and moves the session in", ctx do
      fresh = Path.join(Path.dirname(ctx.repo), "fresh-#{ctx.id}")
      File.mkdir_p!(Path.join(fresh, ".git"))
      seed_terminal!(ctx, fresh)
      minted = "minted-#{ctx.id}"

      %{"adoption" => adoption} =
        post_adoption(
          %{
            "mode" => "mint",
            "subject_kind" => "run",
            "subject_id" => ctx.run,
            "new_project" => %{"id" => minted, "goal" => "Ship the healthz route"}
          },
          201
        )

      assert Map.keys(adoption) |> Enum.sort() == @dto_keys

      assert %{
               "mode" => "mint",
               "minted_project_id" => ^minted,
               "project_id" => ^minted,
               "from_project_id" => from,
               "adopted" => true
             } = adoption

      assert from == ctx.a
      assert %{config: %{goal: "Ship the healthz route"}} = ProjectionStore.project(minted)
      assert %{project_id: moved_to} = ProjectionStore.run(ctx.run)
      assert moved_to == minted
    end

    test "mint without new_project derives the project from the session archive", ctx do
      fresh = Path.join(Path.dirname(ctx.repo), "derived-#{ctx.id}")
      File.mkdir_p!(Path.join(fresh, ".git"))
      seed_terminal!(ctx, fresh)
      archive!(fresh, ctx.run, ctx.a)

      %{"adoption" => adoption} =
        post_adoption(
          %{"mode" => "mint", "subject_kind" => "run", "subject_id" => ctx.run},
          201
        )

      assert adoption["minted_project_id"] == "derived-#{ctx.id}"
      assert adoption["project_id"] == adoption["minted_project_id"]
    end

    test "continue starts a new thread in the target and leaves the original alone", ctx do
      # `continue` approves the new task; keep the app-level Dispatcher from starting a real run.
      :ok =
        Supervisor.terminate_child(ForemanServer.Application, ForemanServer.Workflow.Dispatcher)

      on_exit(fn -> ForemanServer.TestSupport.DispatcherRestart.restart!() end)

      seed_terminal!(ctx)
      archive!(ctx.repo, ctx.run, ctx.a)

      %{"adoption" => adoption} =
        post_adoption(
          %{
            "mode" => "continue",
            "subject_kind" => "run",
            "subject_id" => ctx.run,
            "target_project_id" => ctx.b,
            "prompt" => "also add /readyz"
          },
          201
        )

      assert Map.keys(adoption) |> Enum.sort() == @dto_keys

      # The new thread is what is adopted into the target; the original is not touched.
      assert %{
               "mode" => "continue",
               "adopted" => true,
               "project_id" => target,
               "from_project_id" => from,
               "new_task_id" => new_task,
               "minted_project_id" => nil,
               "moved" => %{"task_ids" => [moved_task], "run_ids" => [], "jobsite_ids" => []},
               "archive_updates" => []
             } = adoption

      assert {from, target} == {ctx.a, ctx.b}
      assert is_binary(new_task) and moved_task == new_task

      assert %{project_id: new_home, prompt: prompt} = ProjectionStore.task_projection(new_task)
      assert new_home == ctx.b
      assert prompt =~ "also add /readyz" and prompt =~ "UNTRUSTED"

      assert %{project_id: still} = ProjectionStore.run(ctx.run)
      assert still == ctx.a
    end
  end

  describe "400 invalid_params" do
    test "a missing or non-string field is named", ctx do
      for {body, detail} <- [
            {%{}, "subject_kind is required"},
            {%{"subject_kind" => "run"}, "subject_id is required"},
            {%{"subject_kind" => "run", "subject_id" => 5}, "subject_id is required"},
            {%{"subject_kind" => "run", "subject_id" => ctx.run},
             "target_project_id is required"},
            {%{
               "mode" => "continue",
               "subject_kind" => "run",
               "subject_id" => ctx.run,
               "target_project_id" => ctx.b
             }, "prompt is required"}
          ] do
        assert %{"error" => "invalid_params", "detail" => ^detail} = post_adoption(body, 400)
      end
    end

    test "an unknown mode is refused and nothing moves", ctx do
      seed_terminal!(ctx)

      assert %{"error" => "invalid_params", "detail" => detail} =
               post_adoption(
                 %{
                   "mode" => "rename",
                   "subject_kind" => "run",
                   "subject_id" => ctx.run,
                   "target_project_id" => ctx.b
                 },
                 400
               )

      assert detail == "mode must be move, continue or mint, got \"rename\""
      assert %{project_id: still} = ProjectionStore.run(ctx.run)
      assert still == ctx.a
    end
  end

  describe "404" do
    test "an unknown target project", ctx do
      seed_terminal!(ctx)
      missing = "missing-#{ctx.id}"

      assert %{"error" => "project_not_found", "detail" => detail} =
               post_adoption(
                 %{
                   "subject_kind" => "run",
                   "subject_id" => ctx.run,
                   "target_project_id" => missing
                 },
                 404
               )

      assert detail =~ missing
    end

    test "an unknown subject", ctx do
      missing = "missing-#{ctx.id}"

      assert %{"error" => "subject_not_found", "detail" => detail} =
               post_adoption(
                 %{
                   "subject_kind" => "run",
                   "subject_id" => missing,
                   "target_project_id" => ctx.b
                 },
                 404
               )

      assert detail =~ missing
    end
  end

  describe "422 refusals keep their tag" do
    test "a running session cannot be moved", ctx do
      seed_run!(%{project: ctx.a, run: ctx.run, task: ctx.task, repo: ctx.repo, terminal?: false})

      assert %{"error" => "subject_active"} =
               post_adoption(
                 %{
                   "subject_kind" => "run",
                   "subject_id" => ctx.run,
                   "target_project_id" => ctx.b
                 },
                 422
               )

      assert %{project_id: still} = ProjectionStore.run(ctx.run)
      assert still == ctx.a
    end

    test "a target that does not own the session's repository (E12)", ctx do
      other = "other-#{ctx.id}"
      home = Path.join(Path.dirname(ctx.repo), "home-#{ctx.id}")
      File.mkdir_p!(Path.join(home, ".git"))
      register!(other, home)
      seed_terminal!(ctx)

      assert %{"error" => "repo_not_in_project", "detail" => detail} =
               post_adoption(
                 %{
                   "subject_kind" => "run",
                   "subject_id" => ctx.run,
                   "target_project_id" => other
                 },
                 422
               )

      assert detail =~ ctx.repo
    end

    test "an unknown subject kind", ctx do
      assert %{"error" => "invalid_subject_kind"} =
               post_adoption(
                 %{
                   "subject_kind" => "branch",
                   "subject_id" => ctx.run,
                   "target_project_id" => ctx.b
                 },
                 422
               )
    end

    test "a blank continue prompt", ctx do
      seed_terminal!(ctx)

      assert %{"error" => "missing_or_invalid"} =
               post_adoption(
                 %{
                   "mode" => "continue",
                   "subject_kind" => "run",
                   "subject_id" => ctx.run,
                   "target_project_id" => ctx.b,
                   "prompt" => "   "
                 },
                 422
               )
    end

    test "mint at a path a live project owns names that owner", ctx do
      solo = "solo-#{ctx.id}"
      solo_repo = Path.join(Path.dirname(ctx.repo), solo)
      File.mkdir_p!(Path.join(solo_repo, ".git"))
      register!(solo, solo_repo)
      seed_terminal!(ctx, solo_repo)

      assert %{"error" => "path_in_use", "detail" => detail} =
               post_adoption(
                 %{"mode" => "mint", "subject_kind" => "run", "subject_id" => ctx.run},
                 422
               )

      assert detail =~ solo
    end

    test "mint at a path that is not a git working tree", ctx do
      plain = Path.join(Path.dirname(ctx.repo), "plain-#{ctx.id}")
      File.mkdir_p!(plain)
      seed_terminal!(ctx, plain)

      assert %{"error" => "path_not_a_git_working_tree", "detail" => detail} =
               post_adoption(
                 %{"mode" => "mint", "subject_kind" => "run", "subject_id" => ctx.run},
                 422
               )

      assert detail =~ plain
    end

    test "mint with an id that already exists", ctx do
      fresh = Path.join(Path.dirname(ctx.repo), "fresh2-#{ctx.id}")
      File.mkdir_p!(Path.join(fresh, ".git"))
      seed_terminal!(ctx, fresh)

      assert %{"error" => "already_exists", "detail" => detail} =
               post_adoption(
                 %{
                   "mode" => "mint",
                   "subject_kind" => "run",
                   "subject_id" => ctx.run,
                   "new_project" => %{"id" => ctx.b}
                 },
                 422
               )

      assert detail =~ ctx.b
    end
  end

  describe "401" do
    test "no bearer token moves nothing", ctx do
      seed_terminal!(ctx)

      body = %{"subject_kind" => "run", "subject_id" => ctx.run, "target_project_id" => ctx.b}

      assert build_conn() |> post("/api/project-adoptions", body) |> response(401)

      assert build_conn()
             |> put_req_header("authorization", "Bearer wrong")
             |> post("/api/project-adoptions", body)
             |> response(401)

      assert %{project_id: still} = ProjectionStore.run(ctx.run)
      assert still == ctx.a
    end
  end
end
