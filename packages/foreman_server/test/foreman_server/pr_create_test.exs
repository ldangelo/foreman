defmodule ForemanServer.PrCreateTest do
  @moduledoc """
  "Create PR" (E9-S5): `ForemanServer.PrCreate` and the operator command
  `run.pr.create` that runs it. The `git`/`gh` binaries are replaced by the
  module's own command-runner seam; the event store, aggregate, projections and
  `PrAssociate` are real. The PR is opened, associated and watched - never merged.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{CommandGateway, PrCreate, ProjectionStore}
  alias ForemanServer.TestSupport.PrFixSupport, as: Fix
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support

  @base "main"

  setup do
    test_pid = self()
    pr_url = "https://github.com/acme/widgets/pull/#{System.unique_integer([:positive])}"
    state = %{gh: {pr_url <> "\n", 0}, ahead: "2\n", push: {"", 0}}
    {:ok, script} = Agent.start_link(fn -> state end)

    runner = fn cmd, args, opts ->
      send(test_pid, {:ran, cmd, args, opts})
      reply = Agent.get(script, & &1)

      case {cmd, args} do
        {"git", ["rev-list" | _]} -> {reply.ahead, 0}
        {"git", ["push" | _]} -> reply.push
        {"gh", ["pr", "create" | _]} -> run_gh(reply.gh, test_pid)
        other -> flunk("unexpected command #{inspect(other)}")
      end
    end

    PrCreate.set_command_runner(runner)

    on_exit(fn ->
      PrCreate.clear_command_runner()
      if Process.alive?(script), do: Agent.stop(script)
    end)

    %{script: script, pr_url: pr_url}
  end

  # A gh reply of `{:hold, reply}` blocks the call until the test releases it.
  defp run_gh({:hold, reply}, test_pid) do
    send(test_pid, {:gh_waiting, self()})

    receive do
      :release -> reply
    after
      10_000 -> flunk("gh was never released")
    end
  end

  defp run_gh(reply, _test_pid), do: reply

  defp script!(script, key, value), do: Agent.update(script, &Map.put(&1, key, value))

  # A completed run on a registered project whose agent worktree branch exists.
  defp thread!(opts \\ []) do
    repo = Fix.git_repo!()
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    project_id = "project-prc-#{token}"

    :ok =
      ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: project_id, path: repo}}
      ])

    run = Support.start_run!(project_id: project_id, complete: true)
    branch = "foreman/#{run.run_id}/implement"

    events =
      [
        %{
          event_type: "TaskCreated",
          payload: %{
            task_id: run.task_id,
            project_id: project_id,
            title: "Add widgets",
            description: "Adds the widget screen",
            status: "open",
            task_type: "implement"
          }
        }
      ] ++
        if(Keyword.get(opts, :base, true),
          do: [
            %{
              event_type: "RunBaseBranchRecorded",
              payload: %{run_id: run.run_id, base_branch: @base}
            }
          ],
          else: []
        ) ++
        if(Keyword.get(opts, :worktree, true),
          do: [
            %{
              event_type: "WorktreeCreated",
              payload: %{
                operation_id: "wt-#{run.run_id}-implement",
                project_id: project_id,
                run_id: run.run_id,
                phase_id: "implement",
                repo_path: repo,
                worktree_path: "/gone/#{token}",
                branch: branch,
                base_ref: @base,
                cleanup: "remove"
              }
            }
          ],
          else: []
        )

    :ok = ProjectionStore.apply_events(events)
    Map.merge(run, %{repo: repo, branch: branch})
  end

  defp ran(cmd, pattern_fun \\ fn _ -> true end) do
    Stream.repeatedly(fn ->
      receive do
        {:ran, ^cmd, args, opts} -> {args, opts}
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
    |> Enum.filter(fn {args, _} -> pattern_fun.(args) end)
  end

  defp create_command(run_id, payload \\ %{}) do
    %{
      type: "run.pr.create",
      command_id: "create-#{run_id}-#{System.unique_integer([:positive])}",
      aggregate_id: "run:#{run_id}",
      payload: Map.merge(%{run_id: run_id}, payload)
    }
  end

  describe "PrCreate.execute/1" do
    test "publishes the run branch, opens the PR from the task, and associates it", %{
      pr_url: pr_url
    } do
      t = thread!()

      assert {:ok, payload} = PrCreate.execute(t.run_id)

      assert payload.pr_url == pr_url
      assert payload.head_branch == t.branch
      assert payload.base_branch == @base
      assert payload.project_id == t.project_id
      assert payload.task_id == t.task_id

      assert {:ok, %{pr_url: ^pr_url}} = ProjectionStore.pr_association(t.run_id)

      assert [{push_args, push_opts}] = ran("git", &(hd(&1) == "push"))
      assert push_args == ["push", "-u", "origin", t.branch]
      # git and gh run from the project checkout: the run worktree is gone
      assert push_opts[:cd] == t.repo

      assert [{gh_args, gh_opts}] = ran("gh")
      assert gh_opts[:cd] == t.repo
      assert Enum.chunk_every(gh_args, 2, 1, :discard) |> Enum.member?(["--head", t.branch])
      assert Enum.chunk_every(gh_args, 2, 1, :discard) |> Enum.member?(["--base", @base])
      assert Enum.chunk_every(gh_args, 2, 1, :discard) |> Enum.member?(["--title", "Add widgets"])
    end

    test "a second Create PR for the same run is refused and opens nothing", %{pr_url: pr_url} do
      t = thread!()
      assert {:ok, _} = PrCreate.execute(t.run_id)
      _ = {ran("gh"), ran("git")}

      assert {:error, {:pr_already_associated, ^pr_url}} = PrCreate.execute(t.run_id)
      assert ran("gh") == []
      assert ran("git") == []
    end

    test "concurrent Create PR calls for one run open exactly one PR", %{script: script} do
      t = thread!()
      script!(script, :gh, {:hold, Agent.get(script, & &1.gh)})

      tasks = for _ <- 1..2, do: Task.async(fn -> PrCreate.execute(t.run_id) end)

      assert_receive {:gh_waiting, gh_pid}, 10_000
      # the second caller is parked on the per-run lock: its gh never starts
      refute_receive {:gh_waiting, _}, 300
      send(gh_pid, :release)

      results = Task.await_many(tasks, 15_000)
      assert [{:ok, _}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert [{:error, {:pr_already_associated, _}}] = Enum.reject(results, &match?({:ok, _}, &1))
      assert length(ran("gh")) == 1
    end

    test "a PR that already exists for the branch is adopted, not duplicated", %{script: script} do
      t = thread!()
      existing = "https://github.com/acme/widgets/pull/7"

      script!(script, :gh, {
        "a pull request for branch \"#{t.branch}\" into branch \"main\" already exists:\n#{existing}\n",
        1
      })

      assert {:ok, %{pr_url: ^existing}} = PrCreate.execute(t.run_id)
      assert {:ok, %{pr_url: ^existing}} = ProjectionStore.pr_association(t.run_id)
    end

    test "any other gh failure is a typed error and records no association", %{script: script} do
      t = thread!()
      script!(script, :gh, {"GraphQL: boom", 1})

      assert {:error, {:gh_pr_create_failed, 1, "GraphQL: boom"}} = PrCreate.execute(t.run_id)
      assert {:error, :not_found} = ProjectionStore.pr_association(t.run_id)
    end

    test "a failed push stops before gh is called", %{script: script} do
      t = thread!()
      script!(script, :push, {"rejected", 1})

      assert {:error, {:git_push_failed, 1, "rejected"}} = PrCreate.execute(t.run_id)
      assert ran("gh") == []
    end

    test "a branch with no commits beyond the base proposes nothing", %{script: script} do
      t = thread!()
      script!(script, :ahead, "0\n")

      assert {:error, :no_commits_to_propose} = PrCreate.execute(t.run_id)
      assert ran("gh") == []
      assert ran("git", &(hd(&1) == "push")) == []
      assert {:error, :not_found} = ProjectionStore.pr_association(t.run_id)
    end

    test "refusals are typed: unknown run, jobsite thread, missing branch/base/project, bad id" do
      assert {:error, {:run_not_found, "run-nope"}} = PrCreate.execute("run-nope")

      assert {:error, {:unsupported_subject, :jobsite, "jobsite:j1"}} =
               PrCreate.execute("jobsite:j1")

      assert {:error, {:missing_or_invalid, :run_id}} = PrCreate.execute(nil)
      assert {:error, {:missing_or_invalid, :run_id}} = PrCreate.execute("")

      no_branch = thread!(worktree: false)
      assert {:error, :no_head_branch} = PrCreate.execute(no_branch.run_id)

      no_base = thread!(base: false)
      assert {:error, :no_base_branch} = PrCreate.execute(no_base.run_id)

      orphan = thread!()

      :ok =
        ProjectionStore.apply_events([
          %{event_type: "ProjectRegistered", payload: %{project_id: orphan.project_id, path: nil}}
        ])

      project_id = orphan.project_id
      assert {:error, {:project_unresolved, ^project_id}} = PrCreate.execute(orphan.run_id)

      # none of the refusals ran a command
      assert ran("gh") == []
      assert ran("git") == []
    end
  end

  describe "run.pr.create command" do
    test "opens, records PrCreated, starts the watch - and never merges", %{pr_url: pr_url} do
      t = thread!()

      assert {:ok, _spec} = CommandGateway.dispatch_operator(create_command(t.run_id))

      types = Support.run_event_types(t.run_id)
      assert "PrCreated" in types
      refute Enum.any?(types, &(&1 in ["PrMerged", "PrMergeRequested"]))

      created = t.run_id |> Support.run_events() |> Enum.find(&(&1.event_type == "PrCreated"))
      assert created.data.pr_url == pr_url
      assert created.data.head_branch == t.branch
      assert created.data.base_branch == @base

      assert {:ok, %{pr_url: ^pr_url}} = ProjectionStore.pr_association(t.run_id)

      # nothing in the whole sequence is a merge
      refute Enum.any?(ran("gh"), fn {args, _} -> "merge" in args end)
    end

    test "a client cannot retarget the PR: the payload is rebuilt from the run", %{pr_url: pr_url} do
      t = thread!()

      forged = %{
        pr_url: "https://github.com/evil/repo/pull/1",
        head_branch: "attacker/branch",
        base_branch: "release",
        project_id: "someone-elses-project"
      }

      assert {:ok, _} = CommandGateway.dispatch_operator(create_command(t.run_id, forged))

      created = t.run_id |> Support.run_events() |> Enum.find(&(&1.event_type == "PrCreated"))
      assert created.data.pr_url == pr_url
      assert created.data.head_branch == t.branch
      assert created.data.base_branch == @base
      assert created.data.project_id == t.project_id
    end

    test "repeating the command is refused and opens no second PR", %{pr_url: pr_url} do
      t = thread!()
      assert {:ok, _} = CommandGateway.dispatch_operator(create_command(t.run_id))
      _ = {ran("gh"), ran("git")}

      assert {:error, {:pr_already_associated, ^pr_url}} =
               CommandGateway.dispatch_operator(create_command(t.run_id))

      assert ran("gh") == []
      assert Enum.count(Support.run_event_types(t.run_id), &(&1 == "PrCreated")) == 1
    end

    test "typed errors reach the caller and append nothing", %{script: script} do
      t = thread!()
      script!(script, :ahead, "0\n")

      assert {:error, :no_commits_to_propose} =
               CommandGateway.dispatch_operator(create_command(t.run_id))

      refute "PrCreated" in Support.run_event_types(t.run_id)

      assert {:error, {:run_not_found, "run-ghost"}} =
               CommandGateway.dispatch_operator(create_command("run-ghost"))
    end
  end
end
