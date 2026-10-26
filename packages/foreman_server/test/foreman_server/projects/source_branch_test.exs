defmodule ForemanServer.Projects.SourceBranchTest do
  # The branch a continuation builds on (`adopt --continue --from-source-branch`): read from the
  # projections of the subject, checked against the repository the new worktree is cut in, and refused
  # with a typed reason when it is not there. Nothing falls back to the project's current branch.
  use ExUnit.Case, async: false

  import ForemanServer.TestSupport.AdoptionFixtures

  alias ForemanServer.ProjectionStore
  alias ForemanServer.Projects.SourceBranch

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    id = uid()
    repo = Path.join(tmp, "repo")
    File.mkdir_p!(Path.join(repo, ".git"))
    a = "a-#{id}"
    register!(a, repo)

    on_exit(fn -> Process.delete(:projection_store_now_ms) end)

    %{a: a, repo: repo, run: "run-#{id}", task: "task-#{id}", id: id}
  end

  describe "validate/1" do
    test "absent is none; a name safe to hand to git is ok" do
      assert SourceBranch.validate(nil) == :none

      for branch <- ["main", "agent/x", "foreman/task-1/run-1", "release-1.2", "feat_x/y.z"] do
        assert SourceBranch.validate(branch) == :ok
      end
    end

    test "anything that is not safe to hand to git is refused, naming the value" do
      for bad <- [
            "",
            "-rf",
            "--upload-pack=x",
            "a b",
            "a..b",
            "a//b",
            "x.lock",
            "x/",
            "x.",
            "feat/\n",
            "refs/heads/x;rm",
            :main,
            42,
            ["main"]
          ] do
        assert {:error, {:invalid_source_branch, ^bad}} = SourceBranch.validate(bad)
      end
    end
  end

  describe "resolve/2" do
    test "a run: the branch of its primary worktree", ctx do
      seed_run!(%{project: ctx.a, run: ctx.run, task: ctx.task, repo: ctx.repo, terminal?: true})

      assert {:ok, "agent/x"} = SourceBranch.resolve("run", ctx.run)
    end

    test "a run whose only worktree is a secondary repository's has none", ctx do
      seed_run!(%{project: ctx.a, run: ctx.run, task: ctx.task, repo: ctx.repo, terminal?: true})
      other = "run-other-#{ctx.id}"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "RunStarted",
            payload: %{run_id: other, task_id: ctx.task, project_id: ctx.a, workflow_name: "x"}
          },
          %{
            event_type: "WorktreeCreated",
            payload: %{
              operation_id: "wt-#{other}-b",
              project_id: ctx.a,
              run_id: other,
              phase_id: "p1",
              repo_path: ctx.repo,
              worktree_path: ctx.repo <> "/wt-b",
              branch: "agent/secondary",
              base_ref: "abc",
              repo_id: "b"
            }
          }
        ])

      assert {:error, {:source_branch_unknown, "run", ^other}} =
               SourceBranch.resolve("run", other)
    end

    test "a run that never created a worktree has none", ctx do
      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "RunStarted",
            payload: %{
              run_id: ctx.run,
              task_id: ctx.task,
              project_id: ctx.a,
              workflow_name: "x"
            }
          }
        ])

      assert {:error, {:source_branch_unknown, "run", run}} = SourceBranch.resolve("run", ctx.run)
      assert run == ctx.run
    end

    test "a task: the branch of its most recently started run that has one", ctx do
      later = "run-later-#{ctx.id}"

      Process.put(:projection_store_now_ms, fn -> 1_000 end)
      seed_run!(%{project: ctx.a, run: ctx.run, task: ctx.task, repo: ctx.repo, terminal?: true})

      Process.put(:projection_store_now_ms, fn -> 2_000 end)

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "RunStarted",
            payload: %{run_id: later, task_id: ctx.task, project_id: ctx.a, workflow_name: "x"}
          },
          %{
            event_type: "WorktreeCreated",
            payload: %{
              operation_id: "wt-#{later}-p1",
              project_id: ctx.a,
              run_id: later,
              phase_id: "p1",
              repo_path: ctx.repo,
              worktree_path: ctx.repo <> "/wt-later",
              branch: "agent/later",
              base_ref: "abc"
            }
          }
        ])

      assert {:ok, "agent/later"} = SourceBranch.resolve("task", ctx.task)
      assert {:ok, "agent/x"} = SourceBranch.resolve("run", ctx.run)
    end

    test "a task that never ran has none", ctx do
      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "TaskCreated",
            payload: %{
              task_id: ctx.task,
              project_id: ctx.a,
              title: "never ran",
              status: "open",
              task_type: "task"
            }
          }
        ])

      assert {:error, {:source_branch_unknown, "task", task}} =
               SourceBranch.resolve("task", ctx.task)

      assert task == ctx.task
    end

    test "a jobsite: the branch it works on; the head strategy has none", ctx do
      js = "js-#{ctx.id}"
      head = "js-head-#{ctx.id}"

      :ok =
        ProjectionStore.apply_events([
          %{
            event_type: "JobsiteStarted",
            payload: %{
              jobsite_id: js,
              repo_path: ctx.repo,
              strategy: "branch:agent/js",
              branch: "agent/js",
              project_id: ctx.a
            }
          },
          %{
            event_type: "JobsiteStarted",
            payload: %{
              jobsite_id: head,
              repo_path: ctx.repo,
              strategy: "head",
              project_id: ctx.a
            }
          }
        ])

      assert {:ok, "agent/js"} = SourceBranch.resolve("jobsite", js)

      assert {:error, {:source_branch_unknown, "jobsite", ^head}} =
               SourceBranch.resolve("jobsite", head)
    end
  end

  describe "ensure_exists/2" do
    test "a local branch of the repository is there; a tag, a remote ref and a stranger are not",
         %{tmp_dir: tmp} do
      repo = Path.join(tmp, "real")
      File.mkdir_p!(repo)
      git!(repo, ["init", "--initial-branch=main", "--quiet"])
      git!(repo, ["config", "user.email", "t@x"])
      git!(repo, ["config", "user.name", "T"])
      File.write!(Path.join(repo, "a"), "a")
      git!(repo, ["add", "."])
      git!(repo, ["commit", "--no-gpg-sign", "-m", "a", "--quiet"])
      git!(repo, ["branch", "agent/x"])
      git!(repo, ["tag", "v1"])
      git!(repo, ["update-ref", "refs/remotes/origin/only-remote", "HEAD"])

      assert :ok = SourceBranch.ensure_exists("agent/x", repo)
      assert :ok = SourceBranch.ensure_exists("main", repo)

      for missing <- ["v1", "origin/only-remote", "only-remote", "agent/gone"] do
        assert {:error, {:source_branch_not_found, ^missing, ^repo}} =
                 SourceBranch.ensure_exists(missing, repo)
      end
    end

    test "a path that is not a repository, or no path at all, has no such branch" do
      # Outside the checkout: the test tmp_dir lives INSIDE this repository, where git would find it.
      plain = Path.join(System.tmp_dir!(), "no-repo-#{System.unique_integer([:positive])}")
      File.mkdir_p!(plain)
      on_exit(fn -> File.rm_rf(plain) end)

      assert {:error, {:source_branch_not_found, "main", ^plain}} =
               SourceBranch.ensure_exists("main", plain)

      assert {:error, {:source_branch_not_found, "main", nil}} =
               SourceBranch.ensure_exists("main", nil)
    end
  end

  defp git!(dir, args) do
    case System.cmd("git", ["-C", dir | args], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      {out, code} -> flunk("git #{Enum.join(args, " ")} failed (#{code}) in #{dir}: #{out}")
    end
  end
end
