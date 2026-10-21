defmodule ForemanServer.RunPrMergeTest do
  # The operator `merge_approve` / `run.pr.merge` path, end to end through the real
  # gateway, Run aggregate and event store. Only `gh` is stubbed. These pin the
  # properties that make exposing a merge command safe: nothing merges before a
  # human approves, what merges is exactly the head that was approved, and a
  # client cannot steer the merge by supplying its own payload.
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.RunPrMerge
  alias ForemanServer.Workflow.MergeGate

  @pr_url "https://github.com/acme/repo/pull/42"
  @approved_sha "approvedsha111"
  @approver "github:ldangelo"

  setup do
    MergeGate.clear()

    run_id = "run-pr-merge-#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: "project-pr-merge", task_id: "task-pr-merge"}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok =
      ForemanServer.ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pr.ready",
        command_id: "ready-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{
          run_id: run_id,
          project_id: "project-pr-merge",
          task_id: "task-pr-merge",
          pr_url: @pr_url,
          branch_name: "foreman/task-pr-merge/run",
          head_sha: @approved_sha,
          base_branch: "main"
        }
      })

    on_exit(&RunPrMerge.clear_command_runner/0)

    %{run_id: run_id}
  end

  # Stubs `gh`: `pr view` answers with `view`, `pr merge` with `merge_exit`. Every
  # call is sent to the test process so tests can assert what was (not) run.
  defp stub_gh(opts \\ []) do
    view = Keyword.get(opts, :view, %{})
    merge_result = Keyword.get(opts, :merge, {"", 0})
    test_pid = self()

    RunPrMerge.set_command_runner(fn "gh", args, _opts ->
      send(test_pid, {:gh, args})

      case args do
        ["pr", "view" | _] ->
          body =
            Map.merge(
              %{
                "state" => "OPEN",
                "mergeable" => "MERGEABLE",
                "headRefOid" => @approved_sha,
                "headRefName" => "foreman/task-pr-merge/run",
                "baseRefName" => "main"
              },
              view
            )

          {Jason.encode!(body), 0}

        ["pr", "merge" | _] ->
          merge_result
      end
    end)
  end

  defp approve(run_id, overrides \\ %{}) do
    CommandGateway.dispatch_operator(%{
      command_id: "approve-#{System.unique_integer([:positive])}",
      type: "merge_approve",
      aggregate_id: "run:#{run_id}",
      payload:
        Map.merge(%{run_id: run_id, approver: "leo", approver_identity: @approver}, overrides)
    })
  end

  defp merge(run_id, payload_overrides \\ %{}) do
    CommandGateway.dispatch_operator(%{
      command_id: "merge-#{System.unique_integer([:positive])}",
      type: "run.pr.merge",
      aggregate_id: "run:#{run_id}",
      payload: Map.merge(%{run_id: run_id}, payload_overrides)
    })
  end

  defp events(run_id, type) do
    {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
    Enum.filter(events, &(&1.event_type == type))
  end

  defp gh_merge_calls do
    receive_all([])
    |> Enum.filter(&match?(["pr", "merge" | _], &1))
  end

  defp receive_all(acc) do
    receive do
      {:gh, args} -> receive_all([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  describe "before approval" do
    test "an unapproved run is refused and gh is never called", %{run_id: run_id} do
      stub_gh()

      assert {:error, :pr_not_acceptable} = merge(run_id)

      assert receive_all([]) == [], "nothing may reach GitHub before a human approves"
      assert events(run_id, "PrMerged") == []
    end

    test "an unauthorized approver does not open the gate", %{run_id: run_id} do
      stub_gh()

      assert {:error, :unauthorized_approver} =
               approve(run_id, %{approver_identity: "github:someone-else"})

      assert {:error, :pr_not_acceptable} = merge(run_id)
      assert receive_all([]) == []
    end

    test "an approval missing the approver is a typed error, not nil", %{run_id: run_id} do
      assert {:error, {:missing_or_invalid, :approver}} =
               approve(run_id, %{approver: nil})

      assert {:error, {:missing_or_invalid, :approver_identity}} =
               approve(run_id, %{approver_identity: nil})
    end
  end

  describe "after approval" do
    setup %{run_id: run_id} do
      {:ok, _} = approve(run_id)
      :ok
    end

    test "squash-merges the approved head and records PrMerged", %{run_id: run_id} do
      stub_gh()

      assert {:ok, _} = merge(run_id)

      assert [["pr", "merge", @pr_url, "--squash", "--match-head-commit", @approved_sha]] =
               gh_merge_calls()

      assert [_one] = events(run_id, "PrMerged")
    end

    test "a head that moved since approval is refused and not merged", %{run_id: run_id} do
      stub_gh(view: %{"headRefOid" => "pushedafterapproval"})

      assert {:error, {:head_moved_since_approval, @approved_sha, "pushedafterapproval"}} =
               merge(run_id)

      assert gh_merge_calls() == []
      assert events(run_id, "PrMerged") == []
    end

    test "an already-merged PR is recorded without merging again", %{run_id: run_id} do
      stub_gh(view: %{"state" => "MERGED", "mergeable" => "UNKNOWN"})

      assert {:ok, _} = merge(run_id)

      assert gh_merge_calls() == [], "a retry after gh succeeded must not call gh merge again"
      assert [_one] = events(run_id, "PrMerged")
    end

    test "a PR merged at some other head is not recorded as this approval's merge", %{
      run_id: run_id
    } do
      stub_gh(
        view: %{
          "state" => "MERGED",
          "mergeable" => "UNKNOWN",
          "headRefOid" => "pushedafterapproval"
        }
      )

      assert {:error, {:head_moved_since_approval, @approved_sha, "pushedafterapproval"}} =
               merge(run_id)

      assert gh_merge_calls() == []
      assert events(run_id, "PrMerged") == []
    end

    test "a closed or conflicted PR is refused with its own reason", %{run_id: run_id} do
      stub_gh(view: %{"state" => "CLOSED", "mergeable" => "UNKNOWN"})
      assert {:error, {:pr_closed, @pr_url}} = merge(run_id)

      stub_gh(view: %{"mergeable" => "CONFLICTING"})
      assert {:error, {:pr_conflicted, @pr_url}} = merge(run_id)

      assert gh_merge_calls() == []
    end

    test "a gh merge failure surfaces gh's message and records nothing", %{run_id: run_id} do
      stub_gh(merge: {"Pull request is not mergeable\n", 1})

      assert {:error, {:gh_merge_failed, 1, "Pull request is not mergeable"}} = merge(run_id)
      assert events(run_id, "PrMerged") == []
    end

    test "the caller's payload cannot retarget the merge", %{run_id: run_id} do
      stub_gh()

      assert {:ok, _} =
               merge(run_id, %{
                 pr_url: "https://github.com/evil/repo/pull/1",
                 head_sha: "evilsha",
                 branch_name: "evil"
               })

      assert [["pr", "merge", @pr_url, "--squash", "--match-head-commit", @approved_sha]] =
               gh_merge_calls()

      assert [event] = events(run_id, "PrMerged")
      assert event.data["pr_url"] == @pr_url or event.data[:pr_url] == @pr_url
    end
  end
end
