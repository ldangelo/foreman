defmodule ForemanServer.OperatorOnlyPrCommandsTest do
  @moduledoc """
  The merge gate stays operator-only (E12-S6): `merge_approve`, `run.pr.merge`
  and `run.pr.retry` are reachable through the operator envelope, and through
  none of the surfaces an agent or automation drives - no MCP tool, no
  coordinator / approvals dispatch, no PR-watch system command.
  """
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.Run.PrWatch
  alias ForemanServer.Approvals.Dispatch, as: ApprovalsDispatch
  alias ForemanServer.CommandGateway
  alias ForemanServer.Coordinator.Dispatch, as: CoordinatorDispatch
  alias ForemanServer.MCP.{Policy, Tools}

  @operator_only ~w(merge_approve run.pr.merge run.pr.retry)
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
end
