defmodule ForemanServer.PrCreateTest do
  @moduledoc """
  "Create PR" (E9-S5): `ForemanServer.PrCreate` and the operator command
  `run.pr.create` that runs it. The `git`/`gh` binaries are replaced by the
  module's own command-runner seam; the event store, aggregate, projections and
  `PrAssociate` are real. The PR is opened, associated and watched - never merged.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.{
    Aggregate,
    CommandGateway,
    CommandRouter,
    PrCreate,
    PrObservation,
    ProjectionStore,
    RunPrMerge
  }

  alias ForemanServer.Aggregates.Run
  alias ForemanServer.TestSupport.PrFixSupport, as: Fix
  alias ForemanServer.TestSupport.PrWatchSupport, as: Support
  alias ForemanServer.Idempotency.{Effect, KeyStore}
  alias ForemanServer.Idempotency.Reconcilers.BranchPush
  alias ForemanServer.Idempotency.Reconcilers.PrCreate, as: CreateEffect
  alias ForemanServer.TelemetryTest.Handler
  alias ForemanServer.TestSupport.{EffectWorld, KeyStoreReset}
  alias ForemanServerWeb.MCP.Tools.Doctor

  @base "main"
  @head_sha "0123456789abcdef0123456789abcdef01234567"

  setup do
    test_pid = self()
    pr_url = "https://github.com/acme/widgets/pull/#{System.unique_integer([:positive])}"

    state = %{
      gh: {pr_url <> "\n", 0},
      ahead: "2\n",
      push: {"", 0},
      rev: {@head_sha <> "\n", 0},
      list: [{"[]\n", 0}]
    }

    {:ok, script} = Agent.start_link(fn -> state end)

    runner = fn cmd, args, opts ->
      send(test_pid, {:ran, cmd, args, opts})
      reply = Agent.get(script, & &1)

      case {cmd, args} do
        {"git", ["rev-list" | _]} -> {reply.ahead, 0}
        # The push's intent reads the branch tip and the remote head before pushing; the
        # gate signal's `rev-parse` (`script.rev`) is a different command.
        {"git", ["rev-parse", "--verify", "refs/heads/" <> _]} -> {@head_sha <> "\n", 0}
        {"git", ["ls-remote" | _]} -> {"", 0}
        {"git", ["rev-parse" | _]} -> reply.rev
        {"git", ["push" | _]} -> reply.push
        {"gh", ["pr", "list" | _]} -> next_list(script)
        {"gh", ["pr", "create" | _]} -> run_gh(reply.gh, test_pid)
        other -> flunk("unexpected command #{inspect(other)}")
      end
    end

    PrCreate.set_command_runner(runner)

    on_exit(fn ->
      PrCreate.clear_command_runner()
      RunPrMerge.clear_command_runner()
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

  # The answers of `gh pr list`, one per call; the last one stays.
  defp next_list(script) do
    Agent.get_and_update(script, fn
      %{list: [only]} = state -> {only, state}
      %{list: [first | rest]} = state -> {first, %{state | list: rest}}
    end)
  end

  # What `gh pr list` answers for one PR: this repository's open PR whose head is the pushed tip,
  # unless `attrs` say otherwise.
  defp pr_list(url, attrs \\ %{}) do
    pr =
      Map.merge(
        %{
          "url" => url,
          "number" => 7,
          "state" => "OPEN",
          "headRefOid" => @head_sha,
          "isCrossRepository" => false
        },
        attrs
      )

    {Jason.encode!([pr]), 0}
  end

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

  # Every append to `stream` is refused by the real `CommandRouter` from now on: it answers an
  # append to a quarantined aggregate with an error, and the actor hands that error to the
  # caller like any other failed append. `release!/1` lifts it again.
  defp quarantine!(stream) do
    :sys.replace_state(CommandRouter, fn state ->
      update_in(state.quarantined_aggregates, &MapSet.put(&1, stream))
    end)
  end

  defp release!(stream) do
    :sys.replace_state(CommandRouter, fn state ->
      update_in(state.quarantined_aggregates, &MapSet.delete(&1, stream))
    end)
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

      # GitHub is asked for the PR first, in the checkout; then the PR is created.
      assert [{list_args, list_opts}, {gh_args, gh_opts}] = ran("gh")
      assert ["pr", "list" | _] = list_args
      assert list_opts[:cd] == t.repo
      assert gh_opts[:cd] == t.repo
      assert Enum.chunk_every(gh_args, 2, 1, :discard) |> Enum.member?(["--head", t.branch])
      assert Enum.chunk_every(gh_args, 2, 1, :discard) |> Enum.member?(["--base", @base])
      assert Enum.chunk_every(gh_args, 2, 1, :discard) |> Enum.member?(["--title", "Add widgets"])
    end

    test "a second execute before PrCreated was recorded resumes the open PR and opens nothing",
         %{pr_url: pr_url} do
      t = thread!()
      assert {:ok, _} = PrCreate.execute(t.run_id)
      _ = {ran("gh"), ran("git")}

      assert {:ok, %{pr_url: ^pr_url, head_branch: head}} = PrCreate.execute(t.run_id)
      assert head == t.branch
      assert ran("gh") == []
      # only the head of the gate signal is resolved again: nothing is pushed or counted
      assert [{["rev-parse" | _], _opts}] = ran("git")
      # ...and the repeated signal is the same deterministic command: still ONE PrReady
      assert Enum.count(Support.run_event_types(t.run_id), &(&1 == "PrReady")) == 1
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
      assert [{:ok, %{pr_url: url}}, {:ok, %{pr_url: url}}] = results
      assert [{["pr", "list" | _], _}, {["pr", "create" | _], _}] = ran("gh")
    end

    test "a PR GitHub already has for the branch is adopted, not duplicated: nothing is pushed or created",
         %{script: script} do
      t = thread!()
      existing = "https://github.com/acme/widgets/pull/7"
      script!(script, :list, [pr_list(existing)])

      assert {:ok, %{pr_url: ^existing}} = PrCreate.execute(t.run_id)
      assert {:ok, %{pr_url: ^existing}} = ProjectionStore.pr_association(t.run_id)

      assert [{["pr", "list" | _], _opts}] = ran("gh")
      assert ran("git", &(hd(&1) == "push")) == []
    end

    test "a PR that appears between the lookup and gh pr create is adopted from the second lookup",
         %{script: script} do
      t = thread!()
      existing = "https://github.com/acme/widgets/pull/7"
      script!(script, :list, [{"[]\n", 0}, pr_list(existing)])

      script!(script, :gh, {
        "a pull request for branch \"#{t.branch}\" into branch \"main\" already exists:\n#{existing}\n",
        1
      })

      assert {:ok, %{pr_url: ^existing}} = PrCreate.execute(t.run_id)
      assert {:ok, %{pr_url: ^existing}} = ProjectionStore.pr_association(t.run_id)

      assert [["pr", "list" | _], ["pr", "create" | _], ["pr", "list" | _]] =
               for({args, _opts} <- ran("gh"), do: args)
    end

    test "gh's text is never read: a create that names a PR GitHub does not list is an error and associates nothing",
         %{script: script} do
      t = thread!()

      script!(script, :gh, {
        "a pull request for branch \"#{t.branch}\" into branch \"main\" already exists:\nhttps://github.com/acme/widgets/pull/7\n",
        1
      })

      assert {:error, {:gh_pr_create_failed, 1, text}} = PrCreate.execute(t.run_id)
      assert text =~ "already exists"
      assert {:error, :not_found} = ProjectionStore.pr_association(t.run_id)
    end

    test "a PR of the branch with another head is refused with both heads, and nothing is associated",
         %{script: script} do
      t = thread!()
      existing = "https://github.com/acme/widgets/pull/7"
      other = String.duplicate("b", 40)
      script!(script, :list, [pr_list(existing, %{"headRefOid" => other})])

      script!(script, :gh, {
        "a pull request for branch \"#{t.branch}\" into branch \"main\" already exists:\n#{existing}\n",
        1
      })

      assert {:error, {:pr_lookup_mismatch, ^existing, @head_sha, ^other}} =
               PrCreate.execute(t.run_id)

      assert {:error, :not_found} = ProjectionStore.pr_association(t.run_id)
    end

    test "a fork's PR of the same branch name is not adopted: the PR opened is the run's own",
         %{script: script, pr_url: pr_url} do
      t = thread!()
      fork = "https://github.com/acme/widgets/pull/9"
      script!(script, :list, [pr_list(fork, %{"isCrossRepository" => true})])

      assert {:ok, %{pr_url: ^pr_url}} = PrCreate.execute(t.run_id)
      assert {:ok, %{pr_url: ^pr_url}} = ProjectionStore.pr_association(t.run_id)
      refute pr_url == fork
    end

    test "any other gh failure is a typed error and records no association", %{script: script} do
      t = thread!()
      script!(script, :gh, {"GraphQL: boom", 1})

      assert {:error, {:gh_pr_create_failed, 1, "GraphQL: boom"}} = PrCreate.execute(t.run_id)
      assert {:error, :not_found} = ProjectionStore.pr_association(t.run_id)
    end

    test "a failed push stops before gh pr create is called", %{script: script} do
      t = thread!()
      script!(script, :push, {"rejected", 1})

      assert {:error, {:git_push_failed, 1, "rejected"}} = PrCreate.execute(t.run_id)
      # GitHub was asked for the PR before the push, and never asked to create one.
      assert [{["pr", "list" | _], _opts}] = ran("gh")
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

    test "a retry after the dispatch failed records PrCreated for the already-open PR",
         %{pr_url: pr_url} do
      t = thread!()
      # the PR was opened and associated, but the command never reached the aggregate
      assert {:ok, _} = PrCreate.execute(t.run_id)
      refute "PrCreated" in Support.run_event_types(t.run_id)
      _ = {ran("gh"), ran("git")}

      assert {:ok, _} = CommandGateway.dispatch_operator(create_command(t.run_id))

      assert Enum.count(Support.run_event_types(t.run_id), &(&1 == "PrCreated")) == 1
      created = t.run_id |> Support.run_events() |> Enum.find(&(&1.event_type == "PrCreated"))
      assert created.data.pr_url == pr_url
      assert ran("gh") == []

      assert {:error, {:pr_already_associated, ^pr_url}} =
               CommandGateway.dispatch_operator(create_command(t.run_id))
    end

    test "a PrCreated append that fails is retryable: the open PR is resumed, never refused",
         %{pr_url: pr_url} do
      t = thread!()
      stream = "run:#{t.run_id}"

      # the first click got as far as opening, associating and gating the PR ...
      assert {:ok, _} = PrCreate.execute(t.run_id)
      _ = {ran("gh"), ran("git")}

      # ... and then the append of its PrCreated fails inside the real router
      on_exit(fn -> release!(stream) end)
      quarantine!(stream)

      assert {:error, :projection_recovery_failed} =
               CommandGateway.dispatch_operator(create_command(t.run_id))

      refute "PrCreated" in Support.run_event_types(t.run_id)
      assert {:ok, %{pr_url: ^pr_url}} = ProjectionStore.pr_association(t.run_id)

      release!(stream)
      assert {:ok, _} = CommandGateway.dispatch_operator(create_command(t.run_id))

      assert [%{data: %{pr_url: ^pr_url}}] =
               t.run_id |> Support.run_events() |> Enum.filter(&(&1.event_type == "PrCreated"))

      # the retry reused the open PR: no second push or PR
      assert ran("gh") == []
      assert ran("git", &(hd(&1) == "push")) == []

      assert {:error, {:pr_already_associated, ^pr_url}} =
               CommandGateway.dispatch_operator(create_command(t.run_id))
    end

    test "the PrCreated command id is derived from the run and the PR, so a replay appends nothing",
         %{pr_url: pr_url} do
      t = thread!()
      assert {:ok, _} = CommandGateway.dispatch_operator(create_command(t.run_id))

      assert [%{data: data}] =
               t.run_id |> Support.run_events() |> Enum.filter(&(&1.event_type == "PrCreated"))

      # what a retry (or a concurrent second click) resolves to for this PR: the same command
      assert {:ok, _} =
               CommandGateway.dispatch_system(%{
                 type: "run.pr.create",
                 command_id: "pr_create:#{t.run_id}:#{PrObservation.url_hash(pr_url)}",
                 aggregate_id: "run:#{t.run_id}",
                 payload:
                   Map.take(data, [
                     :run_id,
                     :project_id,
                     :task_id,
                     :pr_url,
                     :head_branch,
                     :base_branch
                   ])
               })

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

  describe "the merge gate" do
    test "the PR Create PR opens is held for approval: PrReady names the PR, branch, head and base",
         %{pr_url: pr_url} do
      t = thread!()

      assert {:ok, _spec} = CommandGateway.dispatch_operator(create_command(t.run_id))

      assert [ready] =
               t.run_id |> Support.run_events() |> Enum.filter(&(&1.event_type == "PrReady"))

      assert ready.data.pr_url == pr_url
      assert ready.data.branch_name == t.branch
      assert ready.data.head_sha == @head_sha
      assert ready.data.base_branch == @base
      assert ready.data.project_id == t.project_id
      assert ready.data.task_id == t.task_id

      {state, _version} = Aggregate.load(Run, "run:#{t.run_id}")
      assert Run.merge_gate(state) == :pending

      # the head is resolved from the pushed branch, in the project checkout (the push's own
      # intent read the branch tip too, as `refs/heads/<branch>`: a different command)
      assert [{["rev-parse", "--verify", rev], opts}] =
               ran(
                 "git",
                 &(hd(&1) == "rev-parse" and String.ends_with?(List.last(&1), "^{commit}"))
               )

      assert rev == t.branch <> "^{commit}"
      assert opts[:cd] == t.repo
    end

    test "the operator can approve and merge the PR it opened, pinned to its head",
         %{pr_url: pr_url} do
      t = thread!()
      assert {:ok, _} = CommandGateway.dispatch_operator(create_command(t.run_id))

      # `merge_approve` must name the head the operator reviewed (foreman-ehxy6): the head the
      # PR's own PrReady recorded, which the server then reads back from GitHub before approving.
      assert [ready] =
               t.run_id |> Support.run_events() |> Enum.filter(&(&1.event_type == "PrReady"))

      approved_head = ready.data.head_sha
      assert approved_head == @head_sha

      test_pid = self()
      branch = t.branch

      RunPrMerge.set_command_runner(fn "gh", args, _opts ->
        send(test_pid, {:merge_gh, args})

        case args do
          ["pr", "view" | _] ->
            view = %{
              "state" => "OPEN",
              "mergeable" => "MERGEABLE",
              "headRefOid" => approved_head,
              "headRefName" => branch,
              "baseRefName" => @base
            }

            {Jason.encode!(view), 0}

          ["pr", "merge" | _] ->
            {"", 0}
        end
      end)

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "approve-#{t.run_id}",
                 type: "merge_approve",
                 aggregate_id: "run:#{t.run_id}",
                 payload: %{
                   run_id: t.run_id,
                   approver: "leo",
                   approver_identity: "github:ldangelo",
                   head_sha: approved_head
                 }
               })

      # the approval was checked against the live PR head, not trusted
      assert_received {:merge_gh, ["pr", "view" | _]}

      assert {:ok, _} =
               CommandGateway.dispatch_operator(%{
                 command_id: "merge-#{t.run_id}",
                 type: "run.pr.merge",
                 aggregate_id: "run:#{t.run_id}",
                 payload: %{run_id: t.run_id}
               })

      assert_received {:merge_gh,
                       ["pr", "merge", ^pr_url, "--squash", "--match-head-commit", ^approved_head]}

      assert "PrMerged" in Support.run_event_types(t.run_id)
    end

    test "a failed gate signal is an error, never a silent success, and the retry signals it again",
         %{script: script} do
      t = thread!()
      script!(script, :rev, {"fatal: Needed a single revision", 128})

      assert {:error,
              {:pr_ready_signal_failed,
               {:unresolvable_revision, "fatal: Needed a single revision"}}} =
               CommandGateway.dispatch_operator(create_command(t.run_id))

      # the PR is open and associated, but neither the gate nor PrCreated was recorded
      assert {:ok, _} = ProjectionStore.pr_association(t.run_id)
      refute "PrReady" in Support.run_event_types(t.run_id)
      refute "PrCreated" in Support.run_event_types(t.run_id)

      script!(script, :rev, {@head_sha <> "\n", 0})
      _ = {ran("gh"), ran("git")}

      assert {:ok, _} = CommandGateway.dispatch_operator(create_command(t.run_id))

      types = Support.run_event_types(t.run_id)
      assert Enum.count(types, &(&1 == "PrReady")) == 1
      assert Enum.count(types, &(&1 == "PrCreated")) == 1
      # the retry resumed the open PR: no second push or PR
      assert ran("gh") == []
      assert ran("git", &(hd(&1) == "push")) == []
    end
  end

  describe "the push and the PR create are keyed effects (TRD-013)" do
    @terminal_event [:foreman_server, :workflow, :boot_reconciliation, :effect_on_terminal_run]

    setup do
      KeyStoreReset.reset!()
      {handler_id, ref} = Handler.attach_event_handlers(self(), [@terminal_event])

      on_exit(fn ->
        :telemetry.detach(handler_id)
        KeyStoreReset.reset!()
      end)

      %{ref: ref}
    end

    # A thread whose project checkout is a real repository with a bare origin and the run
    # branch, behind the scripted GitHub (`PrCreate.set_command_runner/1` reaches AutoPR).
    defp real_thread!(world) do
      t = thread!()
      fx = EffectWorld.adopt!(t.repo, t.branch)
      PrCreate.set_command_runner(EffectWorld.runner(world))
      {t, fx}
    end

    test "the operator path runs both under keys that carry the project checkout as cwd" do
      t = thread!()

      assert {:ok, _payload} = PrCreate.execute(t.run_id)

      assert {:ok, %{status: :completed, metadata: push}} =
               KeyStore.get(BranchPush.key(t.run_id, t.branch))

      assert %{
               "cwd" => cwd,
               "head_branch" => head,
               "pre_push_remote_sha" => nil,
               "pushed_local_sha" => @head_sha
             } = push

      assert {cwd, head} == {t.repo, t.branch}

      assert {:ok, %{status: :completed, metadata: create}} =
               KeyStore.get(CreateEffect.key(t.run_id, t.branch, @base))

      assert %{"cwd" => ^cwd, "head_branch" => ^head, "base_branch" => @base} = create
    end

    test "a crash after gh pr create made the PR: the sweep finds it and nothing more is created",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, _fx} = real_thread!(world)
      key = CreateEffect.key(t.run_id, t.branch, @base)

      EffectWorld.crash!(world, :create, :after, fn -> PrCreate.execute(t.run_id) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert EffectWorld.executed(world, :create) == 1

      EffectWorld.sweep(world)

      # The operator's run is completed, so the sweep cannot block it: it reports the verdict.
      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{
                        run_id: run_id,
                        status: "completed",
                        effect_class: "pr_create",
                        effect_verdict: "done",
                        reason: "effect_already_done"
                      }}

      assert run_id == t.run_id
      assert {:ok, :ambiguous} = KeyStore.status(key)
      assert EffectWorld.executed(world, :create) == 1
      assert length(EffectWorld.prs(world)) == 1
    end

    test "a crash before gh pr create ran: the sweep reports it not done and the retry creates it once",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, _fx} = real_thread!(world)
      key = CreateEffect.key(t.run_id, t.branch, @base)

      EffectWorld.crash!(world, :create, :before, fn -> PrCreate.execute(t.run_id) end)
      assert EffectWorld.executed(world, :create) == 0

      EffectWorld.sweep(world)

      assert_receive {@terminal_event, ^ref, _, %{effect_verdict: "not_done", reason: nil}}
      assert EffectWorld.executed(world, :create) == 0

      assert {:ok, %{pr_url: url}} = PrCreate.execute(t.run_id)

      assert [%{"url" => ^url}] = EffectWorld.prs(world)
      assert EffectWorld.executed(world, :create) == 1
      assert {:ok, %{pr_url: ^url}} = ProjectionStore.pr_association(t.run_id)
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "a crash after gh pr create made the PR: once the sweep left its key unresolved, the operator's Create PR adopts the PR through the lookup",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, fx} = real_thread!(world)
      key = CreateEffect.key(t.run_id, t.branch, @base)

      EffectWorld.crash!(world, :create, :after, fn -> PrCreate.execute(t.run_id) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert [%{"url" => url}] = EffectWorld.prs(world)
      # GitHub knows the head of the PR it made: the commit that was pushed.
      :ok =
        EffectWorld.report_pr!(world, url,
          head_sha: EffectWorld.local_tip(fx),
          cross_repository: false
        )

      EffectWorld.sweep(world)

      # The run is completed, so the sweep cannot block it: it marks the key unresolved.
      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{effect_class: "pr_create", effect_verdict: "done"}}

      assert {:ok, %{status: :ambiguous, metadata: marked}} = KeyStore.get(key)
      assert {:ok, _version} = KeyStore.unresolved_version(marked)

      assert {:ok, %{pr_url: ^url}} = PrCreate.execute(t.run_id)

      assert {:ok, %{pr_url: ^url}} = ProjectionStore.pr_association(t.run_id)
      assert EffectWorld.executed(world, :create) == 1
      assert {:ok, %{status: :completed, metadata: settled}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(settled) == :none
    end

    test "a crash after the push reached the remote: the sweep reports it done and nothing more is pushed",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, fx} = real_thread!(world)
      key = BranchPush.key(t.run_id, t.branch)

      EffectWorld.crash!(world, :push, :after, fn -> PrCreate.execute(t.run_id) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert EffectWorld.remote_tip(fx) == EffectWorld.local_tip(fx)

      EffectWorld.sweep(world)

      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{
                        run_id: run_id,
                        status: "completed",
                        effect_class: "branch_push",
                        effect_verdict: "done",
                        reason: "effect_already_done"
                      }}

      assert run_id == t.run_id
      assert {:ok, :ambiguous} = KeyStore.status(key)
      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 0
    end

    test "a crash before the push reached the remote: the sweep reports it not done and the retry pushes once",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, fx} = real_thread!(world)
      key = BranchPush.key(t.run_id, t.branch)

      EffectWorld.crash!(world, :push, :before, fn -> PrCreate.execute(t.run_id) end)
      assert EffectWorld.executed(world, :push) == 0
      assert EffectWorld.remote_tip(fx) == nil

      EffectWorld.sweep(world)

      assert_receive {@terminal_event, ^ref, _,
                      %{effect_class: "branch_push", effect_verdict: "not_done", reason: nil}}

      assert EffectWorld.executed(world, :push) == 0

      assert {:ok, %{pr_url: url}} = PrCreate.execute(t.run_id)

      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.remote_tip(fx) == EffectWorld.local_tip(fx)
      assert [%{"url" => ^url}] = EffectWorld.prs(world)
      assert {:ok, :completed} = KeyStore.status(key)
    end
  end

  describe "the keys of a completed run through the operator's Create PR (TRD-039)" do
    @effect_event [:foreman_server, :workflow, :boot_reconciliation, :effect_reconciled]

    setup do
      KeyStoreReset.reset!()
      {handler_id, ref} = Handler.attach_event_handlers(self(), [@terminal_event, @effect_event])

      on_exit(fn ->
        :telemetry.detach(handler_id)
        KeyStoreReset.reset!()
      end)

      %{ref: ref}
    end

    # The operator's Create PR, as the dashboard button sends it.
    defp create_pr(t), do: CommandGateway.dispatch_operator(create_command(t.run_id))

    defp created_url(t) do
      [created] = t.run_id |> Support.run_events() |> Enum.filter(&(&1.event_type == "PrCreated"))
      created.data.pr_url
    end

    # `EffectWorld` makes `gh pr list` fail (`fail_gh_list!/1`) but cannot make it answer again;
    # the world is an Agent over a map, so GitHub answers again once its flag is cleared.
    defp heal_gh_list!(world), do: Agent.update(world, &%{&1 | list_error?: false})

    # The PR the operator opens on GitHub by hand: this repository's, with the pushed tip.
    defp open_by_hand!(world, t, fx) do
      url = EffectWorld.add_pr!(world, t.branch, @base)

      :ok =
        EffectWorld.report_pr!(world, url,
          head_sha: EffectWorld.local_tip(fx),
          cross_repository: false
        )

      url
    end

    test "not_done: the key is decided, the audit command rejected (audit_failed), and the next Create PR runs gh pr create once",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, _fx} = real_thread!(world)
      key = CreateEffect.key(t.run_id, t.branch, @base)

      EffectWorld.crash!(world, :create, :before, fn -> PrCreate.execute(t.run_id) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert EffectWorld.executed(world, :create) == 0

      # Nobody has decided the key yet.
      assert {:error, {:effect_undecided, ^key}} = create_pr(t)

      EffectWorld.sweep(world)

      assert_receive {@effect_event, ^ref,
                      %{
                        audit_failed: 1,
                        on_terminal_run: 0,
                        retried: 0,
                        blocked: 0,
                        unresolved: 0
                      }, _}

      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{
                        effect_class: "pr_create",
                        effect_verdict: "not_done",
                        reason: nil,
                        status: "completed"
                      }}

      # The rejected audit command appended nothing, and the key is decided all the same.
      refute "RunRecoveryAttempted" in Support.run_event_types(t.run_id)
      assert {:ok, %{status: :ambiguous, metadata: decided}} = KeyStore.get(key)
      assert KeyStore.decision(decided) == :not_done
      assert KeyStore.unresolved_version(decided) == :none

      assert {:ok, _spec} = create_pr(t)

      url = created_url(t)
      assert EffectWorld.executed(world, :create) == 1
      assert [%{"url" => ^url}] = EffectWorld.prs(world)
      assert {:ok, %{pr_url: ^url}} = ProjectionStore.pr_association(t.run_id)
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "done: marked unresolved, block counted on_terminal_run, Effect.run/4 refuses, and Create PR returns GitHub's PR with no gh pr create",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, fx} = real_thread!(world)
      key = CreateEffect.key(t.run_id, t.branch, @base)

      EffectWorld.crash!(world, :create, :after, fn -> PrCreate.execute(t.run_id) end)
      assert {:ok, :started} = KeyStore.status(key)
      assert [%{"url" => url}] = EffectWorld.prs(world)

      :ok =
        EffectWorld.report_pr!(world, url,
          head_sha: EffectWorld.local_tip(fx),
          cross_repository: false
        )

      {_state, version} = Aggregate.load(Run, "run:#{t.run_id}")

      EffectWorld.sweep(world)

      assert_receive {@effect_event, ^ref,
                      %{on_terminal_run: 1, blocked: 0, audit_failed: 0, unresolved: 0}, _}

      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{
                        effect_verdict: "done",
                        reason: "effect_already_done",
                        status: "completed"
                      }}

      assert {:ok, %{status: :ambiguous, metadata: marked}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(marked) == {:ok, version}

      # The effect is refused ...
      meta = CreateEffect.intent(t.run_id, t.branch, @base, t.repo)

      assert {:error, {:effect_unresolved, ^key}} =
               Effect.run(:pr_create, key, fn -> flunk("repeated") end, meta)

      # ... and Create PR still returns the PR GitHub has, without creating another.
      assert {:ok, _spec} = create_pr(t)

      assert created_url(t) == url
      assert EffectWorld.executed(world, :create) == 1
      assert [%{"url" => ^url}] = EffectWorld.prs(world)
      assert {:ok, %{status: :completed, metadata: settled}} = KeyStore.get(key)
      assert KeyStore.unresolved_version(settled) == :none
    end

    test "done with a merged PR the lookup cannot adopt: Create PR is refused effect_unresolved and gh pr create is not run again",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, _fx} = real_thread!(world)
      key = CreateEffect.key(t.run_id, t.branch, @base)

      EffectWorld.crash!(world, :create, :after, fn -> PrCreate.execute(t.run_id) end)
      EffectWorld.merge_prs!(world)

      EffectWorld.sweep(world)

      assert_receive {@effect_event, ^ref, %{on_terminal_run: 1}, _}
      assert {:error, {:effect_unresolved, ^key}} = create_pr(t)

      assert EffectWorld.executed(world, :create) == 1
      assert [_the_merged_pr] = EffectWorld.prs(world)
      assert {:error, :not_found} = ProjectionStore.pr_association(t.run_id)
      assert {:ok, %{status: :ambiguous}} = KeyStore.get(key)
    end

    test "unknown: refused effect_undecided then effect_unresolved, the doctor lists the key, and a PR opened by hand is returned",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, fx} = real_thread!(world)
      key = CreateEffect.key(t.run_id, t.branch, @base)

      EffectWorld.crash!(world, :create, :before, fn -> PrCreate.execute(t.run_id) end)
      EffectWorld.fail_gh_list!(world)

      # The scan has not looked at the key yet: it is undecided, and GitHub cannot say more.
      assert {:error, {:effect_undecided, ^key}} = create_pr(t)

      EffectWorld.sweep(world)

      assert_receive {@effect_event, ^ref, %{on_terminal_run: 1, unresolved: 0}, _}

      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{
                        effect_verdict: "unknown",
                        reason: "effect_outcome_ambiguous",
                        status: "completed"
                      }}

      assert {:error, {:effect_unresolved, ^key}} = create_pr(t)

      run_id = t.run_id
      assert {:ok, entries} = Doctor.unresolved_effect_keys()

      assert %{
               key: ^key,
               class: "pr_create",
               run_id: ^run_id,
               status: "completed",
               key_status: "ambiguous",
               decision: "none"
             } = Enum.find(entries, &(&1.key == key))

      # The operator opens the PR by hand; GitHub answers again and the lookup adopts it.
      url = open_by_hand!(world, t, fx)
      heal_gh_list!(world)

      assert {:ok, _spec} = create_pr(t)

      assert created_url(t) == url
      assert EffectWorld.executed(world, :create) == 0
      assert {:ok, :completed} = KeyStore.status(key)
    end

    test "a done branch_push key stays refused: Create PR names the push key, and a PR opened by hand is returned",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, fx} = real_thread!(world)
      push_key = BranchPush.key(t.run_id, t.branch)

      EffectWorld.crash!(world, :push, :after, fn -> PrCreate.execute(t.run_id) end)
      EffectWorld.sweep(world)

      assert_receive {@terminal_event, ^ref, %{count: 1},
                      %{effect_class: "branch_push", effect_verdict: "done"}}

      assert {:error, {:effect_unresolved, ^push_key}} = create_pr(t)
      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 0

      url = open_by_hand!(world, t, fx)

      assert {:ok, _spec} = create_pr(t)

      assert created_url(t) == url
      assert EffectWorld.executed(world, :push) == 1
      assert EffectWorld.executed(world, :create) == 0
    end

    test "a scan during Create PR marks the key, and the key still ends in the effect's own outcome",
         %{ref: ref} do
      world = EffectWorld.start()
      {t, _fx} = real_thread!(world)
      key = CreateEffect.key(t.run_id, t.branch, @base)
      base_runner = EffectWorld.runner(world)
      test_pid = self()

      # GitHub has made the PR and the `gh pr create` call has not returned: a scan runs now.
      PrCreate.set_command_runner(fn
        "gh", ["pr", "create" | _] = args, opts ->
          result = base_runner.("gh", args, opts)
          EffectWorld.sweep(world)
          send(test_pid, {:in_flight, KeyStore.get(key)})
          result

        cmd, args, opts ->
          base_runner.(cmd, args, opts)
      end)

      assert {:ok, %{pr_url: url}} = PrCreate.execute(t.run_id)

      assert_received {:in_flight, {:ok, %{status: :ambiguous, metadata: marked}}}
      assert {:ok, _version} = KeyStore.unresolved_version(marked)
      assert_receive {@effect_event, ^ref, %{on_terminal_run: 1}, _}

      assert EffectWorld.executed(world, :create) == 1
      assert [%{"url" => ^url}] = EffectWorld.prs(world)
      assert {:ok, :completed} = KeyStore.status(key)
    end
  end
end
