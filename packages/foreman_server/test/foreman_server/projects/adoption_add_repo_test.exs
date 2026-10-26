defmodule ForemanServer.Projects.AdoptionAddRepoTest do
  # `AdoptionService.adopt/4` with `add_repo: true`: a session whose repository the target does not have
  # yet gets it attached first, through the operator command `project.repo.add` (so its checks and typed
  # errors apply), and then moves. Every other refusal stands and attaches nothing. The option is not
  # part of the `project.adopt` command, so a command caller cannot skip the repository check.
  use ExUnit.Case, async: false

  import ForemanServer.TestSupport.AdoptionFixtures

  alias ForemanServer.{CommandGateway, ProjectionStore}
  alias ForemanServer.Projects.{AdoptionService, RepoValidation}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    id = uid()
    # The session's repository (`outside`) is not a repository of the target project.
    outside = init_repo!(Path.join(tmp, "outside-#{id}"))
    home = init_repo!(Path.join(tmp, "home-#{id}"))
    a = "a-#{id}"
    b = "b-#{id}"
    register!(a, outside)
    register!(b, home)

    %{a: a, b: b, outside: outside, home: home, run: "run-#{id}", task: "task-#{id}", id: id}
  end

  defp init_repo!(path) do
    File.mkdir_p!(path)
    git!(path, ["init", "--initial-branch=main", "--quiet"])
    git!(path, ["config", "user.email", "t@x"])
    git!(path, ["config", "user.name", "T"])
    File.write!(Path.join(path, "README.md"), "seed")
    git!(path, ["add", "."])
    git!(path, ["commit", "--no-gpg-sign", "-m", "seed", "--quiet"])
    path
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}) in #{dir}: #{out}")
    end
  end

  defp seed!(ctx, opts \\ []) do
    seed_run!(%{
      project: ctx.a,
      run: ctx.run,
      task: ctx.task,
      repo: Keyword.get(opts, :repo, ctx.outside),
      terminal?: Keyword.get(opts, :terminal?, true)
    })
  end

  defp repos(project), do: ProjectionStore.project_repositories(project)
  defp extras(project), do: Enum.reject(repos(project), & &1.primary)

  defp project_of_run(run), do: ProjectionStore.run(run).project_id

  test "without the option the foreign repository is refused (the control)", ctx do
    seed!(ctx)

    assert {:error, {:repo_not_in_project, repo}} = AdoptionService.adopt("run", ctx.run, ctx.b)
    assert repo == ctx.outside
    assert extras(ctx.b) == []
    assert project_of_run(ctx.run) == ctx.a
  end

  test "with the option the repository is attached to the target and the run moves", ctx do
    seed!(ctx)

    assert {:ok, %{adopted?: true, project_id: target, from_project_id: from}} =
             AdoptionService.adopt("run", ctx.run, ctx.b, add_repo: true)

    assert {target, from} == {ctx.b, ctx.a}
    assert project_of_run(ctx.run) == ctx.b

    {:ok, canonical} = RepoValidation.canonical_path(ctx.outside)

    assert [%{id: id, path: ^canonical, added_by: added_by, primary: false}] = extras(ctx.b)
    assert id == "outside-#{ctx.id}"
    assert added_by == "adoption:run:#{ctx.run}"

    # The target's own repository is untouched.
    assert [%{id: "main", path: home}] = Enum.filter(repos(ctx.b), & &1.primary)
    assert home == ctx.home
  end

  test "a repository the target already has is not added twice", ctx do
    seed!(ctx)

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRepositoryAdded",
          payload: %{
            project_id: ctx.b,
            repo_id: "api",
            path: ctx.outside,
            default_branch: nil,
            added_by: "test",
            at: "2026-10-25T00:00:00Z"
          }
        }
      ])

    assert [%{id: "api"}] = extras(ctx.b)

    assert {:ok, %{adopted?: true}} = AdoptionService.adopt("run", ctx.run, ctx.b, add_repo: true)

    assert [%{id: "api", added_by: "test"}] = extras(ctx.b)
    assert project_of_run(ctx.run) == ctx.b
  end

  test "the id is the directory name, made unique among the target's repositories", ctx do
    seed!(ctx)
    taken = "outside-#{ctx.id}"

    :ok =
      ProjectionStore.apply_events([
        %{
          event_type: "ProjectRepositoryAdded",
          payload: %{
            project_id: ctx.b,
            repo_id: taken,
            path: ctx.home <> "-elsewhere",
            default_branch: nil,
            added_by: "test",
            at: "2026-10-25T00:00:00Z"
          }
        }
      ])

    assert {:ok, %{adopted?: true}} = AdoptionService.adopt("run", ctx.run, ctx.b, add_repo: true)

    ids = ctx.b |> extras() |> Enum.map(& &1.id) |> Enum.sort()
    assert ids == Enum.sort([taken, taken <> "-2"])
  end

  test "a session recorded under a symlink of an attached checkout still belongs to it", ctx do
    link = Path.join(Path.dirname(ctx.outside), "link-#{ctx.id}")
    :ok = File.ln_s(ctx.outside, link)
    seed!(ctx, repo: link)

    # Attaching stores the canonical path, so the membership check has to compare canonically:
    # without that the repository would be attached and the move still refused.
    assert {:ok, %{adopted?: true}} = AdoptionService.adopt("run", ctx.run, ctx.b, add_repo: true)
    assert project_of_run(ctx.run) == ctx.b

    {:ok, canonical} = RepoValidation.canonical_path(ctx.outside)
    assert [%{path: ^canonical}] = extras(ctx.b)

    # And a second session recorded under the symlinked path is a member WITHOUT the option.
    second = %{project: ctx.a, run: "run2-#{ctx.id}", task: "task2-#{ctx.id}", repo: link}
    seed_run!(Map.put(second, :terminal?, true))

    assert {:ok, %{adopted?: true}} = AdoptionService.adopt("run", second.run, ctx.b)
    assert project_of_run(second.run) == ctx.b
  end

  describe "refusals attach nothing" do
    test "a repository that is not a git work tree is the attach's typed error and the run stays",
         ctx do
      plain = Path.join(Path.dirname(ctx.outside), "plain-#{ctx.id}")
      File.mkdir_p!(Path.join(plain, ".git"))
      seed!(ctx, repo: plain)

      assert {:error, {:repo_not_git_work_tree, ^plain}} =
               AdoptionService.adopt("run", ctx.run, ctx.b, add_repo: true)

      assert extras(ctx.b) == []
      assert project_of_run(ctx.run) == ctx.a
    end

    test "a session that is still active is refused before anything is attached", ctx do
      seed!(ctx, terminal?: false)

      assert {:error, {:subject_active, _status}} =
               AdoptionService.adopt("run", ctx.run, ctx.b, add_repo: true)

      assert extras(ctx.b) == []
      assert project_of_run(ctx.run) == ctx.a
    end

    test "a paused target is refused before anything is attached", ctx do
      seed!(ctx)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "pause-#{ctx.b}",
                 aggregate_id: "project:" <> ctx.b,
                 type: "project.pause",
                 payload: %{project_id: ctx.b, reason: "test"}
               })

      assert {:error, {:project_paused, target}} =
               AdoptionService.adopt("run", ctx.run, ctx.b, add_repo: true)

      assert target == ctx.b
      assert extras(ctx.b) == []
      assert project_of_run(ctx.run) == ctx.a
    end

    test "a beads-bound task is refused before anything is attached", ctx do
      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "TaskCreated",
            payload: %{
              task_id: "beads:#{ctx.a}:bead-1",
              project_id: ctx.a,
              title: "bead",
              status: "open",
              task_type: "task"
            }
          }
        ])

      assert {:error, {:subject_bound_to_task_provider, "beads"}} =
               AdoptionService.adopt("task", "beads:#{ctx.a}:bead-1", ctx.b, add_repo: true)

      assert extras(ctx.b) == []
    end
  end

  test "the option is not part of the project.adopt command: a command caller cannot skip the check",
       ctx do
    seed!(ctx)

    assert {:error, {:repo_not_in_project, repo}} =
             CommandGateway.dispatch_operator(%{
               command_id: "adopt-smuggle-#{ctx.id}",
               aggregate_id: "project:" <> ctx.b,
               type: "project.adopt",
               payload: %{
                 project_id: ctx.b,
                 subject_kind: "run",
                 subject_id: ctx.run,
                 mode: "move",
                 add_repo: true
               }
             })

    assert repo == ctx.outside
    assert extras(ctx.b) == []
    assert project_of_run(ctx.run) == ctx.a
  end

  test "a non-boolean :add_repo is a programming error, not a maybe", ctx do
    seed!(ctx)

    assert_raise ArgumentError, ~r/:add_repo must be a boolean/, fn ->
      AdoptionService.adopt("run", ctx.run, ctx.b, add_repo: "yes")
    end
  end
end
