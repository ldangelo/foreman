defmodule ForemanServer.Aggregates.RunBaseBranchTest do
  @moduledoc """
  `run.record_base_branch` carries the base commit SHA.

  The SHA is the commit the base branch pointed at when the run worktree was
  cut (`RunBaseBranchRecorded.base_sha`). It is optional: a producer that could
  not resolve a commit omits it, and the event must stay decodable rather than
  storing `nil` (AGENTS.md §5.3 — absent is not malformed). A present value has
  to be a binary, or it would blow up `EventCodec` at the boundary.
  """
  use ExUnit.Case, async: true

  alias ForemanServer.Aggregates.Run

  @run_id "run-1"

  defp started do
    {:ok, spec} =
      Run.handle_command(Run.initial_state(), %{
        type: "run.start",
        payload: %{
          run_id: @run_id,
          task_id: "task-1",
          project_id: "project-1",
          workflow_snapshot: %{}
        }
      })

    Run.apply_event(Run.initial_state(), %{event_type: spec.event_type, payload: spec.payload})
  end

  defp record(payload),
    do: Run.handle_command(started(), %{type: "run.record_base_branch", payload: payload})

  test "a resolved SHA rides along into the event payload" do
    assert {:ok, event} =
             record(%{run_id: @run_id, base_branch: "dev", base_sha: "abc1234def5678"})

    assert event.event_type == "RunBaseBranchRecorded"
    assert event.payload.base_sha == "abc1234def5678"
  end

  test "an unresolved SHA stays absent, never nil" do
    assert {:ok, event} = record(%{run_id: @run_id, base_branch: "dev"})
    refute Map.has_key?(event.payload, :base_sha)
    refute Map.has_key?(event.payload, "base_sha")
  end

  test "a non-binary SHA is refused rather than written into the stream" do
    assert {:error, {:missing_or_invalid, :base_sha, 7}} =
             record(%{run_id: @run_id, base_branch: "dev", base_sha: 7})
  end

  test "a malformed repo_id is refused rather than dropped into the primary" do
    assert {:error, {:missing_or_invalid, :repo_id, 7}} =
             record(%{run_id: @run_id, base_branch: "dev", repo_id: 7})
  end

  test "the payload carries only declared RunBaseBranchRecorded fields" do
    assert {:ok, event} =
             record(%{
               run_id: @run_id,
               base_branch: "dev",
               base_sha: "abc1234def5678",
               repo_id: "api"
             })

    # EventCodec.decode!/2 raises on any key the event struct does not declare.
    assert %ForemanServer.Events.RunBaseBranchRecorded{} =
             ForemanServer.EventCodec.decode!("RunBaseBranchRecorded", event.payload)
  end

  test "a string-keyed SHA is normalised, not duplicated in two forms" do
    assert {:ok, event} =
             record(%{"run_id" => @run_id, "base_branch" => "dev", "base_sha" => "abc1234"})

    assert %ForemanServer.Events.RunBaseBranchRecorded{base_sha: "abc1234"} =
             ForemanServer.EventCodec.decode!("RunBaseBranchRecorded", event.payload)
  end

  test "a base_sha-only mutation without a branch is still refused" do
    assert {:error, {:missing_or_invalid, :base_branch}} =
             record(%{run_id: @run_id, base_sha: "abc1234def5678"})
  end
end
