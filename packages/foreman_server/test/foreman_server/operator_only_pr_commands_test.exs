defmodule ForemanServer.OperatorOnlyPrCommandsTest do
  @moduledoc """
  The merge gate stays operator-only (E12-S6): `merge_approve`, `run.pr.merge`,
  `run.pr.retry` and the evidence waiver `run.pr.waive_evidence` (TRD-012) are reachable through the operator envelope, and through
  none of the surfaces an agent or automation drives - no MCP tool, no
  coordinator / approvals dispatch, no PR-watch system command.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Run.PrWatch
  alias ForemanServer.Approvals.Dispatch, as: ApprovalsDispatch
  alias ForemanServer.CommandGateway
  alias ForemanServer.Coordinator.Dispatch, as: CoordinatorDispatch
  alias ForemanServer.MCP.{Policy, Tools}

  @operator_only ~w(merge_approve run.pr.merge run.pr.retry run.pr.waive_evidence)
  # `run.pr.rehold` voids a stale approval (foreman-ehxy6): automation sends it after a PR head
  # observation, and it can only ever make the gate stricter - but no operator, agent or tool may
  # dispatch it.
  @system_only ~w(run.repo_pr_failed run.pr.rehold)

  test "the operator envelope accepts them (and rejects the system-only failure record)" do
    for type <- @operator_only do
      refute match?(
               {:error, {:command_not_allowed, ^type}},
               CommandGateway.dispatch_operator(%{
                 type: type,
                 command_id: "c-#{type}",
                 aggregate_id: "run:none",
                 payload: %{run_id: "none", repo_id: "b"}
               })
             ),
             "#{type} must be an allowed operator command"
    end

    for type <- @system_only do
      assert {:error, {:command_not_allowed, ^type}} =
               CommandGateway.dispatch_operator(%{
                 type: type,
                 command_id: "c-#{type}",
                 aggregate_id: "run:none",
                 payload: %{run_id: "none", repo_id: "b", reason: "x", at: 1}
               })
    end
  end

  test "no MCP tool is, or is named after, a merge-gate command" do
    names = Enum.map(Tools.list_tools(), & &1.name)

    for type <- @operator_only ++ @system_only do
      flat = String.replace(type, ".", "_")
      refute type in names
      refute ("foreman_" <> flat) in names
    end

    refute Enum.any?(names, &String.contains?(&1, ["merge", "approve_merge"]))
    refute Enum.any?(names, &String.contains?(&1, "waive"))
  end

  test "calling one over MCP is an unknown tool, even with workflow writes enabled" do
    previous = Application.get_env(:foreman_server, :mcp)
    Application.put_env(:foreman_server, :mcp, allow_workflow_writes: true)
    on_exit(fn -> Application.put_env(:foreman_server, :mcp, previous || []) end)

    for type <- @operator_only do
      assert {:error, %{code: "METHOD_NOT_FOUND"}} =
               Tools.call_tool(type, %{run_id: "none", repo_id: "b"})

      assert {:error, %{code: "METHOD_NOT_FOUND"}} =
               Tools.call_tool("foreman_" <> String.replace(type, ".", "_"), %{run_id: "none"})
    end

    for name <- ["foreman_waive_evidence", "foreman_run_waive_evidence"] do
      assert {:error, %{code: "METHOD_NOT_FOUND"}} = Tools.call_tool(name, %{run_id: "none"})
    end

    # The policy has nothing to refuse because nothing is advertised.
    assert Policy.list_tools(Tools.list_tools()) == Tools.list_tools()
  end

  test "coordinator, approvals and PR-watch automation cannot dispatch them" do
    for type <- @operator_only ++ @system_only do
      refute type in CoordinatorDispatch.command_types()
      refute type in ApprovalsDispatch.command_types()
      refute type in PrWatch.operator_types()
      refute type in PrWatch.command_types()
    end

    assert {:error, {:forbidden_command, "run.pr.retry"}} =
             CoordinatorDispatch.system(CommandGateway, %{type: "run.pr.retry", payload: %{}})
  end

  # TRD-033: the failed-ready record is a `PrWatch` command (so a terminal run takes it) that
  # only `PrReadySignal` dispatches: no operator envelope, MCP tool, coordinator or approvals.
  describe "run.pr.ready_failed is system-only" do
    @type_name "run.pr.ready_failed"

    test "it is a PrWatch command but not an operator one" do
      assert @type_name in PrWatch.command_types()
      refute @type_name in PrWatch.operator_types()
      refute @type_name in CommandGateway.operator_types()
      refute @type_name in CommandGateway.pr_operator_types()
    end

    test "the operator envelope refuses it" do
      assert {:error, {:command_not_allowed, @type_name}} =
               CommandGateway.dispatch_operator(%{
                 type: @type_name,
                 command_id: "c-ready-failed",
                 aggregate_id: "run:none",
                 payload: %{
                   run_id: "none",
                   pr_url: "https://github.com/a/b/pull/1",
                   stage: "head_read",
                   reason: "x",
                   failed_at: 1
                 }
               })
    end

    test "no MCP tool is, or is named after, it; calling it is an unknown tool" do
      names = Enum.map(Tools.list_tools(), & &1.name)
      refute @type_name in names
      refute "foreman_run_pr_ready_failed" in names
      refute Enum.any?(names, &String.contains?(&1, "ready_failed"))

      previous = Application.get_env(:foreman_server, :mcp)
      Application.put_env(:foreman_server, :mcp, allow_workflow_writes: true)
      on_exit(fn -> Application.put_env(:foreman_server, :mcp, previous || []) end)

      assert {:error, %{code: "METHOD_NOT_FOUND"}} =
               Tools.call_tool("foreman_run_pr_ready_failed", %{run_id: "none"})
    end

    test "coordinator and approvals cannot dispatch it" do
      refute @type_name in CoordinatorDispatch.command_types()
      refute @type_name in ApprovalsDispatch.command_types()

      assert {:error, {:forbidden_command, @type_name}} =
               CoordinatorDispatch.system(CommandGateway, %{type: @type_name, payload: %{}})
    end
  end

  # TRD-015: the findings record is a `PrWatch` command (so a terminal run takes it) that only
  # the finalising executor dispatches: no operator envelope, MCP tool, coordinator or approvals.
  describe "run.pr.findings is system-only" do
    @findings_type "run.pr.findings"

    test "it is a PrWatch command but in no operator list" do
      assert @findings_type in PrWatch.command_types()
      refute @findings_type in PrWatch.operator_types()
      refute @findings_type in CommandGateway.operator_types()
      refute @findings_type in CommandGateway.command_endpoint_types()
      refute @findings_type in CommandGateway.pr_operator_types()
      refute @findings_type in ForemanServer.Aggregates.Run.repo_pr_operator_types()
    end

    test "the operator envelope refuses it" do
      assert {:error, {:command_not_allowed, @findings_type}} =
               CommandGateway.dispatch_operator(%{
                 type: @findings_type,
                 command_id: "c-findings",
                 aggregate_id: "run:none",
                 payload: %{
                   run_id: "none",
                   pr_url: "https://github.com/a/b/pull/1",
                   head_sha: "h1",
                   status: "absent",
                   findings: [],
                   recorded_at: 1
                 }
               })
    end

    test "no MCP tool is, or is named after, it; calling it is an unknown tool" do
      names = Enum.map(Tools.list_tools(), & &1.name)
      refute @findings_type in names
      refute Enum.any?(names, &String.contains?(&1, "pr_findings"))

      previous = Application.get_env(:foreman_server, :mcp)
      Application.put_env(:foreman_server, :mcp, allow_workflow_writes: true)
      on_exit(fn -> Application.put_env(:foreman_server, :mcp, previous || []) end)

      assert {:error, %{code: "METHOD_NOT_FOUND"}} =
               Tools.call_tool("foreman_run_pr_findings", %{run_id: "none"})
    end

    test "coordinator and approvals cannot dispatch it" do
      refute @findings_type in CoordinatorDispatch.command_types()
      refute @findings_type in ApprovalsDispatch.command_types()

      assert {:error, {:forbidden_command, @findings_type}} =
               CoordinatorDispatch.system(CommandGateway, %{type: @findings_type, payload: %{}})
    end
  end

  # TRD-018: the risk record is a `PrWatch` command only `PrObservation` builds (the Observer
  # dispatches it): no operator envelope, MCP tool, coordinator or approvals dispatch.
  describe "run.pr.risk is system-only" do
    @risk_type "run.pr.risk"

    test "it is a PrWatch command but in no operator list" do
      assert @risk_type in PrWatch.command_types()
      refute @risk_type in PrWatch.operator_types()
      refute @risk_type in CommandGateway.operator_types()
      refute @risk_type in CommandGateway.command_endpoint_types()
      refute @risk_type in CommandGateway.pr_operator_types()
      refute @risk_type in ForemanServer.Aggregates.Run.repo_pr_operator_types()
    end

    test "the operator envelope refuses it, even naming every field" do
      assert {:error, {:command_not_allowed, @risk_type}} =
               CommandGateway.dispatch_operator(%{
                 type: @risk_type,
                 command_id: "c-risk",
                 aggregate_id: "run:none",
                 payload: %{
                   run_id: "none",
                   pr_url: "https://github.com/a/b/pull/1",
                   head_sha: "h1",
                   level: "LOW"
                 }
               })
    end

    test "no MCP tool is, or is named after, it" do
      names = Enum.map(Tools.list_tools(), & &1.name)
      refute @risk_type in names
      refute Enum.any?(names, &String.contains?(&1, "pr_risk"))

      previous = Application.get_env(:foreman_server, :mcp)
      Application.put_env(:foreman_server, :mcp, allow_workflow_writes: true)
      on_exit(fn -> Application.put_env(:foreman_server, :mcp, previous || []) end)

      assert {:error, %{code: "METHOD_NOT_FOUND"}} =
               Tools.call_tool("foreman_run_pr_risk", %{run_id: "none"})
    end

    test "coordinator and approvals cannot dispatch it" do
      refute @risk_type in CoordinatorDispatch.command_types()
      refute @risk_type in ApprovalsDispatch.command_types()

      assert {:error, {:forbidden_command, @risk_type}} =
               CoordinatorDispatch.system(CommandGateway, %{type: @risk_type, payload: %{}})
    end
  end

  # TRD-021: the outcome of publishing the report is a `PrWatch` command only
  # `PrReport.Publisher` dispatches: no operator envelope, MCP tool, coordinator or approvals
  # dispatch, and not a head observation.
  describe "run.pr.comment_published is system-only" do
    @published_type "run.pr.comment_published"

    test "it is a PrWatch command but in no operator list" do
      assert @published_type in PrWatch.command_types()
      refute @published_type in PrWatch.operator_types()
      refute @published_type in CommandGateway.operator_types()
      refute @published_type in CommandGateway.command_endpoint_types()
      refute @published_type in CommandGateway.pr_operator_types()
      refute @published_type in ForemanServer.Aggregates.Run.repo_pr_operator_types()
    end

    test "the operator envelope refuses it, even naming every field" do
      assert {:error, {:command_not_allowed, @published_type}} =
               CommandGateway.dispatch_operator(%{
                 type: @published_type,
                 command_id: "c-published",
                 aggregate_id: "run:none",
                 payload: %{
                   run_id: "none",
                   pr_url: "https://github.com/a/b/pull/1",
                   head_sha: "h1",
                   digest: "d1",
                   status: "published",
                   comment_id: 1,
                   comment_url: "https://github.com/a/b/pull/1#issuecomment-1",
                   recorded_at: 1
                 }
               })
    end

    test "no MCP tool is, or is named after, it" do
      names = Enum.map(Tools.list_tools(), & &1.name)
      refute @published_type in names
      refute Enum.any?(names, &String.contains?(&1, "comment_published"))

      previous = Application.get_env(:foreman_server, :mcp)
      Application.put_env(:foreman_server, :mcp, allow_workflow_writes: true)
      on_exit(fn -> Application.put_env(:foreman_server, :mcp, previous || []) end)

      assert {:error, %{code: "METHOD_NOT_FOUND"}} =
               Tools.call_tool("foreman_run_pr_comment_published", %{run_id: "none"})
    end

    test "coordinator and approvals cannot dispatch it" do
      refute @published_type in CoordinatorDispatch.command_types()
      refute @published_type in ApprovalsDispatch.command_types()

      assert {:error, {:forbidden_command, @published_type}} =
               CoordinatorDispatch.system(CommandGateway, %{type: @published_type, payload: %{}})
    end
  end

  # TRD-012: the waiver is declared with the operator PR types beside `merge_approve` (it needs
  # the merge gate the aggregate keeps), never as a PR-watch command the watcher could issue.
  describe "run.pr.waive_evidence is operator-only" do
    @waive "run.pr.waive_evidence"

    test "it is in the operator allowlist, as merge_approve is, and in no automation list" do
      assert @waive in CommandGateway.operator_types()
      assert @waive in CommandGateway.command_endpoint_types()
      assert @waive in CommandGateway.pr_operator_types()
      assert @waive in ForemanServer.Aggregates.Run.repo_pr_operator_types()
      assert "merge_approve" in CommandGateway.operator_types()

      refute @waive in PrWatch.command_types()
      refute @waive in PrWatch.operator_types()
      refute @waive in CoordinatorDispatch.command_types()
      refute @waive in ApprovalsDispatch.command_types()

      for types <- [CoordinatorDispatch.command_types(), ApprovalsDispatch.command_types()] do
        refute Enum.any?(types, &String.contains?(&1, "waive"))
      end
    end

    test "coordinator and approvals dispatch refuse it" do
      assert {:error, {:forbidden_command, @waive}} =
               CoordinatorDispatch.system(CommandGateway, %{type: @waive, payload: %{}})
    end

    test "the operator envelope addresses it to the run stream" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 type: @waive,
                 command_id: "c-waive-mismatch",
                 aggregate_id: "run:other",
                 payload: %{run_id: "none"}
               })
    end
  end

  # TRD-030: the request to publish the report again is an operator command (the CLI and
  # `POST /api/commands`), reachable through none of the surfaces an agent or automation drives.
  describe "run.pr.publish_report is operator-only" do
    @publish_report "run.pr.publish_report"

    test "it is in the operator allowlists and in no automation list" do
      assert @publish_report in PrWatch.command_types()
      assert @publish_report in PrWatch.operator_types()
      assert @publish_report in CommandGateway.operator_types()
      assert @publish_report in CommandGateway.command_endpoint_types()
      assert @publish_report in CommandGateway.pr_operator_types()

      refute @publish_report in CoordinatorDispatch.command_types()
      refute @publish_report in ApprovalsDispatch.command_types()

      refute Enum.any?(
               CoordinatorDispatch.command_types(),
               &String.contains?(&1, "publish_report")
             )

      refute Enum.any?(ApprovalsDispatch.command_types(), &String.contains?(&1, "publish_report"))
    end

    test "coordinator and approvals dispatch refuse it" do
      assert {:error, {:forbidden_command, @publish_report}} =
               CoordinatorDispatch.system(CommandGateway, %{type: @publish_report, payload: %{}})
    end

    test "no MCP tool is, or is named after, it; calling it is an unknown tool" do
      names = Enum.map(Tools.list_tools(), & &1.name)
      refute @publish_report in names
      refute Enum.any?(names, &String.contains?(&1, "publish_report"))

      previous = Application.get_env(:foreman_server, :mcp)
      Application.put_env(:foreman_server, :mcp, allow_workflow_writes: true)
      on_exit(fn -> Application.put_env(:foreman_server, :mcp, previous || []) end)

      assert {:error, %{code: "METHOD_NOT_FOUND"}} =
               Tools.call_tool("foreman_run_pr_publish_report", %{run_id: "none"})
    end

    test "the operator envelope addresses it to the run stream" do
      assert {:error, {:invalid_envelope, :aggregate_id_mismatch}} =
               CommandGateway.dispatch_operator(%{
                 type: @publish_report,
                 command_id: "c-publish-report-mismatch",
                 aggregate_id: "run:other",
                 payload: %{run_id: "none"}
               })
    end
  end

  # `run.pr.comment_published` and `run.pr.publish_report` are not PR head observations
  # (`@pr_head_observations`): a head observation is checked against the merge approval and
  # voids it when the head differs. The report commands carry the head of a risk record, and
  # taking that path would let posting a comment void an approval.
  describe "the report commands take no head-observation path" do
    alias ForemanServer.Aggregate
    alias ForemanServer.Aggregates.Run

    # A run approved at `sha-1` whose PR was then seen at `sha-2` (appended straight to the
    # stream, as an observation that has not reached the gate yet) with a risk record for it.
    defp approved_run_seen_at_a_newer_head do
      run_id = "run-report-#{System.unique_integer([:positive])}"
      pr_url = "https://github.com/acme/report/pull/#{System.unique_integer([:positive])}"
      ids = %{run_id: run_id, project_id: "project-report", task_id: "task-report"}
      pr = fn extra -> Map.merge(ids, Map.merge(%{pr_url: pr_url}, extra)) end

      events = [
        {"RunStarted", ids},
        {"PrReady", pr.(%{branch_name: "b", head_sha: "sha-1", base_branch: "main"})},
        {"MergeGateApproved",
         %{run_id: run_id, approver: "leo", approver_identity: "github:leo", approved_at: 1}},
        {"PrUpdated",
         pr.(%{branch_name: "b", head_sha: "sha-2", base_branch: "main", pr_status: "open"})},
        {"PrRiskRecorded",
         pr.(%{
           head_sha: "sha-2",
           level: "HIGH",
           rubric_version: "1",
           digest: "dg-1",
           seq: 1,
           recorded_at: 1
         })}
      ]

      :ok =
        ForemanServer.EventStore.append_to_stream(
          "run:#{run_id}",
          0,
          Enum.map(events, fn {type, data} ->
            %EventStore.EventData{event_type: type, data: data, metadata: %{}}
          end)
        )

      %{run_id: run_id, pr_url: pr_url}
    end

    defp gate(run_id) do
      {state, _version} = Aggregate.load(Run, "run:#{run_id}")
      {Run.merge_gate(state), Run.merge_pin(state).head_sha}
    end

    defp dispatch_system(run_id, type, payload) do
      CommandGateway.dispatch_system(%{
        type: type,
        command_id: "head-obs-#{System.unique_integer([:positive])}",
        aggregate_id: "run:#{run_id}",
        payload: Map.put(payload, :run_id, run_id)
      })
    end

    test "a head observation for the newer head voids the approval (the control)" do
      %{run_id: run_id, pr_url: pr_url} = approved_run_seen_at_a_newer_head()
      assert {:approved, "sha-1"} = gate(run_id)

      assert {:ok, _} =
               dispatch_system(run_id, "run.pr.checks", %{
                 pr_url: pr_url,
                 head_sha: "sha-2",
                 digest: "c1",
                 checks_state: "passing",
                 pr_status: "open",
                 observation_seq: 1
               })

      assert {:pending, nil} = gate(run_id)
    end

    test "the published outcome and the operator's request leave the approval alone" do
      %{run_id: run_id, pr_url: pr_url} = approved_run_seen_at_a_newer_head()
      assert {:approved, "sha-1"} = gate(run_id)

      assert {:ok, %{"event_type" => "PrReportRequested"}} =
               dispatch_system(run_id, "run.pr.publish_report", %{pr_url: pr_url})

      assert {:approved, "sha-1"} = gate(run_id)

      assert {:ok, %{"event_type" => "PrCommentPublished"}} =
               dispatch_system(run_id, "run.pr.comment_published", %{
                 pr_url: pr_url,
                 head_sha: "sha-2",
                 digest: "dg-1",
                 status: "published",
                 comment_id: 11,
                 comment_url: pr_url <> "#issuecomment-11",
                 recorded_at: 2
               })

      assert {:approved, "sha-1"} = gate(run_id)
    end
  end
end
