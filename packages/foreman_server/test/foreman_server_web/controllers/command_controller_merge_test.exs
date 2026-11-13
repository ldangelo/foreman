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
    MergeGate.clear()

    run_id = "run-http-merge-#{System.unique_integer([:positive])}"
    started = %{run_id: run_id, project_id: "project-http", task_id: "task-http"}

    :ok =
      ForemanServer.EventStore.append_to_stream("run:#{run_id}", 0, [
        %EventStore.EventData{event_type: "RunStarted", data: started, metadata: %{}}
      ])

    :ok =
      ForemanServer.ProjectionStore.apply_events([%{event_type: "RunStarted", payload: started}])

    # The gate reads the run's project policy: the project must be known to the projection.
    :ok =
      ForemanServer.ProjectionStore.apply_events([
        %{event_type: "ProjectRegistered", payload: %{project_id: "project-http", path: nil}}
      ])

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
    {:ok, rollup} = Agent.start_link(fn -> [] end)

    RunPrMerge.set_command_runner(fn "gh", args, _opts ->
      send(test_pid, {:gh, args})

      case args do
        ["pr", "view" | _] ->
          view = %{
            "state" => "OPEN",
            "mergeable" => "MERGEABLE",
            "headRefOid" => @sha,
            "headRefName" => "foreman/task-http/run",
            "baseRefName" => "main"
          }

          view =
            case Agent.get(rollup, & &1) do
              [] -> view
              checks -> Map.put(view, "statusCheckRollup", checks)
            end

          {Jason.encode!(view), 0}

        ["pr", "merge" | _] ->
          {"", 0}
      end
    end)

    on_exit(&RunPrMerge.clear_command_runner/0)

    %{run_id: run_id, rollup: rollup}
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

  describe "a project with required_checks (TRD-022: POST /api/commands -> CommandGateway.dispatch_operator)" do
    defp gate_events(run_id, type) do
      {:ok, events} = ForemanServer.EventStore.read_stream_forward("run:#{run_id}", 0, 1_000)
      for %{event_type: ^type, data: data} <- events, do: data
    end

    setup do
      ForemanServer.TestSupport.MeckScope.new_once!([ForemanServer.CommandRouter])
      :ok
    end

    @inputs ~w(checks_head_sha checks_observed_at evidence_digest checks_ref findings_head_sha
               findings_digest risk_head_sha risk_digest)

    defp check_run(name, conclusion) do
      %{
        "__typename" => "CheckRun",
        "completedAt" => "2026-11-12T13:58:49Z",
        "conclusion" => conclusion,
        "name" => name,
        "startedAt" => "2026-11-12T13:58:43Z",
        "status" => if(conclusion == "", do: "IN_PROGRESS", else: "COMPLETED"),
        "workflowName" => "ci"
      }
    end

    defp gate!(run_id, rollup, checks, opts \\ []) do
      :ok =
        ForemanServer.ProjectionStore.apply_events([
          %{
            event_type: "ProjectUpdated",
            payload: %{
              project_id: "project-http",
              required_checks: [%{"name" => "unit", "kind" => "check_run"}]
            }
          }
        ])

      Agent.update(rollup, fn _ -> checks end)

      unless opts[:no_findings] do
        :ok =
          ForemanServer.TestSupport.GateEvidence.record_findings!(
            %{run_id: run_id, project_id: "project-http", task_id: "task-http", pr_url: @pr_url},
            @sha
          )
      end
    end

    test "the approval records a forced observation for the head first, then approves", %{
      run_id: run_id,
      rollup: rollup
    } do
      gate!(run_id, rollup, [check_run("unit", "SUCCESS")])

      body =
        run_id
        |> approve_body("github:ldangelo")
        |> Map.put("evidence", %{"checks_ref" => "forged"})

      assert %{"status" => "accepted"} = json_response(command("merge_approve", body), 201)

      assert [forced] = gate_events(run_id, "PrChecksChanged")
      assert ForemanServer.Aggregate.get(forced, :source) == "gate"
      nonce = ForemanServer.Aggregate.get(forced, :observation_ref)

      # what the gateway stamped on the approval it dispatched: its own evidence, not the forged one
      assert [%{payload: %{evidence: evidence} = stamped}] =
               for(
                 {_pid,
                  {ForemanServer.CommandRouter, :dispatch, [%{type: "merge_approve"} = c | _]},
                  _result} <- :meck.history(ForemanServer.CommandRouter),
                 do: c
               )

      refute Map.has_key?(stamped, "evidence")
      assert evidence.checks_ref == nonce
      assert [%{"name" => "unit"}] = evidence.policy.required
      assert is_binary(evidence.policy.version)
      assert is_integer(evidence.now_ms)
      assert [_] = gate_events(run_id, "PrRiskRecorded")

      # the decision is recorded with the approval: the eight inputs, the nonce the batch carried
      assert [approved] = gate_events(run_id, "MergeGateApproved")
      recorded = ForemanServer.Aggregate.get(approved, :evidence)
      assert ForemanServer.Aggregate.get(recorded, :status) == "eligible"
      assert ForemanServer.Aggregate.get(recorded, :checks_ref) == nonce
      inputs = ForemanServer.Aggregate.get(recorded, :inputs)
      assert Enum.sort(Enum.map(Map.keys(inputs), &to_string/1)) == Enum.sort(@inputs)
      assert ForemanServer.Aggregate.get(inputs, :checks_head_sha) == @sha
      assert ForemanServer.Aggregate.get(inputs, :findings_head_sha) == @sha
      assert ForemanServer.Aggregate.get(inputs, :risk_head_sha) == @sha
    end

    for {label, rollup, codes, subject_code} <- [
          {"a failing required check", [{"unit", "FAILURE"}], ["failing"], "failing"},
          {"a pending required check", [{"unit", ""}], ["pending"], "pending"},
          {"a missing required check", [], ["missing"], "missing"}
        ] do
      test "#{label} is a 422 evidence_ineligible with the reasons and the inputs; nothing is approved",
           %{run_id: run_id, rollup: rollup} do
        checks =
          for {name, conclusion} <- unquote(Macro.escape(rollup)), do: check_run(name, conclusion)

        gate!(run_id, rollup, checks)

        conn = command("merge_approve", approve_body(run_id, "github:ldangelo"))
        assert %{"error" => error, "detail" => detail} = json_response(conn, 422)
        assert error =~ "evidence_ineligible"
        assert error =~ @sha
        assert error =~ unquote(subject_code)

        assert detail["status"] == "ineligible"
        assert detail["head_sha"] == @sha
        assert is_binary(detail["policy_version"])
        assert is_binary(detail["checks_ref"])
        assert is_integer(detail["now_ms"])
        assert detail["waived"] == []
        assert detail["waiver"] == nil
        assert Enum.map(detail["reasons"], & &1["code"]) == unquote(codes)
        assert [%{"subject" => "unit"} | _] = detail["reasons"]
        assert Enum.sort(Map.keys(detail["inputs"])) == Enum.sort(@inputs)
        assert detail["inputs"]["checks_ref"] == detail["checks_ref"]
        assert detail["inputs"]["findings_head_sha"] == @sha
        assert detail["inputs"]["risk_head_sha"] == @sha

        assert gate_events(run_id, "MergeGateApproved") == []

        # the gate is still shut: the merge is refused
        assert %{"error" => refused} =
                 json_response(command("run.pr.merge", %{"run_id" => run_id}), 422)

        assert refused =~ "pr_not_acceptable"
      end
    end

    test "findings that were never recorded are a 422 findings_absent, with the findings inputs nil",
         %{run_id: run_id, rollup: rollup} do
      gate!(run_id, rollup, [check_run("unit", "SUCCESS")], no_findings: true)

      conn = command("merge_approve", approve_body(run_id, "github:ldangelo"))
      assert %{"error" => error, "detail" => detail} = json_response(conn, 422)
      assert error =~ "findings_absent"
      assert detail["inputs"]["findings_head_sha"] == nil
      assert detail["inputs"]["findings_digest"] == nil
      assert gate_events(run_id, "MergeGateApproved") == []
    end

    test "a project without required_checks approves as before, recording a gate-off decision",
         %{run_id: run_id} do
      assert %{"status" => "accepted"} =
               json_response(
                 command("merge_approve", approve_body(run_id, "github:ldangelo")),
                 201
               )

      assert [approved] = gate_events(run_id, "MergeGateApproved")
      recorded = ForemanServer.Aggregate.get(approved, :evidence)
      assert ForemanServer.Aggregate.get(recorded, :status) == "off"
      assert gate_events(run_id, "PrChecksChanged") == []
    end

    test "a project the projection does not know is a 422 policy_unavailable and nothing is recorded",
         %{run_id: run_id} do
      :ok =
        ForemanServer.ProjectionStore.apply_events([
          %{
            event_type: "RunStarted",
            payload: %{run_id: run_id, project_id: "project-gone", task_id: "task-http"}
          }
        ])

      assert %{"error" => error} =
               json_response(
                 command("merge_approve", approve_body(run_id, "github:ldangelo")),
                 422
               )

      assert error =~ "policy_unavailable"
      assert gate_events(run_id, "PrChecksChanged") == []
      assert gate_events(run_id, "MergeGateApproved") == []
    end
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
