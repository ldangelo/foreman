defmodule ForemanServer.Aggregates.RunFollowUpTest do
  use ExUnit.Case, async: false

  alias ForemanServer.Aggregates.RunFollowUp
  alias ForemanServer.Aggregates.RunFollowUp.State
  alias ForemanServer.CommandGateway
  alias ForemanServer.Events.RunFollowUpRequested
  alias ForemanServer.FollowUpRuns

  setup do
    FollowUpRuns.enable!()
    on_exit(&FollowUpRuns.disable!/0)
    :ok
  end

  defp payload(overrides \\ %{}) do
    Map.merge(
      %{
        run_id: "run-fu-1",
        project_id: "proj-1",
        kind: "pr_fix",
        requested_by: "pr_watcher",
        parent_run_id: "run-parent",
        pr_url: "https://github.com/o/r/pull/7",
        fix_kind: "ci",
        attach_branch: "feature/x",
        push: true,
        prompt: "fix it",
        at: "2026-11-20T00:00:00Z"
      },
      overrides
    )
  end

  defp handle(p, state \\ RunFollowUp.initial_state()),
    do: RunFollowUp.handle_command(state, %{type: "run.followup.request", payload: p})

  test "emits RunFollowUpRequested on the run's own stream" do
    assert {:ok, spec} = handle(payload())
    assert spec.stream_id == "run_followup:run-fu-1"
    assert spec.stream_id == RunFollowUp.stream_id("run-fu-1")
    assert spec.event_type == "RunFollowUpRequested"

    assert %RunFollowUpRequested{
             run_id: "run-fu-1",
             kind: "pr_fix",
             attach_branch: "feature/x",
             push: true,
             resume_session_provider: nil,
             resume_session_id: nil
           } = spec.payload
  end

  test "is refused while the follow_up gate is off, and writes nothing" do
    FollowUpRuns.disable!()
    assert {:error, :followup_runs_disabled} = handle(payload())
  end

  test "a second request for the same run is refused" do
    assert {:error, {:already_exists, :run_followup, "run-fu-1"}} =
             handle(payload(), %State{requested?: true})
  end

  test "the producer kind is a closed list" do
    assert {:error, {:invalid_kind, "interactive"}} = handle(payload(%{kind: "interactive"}))
    assert {:error, {:missing_or_invalid, :kind}} = handle(Map.delete(payload(), :kind))
  end

  test "a session is both halves or neither" do
    assert {:ok, %{payload: %{resume_session_provider: "claude", resume_session_id: "s-1"}}} =
             handle(payload(%{resume_session_provider: "claude", resume_session_id: "s-1"}))

    assert {:error, {:missing_or_invalid, :resume_session}} =
             handle(payload(%{resume_session_provider: "claude"}))

    assert {:error, {:missing_or_invalid, :resume_session}} =
             handle(payload(%{resume_session_id: "s-1"}))
  end

  test "push needs the branch it publishes" do
    assert {:error, {:missing_or_invalid, :attach_branch}} =
             handle(payload(%{attach_branch: nil, push: true}))

    assert {:error, {:missing_or_invalid, :push}} = handle(payload(%{push: "yes"}))
  end

  test "the command is system-only: the operator envelope refuses it" do
    assert {:error, {:command_not_allowed, "run.followup.request"}} =
             CommandGateway.dispatch_operator(%{
               type: "run.followup.request",
               command_id: "c-followup",
               aggregate_id: "run_followup:run-fu-1",
               payload: payload()
             })
  end

  test "dispatched through the system gateway it lands on the stream and replays" do
    run_id = "run-fu-" <> Integer.to_string(System.unique_integer([:positive]))

    assert {:ok, _} =
             CommandGateway.dispatch_system(%{
               type: "run.followup.request",
               command_id: "followup:" <> run_id,
               aggregate_id: RunFollowUp.stream_id(run_id),
               payload: payload(%{run_id: run_id})
             })

    assert {:error, {:already_exists, :run_followup, ^run_id}} =
             CommandGateway.dispatch_system(%{
               type: "run.followup.request",
               command_id: "followup-again:" <> run_id,
               aggregate_id: RunFollowUp.stream_id(run_id),
               payload: payload(%{run_id: run_id})
             })
  end
end
