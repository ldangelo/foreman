defmodule ForemanServerWeb.CommandControllerMergeTest do
  # `POST /api/commands` for `merge_approve` and `run.pr.merge`, through the real
  # controller, gateway and Run aggregate; only `gh` is stubbed. `merge_approve`
  # had a complete aggregate handler but was in neither allowlist, so no HTTP
  # request could ever reach it.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @moduletag :controller
  @endpoint ForemanServerWeb.Endpoint

  alias ForemanServer.CommandGateway
  alias ForemanServer.RunPrMerge
  alias ForemanServer.Workflow.MergeGate

  @pr_url "https://github.com/acme/repo/pull/77"
  @sha "approvedsha777"

  setup do
    case GenServer.whereis(MergeGate) do
      nil -> {:ok, _pid} = MergeGate.start_link()
      _pid -> :ok
    end

    MergeGate.clear()

    run_id = "run-http-merge-#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: "project-http", task_id: "task-http"}

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
          project_id: "project-http",
          task_id: "task-http",
          pr_url: @pr_url,
          branch_name: "foreman/task-http/run",
          head_sha: @sha,
          base_branch: "main"
        }
      })

    test_pid = self()

    RunPrMerge.set_command_runner(fn "gh", args, _opts ->
      send(test_pid, {:gh, args})

      case args do
        ["pr", "view" | _] ->
          {Jason.encode!(%{
             "state" => "OPEN",
             "mergeable" => "MERGEABLE",
             "headRefOid" => @sha,
             "headRefName" => "foreman/task-http/run",
             "baseRefName" => "main"
           }), 0}

        ["pr", "merge" | _] ->
          {"", 0}
      end
    end)

    on_exit(&RunPrMerge.clear_command_runner/0)

    %{run_id: run_id}
  end

  defp command(type, payload) do
    post(build_conn(), "/api/commands", %{"type" => type, "payload" => payload})
  end

  defp approve_body(run_id, identity) do
    %{
      "run_id" => run_id,
      "approver" => "leo",
      "approver_identity" => identity,
      "head_sha" => @sha
    }
  end

  defp merge_calls do
    Stream.repeatedly(fn ->
      receive do
        {:gh, args} -> args
      after
        0 -> :done
      end
    end)
    |> Enum.take_while(&(&1 != :done))
    |> Enum.filter(&match?(["pr", "merge" | _], &1))
  end

  test "an unapproved run's merge is refused with 422 and gh is not called", %{run_id: run_id} do
    conn = command("run.pr.merge", %{"run_id" => run_id})

    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "pr_not_acceptable"
    assert merge_calls() == []
  end

  test "an unauthorized approver gets 422 and the gate stays shut", %{run_id: run_id} do
    conn = command("merge_approve", approve_body(run_id, "github:intruder"))
    assert %{"error" => error} = json_response(conn, 422)
    assert error =~ "unauthorized_approver"

    assert %{"error" => refused} =
             json_response(command("run.pr.merge", %{"run_id" => run_id}), 422)

    assert refused =~ "pr_not_acceptable"
  end

  test "approve then merge over HTTP merges exactly the approved PR and head", %{run_id: run_id} do
    assert %{"status" => "accepted"} =
             json_response(command("merge_approve", approve_body(run_id, "github:ldangelo")), 201)

    # The caller tries to steer the merge; the server must ignore all of it.
    conn =
      command("run.pr.merge", %{
        "run_id" => run_id,
        "pr_url" => "https://github.com/evil/repo/pull/1",
        "head_sha" => "evil"
      })

    assert %{"status" => "accepted"} = json_response(conn, 201)

    assert [["pr", "merge", @pr_url, "--squash", "--match-head-commit", @sha]] = merge_calls()
  end

  test "a merge_approve missing the approver is a 422, not a crash", %{run_id: run_id} do
    body = run_id |> approve_body("github:ldangelo") |> Map.delete("approver")

    assert %{"error" => error} = json_response(command("merge_approve", body), 422)
    assert error =~ "approver"
  end

  test "a merge_approve naming no head is a 422 naming head_sha, and gh is not asked", %{
    run_id: run_id
  } do
    for body <- [
          run_id |> approve_body("github:ldangelo") |> Map.delete("head_sha"),
          run_id |> approve_body("github:ldangelo") |> Map.put("head_sha", "")
        ] do
      assert %{"error" => error} = json_response(command("merge_approve", body), 422)
      assert error =~ "head_sha"
    end

    assert_received_no_gh_calls()
  end

  test "a merge_approve naming another head than GitHub shows is a 422 naming both", %{
    run_id: run_id
  } do
    body = run_id |> approve_body("github:ldangelo") |> Map.put("head_sha", "reviewedsha000")

    assert %{"error" => error} = json_response(command("merge_approve", body), 422)
    assert error =~ "head_sha_mismatch"
    assert error =~ "reviewedsha000"
    assert error =~ @sha

    assert %{"error" => refused} =
             json_response(command("run.pr.merge", %{"run_id" => run_id}), 422)

    assert refused =~ "pr_not_acceptable"
  end

  test "run.pr.rehold is system-only: the HTTP allowlist refuses it", %{run_id: run_id} do
    conn =
      command("run.pr.rehold", %{"run_id" => run_id, "pr_url" => @pr_url, "head_sha" => "x"})

    assert response(conn, 400)
  end

  defp assert_received_no_gh_calls do
    refute_received {:gh, _args}
  end
end
