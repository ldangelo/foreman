defmodule ForemanServer.Workflow.MultiRepoMergeFlowTest do
  @moduledoc """
  E12-S6: two PRs of one run (a = the primary, no `repo_id`; b = `repo_id: "b"`)
  are approved and merged independently through the real operator gateway, Run
  aggregate and event store. Only `gh` is stubbed.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.CommandGateway
  alias ForemanServer.RunPrMerge
  alias ForemanServer.Workflow.MergeGate

  @url_a "https://github.com/acme/repo-a/pull/1"
  @url_b "https://github.com/acme/repo-b/pull/2"
  @sha_a "sha-a-approved"
  @sha_b "sha-b-approved"
  @approver "github:ldangelo"

  setup do
    MergeGate.clear()

    run_id = "run-multi-merge-#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: "project-mm", task_id: "task-mm"}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok =
      ForemanServer.ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])

    # a first, b last: a merge that resolved "the last PrReady" would pick b's.
    ready(run_id, nil, @url_a, @sha_a)
    ready(run_id, "b", @url_b, @sha_b)

    on_exit(&RunPrMerge.clear_command_runner/0)
    %{run_id: run_id}
  end

  defp ready(run_id, repo_id, url, sha) do
    payload =
      %{
        run_id: run_id,
        project_id: "project-mm",
        task_id: "task-mm",
        pr_url: url,
        branch_name: "foreman/task-mm/#{repo_id || "main"}",
        head_sha: sha,
        base_branch: "main"
      }
      |> put_repo(repo_id)

    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pr.ready",
        command_id: "ready-#{run_id}-#{repo_id || "main"}",
        aggregate_id: "run:#{run_id}",
        payload: payload
      })
  end

  # `gh pr view <url>` answers per URL (head = `heads[url]`, else the approved
  # one); every call is sent to the test process.
  defp stub_gh(heads \\ %{}) do
    test_pid = self()
    approved = %{@url_a => @sha_a, @url_b => @sha_b}

    RunPrMerge.set_command_runner(fn "gh", args, _opts ->
      send(test_pid, {:gh, args})

      case args do
        ["pr", "view", url | _] ->
          {Jason.encode!(%{
             "state" => "OPEN",
             "mergeable" => "MERGEABLE",
             "headRefOid" => Map.get(heads, url, approved[url]),
             "headRefName" => "foreman/task-mm/x",
             "baseRefName" => "main"
           }), 0}

        ["pr", "merge" | _] ->
          {"", 0}
      end
    end)
  end

  defp put_repo(payload, nil), do: payload
  defp put_repo(payload, repo_id), do: Map.put(payload, :repo_id, repo_id)

  # Names the head each repository's PR is at (`@sha_a` / `@sha_b`) unless told otherwise, the way
  # an operator passes `--head-sha`.
  defp approve(run_id, repo_id, identity \\ @approver, head_sha \\ nil) do
    CommandGateway.dispatch_operator(%{
      command_id: "approve-#{System.unique_integer([:positive])}",
      type: "merge_approve",
      aggregate_id: "run:#{run_id}",
      payload:
        put_repo(
          %{
            run_id: run_id,
            approver: "leo",
            approver_identity: identity,
            head_sha: head_sha || if(repo_id == "b", do: @sha_b, else: @sha_a)
          },
          repo_id
        )
    })
  end

  defp merge(run_id, repo_id, overrides \\ %{}) do
    CommandGateway.dispatch_operator(%{
      command_id: "merge-#{System.unique_integer([:positive])}",
      type: "run.pr.merge",
      aggregate_id: "run:#{run_id}",
      payload: put_repo(Map.merge(%{run_id: run_id}, overrides), repo_id)
    })
  end

  defp events(run_id, type) do
    {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)

    events
    |> Enum.filter(&(&1.event_type == type))
    |> Enum.map(fn e -> e.data |> Jason.encode!() |> Jason.decode!() end)
  end

  defp gh_merges do
    receive_all([]) |> Enum.filter(&match?(["pr", "merge" | _], &1))
  end

  defp receive_all(acc) do
    receive do
      {:gh, args} -> receive_all([args | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "approving a does not approve b: b stays unmergeable while a merges at its own head",
       %{run_id: run_id} do
    stub_gh()
    assert {:ok, _} = approve(run_id, nil)

    assert {:error, :pr_not_acceptable} = merge(run_id, "b")
    assert gh_merges() == [], "b is not approved: nothing may be merged"

    assert {:ok, _} = merge(run_id, nil)
    assert [["pr", "merge", @url_a, "--squash", "--match-head-commit", @sha_a]] = gh_merges()

    assert [%{"pr_url" => @url_a} = merged] = events(run_id, "PrMerged")
    refute Map.has_key?(merged, "repo_id"), "the primary's event keeps the single-repo shape"

    assert [approved] = events(run_id, "MergeGateApproved")
    refute Map.has_key?(approved, "repo_id")
  end

  test "b is approved and merged by repo_id, pinned to b's own head", %{run_id: run_id} do
    stub_gh()
    assert {:ok, _} = approve(run_id, "b")

    assert {:error, :pr_not_acceptable} = merge(run_id, nil)
    assert gh_merges() == []

    # The caller cannot steer the PR or the pin either.
    assert {:ok, _} = merge(run_id, "b", %{pr_url: @url_a, head_sha: "evil"})
    assert [["pr", "merge", @url_b, "--squash", "--match-head-commit", @sha_b]] = gh_merges()

    assert [%{"pr_url" => @url_b, "repo_id" => "b"}] = events(run_id, "PrMerged")
    assert [%{"repo_id" => "b"}] = events(run_id, "MergeGateApproved")
  end

  test "both approved: each merges independently", %{run_id: run_id} do
    stub_gh()
    assert {:ok, _} = approve(run_id, nil)
    assert {:ok, _} = approve(run_id, "b")

    assert {:ok, _} = merge(run_id, "b")
    assert {:ok, _} = merge(run_id, nil)

    assert [
             ["pr", "merge", @url_b, "--squash", "--match-head-commit", @sha_b],
             ["pr", "merge", @url_a, "--squash", "--match-head-commit", @sha_a]
           ] = gh_merges()

    assert [%{"pr_url" => @url_b}, %{"pr_url" => @url_a}] = events(run_id, "PrMerged")
  end

  test "approving with an unknown repo_id is a typed error and approves nothing",
       %{run_id: run_id} do
    stub_gh()

    assert {:error, {:merge_gate_not_found, :run, "zzz"}} = approve(run_id, "zzz")
    assert {:error, :pr_not_acceptable} = merge(run_id, nil)
    assert {:error, :pr_not_acceptable} = merge(run_id, "b")
    assert events(run_id, "MergeGateApproved") == []
  end

  test "a non-operator identity cannot approve either repo's PR", %{run_id: run_id} do
    stub_gh()

    for repo_id <- [nil, "b"] do
      assert {:error, :unauthorized_approver} = approve(run_id, repo_id, "github:someone-else")
      assert {:error, :pr_not_acceptable} = merge(run_id, repo_id)
    end

    assert receive_all([]) == []
  end

  test "a head that moved after approval refuses that PR only and re-holds its gate",
       %{run_id: run_id} do
    stub_gh()
    assert {:ok, _} = approve(run_id, nil)
    assert {:ok, _} = approve(run_id, "b")

    # a gets a push GitHub shows but the PR watch has not recorded
    stub_gh(%{@url_a => "pushed-after-approval"})

    assert {:error, {:head_moved_since_approval, @sha_a, "pushed-after-approval"}} =
             merge(run_id, nil)

    assert {:error, :pr_not_acceptable} = merge(run_id, nil), "a's approval is void"

    assert {:ok, _} = merge(run_id, "b")
    assert [["pr", "merge", @url_b | _]] = gh_merges()
    assert [%{"pr_url" => @url_b}] = events(run_id, "PrMerged")

    assert [%{"approved_head_sha" => @sha_a, "head_sha" => "pushed-after-approval"} = held] =
             events(run_id, "MergeGatePending")

    refute Map.has_key?(held, "repo_id"), "the primary's event keeps the single-repo shape"
  end

  test "a push recorded by the PR watch voids that repo's approval only", %{run_id: run_id} do
    stub_gh()
    assert {:ok, _} = approve(run_id, nil)
    assert {:ok, _} = approve(run_id, "b")

    pushed = %ForemanServer.GitHub.PrStatus{
      status: :open,
      head_sha: "pushed-to-b",
      head_branch: "foreman/task-mm/b",
      base_branch: "main"
    }

    {:ok, update} = ForemanServer.PrUpdate.command(run_id, @url_b, pushed, "b")
    assert {:ok, _} = CommandGateway.dispatch_system(update)

    assert [%{"repo_id" => "b", "approved_head_sha" => @sha_b, "head_sha" => "pushed-to-b"}] =
             events(run_id, "MergeGatePending")

    assert {:error, :pr_not_acceptable} = merge(run_id, "b")
    assert {:ok, _} = merge(run_id, nil)
    assert [["pr", "merge", @url_a | _]] = gh_merges()

    # b's old head can no longer be approved, its new one can
    stub_gh(%{@url_b => "pushed-to-b"})

    assert {:error, {:head_sha_mismatch, @sha_b, "pushed-to-b"}} = approve(run_id, "b")
    assert {:ok, _} = approve(run_id, "b", @approver, "pushed-to-b")
    assert {:ok, _} = merge(run_id, "b")

    assert [["pr", "merge", @url_b, "--squash", "--match-head-commit", "pushed-to-b"]] =
             gh_merges()
  end

  test "a b PrReady after a's approval does not un-approve a", %{run_id: run_id} do
    stub_gh()
    assert {:ok, _} = approve(run_id, nil)

    # b's PR is re-readied (new head): only b's gate re-holds.
    {:ok, _} =
      CommandGateway.dispatch_system(%{
        type: "run.pr.ready",
        command_id: "ready-again-#{run_id}",
        aggregate_id: "run:#{run_id}",
        payload: %{
          run_id: run_id,
          repo_id: "b",
          project_id: "project-mm",
          task_id: "task-mm",
          pr_url: @url_b,
          branch_name: "foreman/task-mm/b",
          head_sha: @sha_b,
          base_branch: "main"
        }
      })

    assert {:ok, _} = merge(run_id, nil)
    assert {:error, :pr_not_acceptable} = merge(run_id, "b")
  end
end
