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
end
